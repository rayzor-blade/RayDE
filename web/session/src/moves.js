import {validDocumentId} from "./recovery.js";

const under = (path,root) => path === root || path.startsWith(root+"/");
function path(value) {
  if (typeof value !== "string" || !value || value.length > 4096 || /[\\\0]/.test(value) || value.split("/").some(part=>!part || part === "." || part === ".."))
    throw new Error("Choose a path inside this workspace.");
  return value;
}
const paused = () => Object.assign(new Error("The move could not be confirmed. Reopen this workspace before continuing; document recovery is kept in this browser."),{code:"document-changed"});

function receipt(reply,from,to,plans) {
  if (!Number.isSafeInteger(reply.revision) || reply.revision < 0 || !Array.isArray(reply.documents) || reply.documents.length > 16384) throw paused();
  const ids = new Map(), targets = new Set();
  for (const row of reply.documents) {
    if (!validDocumentId(row.id) || ids.has(row.id) || !under(path(row.from),from) || path(row.to) !== to+row.from.slice(from.length) || targets.has(row.to)) throw paused();
    ids.set(row.id,row); targets.add(row.to);
  }
  for (const plan of plans) {
    const row = ids.get(plan.doc.documentId);
    if (!row || row.from !== plan.from || row.to !== plan.to) throw paused();
  }
}

/** Native moves remain closed-subscription operations; local replicas and undo owners survive the handoff. */
export async function moveDocuments(client,from,to) {
  from = path(from); to = path(to);
  if (from === to) return {documents:[]};
  if (under(to,from)) throw new Error("A folder cannot be moved into itself.");
  if (!client.ready || client.authenticating || client.invalidated) throw new Error("Reconnect before moving workspace files.");
  const generation = client.generation, workspace = client.workspace;
  const current = () => {
    if (!client.ready || client.generation !== generation || client.workspace !== workspace || client.invalidated) throw paused();
  };
  await Promise.all([...client.docs.values()].filter(doc=>under(doc.path,from)||under(doc.path,to)).map(doc=>doc.started));
  current();
  const plans = [...client.docs.values()].filter(doc=>!doc.closed && under(doc.path,from)).map(doc=>({doc,from:doc.path,to:to+doc.path.slice(from.length)}));
  for (const doc of client.docs.values()) if (!doc.closed && under(doc.path,to) && !plans.some(plan=>plan.doc===doc))
    throw new Error("Close destination documents before moving this path.");
  for (const {doc} of plans) { doc.guard(); if (!validDocumentId(doc.documentId)) throw paused(); }
  const released = []; let attempted = false, committed = false;
  const resume = async items => {
    for (const {doc} of items) if (!doc.closed && !doc.blocked) {
      doc.relocating = false;
      try { await doc.sync(true); }
      catch (error) {
        if (client.ready && !doc.blocked) doc.fence(Object.assign(new Error("Document sync paused after moving: "+error.message),{code:"recovery-failed"}));
      }
    }
  };
  try {
    for (const {doc} of plans) doc.relocating = true;
    for (const {doc} of plans) if (!doc.closed) {
      await Promise.all([...doc.saves]);
      await Promise.all([...doc.pending]);
      await doc.sync(true);
      if (doc.unsent) throw new Error("Wait for document synchronization before moving this path.");
      await doc.checkpoint();
    }
    current();
    for (const plan of plans) if (!plan.doc.closed) {
      plan.doc.suspended = true; released.push(plan);
      await client.request("doc.close",{path:plan.from});
    }
    current(); attempted = true;
    const reply = await client.request("fs.rename",{from,to,preserveDocuments:true});
    current(); receipt(reply,from,to,plans);
    // No await separates the path-map transition from updating each replica's path.
    for (const plan of plans) if (client.docs.get(plan.from) === plan.doc) client.docs.delete(plan.from);
    for (const plan of plans) if (!plan.doc.closed) { plan.doc.path = plan.to; client.docs.set(plan.to,plan.doc); }
    committed = true;
    await resume(plans);
    return reply;
  } catch (error) {
    let unchanged = !attempted;
    if (attempted && client.ready && !client.invalidated && client.generation === generation) {
      try {
        const resolved = await Promise.all(released.map(async plan=>(await client.request("doc.resolve",{documentId:plan.doc.documentId})).path === plan.from));
        unchanged = resolved.length > 0 && resolved.every(Boolean);
      } catch { unchanged = false; }
    }
    if (!unchanged || committed) for (const {doc} of plans) doc.fence(paused());
    else await resume(plans);
    throw error;
  } finally {
    for (const {doc} of plans) doc.relocating = false;
  }
}
