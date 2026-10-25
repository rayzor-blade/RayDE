/** Public landing demos and authenticated workspace pages have separate defaults. */
export function pageEntry(location) {
  const url = new URL(location.href), query = url.searchParams;
  const landing = ["rayde.org", "www.rayde.org"].includes(url.hostname);
  const workspace = !landing && /^\/[\w-]{43}$/.test(url.pathname) ? url.pathname.slice(1) : null;
  const socket = workspace ? new URL(`/api/workspaces/${workspace}/socket`, url.origin) : null;
  if (socket) socket.protocol = url.protocol === "https:" ? "wss:" : "ws:";
  const endpoint = socket?.href ?? query.get("session") ?? null;
  return { workspace, endpoint, demo: !endpoint && (query.get("demo") === "1" || landing && query.get("demo") !== "0") };
}
