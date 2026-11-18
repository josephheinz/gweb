// The minified runtime exports morph (CMS design D8: the page builder morphs a re-rendered region).
import { createRequire } from "node:module";
import { pathToFileURL } from "node:url";
import path from "node:path";
import fs from "node:fs";

const { JSDOM } = createRequire(process.env.JSDOM_DIR + "/")("jsdom");
const dom = new JSDOM("<!doctype html><body><div id=root><p gw-key=a>one</p><p gw-key=b>two</p></div></body>");
globalThis.document = dom.window.document;
globalThis.window = dom.window;
globalThis.Node = dom.window.Node;
globalThis.CustomEvent = dom.window.CustomEvent;
globalThis.addEventListener = () => {};
globalThis.dispatchEvent = () => {};

let failed = 0;
const check = (ok, what) => { if (!ok) { failed++; console.log("FAIL " + what); } };
const client = path.resolve(path.dirname(new URL(import.meta.url).pathname), "../client");
for (const file of ["gwi.js", "gwi.min.js"]) {
  const m = await import(pathToFileURL(path.join(client, file)).href);
  check(typeof m.morph == "function", file + " exports morph");
  const root = document.getElementById("root");
  const b = root.children[1];
  const tpl = document.createElement("template");
  tpl.innerHTML = "<p gw-key=b>two!</p><p gw-key=a>one</p><p gw-key=c>three</p>";
  m.morph(root, tpl.content);
  check(root.innerHTML == "<p gw-key=\"b\">two!</p><p gw-key=\"a\">one</p><p gw-key=\"c\">three</p>", file + " morph result: " + root.innerHTML);
  check(root.children[0] === b, file + " morph keeps the keyed node");
  // The range form (documented in 1.6): only the nodes between start and end change.
  root.innerHTML = "<h1>head</h1><!--s--><p gw-key=a>one</p><p>x</p><!--/s--><p>tail</p>";
  const s = root.childNodes[1], z = root.childNodes[4], a = root.childNodes[2];
  const t2 = document.createElement("template");
  t2.innerHTML = "<p>y</p><p gw-key=a>one!</p>";
  m.morph(root, t2.content, false, s, z);
  check(root.innerHTML == "<h1>head</h1><!--s--><p>y</p><p gw-key=\"a\">one!</p><!--/s--><p>tail</p>", file + " range morph: " + root.innerHTML);
  check(root.childNodes[3] === a, file + " range morph keeps the keyed node");
  check(typeof m.swap == "function", file + " exports swap");
  m.swap(root, "<p>swapped</p>");
  check(root.innerHTML == "<p>swapped</p>", file + " swap: " + root.innerHTML);
  root.innerHTML = "<p gw-key=a>one</p><p gw-key=b>two</p>";
}
check(fs.statSync(path.join(client, "gwi.min.js")).size <= 4096, "gwi.min.js is within 4096 bytes");
console.log(failed ? "morph_export: FAILED" : "morph_export: all passed");
process.exit(failed ? 1 : 0);
