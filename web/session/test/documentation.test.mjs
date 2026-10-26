import test from "node:test";
import assert from "node:assert/strict";
import {createServer} from "node:http";
import {readFileSync,existsSync} from "node:fs";
import puppeteer from "puppeteer-core";

const chrome = process.env.CHROME ?? "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
test("browser documentation retains Markdown structure without live HTML or network effects",{skip:!existsSync(chrome)},async t => {
  const requests = [];
  const server = createServer((request,response) => {
    requests.push(request.url);
    response.setHeader("Content-Type",request.url === "/documentation.js" ? "text/javascript" : "text/html");
    response.end(request.url === "/documentation.js" ? readFileSync(new URL("../dist/documentation.js",import.meta.url)) : "<!doctype html><title>Documentation test</title>");
  });
  await new Promise(resolve => server.listen(0,"127.0.0.1",resolve)); t.after(() => server.close());
  const browser = await puppeteer.launch({executablePath:chrome,headless:true,args:["--no-sandbox"]}); t.after(() => browser.close());
  const page = await browser.newPage(); await page.goto(`http://127.0.0.1:${server.address().port}/`);
  const result = await page.evaluate(async () => {
    const {documentation} = await import("/documentation.js");
    const source = '# Title\n\n**bold** *em* and `code` &amp; λ😀\n\n```haxe\nclass Main {}\n```\n\n- [x] done\n- next\n\n| Name | Value |\n|:--|--:|\n| a | b |\n\n[Docs](https://haxe.org) [bad](javascript:alert(1))\n\n<details open><summary>More</summary><p>HTML</p></details>\n\n<script>globalThis.executed = true;fetch("/should-not-fetch-script")</script><style>@import "/should-not-fetch-style";</style><iframe src="/should-not-fetch-frame"></iframe><img src="/should-not-fetch-image" onerror="globalThis.executed=true" alt="picture">';
    const doc = documentation(source), nodes = [];
    function visit(node) { nodes.push(node); for (const child of node.children ?? []) visit(child); }
    visit(doc);
    const errors = [];
    for (const text of ["😀".repeat(20000),"<div>".repeat(100)+"nested"+"</div>".repeat(100),"- item\n".repeat(3000)]) {
      try { documentation(text); errors.push(null); } catch (error) { errors.push(error.message); }
    }
    return {doc,nodes,errors,executed:globalThis.executed ?? false,mounted:document.body.children.length};
  });
  assert.ok(result.nodes.some(node => node.kind === "heading" && node.level === 1));
  for (const kind of ["strong","em","inline-code","task","table","details","summary"]) assert.ok(result.nodes.some(node => node.kind === kind),kind);
  assert.ok(result.nodes.some(node => node.kind === "code" && node.language === "haxe" && node.text === "class Main {}"));
  assert.deepEqual(result.nodes.find(node => node.kind === "table").align,["left","right"]);
  assert.ok(result.nodes.some(node => node.kind === "link" && node.href === "https://haxe.org"));
  assert.ok(!JSON.stringify(result.doc).includes("javascript:"));
  assert.equal(result.executed,false); assert.equal(result.mounted,0);
  assert.ok(result.errors.every(Boolean));
  await new Promise(resolve => setTimeout(resolve,150));
  assert.ok(!requests.some(path => path.startsWith("/should-not-fetch")),"inert markup must not fetch remote resources");
});
