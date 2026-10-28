/** Public landing demos and authenticated workspace pages have separate defaults. */
export function pageEntry(location, connection = null) {
  const url = new URL(location.href), query = url.searchParams;
  const landing = ["rayde.org", "www.rayde.org"].includes(url.hostname);
  const workspace = !landing && /^\/[\w-]{43}$/.test(url.pathname) ? url.pathname.slice(1) : null;
  const socket = workspace ? new URL(`/api/workspaces/${workspace}/socket`, url.origin) : null;
  if (socket) socket.protocol = url.protocol === "https:" ? "wss:" : "ws:";
  const explicit = query.get("session");
  const remembered = !workspace && !explicit && query.get("demo") !== "1" ? connection : null;
  const endpoint = socket?.href ?? explicit ?? remembered?.endpoint ?? null;
  const token = workspace ? undefined : explicit ? new URLSearchParams(url.hash.slice(1)).get("token") : remembered?.token;
  const project = query.get("project") ?? remembered?.project ?? null;
  return { workspace, endpoint, token, project, demo: !endpoint && (query.get("demo") === "1" || landing && query.get("demo") !== "0") };
}
