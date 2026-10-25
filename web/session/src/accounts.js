/** Browser account controls. Credentials and workspace authority stay at the Rust edge. */
export class Accounts {
  constructor({ fetch = globalThis.fetch.bind(globalThis), location = globalThis.location, later = fn => setTimeout(fn, 60) } = {}) {
    this.fetch = fetch;
    this.location = location;
    this.later = later;
    this.csrf = null;
    this.installUrl = null;
    this.landing = ["rayde.org", "www.rayde.org"].includes(new URL(location?.href ?? "http://localhost").hostname);
  }

  async api(path, body) {
    const response = await this.fetch(path, {
      credentials: "same-origin",
      method: body === undefined ? "GET" : "POST",
      headers: body === undefined ? {} : { "Content-Type": "application/json", "X-RayDE-CSRF": this.csrf ?? "" },
      ...(body === undefined ? {} : { body: JSON.stringify(body) }),
    });
    if (response.status === 401 && path === "/api/session") return { user: null };
    if (!response.headers.get("Content-Type")?.includes("application/json")) throw new Error("Connect this editor to the workspace service to sign in.");
    const reply = await response.json();
    if (!response.ok) throw new Error(reply.message ?? "The workspace request failed.");
    return reply;
  }

  async request(op, params) {
    if (op === "account.status") {
      if (this.landing) return { user: null, installable: false };
      const session = await this.api("/api/session");
      this.csrf = session.csrf ?? null;
      this.installUrl = session.installUrl ?? null;
      return { user: session.user, installable: !!this.installUrl };
    }
    if (op === "account.repositories") return this.api("/api/repositories" + (params.cursor ? "?cursor=" + encodeURIComponent(params.cursor) : ""));
    if (op === "account.open") return this.api("/api/workspaces/open", { repository: params.repository });
    if (op === "account.workspace") return this.api("/api/workspaces/" + encodeURIComponent(params.workspace));
    if (op === "account.signin") { this.later(() => this.location.assign(this.landing ? "https://app.rayde.org/auth/github/start" : "/auth/github/start")); return {}; }
    if (op === "account.install") {
      const url = new URL(this.installUrl ?? "https://github.com");
      if (!this.installUrl || url.origin !== "https://github.com" || !url.pathname.startsWith("/apps/")) throw new Error("The GitHub App is not configured.");
      this.later(() => this.location.assign(url.href)); return {};
    }
    if (op === "account.signout") {
      await this.api("/api/logout", {});
      this.csrf = null;
      this.later(() => this.location.assign(this.location.origin)); return {};
    }
    if (op === "account.connect") {
      if (!/^[\w-]{43}$/.test(params.workspace)) throw new Error("Choose a repository workspace.");
      const url = new URL("/" + params.workspace, this.location.origin);
      this.later(() => this.location.assign(url.href)); return {};
    }
    throw new Error("Unknown account request.");
  }
}
