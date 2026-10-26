import { build } from "esbuild";
import { copyFileSync, mkdirSync } from "node:fs";

mkdirSync("dist", { recursive: true });
await build({ entryPoints: { "session-client": "src/client.js", documentation: "src/documentation.js", demo: "src/demo.js", rayde_session: "src/agent.js" }, external: ["./channel-agent.mjs"], bundle: true, format: "esm", target: "es2022", outdir: "dist", sourcemap: true, minify: false });
copyFileSync("src/index.html", "dist/index.html");
