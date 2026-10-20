#!/usr/bin/env python3
"""A real framed peer for async, lifecycle, cancellation and crash-recovery checks."""
import json
import os
from pathlib import Path
import sys

documents = {}
deferred = []
cancelled = []
events = Path(sys.argv[1])


def record(event):
    with events.open("a") as output:
        output.write(event + "\n")


def send(message):
    body = json.dumps({"jsonrpc": "2.0", **message}, ensure_ascii=False).encode()
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
        send({"id": identifier, "result": {"capabilities": {
            "textDocumentSync": {"openClose": True, "change": int(os.environ.get("LSP_SYNC_KIND", "1")), "save": {"includeText": True}},
            "hoverProvider": True, "completionProvider": {}, "definitionProvider": True,
            "documentSymbolProvider": True, "signatureHelpProvider": {}}}})
    elif method == "textDocument/didOpen":
        doc = params["textDocument"]
        documents[doc["uri"]] = doc
    elif method == "textDocument/didChange":
        doc = params["textDocument"]
        if os.environ.get("LSP_SYNC_KIND") == "2":
            old = documents[doc["uri"]]["text"]
            lines = old.split("\n")
            end = {"line": len(lines) - 1, "character": len(lines[-1].encode("utf-16-le")) // 2}
            assert params["contentChanges"][-1]["range"] == {"start": {"line": 0, "character": 0}, "end": end}
        documents[doc["uri"]].update(version=doc["version"], text=params["contentChanges"][-1]["text"])
    elif method == "textDocument/didClose":
        documents.pop(params["textDocument"]["uri"], None)
    elif method == "textDocument/didSave":
        record("save " + params.get("text", ""))
    elif method == "$/cancelRequest":
        cancelled.append(params["id"])
    elif method == "test/state":
        send({"id": identifier, "result": {"pid": os.getpid(), "documents": documents, "cancelled": cancelled}})
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
            for version in [doc["version"] - 1, doc["version"]]:
                send({"method": "textDocument/publishDiagnostics", "params": {
                    "uri": doc["uri"], "version": version, "diagnostics": []}})
        send({"id": identifier, "result": True})
    elif method == "textDocument/completion":
        send({"id": identifier, "result": [{"label": "fixtureMember", "kind": 3,
                                           "detail": "LSP completion", "insertText": "fixtureMember"}]})
    elif method == "textDocument/hover":
        send({"id": identifier, "result": {"contents": {"kind": "plaintext", "value": "LSP hover from stdio"}}})
    elif method == "textDocument/signatureHelp":
        send({"id": identifier, "result": {"signatures": [{"label": "greet(name:String, times:Int)",
              "parameters": [{"label": "name:String"}, {"label": "times:Int"}]}],
              "activeSignature": 0, "activeParameter": 0}})
    elif method == "textDocument/documentSymbol":
        position = {"start": {"line": 0, "character": 0}, "end": {"line": 0, "character": 10}}
        send({"id": identifier, "result": [{"name": "LspMain", "kind": 5,
              "range": position, "selectionRange": position, "children": []}]})
    elif method == "textDocument/definition":
        send({"id": identifier, "result": {"uri": params["textDocument"]["uri"], "range": {
              "start": {"line": 0, "character": 6}, "end": {"line": 0, "character": 10}}}})
    elif method == "shutdown":
        record("shutdown")
        send({"id": identifier, "result": None})
    elif method == "exit":
        record("exit")
        sys.exit(0)
    elif identifier is not None:
        send({"id": identifier, "error": {"code": -32601, "message": "Unknown fixture method"}})
