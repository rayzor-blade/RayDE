//! What leaves the machine. Git's own state and RayDE's session state never do; operating-system litter and rebuildable caches stay behind;
//! anything that looks like a credential is not uploaded until the person says so, even when Git tracks it, because tracking proves nothing
//! about safety. The lists are not exhaustive and the product says so: they are a guard against the common accident.
use crate::{lifecycle::Limits, manifest::{Reason, path_problem}};

/// What the person chose in the preview, by path: a path or a directory prefix.
#[derive(Clone, PartialEq, Eq, Debug, Default)]
pub struct Selection {
    /// Included although the defaults would leave them out or ask. Never overrides `.git` or session state.
    pub include: Vec<String>,
    /// Left out although the defaults would include them.
    pub exclude: Vec<String>,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Decision {
    Include,
    /// Not uploaded, and not asked about.
    Exclude(Reason),
    /// Not uploaded until the person includes it: the preview lists it with the reason.
    NeedsDecision(Reason),
}

fn matches(list: &[String], path: &str) -> bool {
    list.iter().any(|p| path == p || path.strip_prefix(p.as_str()).is_some_and(|rest| rest.starts_with('/')))
}

/// Directories that are always rebuildable or per-machine, wherever they are in the tree.
const CACHES: &[&str] = &[
    "node_modules", ".cache", "__pycache__", ".gradle", ".idea", ".haxelib", ".rayzor", ".haxe", ".sass-cache", ".next", ".nuxt", ".turbo", ".parcel-cache", ".pytest_cache", ".mypy_cache", ".venv",
];

/// Names that are generated output in most projects but could be source in one: left out only when Git does not track them.
const OUTPUT: &[&str] = &["bin", "obj", "dist", "build", "out", "target", "export", "output"];

const OS_FILES: &[&str] = &[".DS_Store", "Thumbs.db", "desktop.ini", ".Spotlight-V100", ".Trashes", ".fseventsd"];

const SECRET_NAMES: &[&str] = &[
    ".netrc", "_netrc", ".npmrc", ".pypirc", ".git-credentials", ".htpasswd", ".pgpass", "id_rsa", "id_dsa", "id_ecdsa", "id_ed25519", "credentials.json", "service-account.json", "terraform.tfvars",
];

const SECRET_EXTENSIONS: &[&str] = &["pem", "key", "p12", "pfx", "keystore", "jks", "tfstate", "kdbx", "ovpn"];

/// An environment file is a secret unless it is the checked-in template.
fn environment_file(name: &str) -> bool {
    if name == ".env" {
        return true;
    }
    match name.strip_prefix(".env.") {
        Some(rest) => !["example", "sample", "template", "dist", "defaults"].contains(&rest),
        None => name.ends_with(".env"),
    }
}

fn secret(path: &str) -> bool {
    let parts: Vec<&str> = path.split('/').collect();
    let name = parts.last().copied().unwrap_or("");
    let lower = name.to_ascii_lowercase();
    if SECRET_NAMES.contains(&lower.as_str()) || environment_file(&lower) {
        return true;
    }
    if lower.rsplit_once('.').is_some_and(|(_, ext)| SECRET_EXTENSIONS.contains(&ext)) && !lower.ends_with(".pub") {
        return true;
    }
    // Directories whose contents are credentials, and the files named for them.
    let dir = |d: &str| parts[..parts.len() - 1].iter().any(|p| *p == d);
    dir(".ssh") || dir(".gnupg") || dir(".aws") || (dir(".docker") && lower == "config.json") || (dir(".kube") && lower == "config") || lower.starts_with("secrets.") || lower.starts_with("service-account")
}

/// RayDE's own state under `.rayde/`, apart from what describes the project: its settings and its themes.
fn session_state(path: &str) -> bool {
    path == ".rayde-session" || path.starts_with(".rayde-session/") || (path.starts_with(".rayde/") && path != ".rayde/settings.json" && !path.starts_with(".rayde/themes/"))
}

/// The decision for one file. `tracked` is whether Git's index has it: it lifts the ambiguity of output directories, and never the secret check.
pub fn classify(path: &str, tracked: bool, selection: &Selection) -> Decision {
    match path_problem(path, &Limits::default()) {
        Some("git-internal") => return Decision::Exclude(Reason::GitInternal),
        Some("session-state") => return Decision::Exclude(Reason::SessionState),
        Some(_) => return Decision::Exclude(Reason::BadPath),
        None => {}
    }
    if session_state(path) {
        return Decision::Exclude(Reason::SessionState);
    }
    if matches(&selection.exclude, path) {
        return Decision::Exclude(Reason::Excluded);
    }
    let chosen = matches(&selection.include, path);
    let parts: Vec<&str> = path.split('/').collect();
    let name = parts.last().copied().unwrap_or("");
    if OS_FILES.contains(&name) || name.starts_with("._") {
        return Decision::Exclude(Reason::OsFile);
    }
    if secret(path) {
        return if chosen { Decision::Include } else { Decision::NeedsDecision(Reason::Secret) };
    }
    let directories = &parts[..parts.len() - 1];
    if !chosen && directories.iter().any(|d| CACHES.contains(d)) || (!chosen && CACHES.contains(&name) && !tracked) {
        return Decision::Exclude(Reason::Cache);
    }
    if !chosen && !tracked && directories.iter().any(|d| OUTPUT.contains(d)) {
        return Decision::Exclude(Reason::Cache);
    }
    Decision::Include
}

#[cfg(test)]
mod tests {
    use super::*;

