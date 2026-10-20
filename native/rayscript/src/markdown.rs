//! Markdown parsing and vector rendering stay on the extension's owning thread.
use latex_rust::{MathFont, SvgOptions};
use pulldown_cmark::{Options, Parser};
use rayscript_vm::{Value, Vm};
use scraper::{ElementRef, Html, Node};
use serde_json::{Value as Json, json};
use std::{cell::RefCell, collections::HashSet, rc::Rc};

struct Renderer {
    font: MathFont,
}

impl Renderer {
    fn new() -> Result<Self, String> {
        Ok(Self {
            font: MathFont::stix_two_math().map_err(|e| e.to_string())?,
        })
    }

    fn math(&self, source: &str, display: bool) -> Json {
        let options = SvgOptions {
            display,
            font_size_pt: latex_rust::Dim::from_i64(16),
            ..SvgOptions::new()
        };
        match latex_rust::latex_to_svg(source, &self.font, &options) {
            Ok(svg) => json!({"kind":"math", "text":source, "display":display,
                "svg":svg.replace("#000000", "currentColor")}),
            Err(error) => json!({"kind":"error", "text":format!("Math: {error}"), "source":source}),
        }
    }

    fn code(&self, source: &str, info: &str) -> Json {
        let language = info.split_whitespace().next().unwrap_or("").to_lowercase();
        if language == "mermaid" {
            if source.len() > 32_768 || source.lines().count() > 500 {
                return json!({"kind":"error", "text":"Mermaid diagram exceeds 32 KiB or 500 lines", "source":source});
            }
            if !mermaid_header(source) {
                return json!({"kind":"error", "text":"Mermaid: expected a supported diagram declaration", "source":source});
            }
            return match std::panic::catch_unwind(|| {
                let mut light_theme = mermaid_rs_renderer::Theme::modern();
                let mut dark_theme = mermaid_rs_renderer::Theme::dark();
                for theme in [&mut light_theme, &mut dark_theme] {
                    theme.font_family = "Arial".into();
                    theme.background = "transparent".into();
                }
                let light = mermaid_rs_renderer::render_strict(
                    source,
                    mermaid_rs_renderer::RenderOptions {
                        theme: light_theme,
                        ..Default::default()
                    },
                )
                .map_err(|e| e.to_string())?;
                let dark = mermaid_rs_renderer::render_strict(
                    source,
                    mermaid_rs_renderer::RenderOptions {
                        theme: dark_theme,
                        ..Default::default()
                    },
                )
                .map_err(|e| e.to_string())?;
                Ok::<_, String>((light, dark))
            }) {
                Ok(Ok((svg, dark))) => {
                    json!({"kind":"diagram", "svg":svg, "darkSvg":dark, "text":source})
                }
                Ok(Err(error)) => {
                    json!({"kind":"error", "text":format!("Mermaid: {error}"), "source":source})
                }
                Err(_) => {
                    json!({"kind":"error", "text":"Mermaid rendering failed", "source":source})
                }
            };
        }
        if language == "math" || language == "latex" {
            return self.math(source, true);
        }
        super::syntax::highlight(source, &language)
    }

    fn parse(&self, source: &str) -> Result<Json, String> {
        if source.len() > 2 * 1024 * 1024 {
            return Err("Markdown preview is limited to 2 MiB".into());
        }
        let options = Options::ENABLE_TABLES
            | Options::ENABLE_FOOTNOTES
            | Options::ENABLE_STRIKETHROUGH
            | Options::ENABLE_TASKLISTS
            | Options::ENABLE_MATH
            | Options::ENABLE_GFM;
        let mut markup = String::new();
        pulldown_cmark::html::push_html(&mut markup, Parser::new_ext(source, options));
        let document = Html::parse_fragment(&markup);
        let children = self.html_children(document.root_element(), &mut HashSet::new(), 0)?;
        Ok(json!({"kind":"document", "children":children}))
    }

