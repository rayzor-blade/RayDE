# RayDE

The Rayzor Development Environment: a Haxe IDE built on [ashui](https://github.com/rayzor-blade/ashui)'s code editor, for two Haxe runtimes, ash (the default in-editor runner) and rayzor. ChimpMonk uses it as a library.

## Layout

- `src/rayde/lang` — the language layer, with no UI: a Haxe compilation server kept running per project, and display requests (completion, hover, definition, references, signature help, diagnostics) through the compiler's JSON-RPC display protocol, typed from the editor's buffers as well as from disk.
- `tests` — checks against the real Haxe compiler, with fixture projects in `tests/fixtures`.

## Checks

```sh
scripts/check.sh   # builds the checks and runs them with ash (ASH, or ash on PATH)
```

Work is tracked with git-bug; `git-bug bug` lists it.
