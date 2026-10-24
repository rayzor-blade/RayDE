#!/usr/bin/env python3
"""Kill real Jam peers, recover their CRDT clocks and merge durable offline edits."""
import argparse
from pathlib import Path
import queue
import random
import subprocess
import tempfile
import time
from urllib.parse import urlsplit

from jam_peer_checks import Peer


def failure(peer, fragment):
    end = time.monotonic() + 15
    while time.monotonic() < end:
        try:
            event = peer.events.get(timeout=.2)
        except queue.Empty:
            continue
        if event.get("t") == "failed":
            assert fragment in event["message"], event
            return
    raise AssertionError("Expected recoverable join rejection")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--ssh")
    parser.add_argument("--remote-binary", default="rayde-jam")
    args = parser.parse_args()
    binary = str(Path(__file__).resolve().parents[1] / "native/jam/target/debug/rayde-jam")
    ssh = ["ssh", "-o", "ConnectTimeout=5", "-o", "ControlMaster=no", "-o", "ControlPath=none"]
    peers = []
    remote_root = "/tmp/rayde-jam-recovery-" + str(random.randrange(1 << 30))
    with tempfile.TemporaryDirectory(prefix="rayde-jam-recovery-") as root:
        host_root, guest_root = root + "/host", remote_root if args.ssh else root + "/guest"

        def host(store, restore=False):
            peer = Peer([binary, "--stdio"]); peers.append(peer)
            peer.send(host=True, name="Host", file="Main.hx", text="hello 🦀", recovery=store, restore=restore)
            restored = peer.until(lambda e: e.get("t") == "restored") if restore else None
            invite = peer.until(lambda e: e.get("t") == "hosting")["invite"]
            welcome = peer.until(lambda e: e.get("t") == "welcome")
            assert welcome["durable"], welcome
            peer.until(lambda e: e.get("t") == "ack")
            return peer, invite, welcome, restored

        def guest(invite, restore=False):
            command = [binary, "--stdio"]
            if args.ssh:
                uri, port = urlsplit(invite), random.randrange(49152, 60999)
                command = ssh + ["-o", "ExitOnForwardFailure=yes", "-R", f"127.0.0.1:{port}:127.0.0.1:{uri.port}", args.ssh, args.remote_binary, "--stdio"]
                invite = f"ws://127.0.0.1:{port}{uri.path}"
            peer = Peer(command); peers.append(peer)
            peer.send(host=False, name="Guest", file="Main.hx", invite=invite, recovery=guest_root, restore=restore)
            return peer

        def crash(peer):
            peer.send(op="crash")
            assert peer.process.wait(timeout=10) == 86

        try:
            a, original, welcome, _ = host(host_root)
            identity = welcome["document_id"]
            b = guest(original); b.until(lambda e: e.get("t") == "ack")
            a.send(op="edit", before="hello 🦀", parts=[{"from":0,"removed":"","inserted":"Host: "}])
            a.until(lambda e: e.get("t") == "ack" and e.get("id") == 2)
            b.text("Host: hello 🦀")
            b.send(op="pause", paused=True); b.until(lambda e: e.get("t") == "paused")
            b.send(op="edit", before="Host: hello 🦀", parts=[{"from":14,"removed":"","inserted":" offline"}])
            b.until(lambda e: e.get("t") == "locally_saved" and e.get("id") == 2)
            crash(b)
            a.send(op="edit", before="Host: hello 🦀", parts=[{"from":0,"removed":"","inserted":"New: "}])
            a.until(lambda e: e.get("t") == "ack" and e.get("id") == 3)
            # The invitation is never written alongside the source document or recovery records.
            token = urlsplit(original).path.split("/")[-1].encode()
            assert all(token not in path.read_bytes() for path in Path(host_root).iterdir() if path.is_file())
            crash(a)
            a, invite, welcome, restored = host(host_root, True)
            assert welcome["document_id"] == identity and invite != original
            assert restored["text"] == "New: Host: hello 🦀", restored
            b = guest(invite, True)
            restored = b.until(lambda e: e.get("t") == "restored")
            assert restored["text"] == "Host: hello 🦀 offline", restored
            b.until(lambda e: e.get("t") == "ack")
            merged = "New: Host: hello 🦀 offline"
            a.text(merged); b.text(merged)
            b.close(); a.close()
            # A different room with the same filename cannot absorb an old replica's edits.
            wrong, wrong_invite, _, _ = host(root + "/unrelated")
            rejected = guest(wrong_invite, True)
            failure(rejected, "different Jam")
            rejected.process.wait(timeout=10)
            recovered = guest(invite, True)
            restored = recovered.until(lambda e: e.get("t") == "restored")
            assert restored["text"] == merged, restored
            recovered.close(); wrong.close()
            print("Jam recovery: host/client process crashes, durable offline merge, identity preservation, secret rotation and unrelated-room rejection passed" + (" (macOS + Linux NUC over SSH)" if args.ssh else " (local)"))
        finally:
            for peer in reversed(peers):
                peer.close()
            if args.ssh:
                subprocess.run(ssh + [args.ssh, "rm", "-rf", "--", remote_root], check=True)


if __name__ == "__main__":
    main()
