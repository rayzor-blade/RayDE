use serde_json::{Value, json};

pub fn parse(source: &str) -> Value {
    if source.len() > 2 << 20 { return json!({"error":"Project manifest exceeds 2 MiB"}); }
    match source.parse::<toml::Value>() {
        Ok(value) => json!({"value": value}),
        Err(error) => json!({"error": error.to_string()}),
    }
}

pub fn create_directory(path: &str) -> Value {
    match std::fs::create_dir(path) {
        Ok(()) => json!({"ok":true}),
        Err(error) => json!({"error":error.to_string()}),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn toml_preserves_nested_fields_and_rejects_invalid_syntax() {
        let value = parse("[project]\nname = 'Hello λ'\n[build]\nclass-paths = [\n'src', # source\n'lib code'\n]\n[build.defines]\nfeature = true\n");
        assert_eq!(value["value"]["build"]["class-paths"][1], "lib code");
        assert_eq!(value["value"]["build"]["defines"]["feature"], true);
        assert!(parse("[project\nname = x")["error"].is_string());
    }
}
