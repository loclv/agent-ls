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

# --- git proxy ------------------------------------------------------------
if command -v git >/dev/null 2>&1; then
    G="$TMP/git"
    mkdir -p "$G"
    (
        cd "$G"
        git init -q
        git config user.email al@example.com
        git config user.name al
        printf 'one\n' > a.txt
        git add a.txt
        git commit -qm first -m body
        printf 'two\n' > a.txt
        printf 'new\n' > b.txt
    ) >/dev/null 2>&1

    gs=$("$ALS" git -C "$G" status)
    expect_contains "$gs" "## " "git status branch line"
    expect_not_contains "$gs" "Changes not staged" "git status is short"

    # Only globals were given, so this still reads status.
    gs2=$("$ALS" git -C "$G")
    expect_contains "$gs2" "## " "git with only globals reads status"

    glog=$("$ALS" git -C "$G" log)
    [ "$(printf '%s\n' "$glog" | grep -vc '^$')" = "1" ] || fail "git log should be one line per commit"
    expect_contains "$glog" "first" "git log oneline"

    # A blank line in the commit message survives as exactly one blank line.
    gfuller=$("$ALS" git -C "$G" log --format=fuller)
    expect_contains "$gfuller" $'\n\n    first' "git log keeps a blank line"
    expect_not_contains "$gfuller" $'\n\n\n' "git log collapses blank runs"

    ghelp=$("$ALS" git --help)
    expect_contains "$ghelp" "usage: al git" "git --help"

    gdiff=$("$ALS" git -C "$G" diff)
    expect_contains "$gdiff" "1 file changed" "git diff stat"
    expect_not_contains "$gdiff" "+two" "git diff stat has no patch"

    # Overrides pass through unchanged.
    gp=$("$ALS" git -C "$G" diff -p)
    expect_contains "$gp" "+two" "git diff -p passes the patch through"
    gshort=$("$ALS" git -C "$G" status --long)
    expect_contains "$gshort" "Changes not staged" "status --long override"

    # Forced color is stripped before it reaches stdout.
    gcolor=$("$ALS" git -C "$G" -c color.ui=always log)
    expect_not_contains "$gcolor" $'\033' "color stripped"

    # The exit code is git's.
    set +e
    "$ALS" git -C "$G" rev-parse --verify nosuchbranch >/dev/null 2>&1
    gerr=$?
    "$ALS" git -C "$G" status >/dev/null 2>&1
    gok=$?
    set -e
    [ "$gerr" = "128" ] || fail "git failure should exit 128, got $gerr"
    [ "$gok" = "0" ] || fail "git success should exit 0, got $gok"
else
    echo "skip: git not found"
fi

echo "ok: all al tests passed"