    fn html_children(
        &self,
        element: ElementRef<'_>,
        headings: &mut HashSet<String>,
        depth: usize,
    ) -> Result<Vec<Json>, String> {
        if depth > 128 {
            return Err("Markdown/HTML nesting exceeds 128 levels".into());
        }
        let keep_spaces = matches!(
            element.value().name(),
            "p" | "h1"
                | "h2"
                | "h3"
                | "h4"
                | "h5"
                | "h6"
                | "a"
                | "span"
                | "strong"
                | "b"
                | "em"
                | "i"
                | "s"
                | "del"
                | "strike"
                | "li"
                | "td"
                | "th"
                | "summary"
                | "small"
                | "sub"
                | "sup"
                | "mark"
                | "u"
                | "ins"
                | "q"
        );
        let mut children = Vec::new();
        for child in element.children() {
            match child.value() {
                Node::Text(value) if keep_spaces || !value.trim().is_empty() => {
                    children.push(json!({"kind":"text", "text":value.to_string()}))
                }
                Node::Element(_) => children.extend(self.html_element(
                    ElementRef::wrap(child).unwrap(),
                    headings,
                    depth + 1,
                )?),
                _ => {}
            }
        }
        Ok(children)
    }

    fn html_element(
        &self,
        element: ElementRef<'_>,
        headings: &mut HashSet<String>,
        depth: usize,
    ) -> Result<Vec<Json>, String> {
        let tag = element.value().name();
        let style = styles(element.attr("style").unwrap_or(""));
        if matches!(
            tag,
            "script"
                | "style"
                | "iframe"
                | "object"
                | "embed"
                | "template"
                | "head"
                | "link"
                | "meta"
                | "base"
                | "svg"
                | "math"
        ) || element.attr("hidden").is_some()
            || style.get("display").is_some_and(|s| s == "none")
        {
            return Ok(Vec::new());
        }
        let classes: Vec<_> = element.value().classes().collect();
        let content = || element.text().collect::<String>();
        if tag == "pre" {
            let code = element
                .child_elements()
                .find(|e| e.value().name() == "code")
                .unwrap_or(element);
            let language = code
                .value()
                .classes()
                .find_map(|c| c.strip_prefix("language-"))
                .unwrap_or("");
            return Ok(vec![self.code(&code.text().collect::<String>(), language)]);
        }
        if tag == "span" && classes.contains(&"math") {
            return Ok(vec![
                self.math(&content(), classes.contains(&"math-display")),
            ]);
        }
        if classes.contains(&"footnote-definition-label") {
            return Ok(Vec::new());
        }
        let children = self.html_children(element, headings, depth)?;
        self.html_node(element, children, headings)
    }

