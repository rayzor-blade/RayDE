// Local mocks only. Production authentication and orchestration are the Rust WASM module.
import { Miniflare, Response } from "miniflare";
import { createHash } from "node:crypto";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import {createConnection} from "node:net";

export const directory = fileURLToPath(new URL("../", import.meta.url));
export const origin = "http://127.0.0.1:8787";
export const json = (body, status = 200) => new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
export const repo = { id: 111, name: "demo", full_name: "alice/demo", private: true, default_branch: "main", clone_url: "https://github.com/alice/demo.git", permissions: { pull: true } };
export async function listening(port,child) {
  const deadline=Date.now()+10000;
  while(Date.now()<deadline) {
    if(child.exitCode!==null || child.signalCode!==null)throw Error("Workspace test server exited before listening");
    const ready=await new Promise(resolve=>{
      const socket=createConnection({host:"127.0.0.1",port});
      socket.once("connect",()=>{socket.destroy();resolve(true);});
      socket.once("error",()=>resolve(false));socket.setTimeout(200,()=>{socket.destroy();resolve(false);});
    });
    if(ready)return;await new Promise(resolve=>setTimeout(resolve,20));
  }
  throw Error("Workspace test server did not start listening");
}
export function options({ persist = false, endpoint = "ws://127.0.0.1:8790/session", asset, port = 0, appOrigin = origin, failProvisionOnce = false, files = true, runnerUrl, runnerSecret = "test-runner-secret" } = {}) {
  const calls = { exchanges: [], runner: [], api: [] };
  const config = {
    modules: true,
    modulesRules: [{ type: "ESModule", include: ["**/*.js"] }, { type: "CompiledWasm", include: ["**/*.wasm"] }],
    scriptPath: resolve(directory, "build/worker/shim.mjs"),
    compatibilityDate: "2026-07-30",
    port,
    host: "127.0.0.1",
    durableObjects: { ACCOUNTS: { className: "AccountSession", useSQLite: true }, WORKSPACES: { className: "WorkspaceSession", useSQLite: true } },
    durableObjectsPersist: persist,
    r2Buckets: files ? ["WORKSPACE_FILES"] : [],
    r2Persist: persist,
    bindings: { LOCAL_DEV: "1", APP_ORIGIN: appOrigin, GITHUB_CLIENT_ID: "test-client", GITHUB_CLIENT_SECRET: "test-client-secret", GITHUB_APP_SLUG: "rayde-test", RUNNER_SECRET: runnerSecret, ...(asset ? { ASSETS_ORIGIN: asset } : {}) },
    serviceBindings: {
      GITHUB: async request => {
        const url = new URL(request.url);
        if (url.pathname === "/login/oauth/access_token") {
          const data = await request.json(); calls.exchanges.push(data);
          if (data.grant_type === "refresh_token") return json({ access_token: "access-alice-refreshed", refresh_token: "refresh-alice-next", expires_in: 28800 });
          return json({ access_token: "access-" + data.code, refresh_token: "refresh-" + data.code, expires_in: data.code === "refresh" ? 0 : 28800 });
        }
        const token = request.headers.get("Authorization");
        const bob = token === "Bearer access-bob";
        calls.api.push({ path: url.pathname, query: url.search, token });
        if (url.pathname === "/user") return json({ id: bob ? 2 : 1, login: bob ? "bob" : "alice", avatar_url: "https://avatars.githubusercontent.com/u/1" });
        if (url.pathname === "/user/installations") return json({ installations: [{ id: 17 }] });
        if (url.pathname === "/user/installations/17/repositories") {
          if (url.searchParams.get("page") === "2") return json({ repositories: [{ ...repo, id: 999, name: "last", full_name: "alice/last" }] });
          return json({ repositories: [repo, ...Array.from({ length: 99 }, (_, i) => ({ ...repo, id: i + 200, name: `project-${i}`, full_name: `alice/project-${i}` }))] });
        }
        if (url.pathname === "/repositories/111") return json(repo);
        return json({ message: "No access" }, 404);
      },
      RUNNER: async request => {
        if (request.headers.get("Authorization") !== "Bearer "+runnerSecret) return json({}, 403);
        const data = await request.json(); calls.runner.push(data);
        if(runnerUrl){
          const response=await fetch(runnerUrl.replace(/\/$/,"")+"/workspaces/open",{method:"POST",headers:{Authorization:"Bearer "+runnerSecret,"Content-Type":"application/json"},body:JSON.stringify(data)});
          return json(await response.json(),response.status);
        }
        if (failProvisionOnce && calls.runner.length === 1) return json({}, 503);
        return json({ url: endpoint, token: "compute-secret", project: "build.hxml" });
      },
    },
  };
  return { config, calls };
}
export async function fixture(settings) {
  const { config, calls } = options(settings);
  const mf = new Miniflare(config);
  try { await mf.ready; } catch (error) { await mf.dispose(); throw error; }
  const fetch = (path, init) => mf.dispatchFetch((settings?.appOrigin ?? origin) + path, init);
  return { mf, fetch, calls };
}
export async function signin(fetch, code = "alice", workspace) {
  const start = await fetch("/auth/github/start" + (workspace ? "?workspace=" + workspace : ""), { redirect: "manual" });
  if (start.status !== 302) throw new Error(`Sign-in start ${start.status}: ${await start.text()}`);
  const location = new URL(start.headers.get("Location"));
  const cookie = start.headers.getSetCookie().map(value => value.split(";")[0]).join("; ");
  const callback = `/auth/github/callback?state=${location.searchParams.get("state")}&code=${code}`;
  const response = await fetch(callback, { headers: { Cookie: cookie }, redirect: "manual" });
  if (response.status !== 302) throw new Error(`Sign-in callback ${response.status}: ${await response.text()}`);
  const sessionCookie = response.headers.getSetCookie().find(value => value.startsWith("rayde_session="));
  const session = await (await fetch("/api/session", { headers: { Cookie: sessionCookie } })).json();
  const headers = { Cookie: sessionCookie, Origin: origin, "X-RayDE-CSRF": session.csrf, "Content-Type": "application/json" };
  return { headers, cookie: sessionCookie, session, callback, oauthCookie: cookie, authorize: location, response };
}
export const challenge = verifier => createHash("sha256").update(verifier).digest("base64url");
