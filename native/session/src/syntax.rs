//! Bounded snapshot queries complete independently of the connection's ordered mutations.
use crate::{
    error::{Result, SessionError},
    session::Out,
};
use serde_json::{Value, json};
use std::{
    collections::HashMap,
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
    },
};

pub const MAX_SOURCE: usize = 2 * 1024 * 1024;
pub type Complete = Box<dyn FnOnce(Result<Value>) + Send>;

pub trait Syntax: Send + Sync + 'static {
    fn submit(
        &self,
        source: String,
        file: String,
        cancelled: Arc<AtomicBool>,
        complete: Complete,
    ) -> Result<()>;
}

struct Job {
    id: Value,
    cancelled: Arc<AtomicBool>,
    answered: AtomicBool,
}
type Jobs = Arc<Mutex<HashMap<String, Arc<Job>>>>;

pub struct SyntaxJobs {
    backend: Option<Arc<dyn Syntax>>,
    jobs: Jobs,
    out: Out,
}
impl SyntaxJobs {
    pub fn new(backend: Option<Arc<dyn Syntax>>, out: Out) -> Self {
        Self {
            backend,
            jobs: Arc::default(),
            out,
        }
    }
    fn answer(out: &Out, job: &Job, result: Result<Value>) {
        if job.answered.swap(true, Ordering::AcqRel) {
            return;
        }
        let response = match result {
            Ok(Value::Object(mut fields)) => {
                fields.insert("id".into(), job.id.clone());
                fields.insert("ok".into(), Value::Bool(true));
                Value::Object(fields)
            }
            Ok(_) => json!({"id":job.id,"ok":true}),
            Err(e) => json!({"id":job.id,"ok":false,"code":e.code,"message":e.message}),
        };
        out(response.to_string());
    }
    fn stop(&self, job: Arc<Job>) {
        job.cancelled.store(true, Ordering::Release);
        Self::answer(
            &self.out,
            &job,
            Err(SessionError::new("cancelled", "Syntax request cancelled.")),
        );
    }
    pub fn start(&self, request: &Value) -> Result<()> {
        let backend = self.backend.as_ref().ok_or_else(|| {
            SessionError::new("unavailable", "This session has no syntax service.")
        })?;
        let text = |key| {
            request
                .get(key)
                .and_then(Value::as_str)
                .ok_or_else(|| SessionError::new("bad-request", format!("`{key}` must be text.")))
        };
        let (key, source, file) = (text("key")?, text("source")?, text("file")?);
        if key.is_empty() || key.len() > 1024 || file.len() > 4096 {
            return Err(SessionError::new(
                "bad-request",
                "Invalid syntax key or filename.",
            ));
        }
        if source.len() > MAX_SOURCE {
            return Err(SessionError::new(
                "too-large",
                "Source exceeds the syntax limit.",
            ));
        }
        let id = request
            .get("id")
            .filter(|id| !id.is_null())
            .ok_or_else(|| SessionError::new("bad-request", "Syntax queries need an id."))?
            .clone();
        let job = Arc::new(Job {
            id,
            cancelled: Arc::new(AtomicBool::new(false)),
            answered: AtomicBool::new(false),
        });
        let old = {
            let mut jobs = self.jobs.lock().unwrap();
            if jobs.len() >= 4 && !jobs.contains_key(key) {
                return Err(SessionError::new(
                    "busy",
                    "Too many syntax queries are active.",
                ));
            }
            jobs.insert(key.to_string(), job.clone())
        };
        if let Some(old) = old {
            self.stop(old);
        }
        let (jobs, out, key, done_job) = (
            self.jobs.clone(),
            self.out.clone(),
            key.to_string(),
            job.clone(),
        );
        let submitted = backend.submit(
            source.to_string(),
            file.to_string(),
            job.cancelled.clone(),
            Box::new(move |result| {
                let mut active = jobs.lock().unwrap();
                if active
                    .get(&key)
                    .is_some_and(|current| Arc::ptr_eq(current, &done_job))
                {
                    active.remove(&key);
                }
                drop(active);
                Self::answer(&out, &done_job, result);
            }),
        );
        if let Err(error) = submitted {
            let mut jobs = self.jobs.lock().unwrap();
            if jobs
                .get(text("key")?)
                .is_some_and(|current| Arc::ptr_eq(current, &job))
            {
                jobs.remove(text("key")?);
            }
            drop(jobs);
            Self::answer(&self.out, &job, Err(error));
        }
        Ok(())
    }
    pub fn cancel(&self, key: &str) {
        let job = self.jobs.lock().unwrap().remove(key);
        if let Some(job) = job {
            self.stop(job);
        }
    }
    pub fn close(&self) {
        let jobs: Vec<_> = self
            .jobs
            .lock()
            .unwrap()
            .drain()
            .map(|(_, job)| job)
            .collect();
        for job in jobs {
            self.stop(job);
        }
    }
}

impl Drop for SyntaxJobs {
    fn drop(&mut self) {
        self.close();
    }
}

