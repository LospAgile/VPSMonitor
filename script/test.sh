#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DEVELOPER_DIR="$(xcode-select -p)"
TEST_FRAMEWORKS="$TEST_DEVELOPER_DIR/Library/Developer/Frameworks"
TEST_FLAGS=()

# Recent Command Line Tools bundle Swift Testing outside the default search paths.
# These flags affect test builds only and do not change the system toolchain.
if [[ -d "$TEST_FRAMEWORKS/Testing.framework" ]]; then
  TEST_FLAGS+=( -Xswiftc -F -Xswiftc "$TEST_FRAMEWORKS" )
  TEST_FLAGS+=( -Xlinker -F -Xlinker "$TEST_FRAMEWORKS" )
  TEST_FLAGS+=( -Xlinker -rpath -Xlinker "$TEST_FRAMEWORKS" )
  TEST_FLAGS+=( -Xlinker -rpath -Xlinker "$TEST_DEVELOPER_DIR/Library/Developer/usr/lib" )
fi

cd "$ROOT_DIR"
exec swift test --disable-xctest "${TEST_FLAGS[@]}" "$@"
