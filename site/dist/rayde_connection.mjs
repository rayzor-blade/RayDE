// src/connection.js
var KEY = "rayde.workspaceConnection.v1";
function connectionSettings(value) {
  if (!value || value.version !== 1) throw new Error("Invalid connection settings.");
  let endpoint = null;
  if (value.endpoint) {
    const url = new URL(value.endpoint);
    if (!["ws:", "wss:"].includes(url.protocol) || url.username || url.password || url.hash) throw new Error("Use a ws:// or wss:// session address.");
    endpoint = url.href;
  }
  const token = value.token ?? "", project = value.project ?? "";
  if (typeof token !== "string" || token.length > 4096 || typeof project !== "string" || project.length > 4096) throw new Error("Invalid workspace settings.");
  const environment = value.environment ?? [];
  if (!Array.isArray(environment) || environment.length > 128 || environment.some((entry) => typeof entry !== "string" || entry.length > 8192 || !/^[A-Za-z_][A-Za-z0-9_]*=/.test(entry) || /[\r\n\0]/.test(entry))) throw new Error("Enter one NAME=value environment variable per line.");
  return { version: 1, endpoint, token, project, environment };
}
function readConnection(storage) {
  try {
    return connectionSettings(JSON.parse((storage ?? globalThis.localStorage).getItem(KEY)));
  } catch {
    return null;
  }
}
function saveConnection(value, storage = globalThis.localStorage) {
  const settings = connectionSettings(value);
  storage.setItem(KEY, JSON.stringify(settings));
  return settings;
}
function clearConnection(storage = globalThis.localStorage) {
  storage.removeItem(KEY);
}
async function previewConnection(location = globalThis.location) {
  if (!["127.0.0.1", "localhost", "[::1]"].includes(location.hostname)) return null;
  try {
    const response = await fetch(new URL("/.well-known/rayde-preview", location.href), { signal: AbortSignal.timeout(3e3) });
    if (response.status !== 200) return null;
    return saveConnection(await response.json());
  } catch {
    return null;
  }
}
export {
  clearConnection,
  connectionSettings,
  previewConnection,
  readConnection,
  saveConnection
};
//# sourceMappingURL=rayde_connection.js.map
