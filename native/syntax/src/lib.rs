//! The shared TextMate registry and source tokens, independent of the extension VM.
use irosashi::{CodeToTokensOptions, TokenizeOptions};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
pub mod grammars;

pub const MAX_SOURCE: usize = 2 * 1024 * 1024;
const MAX_LINES: usize = 32_768;
const MAX_TOKENS: usize = 100_000;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Token {
    pub from: usize,
    pub to: usize,
    pub kind: String,
}

/// Tokenizes one snapshot without retaining its source or lexical states after completion.
pub fn source_tokens(
    source: &str,
    file: &str,
    cancelled: impl Fn() -> bool,
) -> Result<Option<Vec<Vec<Token>>>, String> {
    if source.len() > MAX_SOURCE {
        return Err("Source exceeds the syntax limit.".into());
    }
    if cancelled() {
        return Err("Syntax request cancelled.".into());
    }
    let highlighter = grammars::highlighter()?;
    let Some(language) = highlighter.detect_language(file) else {
        return Ok(None);
    };
    let mut session = highlighter.session(&language).map_err(|e| e.to_string())?;
    let mut state = session.initial_state();
    let mut lines = Vec::new();
    let mut count = 0;
    for text in source.split('\n') {
        if cancelled() {
            return Err("Syntax request cancelled.".into());
        }
        if lines.len() >= MAX_LINES {
            return Err("Source has too many lines for syntax highlighting.".into());
        }
        let result = session.tokenize_line(
            text,
            &state,
            lines.is_empty(),
            TokenizeOptions {
                max_line_length: Some(16_384),
            },
        );
        count += result.tokens.len();
        if count > MAX_TOKENS {
            return Err("Source has too many syntax tokens.".into());
        }
        let ascii = text.is_ascii();
        let mut offsets = if ascii {
            Vec::new()
        } else {
            vec![0; text.len() + 1]
        };
        if !ascii {
            let mut units = 0;
            for (byte, c) in text.char_indices() {
                offsets[byte] = units;
                units += c.len_utf16();
            }
            offsets[text.len()] = units;
        }
        lines.push(
            result
                .tokens
                .iter()
                .map(|t| Token {
                    from: if ascii { t.start } else { offsets[t.start] },
                    to: if ascii { t.end } else { offsets[t.end] },
                    kind: token_kind(session.scope_names(t.scopes).iter().copied()).to_string(),
                })
                .collect(),
        );
        state = result.state;
    }
    Ok(Some(lines))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn file_grammars_and_utf16_offsets() {
        for (file, source) in [
            ("main.rs", "fn main() { let value = 42; }"),
            ("rayzor.toml", "[package]\nname = \"sample\"\nversion = 42"),
            ("ci.yaml", "name: \"sample\"\ncount: 42"),
            ("run.sh", "#!/bin/sh\n# comment\necho \"hello\""),
            ("index.html", "<div class=\"hello\">Hello</div>"),
            ("main.go", "package main\nfunc main() { var value = 42 }"),
        ] {
            let result = source_tokens(source, file, || false).unwrap().unwrap();
            assert!(result.iter().flatten().any(|t| t.kind != "plain"), "{file}");
        }
        let source = "let text = \"🙂\"; let λ = 42;";
        let lines = source_tokens(source, "main.rs", || false).unwrap().unwrap();
        let expected = source[..source.find("42").unwrap()].encode_utf16().count();
        assert!(
            lines[0]
                .iter()
                .any(|t| t.kind == "number" && t.from == expected && t.to == expected + 2)
        );
        assert!(
            source_tokens("text", "unknown.no-such-extension", || false)
                .unwrap()
                .is_none()
        );
        assert!(source_tokens("fn main() {}", "main.rs", || true).is_err());
        assert!(source_tokens(&"a".repeat(MAX_SOURCE + 1), "main.rs", || false).is_err());
    }
}

pub fn highlight(source: &str, language: &str) -> Value {
    let Ok(highlighter) = grammars::highlighter() else {
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

pub fn token_kind<'a>(scopes: impl IntoIterator<Item = &'a str>) -> &'static str {
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
