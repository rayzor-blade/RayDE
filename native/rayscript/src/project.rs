use serde_json::{Value, json};
use toml_edit::{Array, DocumentMut, Item, Table};

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

/// Changes one TOML field without rewriting unrelated sections or their formatting.
pub fn edit(request: &str) -> Value {
    match edit_source(request) {
        Ok(source) => json!({"source":source}),
        Err(error) => json!({"error":error}),
    }
}

fn edit_source(request: &str) -> Result<String, String> {
    let request: Value = serde_json::from_str(request).map_err(|e| e.to_string())?;
    let source = request["source"].as_str().ok_or("Missing TOML source")?;
    if source.len() > 2 << 20 { return Err("Project manifest exceeds 2 MiB".into()); }
    let path = request["path"].as_array().ok_or("Missing field path")?;
    if path.is_empty() || path.len() > 8 { return Err("Invalid field path".into()); }
    let path: Vec<&str> = path.iter().map(|key| key.as_str().filter(|k| !k.is_empty()).ok_or("Invalid field name"))
        .collect::<Result<_, _>>()?;
    let action = request["action"].as_str().unwrap_or("set");
    if !["set", "append", "remove-index"].contains(&action) { return Err("Unknown TOML edit".into()); }
    let mut document = source.parse::<DocumentMut>().map_err(|e| e.to_string())?;
    let mut parent = document.as_item_mut();
    for key in &path[..path.len() - 1] {
        let table = parent.as_table_like_mut().ok_or("Field parent is not a table")?;
        if !table.contains_key(key) {
            if request["value"].is_null() && action == "set" { return Ok(source.to_owned()); }
            let mut child = Table::new(); child.set_implicit(true);
            table.insert(key, Item::Table(child));
        }
        parent = table.get_mut(key).ok_or("Missing field parent")?;
    }
    let table = parent.as_table_like_mut().ok_or("Field parent is not a table")?;
    let key = path[path.len() - 1];
    match action {
        "append" => {
            if !table.contains_key(key) { table.insert(key, Item::Value(Array::new().into())); }
            let array = table.get_mut(key).and_then(Item::as_array_mut).ok_or("Field is not an array")?;
            let value = edit_value(&request["value"])?;
            if !array.iter().any(|v| v.as_str().is_some() && v.as_str() == value.as_str()) { array.push(value); }
        }
        "remove-index" => {
            let array = table.get_mut(key).and_then(Item::as_array_mut).ok_or("Field is not an array")?;
            let index = request["index"].as_u64().ok_or("Missing array index")?;
            if index >= array.len() as u64 { return Err("Array entry no longer exists".into()); }
            array.remove(index as usize);
        }
        _ if request["value"].is_null() => { table.remove(key); }
        _ => {
            let mut value = edit_value(&request["value"])?;
            if let Some(old) = table.get(key).and_then(Item::as_value) { *value.decor_mut() = old.decor().clone(); }
            table.insert(key, Item::Value(value));
        }
    }
    Ok(document.to_string())
}

fn edit_value(value: &Value) -> Result<toml_edit::Value, String> {
    Ok(match value {
        Value::String(value) => value.as_str().into(),
        Value::Bool(value) => (*value).into(),
        Value::Number(value) => {
            if let Some(value) = value.as_i64() { value.into() }
            else { value.as_f64().ok_or("Invalid TOML number")?.into() }
        }
        Value::Array(values) => {
            let mut array = Array::new();
            for value in values { array.push(edit_value(value)?); }
            array.into()
        }
        _ => return Err("Expected a TOML string, number, boolean or array".into()),
    })
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

    #[test]
    fn edits_keep_comments_unknown_fields_and_quoted_keys() {
        let source = "# project\n[project]\nname = 'hello' # keep\n[build]\ndefines = { 'feature.name' = true, untouched = 42 }\n[tier]\ncustom = 'keep'\n";
        let edited = edit(&json!({"source":source,"path":["project","name"],"value":"Hello λ"}).to_string());
        let source = edited["source"].as_str().unwrap();
        assert!(source.contains("name = \"Hello λ\" # keep"));
        let edited = edit(&json!({"source":source,"path":["build","defines","feature.name"],"value":"yes"}).to_string());
        let source = edited["source"].as_str().unwrap();
        assert_eq!(parse(source)["value"]["build"]["defines"]["feature.name"], "yes");
        assert!(source.contains("untouched = 42"));
        assert!(source.ends_with("[tier]\ncustom = 'keep'\n"));
    }

    #[test]
    fn array_edits_create_nested_tables_and_preserve_existing_entries() {
        let source = "[workspace]\nmembers = [\n  'app', # keep\n  'lib'\n]\n";
        let edited = edit(&json!({"source":source,"path":["workspace","members"],"action":"append","value":"tools"}).to_string());
        let source = edited["source"].as_str().unwrap();
        assert!(source.contains("'app', # keep"));
        let edited = edit(&json!({"source":source,"path":["workspace","cache","dir"],"value":".shared"}).to_string());
        let source = edited["source"].as_str().unwrap();
        assert_eq!(parse(source)["value"]["workspace"]["cache"]["dir"], ".shared");
        let edited = edit(&json!({"source":source,"path":["workspace","members"],"action":"remove-index","index":1}).to_string());
        assert_eq!(parse(edited["source"].as_str().unwrap())["value"]["workspace"]["members"], json!(["app","tools"]));
        assert!(edit(&json!({"source":"[broken", "path":["project","name"],"value":"x"}).to_string())["error"].is_string());
        assert!(edit(&json!({"source":"build = 42", "path":["build","output"],"value":"x"}).to_string())["error"].is_string());
    }
}