#[cfg(feature = "server")]
pub struct NativeSyntax {
    slots: Arc<tokio::sync::Semaphore>,
}
#[cfg(feature = "server")]
impl NativeSyntax {
    pub fn new() -> Self {
        Self {
            slots: Arc::new(tokio::sync::Semaphore::new(2)),
        }
    }
}
#[cfg(feature = "server")]
impl Syntax for NativeSyntax {
    fn submit(
        &self,
        source: String,
        file: String,
        cancelled: Arc<AtomicBool>,
        complete: Complete,
    ) -> Result<()> {
        let permit = self
            .slots
            .clone()
            .try_acquire_owned()
            .map_err(|_| SessionError::new("busy", "The syntax workers are busy."))?;
        tokio::task::spawn_blocking(move || {
            let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                rayde_syntax::source_tokens(&source, &file, || cancelled.load(Ordering::Acquire))
            }));
            let result = match result {
                Ok(Ok(tokens)) => Ok(json!({"tokens":tokens})),
                Ok(Err(message)) => Err(SessionError::new("syntax-error", message)),
                Err(_) => Err(SessionError::new(
                    "syntax-error",
                    "Syntax processing failed.",
                )),
            };
            drop(permit);
            complete(result);
        });
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[derive(Default)]
    struct Held {
        pending: Mutex<Vec<(Arc<AtomicBool>, Complete)>>,
    }
    impl Syntax for Held {
        fn submit(
            &self,
            _source: String,
            _file: String,
            cancelled: Arc<AtomicBool>,
            complete: Complete,
        ) -> Result<()> {
            self.pending.lock().unwrap().push((cancelled, complete));
            Ok(())
        }
    }
    fn output() -> (Out, Arc<Mutex<Vec<Value>>>) {
        let values = Arc::new(Mutex::new(Vec::new()));
        let copy = values.clone();
        (
            Arc::new(move |text| {
                copy.lock()
                    .unwrap()
                    .push(serde_json::from_str(&text).unwrap())
            }),
            values,
        )
    }
    fn query(id: u64, key: &str) -> Value {
        json!({"id":id,"op":"syntax.highlight","key":key,"file":"config.toml","source":"value = 42"})
    }
    #[test]
    fn cancellation_latest_result_limits_and_close() {
        let held = Arc::new(Held::default());
        let (out, values) = output();
        let jobs = SyntaxJobs::new(Some(held.clone()), out);
        jobs.start(&query(1, "same")).unwrap();
        jobs.start(&query(2, "same")).unwrap();
        let (cancelled, complete) = held.pending.lock().unwrap().remove(0);
        assert!(cancelled.load(Ordering::Acquire));
        complete(Ok(json!({"tokens":[]})));
        assert_eq!(jobs.jobs.lock().unwrap().len(), 1);
        let (_, complete) = held.pending.lock().unwrap().remove(0);
        complete(Ok(json!({"tokens":[]})));
        assert_eq!(jobs.jobs.lock().unwrap().len(), 0);
        let values = values.lock().unwrap();
        assert_eq!(values.len(), 2);
        assert_eq!(values[0]["code"], "cancelled");
        assert_eq!(values[1]["id"], 2);
        drop(values);
        for id in 3..7 {
            jobs.start(&query(id, &id.to_string())).unwrap();
        }
        assert_eq!(jobs.start(&query(7, "fifth")).unwrap_err().code, "busy");
        let mut oversized = query(8, "large");
        oversized["source"] = Value::String("x".repeat(MAX_SOURCE + 1));
        assert_eq!(jobs.start(&oversized).unwrap_err().code, "too-large");
        jobs.close();
        assert!(
            held.pending
                .lock()
                .unwrap()
                .iter()
                .all(|(cancelled, _)| cancelled.load(Ordering::Acquire))
        );
    }
    #[cfg(feature = "server")]
    #[tokio::test]
    async fn pending_syntax_does_not_block_authenticated_filesystem_requests() {
        use crate::{dir_store::DirStore, session::Workspace};
        let dir = tempfile::tempdir().unwrap();
        let state = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("config.toml"), "value = 42").unwrap();
        let workspace = Workspace::new(
            Arc::new(DirStore::with_state_root(dir.path(), state.path()).unwrap()),
            Some("secret".into()),
            None,
            Arc::new(|_| {}),
        );
        let held = Arc::new(Held::default());
        assert!(workspace.set_syntax(held.clone()));
        let (out, values) = output();
        let mut connection = workspace.connect(out).unwrap();
        connection.handle(&query(1, "job").to_string()).await;
        assert_eq!(values.lock().unwrap()[0]["code"], "unauthorised");
        assert!(held.pending.lock().unwrap().is_empty());
        connection
            .handle(&json!({"id":2,"op":"hello","token":"secret"}).to_string())
            .await;
        assert_eq!(values.lock().unwrap()[1]["syntax"], true);
        connection.handle(&query(3, "job").to_string()).await;
        connection
            .handle(&json!({"id":4,"op":"fs.stat","path":"config.toml"}).to_string())
            .await;
        assert_eq!(values.lock().unwrap().last().unwrap()["id"], 4);
        let (_, complete) = held.pending.lock().unwrap().remove(0);
        complete(Ok(json!({"tokens":[]})));
        assert_eq!(values.lock().unwrap().last().unwrap()["id"], 3);
        connection.close();
    }
}
