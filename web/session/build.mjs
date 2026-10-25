import { build } from "esbuild";
import { copyFileSync, mkdirSync } from "node:fs";

mkdirSync("dist", { recursive: true });
await build({ entryPoints: { "session-client": "src/client.js", demo: "src/demo.js" }, bundle: true, format: "esm", target: "es2022", outdir: "dist", sourcemap: true, minify: false });
copyFileSync("src/index.html", "dist/index.html");
