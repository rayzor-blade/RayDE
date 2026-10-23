#!/usr/bin/env python3
"""A real framed peer for async, lifecycle, cancellation and crash-recovery checks."""
import json
import os
from pathlib import Path
import sys
import threading

documents = {}
deferred = []
cancelled = []
events = Path(sys.argv[1])
output_lock = threading.Lock()


def record(event):
    with events.open("a") as output:
        output.write(event + "\n")


def send(message):
    body = json.dumps({"jsonrpc": "2.0", **message}, ensure_ascii=False).encode()
    with output_lock:
        sys.stdout.buffer.write(f"Content-Length: {len(body)}\r\n\r\n".encode() + body)
        sys.stdout.buffer.flush()


record("start " + str(os.getpid()))
while True:
    headers = {}
    while True:
        line = sys.stdin.buffer.readline()
        if not line:
            sys.exit(0)
        if line == b"\r\n":
            break
        key, value = line.decode().split(":", 1)
        headers[key.lower()] = value.strip()
    message = json.loads(sys.stdin.buffer.read(int(headers["content-length"])))
    method = message.get("method")
    params = message.get("params") or {}
    identifier = message.get("id")
    if method == "initialize":
        record("initialize " + json.dumps(params.get("capabilities", {}), sort_keys=True))
        send({"id": identifier, "result": {"capabilities": {
            "textDocumentSync": {"openClose": True, "change": int(os.environ.get("LSP_SYNC_KIND", "1")), "save": {"includeText": True}},
            "hoverProvider": True, "completionProvider": {}, "definitionProvider": True,
            "documentSymbolProvider": True, "signatureHelpProvider": {},
            "experimental": {"analysisStatusProvider": os.environ.get("LSP_ANALYSIS_STATUS") == "1"}}}})
    elif method == "textDocument/didOpen":
        doc = params["textDocument"]
        documents[doc["uri"]] = doc
        record("open " + doc["uri"])
    elif method == "textDocument/didChange":
        doc = params["textDocument"]
        record("change " + doc["uri"])
        if os.environ.get("LSP_SYNC_KIND") == "2":
            old = documents[doc["uri"]]["text"]
            lines = old.split("\n")
            end = {"line": len(lines) - 1, "character": len(lines[-1].encode("utf-16-le")) // 2}
            assert params["contentChanges"][-1]["range"] == {"start": {"line": 0, "character": 0}, "end": end}
        documents[doc["uri"]].update(version=doc["version"], text=params["contentChanges"][-1]["text"])
    elif method == "textDocument/didClose":
        uri = params["textDocument"]["uri"]
        documents.pop(uri, None)
        send({"method": "window/logMessage", "params": {"type": 3, "message": "closed " + uri}})
        record("close " + uri)
    elif method == "textDocument/didSave":
        record("save " + params.get("text", ""))
    elif method == "$/cancelRequest":
        cancelled.append(params["id"])
    elif method == "test/state":
        send({"id": identifier, "result": {"pid": os.getpid(), "documents": documents, "cancelled": cancelled}})
    elif method == "test/notify":
        for notification in params.get("notifications", []):
            send(notification)
        send({"id": identifier, "result": True})
    elif method == "test/notifyLater":
        later = threading.Timer(params.get("delay", 0.6), lambda text=params["message"]: send({"method": "window/logMessage", "params": {"type": 3, "message": text}}))
        later.daemon = True
        later.start()
        send({"id": identifier, "result": True})
    elif method == "test/deferred":
        deferred.append(identifier)
    elif method == "test/reverse":
        for pending in reversed(deferred):
            send({"id": pending, "result": pending})
        deferred.clear()
        send({"id": identifier, "result": True})
    elif method == "test/crash":
        sys.exit(7)
    elif method == "test/error":
        send({"id": identifier, "error": {"code": -32603, "message": "fixture analysis failed"}})
    elif method == "test/diagnostics":
        for doc in documents.values():
            if params.get("uri") is not None and params["uri"] != doc["uri"]:
                continue
            versions = [None] if params.get("unversioned") else [doc["version"] - 1] if params.get("staleOnly") else [doc["version"] - 1, doc["version"]]
            for version in versions:
                send({"method": "textDocument/publishDiagnostics", "params": {
                    "uri": doc["uri"], "version": version, "diagnostics": []}})
        send({"id": identifier, "result": True})
    elif method == "textDocument/completion":
        send({"id": identifier, "result": [{"label": "fixtureMember", "kind": 3,
                                           "detail": "LSP completion", "insertText": "fixtureMember"}]})
    elif method == "textDocument/hover":
        record("hover " + params["textDocument"]["uri"])
        send({"id": identifier, "result": {"contents": {"kind": "markdown", "value": "```haxe\npublic class AppIcon\n```\n\n*rayde.ui.AppIcon*\n\nBuilds the **application icon** from `SVG`.\n\n- [Documentation](https://haxe.org)\n- Supports dark and light themes."}}})
    elif method == "textDocument/signatureHelp":
        send({"id": identifier, "result": {"signatures": [{"label": "greet(name:String, times:Int)",
              "parameters": [{"label": "name:String"}, {"label": "times:Int"}]}],
              "activeSignature": 0, "activeParameter": 0}})
    elif method == "textDocument/documentSymbol":
        position = {"start": {"line": 0, "character": 0}, "end": {"line": 0, "character": 10}}
        send({"id": identifier, "result": [{"name": "LspMain", "kind": 5,
              "range": position, "selectionRange": position, "children": []}]})
    elif method == "textDocument/definition":
        record(f"definition {params['position']['line']}:{params['position']['character']}")
        send({"id": identifier, "result": {"uri": params["textDocument"]["uri"], "range": {
              "start": {"line": 0, "character": 6}, "end": {"line": 0, "character": 10}}}})
    elif method == "shutdown":
        record("shutdown")
        send({"method": "$/progress", "params": {"token": "late-shutdown", "value": {"kind": "begin", "title": "Late work"}}})
        send({"method": "rayzor/indexProgress", "params": {"scope": "workspace", "phase": "scanning", "subject": "late.Subject"}})
        send({"id": identifier, "result": None})
    elif method == "exit":
        record("exit")
        sys.exit(0)
    elif identifier is not None:
        send({"id": identifier, "error": {"code": -32601, "message": "Unknown fixture method"}})
