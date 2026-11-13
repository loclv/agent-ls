#!/usr/bin/env bash
# Tests for al. Builds nothing: run `make test`, or set AL to a
# built binary.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
ALS=${AL:-"$ROOT/al"}
if [ ! -x "$ALS" ]; then
    echo "FAIL: $ALS is not executable (run: goose build al.goose)" >&2
    exit 1
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/al-test.XXXXXX")
FIX="$TMP/fixture"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

expect_contains() {
    local haystack=$1 needle=$2 label=${3:-output}
    case $haystack in
        *"$needle"*) ;;
        *) fail "$label does not contain: $needle" ;;
    esac
}

expect_not_contains() {
    local haystack=$1 needle=$2 label=${3:-output}
    case $haystack in
        *"$needle"*) fail "$label unexpectedly contains: $needle" ;;
        *) ;;
    esac
}

mkdir -p "$FIX/.git" "$FIX/node_modules" "$FIX/src" "$FIX/sub"
printf '[core]\n' > "$FIX/.git/config"
printf 'noise\n' > "$FIX/node_modules/x.js"
printf 'package main\n\nfunc main() {}\n' > "$FIX/src/main.go"
printf 'package main\n' > "$FIX/src/util.go"
printf '# Fixture\n\nTwo lines.\n' > "$FIX/README.md"
printf '\x00\x01\x02binary\n' > "$FIX/data.bin"
printf '#!/bin/sh\necho hi\n' > "$FIX/run.sh"
chmod +x "$FIX/run.sh"
printf 'hidden\n' > "$FIX/.hidden"
printf 'deep\n' > "$FIX/sub/deep.txt"
: > "$FIX/empty.txt"
printf 'tab\n' > "$FIX/tab"$'\t'"name.txt"
printf 'nl\n' > "$FIX/nl"$'\n'"name.txt"
ln -s README.md "$FIX/link.txt"

# --- basics ---------------------------------------------------------------
version=$("$ALS" --version)
expect_contains "$version" "al 1." "--version"

help=$("$ALS" --help)
expect_contains "$help" "usage: al" "--help"
expect_contains "$help" "--depth" "--help"

out=$("$ALS" "$FIX")
expect_not_contains "$out" "#" "default has no header"
expect_not_contains "$out" $'\t' "default has no tabs"
expect_contains "$out" "src" "default listing"
expect_not_contains "$out" "src/" "default is ls-shaped, no trailing slash"
expect_not_contains "$out" "src/main.go" "depth 1"
expect_contains "$out" "link.txt" "symlink"
expect_contains "$out" "data.bin" "binary"

table=$("$ALS" --table "$FIX")
expect_contains "$table" "# path	kind	size	lines	tokens	age	flags	lang" "table header"
expect_contains "$table" "src/" "table listing"

# The default is exactly one name per line, matching the table's row count.
[ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = "$(printf '%s\n' "$table" | grep -vc '^#')" ] || fail "default should be one name per line"

# Ignored noise is absent by default, counted in the summary, and shown on
# request without being descended into.
expect_not_contains "$table" ".git/" "default ignore"
expect_not_contains "$table" "node_modules/" "default ignore"
expect_contains "$table" "2 ignored" "summary"

all=$("$ALS" --table --all "$FIX")
expect_contains "$all" ".git/" "--all"

ignored=$("$ALS" --table --ignored "$FIX")
expect_contains "$ignored" ".git/" "--ignored"
gitrow=$(printf '%s\n' "$ignored" | grep -F ".git/") || fail "missing .git row"
expect_contains "$gitrow" "	i	" "ignored flag"

# Depth.
depth2=$("$ALS" -d 2 "$FIX")
expect_contains "$depth2" "src/main.go" "depth 2"
expect_contains "$depth2" "sub/deep.txt" "depth 2"
rootonly=$("$ALS" -d 0 "$FIX")
[ "$(printf '%s\n' "$rootonly" | grep -vc '^#')" = "1" ] || fail "-d 0 should list only the root"

# Quiet output is paths only.
quiet=$("$ALS" -q -d 2 "$FIX")
expect_not_contains "$quiet" "#" "quiet"
expect_not_contains "$quiet" $'\t' "quiet"
expect_contains "$quiet" "src/main.go" "quiet"

# Filters and limits.
ext=$("$ALS" -d 2 --ext go "$FIX")
expect_contains "$ext" "src/main.go" "--ext go"
expect_not_contains "$ext" "README.md" "--ext go"
limited=$("$ALS" --table -N 1 "$FIX")
[ "$(printf '%s\n' "$limited" | grep -vc '^#')" = "1" ] || fail "-N 1 should show one row"
expect_contains "$limited" "showing 1 of" "limit summary"

# Flags: executable, binary, and control characters kept inside one column.
runrow=$(printf '%s\n' "$table" | grep -F "run.sh") || fail "missing run.sh row"
expect_contains "$runrow" "	x" "exec flag"
binrow=$(printf '%s\n' "$table" | grep -F "data.bin") || fail "missing data.bin row"
expect_contains "$binrow" "	b" "binary flag"
tabrow=$(printf '%s\n' "$table" | grep -F 'tab\tname.txt') || fail "missing escaped tab name"
[ "$(printf '%s' "$tabrow" | awk -F '\t' '{print NF}')" = "8" ] || fail "tab name broke the column count"
expect_contains "$table" 'nl\nname' "escaped newline name"

# Long mode.
long=$("$ALS" -l "$FIX")
expect_contains "$long" "mode	size	lines" "long header"
expect_contains "$long" "rwxr-xr-x" "long mode"

# --no-lines must not claim a text/binary classification.
nolines=$("$ALS" --table --no-lines "$FIX")
emptyrow=$(printf '%s\n' "$nolines" | grep -F "empty.txt") || fail "missing empty.txt"
case $emptyrow in
    *$'\tf\t0B\t-\t-\t'*) ;;
    *) fail "--no-lines should leave lines and tokens unknown: $emptyrow" ;;
esac

# Sorting.
bykind=$("$ALS" --table -s kind "$FIX")
first=$(printf '%s\n' "$bykind" | grep -v '^#' | head -1)
firstkind=$(printf '%s' "$first" | awk -F '\t' '{print $2}')
[ "$firstkind" = "d" ] || fail "-s kind should put a directory first: $first"

# --- JSON -----------------------------------------------------------------
json=$("$ALS" -j -d 2 "$FIX")
printf '%s' "$json" > "$TMP/out.json"
python3 - "$TMP/out.json" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    roots = json.load(f)
assert isinstance(roots, list) and len(roots) == 1, roots
r = roots[0]
s = r["summary"]
assert s["files"] == 10, s
assert s["dirs"] == 2, s
assert s["links"] == 1, s
assert s["bytes"] > 0
paths = {e["path"] for e in r["entries"]}
assert any(p.endswith("src/main.go") for p in paths), paths
assert any(p.endswith("nl\nname.txt") for p in paths), paths
assert all(isinstance(e["depth"], int) for e in r["entries"])
PY

multi=$("$ALS" -j "$FIX/src" "$FIX/sub")
printf '%s' "$multi" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert len(d)==2, len(d)'

# --- errors ---------------------------------------------------------------
set +e
missing=$("$ALS" "$TMP/does-not-exist" 2>&1)
status=$?
set -e
[ "$status" = "1" ] || fail "missing path should exit 1, got $status"
expect_contains "$missing" "no such file or directory" "missing path"
[ -z "$(printf '%s\n' "$missing" | grep -v '^al:')" ] || fail "missing path should not print an empty table"

echo "ok: all al tests passed"
