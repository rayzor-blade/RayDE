#!/usr/bin/env python3
"""Exercise two native Jam clients locally, or use an idle SSH host as participant two."""
import argparse
import json
from pathlib import Path
import queue
import random
import subprocess
import threading
import time
from urllib.parse import urlsplit


class Peer:
    def __init__(self, command):
        self.process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.PIPE, text=True, bufsize=1)
        self.events = queue.Queue()
        self.errors = []
        def read():
            for line in self.process.stdout:
                try:
                    self.events.put(json.loads(line))
                except ValueError:
                    self.errors.append(line)
        def errors():
            self.errors.extend(self.process.stderr)
        threading.Thread(target=read, daemon=True).start()
        threading.Thread(target=errors, daemon=True).start()

    def send(self, **command):
        self.process.stdin.write(json.dumps(command, ensure_ascii=False) + "\n")
        self.process.stdin.flush()

    def until(self, predicate, timeout=15):
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            try:
                event = self.events.get(timeout=min(0.2, max(0.01, end-time.monotonic())))
            except queue.Empty:
                if self.process.poll() is not None:
                    raise AssertionError(f"Peer exited: {self.errors}")
                continue
            if event.get("t") == "failed":
                raise AssertionError(event)
            if predicate(event):
                return event
        raise AssertionError(f"Peer event timeout: {self.errors}")

    def text(self, expected):
        end = time.monotonic() + 15
        while time.monotonic() < end:
            self.send(op="snapshot")
            event = self.until(lambda e: e.get("t") == "snapshot")
            if event["text"] == expected:
                return
            time.sleep(0.03)
        raise AssertionError(f"Expected {expected!r}; got {event}")

    def close(self):
        if self.process.poll() is None:
            try:
                self.send(op="close")
                self.process.wait(timeout=5)
            except (BrokenPipeError, subprocess.TimeoutExpired):
                self.process.terminate()
                self.process.wait(timeout=5)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--ssh", help="Use this SSH host as participant two through a reverse loopback tunnel")
    parser.add_argument("--remote-binary", default="rayde-jam")
    args = parser.parse_args()
    binary = Path(__file__).resolve().parents[1] / "native/jam/target/debug/rayde-jam"
    peers = []
    try:
        a = Peer([str(binary), "--stdio"]); peers.append(a)
        base = "hello 🦀"
        a.send(host=True, name="macOS", file="Main.hx", text=base)
        invite = a.until(lambda e: e.get("t") == "hosting")["invite"]
        a.until(lambda e: e.get("t") == "ack")
        command = [str(binary), "--stdio"]
        if args.ssh:
            # Remote compilation is deliberately separate; never start it on a busy host.
            uri = urlsplit(invite)
            port = random.randrange(49152, 60999)
            command = ["ssh", "-o", "ConnectTimeout=5", "-o", "ControlMaster=no", "-o", "ControlPath=none",
                       "-o", "ExitOnForwardFailure=yes", "-R", f"127.0.0.1:{port}:127.0.0.1:{uri.port}",
                       args.ssh, args.remote_binary, "--stdio"]
            invite = f"ws://127.0.0.1:{port}{uri.path}"
        b = Peer(command); peers.append(b)
        b.send(host=False, name="Linux NUC" if args.ssh else "Guest", invite=invite, file="Main.hx")
        b.until(lambda e: e.get("t") == "ack")
        b.text(base)
        for peer in peers:
            peer.send(op="pause", paused=True)
            peer.until(lambda e: e.get("t") == "paused")
        a.send(op="edit", before=base, parts=[{"from": 0, "removed": "", "inserted": "Mac: "}])
        b.send(op="edit", before=base, parts=[{"from": 8, "removed": "", "inserted": " NUC"}])
        a.until(lambda e: e.get("t") == "edited")
        b.until(lambda e: e.get("t") == "edited")
        for peer in peers:
            peer.send(op="pause", paused=False)
        merged = "Mac: hello 🦀 NUC"
        a.text(merged); b.text(merged)
        b.send(op="presence", caret=17, anchor=5, view={"top":5,"offset":0.25,"x":3})
        cursor = a.until(lambda e: e.get("t") == "cursor")
        assert cursor["caret"] == 17 and cursor["anchor"] == 5, cursor
        assert cursor["view"] == {"top":5,"offset":0.25,"x":3}, cursor
        b.send(op="undo")
        a.text("Mac: " + base); b.text("Mac: " + base)
        a.send(op="undo")
        a.text(base); b.text(base)
        a.send(op="redo"); b.send(op="redo")
        a.text(merged); b.text(merged)
        a.close()
        b.until(lambda e: e.get("t") == "room_closed")
        print("Jam peers: concurrent Unicode edits, reconnect convergence, remote selection/viewport, per-author undo/redo and clean exit passed" + (" (macOS + Linux NUC over SSH)" if args.ssh else " (local)"))
    finally:
        for peer in reversed(peers):
            peer.close()


if __name__ == "__main__":
    main()
