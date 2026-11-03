//! Hibernating change notices; document durability remains owned by the journal exchange.
use super::*;
use crate::{
    sync::SyncWorkspaceSession,
    sync_documents::{Documents, Head},
};
use rayde_sync::gateway::SyncWorkspace;
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};

const MAX_CONNECTIONS: usize = 32;
const MAX_DOCUMENTS: usize = 256;
const MAX_TOTAL_DOCUMENTS: usize = 512;
const MAX_BYTES: usize = 64 * 1024;
const ACK_MS: u64 = 60_000;
#[derive(Clone, Serialize, Deserialize)]
struct Attachment {
    id: String,
    owner: String,
    workspace: String,
    expires: u64,
    acl: u64,
    sid: Option<String>,
    issued: Option<u64>,
    deadline: Option<u64>,
    #[serde(default)]
    closed: bool,
}
#[derive(Clone, Serialize, Deserialize)]
struct Subscription {
    lineage: String,
    accepted: u64,
    offered: Option<u64>,
    since: u64,
}
#[derive(Default, Serialize, Deserialize)]
struct Record {
    documents: BTreeMap<String, Subscription>,
    window: u64,
    messages: u32,
    bytes: usize,
}
fn key(id: &str) -> String {
    format!("sync-watch:{id}")
}
const INDEX: &str = "sync-watches:v1";
impl SyncWorkspaceSession {
    async fn watch_prune(&self) -> AppResult<()> {
        let active: BTreeSet<String> = self
            .state
            .get_websockets()
            .iter()
            .filter_map(|ws| {
                self.watch_attachment(ws)
                    .ok()
                    .filter(|a| !a.closed)
                    .map(|a| a.id)
            })
            .collect();
        let mut ids = self
            .state
            .storage()
            .get::<BTreeSet<String>>(INDEX)
            .await?
            .unwrap_or_default();
        if ids.len() > MAX_CONNECTIONS + 1 {
            return Err(bad(503, "Cloud Sync subscriptions are unavailable."));
        }
        for id in ids.clone() {
            if !active.contains(&id) {
                self.state.storage().delete(&key(&id)).await?;
                ids.remove(&id);
            }
        }
        self.state.storage().put(INDEX, ids).await?;
        Ok(())
    }
    fn watch_attachment(&self, ws: &WebSocket) -> AppResult<Attachment> {
        ws.deserialize_attachment()?
            .ok_or_else(|| bad(401, "Reconnect to Cloud Sync."))
    }
    async fn watch_valid(&self, a: &Attachment) -> AppResult<SyncWorkspace> {
        let workspace: SyncWorkspace = self
            .state
            .storage()
            .get("ws")
            .await?
            .ok_or_else(|| bad(404, "No such synced workspace."))?;
        let revoked = self.state.storage().get::<u64>("sync-access-after").await?;
        if a.closed
            || a.expires <= now()
            || workspace.expiry.is_expired(now())
            || workspace.id.as_str() != a.workspace
            || workspace.owner.as_str() != a.owner
            || workspace.acl_version != a.acl
            || a.issued
                .is_some_and(|issued| revoked.is_some_and(|revoked| issued <= revoked))
        {
            return Err(bad(401, "Cloud Sync access expired. Reopen the workspace."));
        }
        if let Some(sid) = &a.sid {
            let session = rpc(&self.env, "ACCOUNTS", sid, "sync-valid", &json!({})).await?;
            if session["owner"].as_str() != Some(&a.owner) {
                return Err(bad(401, "Cloud Sync access expired. Reopen the workspace."));
            }
        }
        Ok(workspace)
    }
    pub(crate) async fn watch_open(
        &self,
        req: &Request,
        workspace: &SyncWorkspace,
    ) -> AppResult<Response> {
        self.watch_prune().await?;
        if req.headers().get("Upgrade")?.as_deref() != Some("websocket") {
            return Err(bad(426, "Open a Cloud Sync socket."));
        }
        if self
            .state
            .get_websockets()
            .iter()
            .filter(|ws| self.watch_attachment(ws).is_ok_and(|a| !a.closed))
            .count()
            >= MAX_CONNECTIONS
        {
            return Err(bad(429, "Too many Cloud Sync connections."));
        }
        let expires = req
            .headers()
            .get("X-Sync-Expires")?
            .and_then(|v| v.parse::<u64>().ok())
            .filter(|expires| *expires > now() && *expires <= now() + 8 * 60 * 60 * 1000)
            .ok_or_else(|| bad(401, "Sign in to continue."))?;
        let attachment = Attachment {
            id: random()?,
            owner: workspace.owner.as_str().into(),
            workspace: workspace.id.as_str().into(),
            expires,
            acl: workspace.acl_version,
            sid: req.headers().get("X-Sync-Session")?,
            issued: req
                .headers()
                .get("X-Sync-Issued")?
                .and_then(|v| v.parse().ok()),
            deadline: None,
            closed: false,
        };
        self.watch_valid(&attachment).await?;
        let pair = WebSocketPair::new()?;
        let mut ids = self
            .state
            .storage()
            .get::<BTreeSet<String>>(INDEX)
            .await?
            .unwrap_or_default();
        ids.insert(attachment.id.clone());
        let mut values = BTreeMap::new();
        values.insert(INDEX.into(), json!(ids));
        values.insert(key(&attachment.id), json!(Record::default()));
        crate::checkpoints::put(&self.state.storage(), values).await?;
        self.state.accept_web_socket(&pair.server);
        pair.server.serialize_attachment(&attachment)?;
        pair.server
            .send(&json!({"ev":"ready","version":1,"workspace":attachment.workspace}))?;
        self.schedule(workspace).await?;
        let due = attachment
            .expires
            .min(workspace.expiry.expires_at.unwrap_or(u64::MAX));
        if self
            .state
            .storage()
            .get_alarm()
            .await?
            .is_none_or(|alarm| alarm > due as i64)
        {
            self.state
                .storage()
                .set_alarm(std::time::Duration::from_millis(
                    due.saturating_sub(now()).max(1),
                ))
                .await?;
        }
        Ok(Response::from_websocket(pair.client)?)
    }
    pub(crate) async fn watch_close(
        &self,
        ws: &WebSocket,
        code: u16,
        reason: &str,
    ) -> AppResult<()> {
        if let Ok(mut a) = self.watch_attachment(ws) {
            if !a.closed {
                a.closed = true;
                ws.serialize_attachment(&a)?;
                let _ = ws.close(Some(code), Some(reason));
            }
            self.state.storage().delete(&key(&a.id)).await?;
            let mut ids = self
                .state
                .storage()
                .get::<BTreeSet<String>>(INDEX)
                .await?
                .unwrap_or_default();
            ids.remove(&a.id);
            self.state.storage().put(INDEX, ids).await?;
        } else {
            let _ = ws.close(Some(code), Some(reason));
        }
        if let Some(workspace) = self.state.storage().get::<SyncWorkspace>("ws").await? {
            self.schedule(&workspace).await?;
        }
        Ok(())
    }
    pub(crate) async fn watch_message(
        &self,
        ws: &WebSocket,
        message: WebSocketIncomingMessage,
    ) -> AppResult<()> {
        let mut attachment = self.watch_attachment(ws)?;
        let workspace = self.watch_valid(&attachment).await?;
        let WebSocketIncomingMessage::String(raw) = message else {
            return Err(bad(400, "Invalid Cloud Sync message."));
        };
        if raw.len() > MAX_BYTES {
            return Err(bad(413, "Cloud Sync message is too large."));
        }
        let data: Value =
            serde_json::from_str(&raw).map_err(|_| bad(400, "Invalid Cloud Sync message."))?;
        let mut record = self
            .state
            .storage()
            .get::<Record>(&key(&attachment.id))
            .await?
            .ok_or_else(|| bad(401, "Reconnect to Cloud Sync."))?;
        let window = now() / 1000;
        if record.window != window {
            record.window = window;
            record.messages = 0;
            record.bytes = 0;
        }
        record.messages += 1;
        record.bytes += raw.len();
        if record.messages > 512 || record.bytes > 128 * 1024 {
            return Err(bad(429, "Cloud Sync messages arrived too quickly."));
        }
        let path = text(&data, "path")?;
        if path.is_empty()
            || rayde_sync::manifest::path_problem(path, &rayde_sync::lifecycle::Limits::default())
                .is_some()
        {
            return Err(bad(400, "Invalid Cloud Sync path."));
        }
        if data["op"] == "unsubscribe" {
            record.documents.remove(path);
        } else {
            let head = Documents::new(self.state.storage()).head(path).await?;
            let lineage = text(&data, "lineage")?;
            if !opaque(lineage) {
                return Err(bad(400, "Invalid Cloud Sync lineage."));
            }
            let Some(head) = head.filter(|head| {
                head.lineage == lineage
                    && data["sequence"]
                        .as_u64()
                        .is_some_and(|sequence| sequence <= head.sequence)
            }) else {
                record.documents.remove(path);
                self.state
                    .storage()
                    .put(&key(&attachment.id), &record)
                    .await?;
                attachment.deadline = record
                    .documents
                    .values()
                    .filter(|s| s.offered.is_some())
                    .map(|s| s.since + ACK_MS)
                    .min();
                ws.serialize_attachment(&attachment)?;
                ws.send(&json!({"ev":"changed","path":path,"lineage":lineage,"retired":true}))?;
                self.schedule(&workspace).await?;
                return Ok(());
            };
            let sequence = data["sequence"]
                .as_u64()
                .filter(|v| *v > 0 && *v <= head.sequence)
                .ok_or_else(|| bad(409, "The document frontier is invalid."))?;
            if data["lineage"].as_str() != Some(&head.lineage) {
                return Err(bad(409, "The document history changed."));
            }
            match data["op"].as_str() {
                Some("subscribe") => {
                    if record.documents.contains_key(path) {
                        return Err(bad(409, "The document is already subscribed."));
                    }
                    let total = self.watch_document_count().await?;
                    if record.documents.len() >= MAX_DOCUMENTS || total >= MAX_TOTAL_DOCUMENTS {
                        return Err(bad(429, "Too many Cloud Sync documents are subscribed."));
                    }
                    record.documents.insert(
                        path.into(),
                        Subscription {
                            lineage: head.lineage,
                            accepted: sequence,
                            offered: None,
                            since: 0,
                        },
                    );
                }
                Some("ack") => {
                    let subscription = record
                        .documents
                        .get_mut(path)
                        .ok_or_else(|| bad(409, "Subscribe before acknowledging."))?;
                    if sequence < subscription.accepted {
                        return Err(bad(409, "The document frontier went backwards."));
                    }
                    subscription.accepted = sequence;
                    if subscription
                        .offered
                        .is_some_and(|offered| sequence >= offered)
                    {
                        subscription.offered = None;
                        subscription.since = 0;
                    }
                }
                _ => return Err(bad(400, "Unknown Cloud Sync operation.")),
            }
        }
        if serde_json::to_vec(&record).unwrap().len() > MAX_BYTES {
            return Err(bad(
                413,
                "Cloud Sync subscriptions exceed their size limit.",
            ));
        }
        self.state
            .storage()
            .put(&key(&attachment.id), &record)
            .await?;
        attachment.deadline = record
            .documents
            .values()
            .filter(|s| s.offered.is_some())
            .map(|s| s.since + ACK_MS)
            .min();
        ws.serialize_attachment(&attachment)?;
        if record.documents.contains_key(path) {
            self.watch_offer(ws, &mut attachment, &mut record, path)
                .await?;
        }
        self.schedule(&workspace).await?;
        Ok(())
    }
    async fn watch_document_count(&self) -> AppResult<usize> {
        let mut count = 0;
        for ws in self.state.get_websockets() {
            if let Ok(a) = self.watch_attachment(&ws) {
                if let Some(record) = self.state.storage().get::<Record>(&key(&a.id)).await? {
                    count += record.documents.len();
                }
            }
        }
        Ok(count)
    }
    async fn watch_offer(
        &self,
        ws: &WebSocket,
        a: &mut Attachment,
        record: &mut Record,
        path: &str,
    ) -> AppResult<()> {
        let Some(subscription) = record.documents.get_mut(path) else {
            return Ok(());
        };
        let head = Documents::new(self.state.storage()).head(path).await?;
        let Some(Head {
            lineage, sequence, ..
        }) = head.filter(|head| head.lineage == subscription.lineage)
        else {
            ws.send(
                &json!({"ev":"changed","path":path,"lineage":subscription.lineage,"retired":true}),
            )?;
            record.documents.remove(path);
            self.state.storage().put(&key(&a.id), &record).await?;
            a.deadline = record
                .documents
                .values()
                .filter(|s| s.offered.is_some())
                .map(|s| s.since + ACK_MS)
                .min();
            ws.serialize_attachment(&a)?;
            return Ok(());
        };
        if subscription.offered.is_some() || sequence <= subscription.accepted {
            return Ok(());
        }
        subscription.offered = Some(sequence);
        subscription.since = now();
        a.deadline = record
            .documents
            .values()
            .filter(|s| s.offered.is_some())
            .map(|s| s.since + ACK_MS)
            .min();
        self.state.storage().put(&key(&a.id), &record).await?;
        ws.serialize_attachment(&a)?;
        ws.send(&json!({"ev":"changed","path":path,"lineage":lineage,"sequence":sequence}))?;
        Ok(())
    }
    pub(crate) async fn watch_changed(&self, path: Option<&str>) -> AppResult<()> {
        for ws in self.state.get_websockets() {
            let result = async {
                let mut a = self.watch_attachment(&ws)?;
                self.watch_valid(&a).await?;
                let mut record = self
                    .state
                    .storage()
                    .get::<Record>(&key(&a.id))
                    .await?
                    .ok_or_else(|| bad(401, "Reconnect to Cloud Sync."))?;
                let paths: Vec<String> = record
                    .documents
                    .keys()
                    .filter(|p| path.is_none_or(|path| p.as_str() == path))
                    .cloned()
                    .collect();
                for path in paths {
                    self.watch_offer(&ws, &mut a, &mut record, &path).await?;
                }
                Ok::<_, Failure>(())
            }
            .await;
            if result.is_err() {
                self.watch_close(&ws, 1011, "Reconnect to Cloud Sync")
                    .await?;
            }
        }
        Ok(())
    }
    pub(crate) async fn watch_sweep(&self) -> AppResult<()> {
        for ws in self.state.get_websockets() {
            match self.watch_attachment(&ws) {
                Ok(a) if self.watch_valid(&a).await.is_ok() => {
                    if a.deadline.is_some_and(|deadline| deadline <= now()) {
                        self.watch_close(&ws, 1013, "Cloud Sync acknowledgement expired")
                            .await?;
                    }
                }
                _ => {
                    self.watch_close(&ws, 1008, "Cloud Sync access expired")
                        .await?
                }
            }
        }
        self.watch_prune().await
    }
    pub(crate) fn watch_deadline(&self) -> Option<u64> {
        self.state
            .get_websockets()
            .iter()
            .filter_map(|ws| self.watch_attachment(ws).ok())
            .filter(|a| !a.closed)
            .map(|a| a.expires.min(a.deadline.unwrap_or(u64::MAX)))
            .min()
    }
    pub(crate) async fn watch_disconnect(&self, sid: Option<&str>) -> AppResult<()> {
        for ws in self.state.get_websockets() {
            if sid.is_none_or(|sid| {
                self.watch_attachment(&ws)
                    .is_ok_and(|a| a.sid.as_deref() == Some(sid))
            }) {
                self.watch_close(&ws, 1008, "Cloud Sync access revoked")
                    .await?;
            }
        }
        Ok(())
    }
}
