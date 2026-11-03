/** Browser account controls. Credentials and workspace authority stay at the Rust edge. */
export class Accounts {
  constructor({ fetch = globalThis.fetch.bind(globalThis), location = globalThis.location, later = fn => setTimeout(fn, 60), pause = ms => new Promise(resolve => setTimeout(resolve,ms)), timeout = 15000,
    open = (...args) => globalThis.open(...args), broadcast = name => new BroadcastChannel(name), authTimeout = 600000 } = {}) {
    this.fetch = fetch;
    this.location = location;
    this.later = later;
    this.pause = pause;
    this.timeout = timeout;
    this.open = open;
    this.broadcast = broadcast;
    this.authTimeout = authTimeout;
    this.signin = null;
    this.csrf = null;
    this.installUrl = null;
    this.landing = ["rayde.org", "www.rayde.org"].includes(new URL(location?.href ?? "http://localhost").hostname);
  }

  signIn() {
    if (this.signin) return this.signin.promise;
    const channel = Array.from(crypto.getRandomValues(new Uint8Array(32)), byte => byte.toString(16).padStart(2,"0")).join("");
    const notifications = this.broadcast("rayde-auth:" + channel);
    let popup, timer, finish, settled=false, checking=false;
    const promise = new Promise((resolve,reject) => {
      finish = (error, result) => {
        if (settled) return;
        settled = true;
        clearTimeout(timer); notifications.close(); this.signin = null;
        if (error) reject(error); else resolve(result);
      };
      notifications.onmessage = async event => {
        if (settled || checking || event.data?.type !== "rayde-auth-complete" || event.data.channel !== channel) return;
        if (event.data.status !== "success") { finish(new Error("GitHub sign-in was not completed. Try again.")); return; }
        checking = true;
        try {
          const result = await this.request("account.status",{});
          if (!result.user) throw new Error("GitHub sign-in was not completed. Try again.");
          finish(null,result);
        } catch (error) { finish(error); }
      };
    });
    this.signin = {promise,cancel:() => { try { popup?.close(); } catch {} finish(new Error("GitHub sign-in was cancelled.")); }};
    timer = setTimeout(() => finish(new Error("GitHub sign-in timed out. Try again.")),this.authTimeout);
    try {
      popup = this.open("/auth/github/start?popup=" + channel,"_blank","popup,width=560,height=760");
      if (!popup) finish(new Error("Allow the GitHub sign-in window, then try again."));
    } catch (error) { finish(error); }
    return promise;
  }

  async api(path, body, timeout = this.timeout) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(),timeout);
    try {
      const response = await this.fetch(path, {
        signal: controller.signal,
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
    } catch (error) {
      if (controller.signal.aborted) throw new Error("The workspace service did not respond. Try again.");
      throw error;
    } finally {
      clearTimeout(timer);
    }
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
    if (op === "account.create") {
      if (!/^[a-f0-9]{64}$/.test(params.key)) throw new Error("Invalid project request.");
      return this.api("/api/projects/create/" + params.key, params.project, 150000);
    }
    if (op === "account.open") return this.api("/api/workspaces/open", { repository: params.repository });
    if (op === "account.workspace") return this.api("/api/workspaces/" + encodeURIComponent(params.workspace));
    if (op === "account.sync-reopen") {
      if (!/^[\w-]{43}$/.test(params.workspace)) throw new Error("Choose a synced workspace.");
      await this.request("account.status", {});
      let workspace=await this.api("/api/sync/workspaces/" + params.workspace + "/open", {});
      for (let attempt=0; workspace.status==="preparing" && attempt<100; attempt++) {
        await this.pause(100);
        workspace=await this.request("account.workspace",params);
      }
      if (workspace.status!=="ready") throw new Error(workspace.message??"The workspace is still starting. Try reopening again.");
      return workspace;
    }
    if (op === "account.signin") {
      if (this.landing) { this.later(() => this.location.assign("https://app.rayde.org/auth/github/start")); return {}; }
      return this.signIn();
    }
    if (op === "account.cancel-signin") { this.signin?.cancel(); return {}; }
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