    // Keep node construction outside the recursive traversal's stack frame.
    #[inline(never)]
    fn html_node(
        &self,
        element: ElementRef<'_>,
        children: Vec<Json>,
        headings: &mut HashSet<String>,
    ) -> Result<Vec<Json>, String> {
        let tag = element.value().name();
        let style = styles(element.attr("style").unwrap_or(""));
        let classes: Vec<_> = element.value().classes().collect();
        let content = || element.text().collect::<String>();
        let mut node = match tag {
            "p" => json!({"kind":"paragraph"}),
            "h1" | "h2" | "h3" | "h4" | "h5" | "h6" => {
                json!({"kind":"heading", "level":tag.as_bytes()[1]-b'0'})
            }
            "strong" | "b" => json!({"kind":"strong"}),
            "em" | "i" | "cite" | "dfn" => json!({"kind":"em"}),
            "s" | "del" | "strike" => json!({"kind":"strike"}),
            "span" | "small" | "sub" | "sup" | "mark" | "u" | "ins" | "abbr" | "q" => {
                json!({"kind":"inline", "variant":tag})
            }
            "code" | "kbd" | "samp" => json!({"kind":"inline-code", "text":content()}),
            "a" => json!({"kind":"link", "href":element.attr("href").unwrap_or("")}),
            "img" => {
                json!({"kind":"image", "href":element.attr("src").unwrap_or(""), "text":element.attr("alt").unwrap_or("")})
            }
            "br" => json!({"kind":"break"}),
            "hr" => json!({"kind":"rule"}),
            "blockquote" => json!({"kind":"quote"}),
            "ul" | "ol" => {
                json!({"kind":"list", "start":if tag == "ol" {Some(element.attr("start").and_then(|s| s.parse::<u64>().ok()).unwrap_or(1))} else {None}})
            }
            "li" => json!({"kind":"item"}),
            "table" => json!({"kind":"table"}),
            "tr" => {
                json!({"kind":if element.child_elements().any(|e| e.value().name() == "th") {"table-head"} else {"table-row"}})
            }
            "th" | "td" => json!({"kind":"table-cell"}),
            "details" => json!({"kind":"details", "open":element.attr("open").is_some()}),
            "summary" => json!({"kind":"summary"}),
            "input"
                if element
                    .attr("type")
                    .is_some_and(|t| t.eq_ignore_ascii_case("checkbox")) =>
            {
                json!({"kind":"task", "checked":element.attr("checked").is_some()})
            }
            "input" | "button" | "textarea" | "select" => return Ok(Vec::new()),
            "thead" | "tbody" | "tfoot" | "html" | "body" => return Ok(children),
            _ if classes.contains(&"footnote-definition") => json!({"kind":"footnote"}),
            _ => json!({"kind":"group"}),
        };
        node["children"] = json!(children);
        node["htmlTag"] = json!(tag);
        if let Some(id) = element.attr("id").or_else(|| {
            if tag == "a" {
                element.attr("name")
            } else {
                None
            }
        }) {
            node["id"] = json!(id);
        }
        if node["kind"] == "heading" {
            let base = node["id"].as_str().map(str::to_owned).unwrap_or_else(|| {
                plain(&node)
                    .to_lowercase()
                    .chars()
                    .filter_map(|c| {
                        if c.is_whitespace() {
                            Some('-')
                        } else if c.is_alphanumeric() || c == '-' || c == '_' {
                            Some(c)
                        } else {
                            None
                        }
                    })
                    .collect()
            });
            let mut id = base.clone();
            let mut suffix = 0;
            while !headings.insert(id.clone()) {
                suffix += 1;
                id = format!("{base}-{suffix}");
            }
            node["id"] = json!(id);
        }
        if tag == "sup" && classes.contains(&"footnote-reference") {
            if let Some(parts) = node["children"].as_array_mut() {
                for part in parts {
                    if let Some(id) = part["href"].as_str().and_then(|s| s.strip_prefix('#')) {
                        part["href"] = json!(format!("#footnote-{id}"));
                    }
                }
            }
        }
        if let Some(align) = style
            .get("text-align")
            .map(String::as_str)
            .or_else(|| element.attr("align"))
        {
            let align = align.to_ascii_lowercase();
            if matches!(align.as_str(), "left" | "center" | "right" | "justify") {
                node["textAlign"] = json!(align);
            }
        }
        if tag == "img" {
            for key in ["width", "height"] {
                if let Some(value) = style
                    .get(key)
                    .map(String::as_str)
                    .or_else(|| element.attr(key))
                {
                    if let Some((amount, percent)) = dimension(value) {
                        node[if percent {
                            format!("{key}Percent")
                        } else {
                            key.into()
                        }] = json!(amount);
                    }
                }
            }
        }
        if let Some(title) = element.attr("title") {
            node["title"] = json!(title);
        }
        Ok(vec![node])
    }
}

fn mermaid_header(source: &str) -> bool {
    let mut frontmatter = false;
    for line in source.lines().map(str::trim) {
        if line == "---" {
            frontmatter = !frontmatter;
            continue;
        }
        if frontmatter || line.is_empty() || line.starts_with("%%") {
            continue;
        }
        let token = line
            .split([' ', '\t', ';'])
            .next()
            .unwrap_or("")
            .to_lowercase();
        return [
            "graph",
            "flowchart",
            "sequencediagram",
            "classdiagram",
            "statediagram",
            "erdiagram",
            "pie",
            "mindmap",
            "journey",
            "timeline",
            "gantt",
            "requirementdiagram",
            "gitgraph",
            "c4context",
            "c4container",
            "c4component",
            "c4dynamic",
            "c4deployment",
            "sankey",
            "quadrantchart",
            "zenuml",
            "block",
            "packet",
            "kanban",
            "architecture",
            "radar",
            "treemap",
            "xychart",
        ]
        .iter()
        .any(|name| token == *name || token.starts_with(&format!("{name}-")));
    }
    false
}

fn styles(source: &str) -> std::collections::HashMap<String, String> {
    source
        .split(';')
        .filter_map(|declaration| declaration.split_once(':'))
        .map(|(key, value)| {
            (
                key.trim().to_ascii_lowercase(),
                value.trim().to_ascii_lowercase(),
            )
        })
        .collect()
}

fn dimension(source: &str) -> Option<(f64, bool)> {
    let source = source.trim();
    let percent = source.ends_with('%');
    let amount: f64 = source
        .trim_end_matches('%')
        .trim_end_matches("px")
        .trim()
        .parse()
        .ok()?;
    (amount.is_finite() && amount > 0.0)
        .then_some((amount.min(if percent { 100.0 } else { 2048.0 }), percent))
}

fn plain(node: &Json) -> String {
    if let Some(text) = node["text"].as_str() {
        return text.into();
    }
    node["children"]
        .as_array()
        .map(|nodes| nodes.iter().map(plain).collect())
        .unwrap_or_default()
}

