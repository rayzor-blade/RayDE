// Converts the pinned Linguist-derived grammar data; Node is needed only when updating it.
import {createHash} from 'node:crypto';
import {mkdir, readFile, readdir, writeFile, copyFile} from 'node:fs/promises';
import {execFileSync} from 'node:child_process';
import {resolve, join} from 'node:path';
import {pathToFileURL, fileURLToPath} from 'node:url';

const version = '3.11.0';
const sha256 = 'b10291d2f580bc95ee9b4e75a696426f1f9fa0beaed7adb960744633da9ec374';
const root = resolve(fileURLToPath(new URL('..', import.meta.url)));
const cache = join(root, '.deps', `starry-night-${version}`);
await mkdir(cache, {recursive:true});
const archive = join(cache, 'source.tgz');
let bytes;
try { bytes = await readFile(archive); } catch {
  const response = await fetch(`https://registry.npmjs.org/@wooorm/starry-night/-/starry-night-${version}.tgz`);
  if (!response.ok) throw new Error(`Grammar download: ${response.status}`);
  bytes = Buffer.from(await response.arrayBuffer());
}
if (createHash('sha256').update(bytes).digest('hex') !== sha256) throw new Error('Grammar archive checksum mismatch');
await writeFile(archive, bytes);
execFileSync('tar', ['-xzf', archive, '-C', cache]);
const out = join(root, 'native/rayscript/grammars');
const notices = join(root, 'native/rayscript/notices');
await mkdir(out, {recursive:true});
await mkdir(notices, {recursive:true});
const entries = new Map();
for (const filename of (await readdir(join(cache, 'package/lang'))).filter(f => f.endsWith('.js')).sort()) {
  const {default:grammar} = await import(pathToFileURL(join(cache, 'package/lang', filename)));
  if (entries.has(grammar.scopeName)) continue;
  const file = filename.replace(/\.js$/, '.json');
  const extensions = grammar.extensions ?? [];
  const names = grammar.names ?? [];
  const data = {...grammar, fileTypes: extensions.map(ext => ext.replace(/^\./, ''))};
  delete data.names; delete data.extensions;
  await writeFile(join(out, file), JSON.stringify(data) + '\n');
  entries.set(grammar.scopeName, {file, scope:grammar.scopeName, names, extensions});
}
const manifest = {package:'@wooorm/starry-night', version, sha256, grammars:[...entries.values()]};
await writeFile(join(out, 'index.json'), JSON.stringify(manifest, null, 2) + '\n');
await copyFile(join(cache, 'package/license'), join(notices, 'starry-night-LICENSE'));
await copyFile(join(cache, 'package/notice'), join(notices, 'starry-night-NOTICE'));
console.log(`${entries.size} pinned grammar scopes converted`);
