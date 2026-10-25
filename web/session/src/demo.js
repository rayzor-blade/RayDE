// A page over a session: the workspace's files, and a text editor bound to a document. It is the browser client's harness.
import { SessionClient } from "./client.js";

const $ = (id) => document.getElementById(id);
const params = new URLSearchParams(location.hash.slice(1));
const client = new SessionClient({ url: `ws://${location.host}/session`, token: params.get("token") ?? undefined, credential: params.get("credential") ?? undefined });
const demo = (window.demo = { client, doc: null });
let binding = null;

function setStatus() {
  $("status").textContent = client.ready ? "connected" : "offline";
  $("sync").textContent = demo.doc ? (demo.doc.unsent ? "unsent edits" : "saved") : "";
  $("who").textContent = client.identity ? `@${client.identity.login}` : "";
}

async function showFiles() {
  const files = $("files");
  files.replaceChildren();
  for (const entry of (await client.list("")).filter((e) => e.kind === "file")) {
    const button = document.createElement("button");
    button.textContent = entry.name;
    button.dataset.path = entry.name;
    button.onclick = () => openFile(entry.name);
    files.append(button);
  }
}

/** The textarea shows the document and edits it by what changed, so a remote edit does not take over the caret. */
function bind(doc) {
  const editor = $("editor");
  binding?.();
  editor.disabled = false;
  editor.value = doc.text.toString();
  const onInput = () => {
    const before = doc.text.toString(), after = editor.value;
    let start = 0;
    const limit = Math.min(before.length, after.length);
    while (start < limit && before[start] === after[start]) start++;
    let end = 0;
    while (end < limit - start && before[before.length - 1 - end] === after[after.length - 1 - end]) end++;
    doc.ydoc.transact(() => {
      if (before.length - start - end > 0) doc.text.delete(start, before.length - start - end);
      if (after.length - start - end > 0) doc.text.insert(start, after.slice(start, after.length - end));
    }, "editor");
    setStatus();
  };
  const onText = (event) => {
    if (event.transaction.origin === "editor") return;
    const caret = editor.selectionStart;
    editor.value = doc.text.toString();
    editor.setSelectionRange(caret, caret);
  };
  editor.addEventListener("input", onInput);
  doc.text.observe(onText);
  binding = () => {
    editor.removeEventListener("input", onInput);
    doc.text.unobserve(onText);
  };
}

async function openFile(path) {
  if (demo.doc) await demo.doc.close();
  demo.doc = await client.openDoc(path);
  bind(demo.doc);
  demo.doc.onChange(setStatus);
  setStatus();
}
demo.openFile = openFile;

client.on("connected", async (hello) => {
  $("name").textContent = hello.name;
  $("login-link").href = hello.signin ?? "#";
  setStatus();
  await showFiles().catch(() => {});
});
client.on("disconnected", setStatus);
client.on("fs.changed", () => showFiles().catch(() => {}));
client.on("auth-required", ({ login }) => {
  $("signin").classList.add("on");
  if (login) $("login-link").href = login;
});
client.on("signed-in", () => {
  $("signin").classList.remove("on");
  setStatus();
});
$("signin-go").onclick = () => client.login($("credential").value.trim()).catch((error) => alert(error.message));
setInterval(setStatus, 250);
client.connect().catch((error) => ($("status").textContent = error.message));
