#!/usr/bin/env bash
# Exercises native faults in child hosts, including presentation cleanup and idle window waking.
set -euo pipefail
source "$(dirname "$0")/deps.sh"
cd "$here"
stage_natives bin
mkdir -p bin/check-native-isolation
rustc --edition 2024 --crate-type cdylib -C opt-level=1 tests/fixtures/nativeextension/fault.rs \
  -o "bin/check-native-isolation/${prefix}fault.$ext"
haxe "${ui_args[@]}" -cp tests -main NativeExtensionChecks -hl bin/native-extension-checks.hl
haxe "${ui_args[@]}" -cp tests -main NativeExtensionViewChecks -hl bin/native-extension-view.hl
haxe "${ui_args[@]}" -D ashui_window -cp tests -main ExtensionIdleWindow -hl bin/native-extension-idle.hl
ulimit -c 0 || true
export ASH="$ash"
"$ash" --preset application bin/native-extension-checks.hl
"$ash" --preset application bin/native-extension-view.hl
RAYDE_IDLE_NATIVE="$here/bin/check-native-isolation/native-test.rayext" "$ash" --preset application bin/native-extension-idle.hl
