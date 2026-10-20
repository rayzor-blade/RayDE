//! Editor sessions retain lexical state, never editor views.
use irosashi::{CodeToTokensOptions, Highlighter, Session, StateStack, TokenizeOptions};
use serde_json::{Value, json};
use std::{cell::RefCell, sync::Arc};

struct Document {
    session: Session,
    states: Vec<StateStack>,
}
struct Service {
    highlighter: Arc<Highlighter>,
    documents: Vec<Option<Document>>,
}
thread_local! { static SERVICE:RefCell<Option<Service>> = const { RefCell::new(None) }; }

pub fn install(vm: &mut rayscript_vm::Vm) {
    let render = vm.native("rayde.syntax.highlight", |vm, args| {
        let source = args
            .first()
            .and_then(|v| vm.string_of(*v))
            .unwrap_or("")
            .to_owned();
        let language = args
            .get(1)
            .and_then(|v| vm.string_of(*v))
            .unwrap_or("")
            .to_owned();
        Ok(vm.new_string(&highlight(&source, &language).to_string()))
    });
    let languages = vm.native("rayde.syntax.languages", |vm, _| {
        let highlighter = super::grammars::highlighter().map_err(|e| vm.new_string(&e))?;
        Ok(vm.new_string(&json!(highlighter.languages()).to_string()))
    });
    let module = vm.new_object();
    vm.set_member(module, "highlight", render);
    vm.set_member(module, "languages", languages);
    vm.register_module("rayde.syntax", module);
}

pub fn open(file: &str) -> i32 {
    SERVICE.with(|cache| {
        let mut cache = cache.borrow_mut();
        if cache.is_none() {
            let Ok(highlighter) = super::grammars::highlighter() else {
                return -1;
            };
            *cache = Some(Service {
                highlighter,
                documents: Vec::new(),
            });
        }
        let service = cache.as_mut().unwrap();
        let Some(language) = service.highlighter.detect_language(file) else {
            return -1;
        };
        let Ok(session) = service.highlighter.session(&language) else {
            return -1;
        };
        let state = session.initial_state();
        let at = service
            .documents
            .iter()
            .position(Option::is_none)
            .unwrap_or(service.documents.len());
        let document = Some(Document {
            session,
            states: vec![state],
        });
        if at == service.documents.len() {
            service.documents.push(document);
        } else {
            service.documents[at] = document;
        }
        at as i32
    })
}

pub fn close(handle: i32) {
    SERVICE.with(|cache| {
        if let Some(service) = cache.borrow_mut().as_mut() {
            if let Some(slot) = service.documents.get_mut(handle as usize) {
                *slot = None;
            }
        }
    });
}

pub fn line(handle: i32, text: &str, incoming: i32) -> Value {
    SERVICE.with(|cache| {
        let mut cache = cache.borrow_mut();
        let Some(document) = cache.as_mut().and_then(|s| s.documents.get_mut(handle as usize)).and_then(Option::as_mut) else {
            return json!({"state":0, "tokens":[]});
        };
        let state = document.states.get(incoming as usize).unwrap_or(&document.states[0]).clone();
        let result = document.session.tokenize_line(text, &state, incoming < 0, TokenizeOptions {max_line_length:Some(16_384)});
        let next = document.states.iter().position(|s| *s == result.state).unwrap_or_else(|| {
            document.states.push(result.state.clone()); document.states.len()-1
        });
        let tokens:Vec<Value> = result.tokens.iter().map(|t| {
            let scopes = document.session.scope_names(t.scopes);
            let kind = token_kind(scopes.iter().copied());
            json!({"from":text[..t.start].encode_utf16().count(), "to":text[..t.end].encode_utf16().count(), "kind":kind})
        }).collect();
        json!({"state":next, "tokens":tokens})
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn incremental_states_and_disposal() {
        let doc = open("example.rs");
        assert!(doc >= 0);
        let first = line(doc, "/* comment", -1);
        let next = first["state"].as_i64().unwrap() as i32;
        assert!(
            line(doc, "still comment */ fn main() {}", next)
                .to_string()
                .contains("keyword")
        );
        assert!(
            line(doc, "still comment", next)
                .to_string()
                .contains("comment")
        );
        assert!(line(doc, "let λ = 123;", 0).to_string().contains("number"));
        close(doc);
        assert!(
            line(doc, "fn main() {}", 0)["tokens"]
                .as_array()
                .unwrap()
                .is_empty()
        );
        assert_eq!(open("example.unknown-extension"), -1);
    }
}

pub fn highlight(source: &str, language: &str) -> Value {
    let Ok(highlighter) = super::grammars::highlighter() else {
        return json!({"kind":"code","text":source,"language":language,"tokens":[]});
    };
    let mut options = CodeToTokensOptions::new(&language, "rayde");
    options.include_scopes = true;
    options.max_line_length = Some(16_384);
    let mut lines = Vec::new();
    if let Ok(result) = highlighter.code_to_tokens(source.trim_end_matches('\n'), &options) {
        for line in &result.lines {
            let text = &result.source[line.range.clone()];
            let tokens: Vec<Value> = line
                .tokens
                .iter()
                .map(|token| {
                    let scopes = result.scopes_of(token).unwrap_or(&[]);
                    let kind = token_kind(scopes.iter().map(|s| s.as_ref()));
                    json!({"from":text[..token.start].encode_utf16().count(),
                        "to":text[..token.end].encode_utf16().count(), "kind":kind})
                })
                .collect();
            lines.push(json!(tokens));
        }
    }
    json!({"kind":"code", "text":source.trim_end_matches('\n'), "language":language, "tokens":lines})
}

pub(crate) fn token_kind<'a>(scopes: impl IntoIterator<Item = &'a str>) -> &'static str {
    let mut kind = "plain";
    for s in scopes {
        if s.starts_with("comment") {
            kind = "comment";
            break;
        }
        if s.starts_with("string") {
            kind = "string";
        } else if s.starts_with("keyword.operator") {
            kind = "operator";
        } else if s.starts_with("keyword") || s.starts_with("storage") {
            kind = "keyword";
        } else if s.starts_with("constant.numeric") {
            kind = "number";
        } else if s.starts_with("entity.name.function") || s.starts_with("support.function") {
            kind = "function";
        } else if s.starts_with("entity.name.type")
            || s.starts_with("support.type")
            || s.starts_with("support.class")
        {
            kind = "type";
        } else if s.starts_with("entity.name.tag") {
            kind = "tag";
        } else if s.starts_with("entity.other.attribute") {
            kind = "attribute";
        }
    }
    kind
}
