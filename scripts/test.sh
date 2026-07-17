#!/usr/bin/env bash
# Runs the test suite. On machines with only the Command Line Tools (no Xcode),
# the Swift Testing framework is installed but not on the default search path.
set -euo pipefail
cd "$(dirname "$0")/.."
F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
if ! xcode-select -p 2>/dev/null | grep -q Xcode.app && [ -d "$F/Testing.framework" ]; then
  exec swift test -Xswiftc -F"$F" -Xlinker -F"$F" -Xlinker -rpath -Xlinker "$F" "$@"
fi
exec swift test "$@"
