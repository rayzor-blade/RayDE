//! Host-owned environment defaults for workspace processes; never sent to browser clients.
use std::{collections::HashMap, path::Path};

pub fn load(path: &Path, required: bool) -> std::io::Result<HashMap<String, String>> {
    let bytes = match std::fs::read(path) {
        Ok(bytes) => bytes,
        Err(e) if !required && e.kind() == std::io::ErrorKind::NotFound => {
            return Ok(HashMap::new());
        }
        Err(e) => return Err(e),
    };
    if bytes.len() > 128 * 1024 {
        return Err(std::io::Error::other(
            "Session environment file is too large.",
        ));
    }
    let values: HashMap<String, String> = serde_json::from_slice(&bytes).map_err(|_| {
        std::io::Error::other("Session environment must be a JSON object with string values.")
    })?;
    for (key, value) in &values {
        if key.is_empty() || key.contains(['=', '\0']) || value.contains('\0') {
            return Err(std::io::Error::other(
                "Session environment contains an invalid variable.",
            ));
        }
    }
    if let Some(value) = values.get("RAYZOR_STD_PATH") {
        if !Path::new(value).join("StdTypes.hx").is_file() {
            return Err(std::io::Error::other(
                "Configured RAYZOR_STD_PATH must contain StdTypes.hx.",
            ));
        }
    }
    Ok(values)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn configuration_is_explicit_validated_and_optional() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("environment.json");
        assert!(load(&path, false).unwrap().is_empty());
        assert!(load(&path, true).is_err());
        std::fs::write(&path, r#"{"RAYZOR_STD_PATH":"/rayde-missing-stdlib"}"#).unwrap();
        assert!(load(&path, true).is_err());
        std::fs::write(&path, r#"{"TEST_VALUE":"configured", "BAD=KEY":"hidden"}"#).unwrap();
        assert!(load(&path, true).is_err());
        std::fs::write(&path, r#"{"TEST_VALUE":"configured"}"#).unwrap();
        assert_eq!(load(&path, true).unwrap()["TEST_VALUE"], "configured");
    }
}
