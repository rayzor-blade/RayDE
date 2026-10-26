import { marked } from "marked";

/** Convert an inert HTML template to the preview's data model; no source DOM enters the page. */
export function documentation(source) {
  if (typeof source !== "string" || new TextEncoder().encode(source).length > 65536) throw new Error("Documentation exceeds 64 KiB.");
  const template = document.createElement("template");
  template.innerHTML = marked.parse(source, {gfm:true, async:false});
  let count = 0;
  const blocked = new Set(["script","style","iframe","object","embed","template","head","link","meta","base","svg","math"]);
  const inline = new Set(["p","a","strong","b","em","i","s","del","span","u","ins","sub","sup","small","mark","summary","td","th","h1","h2","h3","h4","h5","h6"]);
  const children = (node,depth,flow = false) => Array.from(node.childNodes).flatMap(child => convert(child,depth+1,flow));
  function convert(node,depth,flow) {
    if (++count > 2048 || depth > 64) throw new Error("Documentation is too deeply nested or has too many elements.");
    if (node.nodeType === 3) return !flow && !node.textContent.trim() ? [] : [{kind:"text",text:node.textContent}];
    if (node.nodeType !== 1) return [];
    const tag = node.tagName.toLowerCase();
    if (blocked.has(tag) || node.hasAttribute("hidden") || node.style.display === "none") return [];
    if (tag === "pre") {
      const code = Array.from(node.children).find(child => child.tagName === "CODE") ?? node;
      return [{kind:"code",text:code.textContent.replace(/\n$/, ""),language:Array.from(code.classList).find(name => name.startsWith("language-"))?.slice(9) ?? "",tokens:null}];
    }
    if (tag === "br") return [{kind:"break"}];
    if (tag === "hr") return [{kind:"rule"}];
    if (tag === "img") return [{kind:"text",text:node.getAttribute("alt") ?? ""}];
    if (tag === "input") return node.getAttribute("type") === "checkbox" ? [{kind:"task",checked:node.hasAttribute("checked")}] : [];
    if (tag === "code") return [{kind:"inline-code",text:node.textContent}];
    if (tag === "table") {
      const rows = Array.from(node.children).flatMap(child => child.tagName === "TR" ? [child] : Array.from(child.children).filter(row => row.tagName === "TR"));
      const align = rows.length ? Array.from(rows[0].children).map(cell => cell.getAttribute("align") ?? cell.style.textAlign ?? "") : [];
      return [{kind:"table",align,children:rows.flatMap(row => convert(row,depth+1,false))}];
    }
    const data = {kind:({p:"paragraph",blockquote:"quote",ul:"list",ol:"list",li:"item",strong:"strong",b:"strong",em:"em",i:"em",s:"strike",del:"strike",a:"link",details:"details",summary:"summary",tr:node.parentElement?.tagName === "THEAD" ? "table-head" : "table-row",td:"table-cell",th:"table-cell"})[tag] ?? "group",children:children(node,depth,inline.has(tag))};
    if (/^h[1-6]$/.test(tag)) { data.kind = "heading"; data.level = Number(tag[1]); }
    if (tag === "ol") data.start = Number(node.getAttribute("start") ?? 1);
    if (tag === "details") data.open = node.hasAttribute("open");
    if (tag === "a") {
      const href = node.getAttribute("href") ?? "";
      if (/^(https?:\/\/|mailto:)/i.test(href)) data.href = href;
      else data.kind = "inline";
    }
    if (["u","ins","sub","sup","small","mark"].includes(tag)) { data.kind = "inline"; data.variant = tag; }
    return [data];
  }
  return {kind:"document",children:children(template.content,0)};
}
