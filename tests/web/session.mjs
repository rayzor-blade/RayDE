// Full browser editor against a real workspace and supervised extension host.
import { spawn } from "node:child_process";
import { cpSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const workspace = mkdtempSync(join(tmpdir(), "rayde-browser-"));
try {
  cpSync(join(root, "tests/fixtures/browser-session"), workspace, {recursive:true});
  writeFileSync(join(workspace, "large.txt"), "large file: " + "🙂 data\n".repeat(120000));
  const child = spawn(process.execPath, [join(root, "tests/web/page.mjs"), "--probe", "--session-root", workspace,
    "--extension-proof", ...process.argv.slice(2)], {cwd:root, stdio:"inherit"});
  process.exitCode = await new Promise(resolve => child.once("exit", code => resolve(code ?? 1)));
} finally { rmSync(workspace, {recursive:true, force:true}); }
