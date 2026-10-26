# Language assistance

Rayzor is enabled by default for Haxe files. It supplies completion, hover documentation, signature help, definitions, diagnostics and Outline. If Rayzor is disabled or cannot start, RayDE falls back to the Haxe compiler's display service. Build and Run use the project's chosen runtime separately.

Syntax highlighting also covers other languages and configuration files. Browser workspaces use the session's TextMate grammars, with built-in colors available immediately for common languages. Highlighting does not require a language server.

## Completion and documentation

Completion opens after `.` or the first character of a word, or with **Ctrl+Space**. Typing narrows the results. Arrow keys, Page Up/Down, Home and End move through them; Enter or Tab inserts the selection; Escape closes the list. Suggestions reflect unsaved text.

Hover a name to see its type and documentation. Hover and diagnostic popovers render Markdown, including highlighted code blocks; long content scrolls within the popup.

![Completion list narrowed to charAt, with its documentation](images/editor-completion.png)

## Signature help and definitions

Typing `(` or `,` shows the call's signatures with the current argument emphasized. Escape closes the popup; **Cmd+Shift+Space** opens it explicitly.

Use **F12**, Cmd-click on macOS or Ctrl-click elsewhere to go to a symbol's definition.

![Signature help with the second argument emphasized](images/editor-signature.png)

## Server status

The bottom status bar shows the language server and its state. During scanning or indexing, Rayzor's logo spins and the label identifies the module or class. Hover for the full status.

Click it for **Start**, **Restart**, **Stop**, extension settings or Output. A stopped server stays stopped until you start it. Start and Restart synchronize your current unsaved buffers.

## Configure Rayzor

**Settings > Extensions > Rayzor Language Server** sets the executable, build file, standard library and macro time budget. Leave the executable on automatic discovery to use the packaged server, PATH or a sibling development build; an explicit path overrides discovery. The standard library is discovered automatically unless overridden.

After changing settings, run **Rayzor: Restart Language Server**. **Rayzor: Language Server Status** reports the registration's state.

Extension authors can [register other language servers](extensions/languages.md).
