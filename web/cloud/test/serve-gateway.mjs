// Runs the Worker locally on a free port, for checks that drive it from outside Node. Prints `READY <url>` and serves until killed.
import { createServer } from "node:net";
import { fixture } from "./fixture.mjs";

const port = await new Promise(done => { const server = createServer().listen(0, "127.0.0.1", () => { const p = server.address().port; server.close(() => done(p)); }); });
const base = `http://127.0.0.1:${port}`;
const host = await fixture({ port, appOrigin: base, persist: process.argv[2] });
console.log(`READY ${base}`);
process.on("SIGTERM", async () => { await host.mf.dispose(); process.exit(0); });
setInterval(() => {}, 1 << 30);
