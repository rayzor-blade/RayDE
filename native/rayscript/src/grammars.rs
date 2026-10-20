//! Pinned Linguist-derived data is shared by preview fences and incremental editors.
use irosashi::{Highlighter, HighlighterBuilder};
use serde_json::Value;
use std::sync::{Arc, OnceLock};

static DATA: include_dir::Dir<'static> = include_dir::include_dir!("$CARGO_MANIFEST_DIR/grammars");

static SHARED: OnceLock<Result<Arc<Highlighter>, String>> = OnceLock::new();

pub fn highlighter() -> Result<Arc<Highlighter>, String> {
    SHARED
        .get_or_init(|| build().map(Arc::new).map_err(|e| e.to_string()))
        .clone()
}

fn build() -> Result<Highlighter, irosashi::Error> {
    let index: Value =
        serde_json::from_slice(DATA.get_file("index.json").unwrap().contents()).unwrap();
    let mut builder = HighlighterBuilder::without_bundled_assets().theme("rayde", Arc::<[u8]>::from(
        br##"{"name":"RayDE scopes","colors":{"editor.foreground":"#ffffff","editor.background":"#000000"},"tokenColors":[]}"##.as_slice()))?;
    for entry in index["grammars"].as_array().unwrap() {
        let scope = entry["scope"].as_str().unwrap().to_lowercase();
        let bytes = DATA
            .get_file(entry["file"].as_str().unwrap())
            .unwrap()
            .contents();
        builder = builder.grammar(&scope, Arc::<[u8]>::from(bytes))?;
        for name in entry["names"].as_array().unwrap() {
            builder = builder.alias(&name.as_str().unwrap().to_lowercase(), &scope);
        }
        for extension in entry["extensions"].as_array().unwrap() {
            builder =
                builder.extension(extension.as_str().unwrap().trim_start_matches('.'), &scope);
        }
    }
    builder.build()
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn complete_bundle_loads_with_aliases() {
        let highlighter = highlighter().unwrap();
        assert_eq!(highlighter.languages().len(), 731);
        for language in highlighter.languages() {
            assert!(
                highlighter.session(&language).is_ok(),
                "invalid bundled grammar {language}"
            );
        }
        for language in [
            "rust",
            "python",
            "ruby",
            "bash",
            "go",
            "c++",
            "swift",
            "kotlin",
            "zig",
            "sql",
            "haskell",
            "elixir",
            "csharp",
            "javascript",
            "typescript",
        ] {
            assert!(
                highlighter.session(language).is_ok(),
                "missing grammar {language}"
            );
        }
    }
}