    fn d(path: &str, tracked: bool) -> Decision {
        classify(path, tracked, &Selection::default())
    }

    #[test]
    fn git_state_and_session_state_never_leave_even_when_chosen() {
        let chosen = Selection { include: vec![".git".into(), ".rayde-session".into(), ".rayde/run".into()], exclude: vec![] };
        for (path, reason) in [(".git/config", Reason::GitInternal), ("sub/.git/HEAD", Reason::GitInternal), (".GIT/hooks/pre-commit", Reason::GitInternal), (".rayde-session/state/x.ydoc", Reason::SessionState), (".rayde/run/run.log", Reason::SessionState), (".rayde/cache/x", Reason::SessionState)] {
            assert_eq!(classify(path, true, &chosen), Decision::Exclude(reason), "{path}");
        }
        assert_eq!(d(".rayde/settings.json", true), Decision::Include, "the project's own settings sync");
        assert_eq!(d(".rayde/themes/mine/theme.css", true), Decision::Include);
    }

    #[test]
    fn credentials_need_a_decision_whether_or_not_git_tracks_them() {
        for path in [".env", "app/.env", ".env.local", ".env.production", "deploy.env", "key.pem", "certs/server.key", "id_rsa", "home/.ssh/config", ".aws/credentials", ".docker/config.json", ".netrc", ".npmrc", "terraform.tfstate", "secrets.yaml", "service-account-prod.json", "vault.kdbx"] {
            for tracked in [true, false] {
                assert_eq!(d(path, tracked), Decision::NeedsDecision(Reason::Secret), "{path} (tracked: {tracked})");
            }
        }
        for path in [".env.example", ".env.sample", "id_rsa.pub", "src/keys.hx", "docs/secrets-policy.md", "monkey.hx", "environment.md", ".envrc"] {
            assert_eq!(d(path, true), Decision::Include, "{path}");
        }
    }

    #[test]
    fn the_person_can_include_a_secret_or_exclude_anything() {
        let include = Selection { include: vec!["config/.env".into()], exclude: vec![] };
        assert_eq!(classify("config/.env", true, &include), Decision::Include);
        assert_eq!(classify("other/.env", true, &include), Decision::NeedsDecision(Reason::Secret));
        let leave = Selection { include: vec![], exclude: vec!["assets/raw".into()] };
        assert_eq!(classify("assets/raw/big.psd", true, &leave), Decision::Exclude(Reason::Excluded));
        assert_eq!(classify("assets/rawer.txt", true, &leave), Decision::Include, "a prefix is a directory, not a string");
    }

    #[test]
    fn rebuildable_caches_stay_behind_and_ambiguous_output_directories_follow_git() {
        for path in ["node_modules/x/index.js", "web/node_modules/y.js", ".haxelib/lime/1.0/x", ".rayzor/cache/blade", "a/__pycache__/m.pyc", ".idea/workspace.xml"] {
            assert_eq!(d(path, true), Decision::Exclude(Reason::Cache), "{path}");
        }
        for path in ["bin/app.hl", "dist/app.js", "target/debug/x", "export/html5/bin/index.html", "a/build/out.o"] {
            assert_eq!(d(path, false), Decision::Exclude(Reason::Cache), "{path} untracked");
            assert_eq!(d(path, true), Decision::Include, "{path} tracked: source in this project");
        }
        assert_eq!(d(".vscode/launch.json", true), Decision::Include, "editor tasks are project content");
        assert_eq!(classify("node_modules/x.js", false, &Selection { include: vec!["node_modules/x.js".into()], exclude: vec![] }), Decision::Include);
    }

    #[test]
    fn operating_system_litter_is_left_out() {
        for path in [".DS_Store", "a/Thumbs.db", "src/._Main.hx", "desktop.ini"] {
            assert_eq!(d(path, true), Decision::Exclude(Reason::OsFile), "{path}");
        }
    }

    #[test]
    fn ordinary_source_is_included_and_unstorable_paths_are_refused() {
        for path in ["src/Main.hx", "README.md", "ünï/code.hx", ".gitignore", ".github/workflows/ci.yml", "build.hxml"] {
            assert_eq!(d(path, true), Decision::Include, "{path}");
        }
        assert_eq!(d("../escape", true), Decision::Exclude(Reason::BadPath));
        assert_eq!(d("/abs", true), Decision::Exclude(Reason::BadPath));
    }
}