pub fn install(vm: &mut Vm) {
    let renderer: Rc<RefCell<Option<Renderer>>> = Rc::new(RefCell::new(None));
    let render = vm.native(
        "rayde.markdown.render",
        move |vm: &mut Vm, args: &[Value]| {
            let start = std::time::Instant::now();
            let source = args
                .first()
                .and_then(|v| vm.string_of(*v))
                .unwrap_or("")
                .to_owned();
            let mut cache = renderer.borrow_mut();
            if cache.is_none() {
                *cache = Some(Renderer::new().map_err(|e| vm.new_string(&e))?);
            }
            let result = cache
                .as_ref()
                .unwrap()
                .parse(&source)
                .map_err(|e| vm.new_string(&e))?;
            let output = vm.new_string(&result.to_string());
            super::timed(start, "markdown.render", &format!("{} source bytes", source.len()));
            Ok(output)
        },
    );
    let module = vm.new_object();
    vm.set_member(module, "render", render);
    vm.register_module("rayde.markdown", module);
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn html_layout_and_mixed_markdown() {
        let renderer = Renderer::new().unwrap();
        let doc = renderer.parse("<p align=\"center\"><img src=\"logo.svg\" width=\"250\" alt=\"Logo\"></p>\n<h2 align=\"center\">A &amp; B</h2>\n\nMarkdown **strong** with <i>inline HTML</i> and $x^2$.\n\n<details open><summary>More</summary><p>Body</p></details>\n\n<pre><code class=\"language-rust\">fn main() {}</code></pre>").unwrap();
        let blocks = doc["children"].as_array().unwrap();
        assert_eq!(blocks[0]["textAlign"], "center");
        assert_eq!(blocks[0]["children"][0]["width"], 250.0);
        assert_eq!(blocks[0]["children"][0]["href"], "logo.svg");
        assert_eq!(blocks[1]["id"], "a--b");
        let rendered = doc.to_string();
        for expected in ["strong", "em", "math", "details", "summary", "keyword"] {
            assert!(rendered.contains(expected), "missing {expected}");
        }
    }

    #[test]
    fn html_recovery_and_document_only_attributes() {
        let renderer = Renderer::new().unwrap();
        let doc = renderer.parse("<p><b>Unclosed\n\n<script>bad()</script><iframe src=\"https://example.com\">hidden</iframe>\n\n<img src=\"photo.png\" style=\"width:50%;height:100px\" onclick=\"bad()\">\n\n&lt;b&gt;literal&lt;/b&gt;").unwrap().to_string();
        assert!(!doc.contains("bad()") && !doc.contains("hidden") && !doc.contains("onclick"));
        assert!(doc.contains("widthPercent") && doc.contains("<b>literal</b>"));
        assert!(
            renderer
                .parse(&format!(
                    "{}text{}",
                    "<div>".repeat(200),
                    "</div>".repeat(200)
                ))
                .is_err()
        );
    }

    #[test]
    fn gfm_math_diagrams_and_highlighting() {
        let renderer = Renderer::new().unwrap();
        let doc = renderer.parse("# Same\n\n# Same\n\n- [x] done\n\n| A | B |\n|---|---|\n| 1 | 2 |\n\n$x^2 + \\alpha$\n\n$$\\frac{1}{2}$$\n\n```mermaid\nflowchart LR\n A[Start] --> B[End]\n```\n\n```rust\nfn main() { println!(\"λ\"); }\n```\n").unwrap();
        let rendered = doc.to_string();
        for kind in [
            "table", "task", "math", "diagram", "code", "keyword", "same-1",
        ] {
            assert!(rendered.contains(kind), "missing {kind}: {rendered}");
        }
        assert!(rendered.contains("<path"));
        assert!(
            super::super::grammars::highlighter()
                .unwrap()
                .languages()
                .len()
                > 200
        );
    }

    #[test]
    fn malformed_and_unknown_inputs_remain_readable() {
        let renderer = Renderer::new().unwrap();
        let doc = renderer.parse("<script>alert(1)</script>\n\n```no-such-language\ncode\n```\n\n$\\notarealcommand{x}$\n\n```mermaid\nnot-a-diagram\n```\n\nStill readable").unwrap();
        let text = doc.to_string();
        assert!(text.contains("Still readable"));
        assert!(text.contains("error"));
        assert!(text.contains("no-such-language"));
        assert!(renderer.parse(&"x".repeat(2 * 1024 * 1024 + 1)).is_err());
    }
}
