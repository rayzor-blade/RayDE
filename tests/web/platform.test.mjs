import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { runInNewContext } from "node:vm";
import test from "node:test";

const source = readFileSync(new URL("../../web/platform.js", import.meta.url), "utf8");
function boot({ platform = "MacIntel", data, search = "", standalone = false, embedded = false } = {}) {
  let url;
  const window = { matchMedia: () => ({ matches: standalone }) };
  window.top = embedded ? {} : window;
  runInNewContext(source, { URLSearchParams, navigator: { platform, userAgentData: data }, window,
    location: { search, pathname: "/playground/", hash: "#editor" }, history: { replaceState: (_, __, value) => { url = value; } } });
  return new URL(url, "https://example.test");
}

for (const [platform, expected] of [["MacIntel", "Mac"], ["iPad", "Mac"], ["Win32", "Windows"], ["Linux x86_64", "Linux"]]) {
  test(`fallback platform ${platform}`, () => assert.deepEqual(boot({ platform }).searchParams.getAll("env"), ["RAYDE_VISITOR=" + expected]));
}
test("browser platform data takes precedence over legacy platform", () => {
  assert.deepEqual(boot({ platform: "MacIntel", data: { platform: "Windows" } }).searchParams.getAll("env"), ["RAYDE_VISITOR=Windows"]);
});
test("a shared URL cannot pin another visitor's keyboard", () => {
  const url = boot({ search: "?env=RAYDE_VISITOR=Linux&env=ASH_GC_STATS=1&env=RAYDE_VISITOR=Windows&session=demo" });
  assert.deepEqual(url.searchParams.getAll("env"), ["ASH_GC_STATS=1", "RAYDE_VISITOR=Mac"]);
  assert.equal(url.searchParams.get("session"), "demo");
  assert.equal(url.pathname, "/playground/");
  assert.equal(url.hash, "#editor");
});
test("standalone mode and keyboard are both detected", () => {
  assert.deepEqual(boot({ standalone: true }).searchParams.getAll("env"), ["RAYDE_VISITOR=Mac", "RAYDE_STANDALONE=1"]);
  assert.deepEqual(boot({ standalone: true, embedded: true }).searchParams.getAll("env"), ["RAYDE_VISITOR=Mac"]);
});
