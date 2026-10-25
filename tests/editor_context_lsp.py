"""A language server with the editor menu's optional capabilities."""
import json
from pathlib import Path
import sys
import time

documents = {}
requests = Path(sys.argv[1])


def send(value):
    body = json.dumps({"jsonrpc": "2.0", **value}).encode()
    sys.stdout.buffer.write(f"Content-Length: {len(body)}\r\n\r\n".encode() + body)
    sys.stdout.buffer.flush()


while True:
    length = None
    while True:
        line = sys.stdin.buffer.readline()
        if not line:
            sys.exit(0)
        if line in (b"\r\n", b"\n"):
            break
        if line.lower().startswith(b"content-length:"):
            length = int(line.split(b":", 1)[1])
    message = json.loads(sys.stdin.buffer.read(length))
    method, params = message.get("method"), message.get("params", {})
    if method == "textDocument/didOpen":
        documents[params["textDocument"]["uri"]] = params["textDocument"]["text"]
    elif method == "textDocument/didChange":
        uri = params["textDocument"]["uri"]
        for change in params["contentChanges"]:
            # Tests configure full document synchronization.
            documents[uri] = change["text"]
    elif method == "exit":
        break
    if "id" not in message:
        continue
    with requests.open("a") as log:
        log.write(json.dumps(message) + "\n")
    if method == "initialize":
        result = {"capabilities": {"textDocumentSync": 1, "definitionProvider": True,
                  "typeDefinitionProvider": True, "implementationProvider": True,
                  "referencesProvider": True, "renameProvider": True, "documentFormattingProvider": True}}
    elif method == "shutdown":
        result = None
    elif method in ["textDocument/definition", "textDocument/typeDefinition", "textDocument/implementation", "textDocument/references"]:
        location = {"uri": params["textDocument"]["uri"], "range": {"start": {"line": 0, "character": 6}, "end": {"line": 0, "character": 7}}}
        result = [location, {**location, "range": {"start": {"line": 1, "character": 6}, "end": {"line": 1, "character": 11}}}] if method.endswith("references") else location
    elif method == "textDocument/formatting":
        time.sleep(.15)
        result = [{"range": {"start": {"line": 0, "character": 0}, "end": {"line": 0, "character": 0}}, "newText": "// formatted\n"}]
    elif method == "textDocument/rename":
        result = {"changes": {params["textDocument"]["uri"]: [{"range": {"start": {"line": 1, "character": 6}, "end": {"line": 1, "character": 11}}, "newText": params["newName"]}]}}
    else:
        result = None
    send({"id": message["id"], "result": result})
