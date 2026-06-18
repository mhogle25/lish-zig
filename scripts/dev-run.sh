#!/bin/sh
# Rebuild lish, then exec it with the given args, so a "run" command always uses
# a fresh binary. Build log keeps stdout/stderr clean; on build failure the last
# good binary runs.
set -e
dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$dir"
zig build > "${TMPDIR:-/tmp}/lish-build.log" 2>&1 || true
exec "$dir/zig-out/bin/lish" "$@"
