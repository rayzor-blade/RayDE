//! Markdown parsing and vector rendering stay on the extension's owning thread.
use latex_rust::{MathFont, SvgOptions};
use pulldown_cmark::{CodeBlockKind, Event, Options, Parser, Tag};
use rayscript_vm::{Value, Vm};
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
        let mut stack = vec![json!({"kind":"document", "children":[]})];
        let mut headings = HashSet::new();
        let line_starts: Vec<usize> = std::iter::once(0)
            .chain(source.match_indices('\n').map(|(i, _)| i + 1))
            .collect();
        for (event, range) in Parser::new_ext(source, options).into_offset_iter() {
            if stack.len() > 128 {
                return Err("Markdown nesting exceeds 128 levels".into());
            }
            match event {
                Event::Start(tag) => {
                    let mut node = match tag {
                        Tag::Heading { level, .. } => {
                            json!({"kind":"heading", "level":level as u8})
                        }
                        Tag::CodeBlock(kind) => {
                            json!({"kind":"code", "language":match kind { CodeBlockKind::Fenced(s) => s.to_string(), _ => String::new() }, "text":""})
                        }
                        Tag::BlockQuote(_) => json!({"kind":"quote"}),
                        Tag::List(start) => json!({"kind":"list", "start":start}),
                        Tag::Item => json!({"kind":"item"}),
                        Tag::Emphasis => json!({"kind":"em"}),
                        Tag::Strong => json!({"kind":"strong"}),
                        Tag::Strikethrough => json!({"kind":"strike"}),
                        Tag::Link {
                            dest_url, title, ..
                        } => {
                            json!({"kind":"link", "href":dest_url.to_string(), "title":title.to_string()})
                        }
                        Tag::Image {
                            dest_url, title, ..
                        } => {
                            json!({"kind":"image", "href":dest_url.to_string(), "title":title.to_string()})
                        }
                        Tag::Table(align) => {
                            json!({"kind":"table", "align":align.iter().map(|a|format!("{a:?}")).collect::<Vec<_>>()})
                        }
                        Tag::TableHead => json!({"kind":"table-head"}),
                        Tag::TableRow => json!({"kind":"table-row"}),
                        Tag::TableCell => json!({"kind":"table-cell"}),
                        Tag::FootnoteDefinition(label) => {
                            json!({"kind":"footnote", "id":label.to_string()})
                        }
                        Tag::HtmlBlock => json!({"kind":"html"}),
                        _ => json!({"kind":"paragraph"}),
                    };
                    node["children"] = json!([]);
                    node["line"] = json!(
                        line_starts
                            .partition_point(|at| *at <= range.start)
                            .saturating_sub(1)
                    );
                    stack.push(node);
                }
                Event::End(_) => {
                    let mut node = stack.pop().ok_or("Invalid Markdown structure")?;
                    if node["kind"] == "code" {
                        node = self.code(
                            node["text"].as_str().unwrap_or(""),
                            node["language"].as_str().unwrap_or(""),
                        );
                    } else if node["kind"] == "heading" {
                        let title = plain(&node);
                        let base: String = title
                            .to_lowercase()
                            .chars()
                            .filter_map(|c| {
                                if c == ' ' {
                                    Some('-')
                                } else if c.is_alphanumeric() || c == '-' || c == '_' {
                                    Some(c)
                                } else {
                                    None
                                }
                            })
                            .collect();
                        let mut id = base.clone();
                        let mut suffix = 0;
                        while !headings.insert(id.clone()) {
                            suffix += 1;
                            id = format!("{base}-{suffix}");
                        }
                        node["id"] = json!(id);
                    }
                    push(&mut stack, node);
                }
                Event::Text(text) if stack.last().is_some_and(|n| n["kind"] == "code") => {
                    let node = stack.last_mut().unwrap();
                    let mut code = node["text"].as_str().unwrap_or("").to_string();
                    code.push_str(&text);
                    node["text"] = json!(code);
                }
                Event::Text(text) => {
                    push(&mut stack, json!({"kind":"text", "text":text.to_string()}))
                }
                Event::Code(text) => push(
                    &mut stack,
                    json!({"kind":"inline-code", "text":text.to_string()}),
                ),
                Event::InlineMath(text) => push(&mut stack, self.math(&text, false)),
                Event::DisplayMath(text) => push(&mut stack, self.math(&text, true)),
                Event::SoftBreak => push(&mut stack, json!({"kind":"text", "text":" "})),
                Event::HardBreak => push(&mut stack, json!({"kind":"break"})),
                Event::Rule => push(&mut stack, json!({"kind":"rule"})),
                Event::TaskListMarker(checked) => {
                    push(&mut stack, json!({"kind":"task", "checked":checked}))
                }
                Event::FootnoteReference(label) => push(
                    &mut stack,
                    json!({"kind":"link", "href":format!("#footnote-{label}"), "children":[{"kind":"text","text":format!("[{label}]")}]}),
                ),
                // HTML remains visible text; no scripts, embedded pages or event attributes execute.
                Event::Html(text) | Event::InlineHtml(text) => {
                    push(&mut stack, json!({"kind":"text", "text":text.to_string()}))
                }
            }
        }
        Ok(stack.remove(0))
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

fn push(stack: &mut [Json], node: Json) {
    if let Some(children) = stack.last_mut().and_then(|n| n["children"].as_array_mut()) {
        children.push(node);
    }
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
            Ok(vm.new_string(&result.to_string()))
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
