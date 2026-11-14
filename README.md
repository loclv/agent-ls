# al

`ls` for AI agents, not humans.

`ls` is designed for eyes: it optimizes for scanning and color. An agent
needs different facts before it decides what to read: how large a file is,
whether it is text, how many lines it has, roughly how many tokens reading
it will cost, how old it is, and which directories are generated noise.
`al` by default prints plain names, one per line, like `ls` when piped;
`--table` puts exactly those facts in one deterministic, tab-separated table;
`--csv` and `--json` provide machine-readable formats.

It is a single ~1,000-line [Goose](https://github.com/aardappel/goose)
program plus a small C shim for the filesystem metadata Goose's standard
library does not expose.

## Quick start

Requirements: a Goose compiler (built and tested with the v2026.3 release)
and a C compiler, which `goose build` already needs.

```sh
goose build al.goose
./al
```

```text
Makefile
README.md
src
test
```

`--table` adds the facts an agent needs before reading:

```text
$ ./al --table
# path	kind	size	lines	tokens	age	flags	lang
README.md	f	3.4K	112	~870	2d	-	markdown
al.goose	f	33K	1020	~8.5k	12s	-	goose
scratch/	d	-	-	-	4m	-	-
src/	d	-	-	-	4m	-	-
src/fs.c	f	8.8K	281	~2.3k	4m	-	c
# .: 5 entries (2 dirs, 3 files), 45K, ~12k tokens, 1 ignored
```

For tools that consume comma-separated records, use `--csv`. It emits a
header and one RFC-style quoted CSV row per entry, without the human summary:

```text
$ ./al --csv
"path","kind","size","lines","tokens","age","flags","lang"
"README.md","f","3.4K","112","~870","2d","-","markdown"
```

The TSV table header and summary start with `#`, so a parser can tell them
from rows. Every path is ready to pass to a read tool. No color, no alignment
padding, no locale-dependent dates, no inode or owner columns.

## Compared with `ls`

For a plain listing, a piped `ls` and `al` speak the same language:
one name per line, no columns, no color. `al` only drops known noise
(`node_modules` here) and sorts by bytes, not locale:

```text
$ ls                 $ al
Makefile             Makefile
node_modules         README.md
README.md            src
src                  test
test
```

In a terminal `ls` would switch to padded columns; `al` always keeps
the one-name-per-line shape, so a name is never separated from the next by
more than a newline. Dotfiles such as `.gitignore` are listed (only known
noise like `.git` is pruned), which is the one place the two disagree about
what exists.

## Agent usage

When an AI agent works in a repository, give it this rule (for example in
`AGENTS.md`) instead of aliasing `ls`: it is explicit, scoped to the repo,
and needs no flag compatibility.

> For directory listings use `al`: `al` to discover names,
> `al -T -d 2` to triage a subtree, and `al -R` instead of
> `ls -R` or `ls -lR`. Never run `ls -lR` / `ls -R` on a repo root.

## Git proxy

`al git <args>` runs git through a token-saving proxy: same commands, shorter
output. Color codes and repeated blank lines are stripped, and the formats an
agent reads most are already chosen:

| you type | runs |
| --- | --- |
| `al git` | `git status --short --branch` |
| `al git status` | short rows, branch line first |
| `al git log` | one line per commit, newest first, at most 30 |
| `al git diff` / `show` | `--stat` instead of a patch |

Everything else (`add`, `commit`, `push`, `checkout`, `branch`, ...) is passed
through untouched, so writes behave exactly like git, and the exit code is
git's. Override a default the usual git way: `al git diff -p` for the full
patch, `al git log --format=fuller`, `al git status --long`.

## Why it is shaped this way

- **Cost is a first-class column.** `lines` and `tokens` let an agent decide
  between reading a file, reading a range, and not reading it at all. The
  token count is a labelled estimate (`bytes / 4`), not a tokenizer promise.
- **Noise is skipped by default, but never hidden silently.** `.git`,
  `node_modules`, `__pycache__`, `dist`, `target`, `vendor` and similar
  build/VCS directories are pruned. The summary reports how many were
  skipped; `--ignored` shows them as `i` rows without descending, and
  `--all` includes everything.
- **One row per entry, one pass per file.** The native layer returns type,
  mode, size and mtime from the same `stat` that follows `readdir`, and only
  then reads a file if a line count is requested. The default plain mode
  requests none, so it does no reads at all.
- **Deterministic output.** Rows are always sorted, paths are explicit, and
  the format does not change with terminal width, `TERM`, locale or time
  zone (ages are relative; `--long` uses UTC).
- **Machine modes are not an afterthought.** The default is one name per
  line, so nothing is padded. `--csv` emits standard quoted CSV records;
  `--json` emits a stable schema with per-root summaries. `-q` is the default
  text mode even when `-l` asks for more; the table is explicit via `--table`.

## Output

### Text (default)

Plain names, one line each, like `ls` when piped. There is no header, no
summary and no padding, so a name is never separated from the next by more
than a newline. Directories are listed without a trailing slash, and file
contents are not read, which keeps the default as cheap as `ls`.

### Table

`--table` (`-T`, also implied by `-l`) prints one tab-separated row per
entry:

| column | meaning |
| --- | --- |
| `path` | path relative to the root given on the command line (or the root itself) |
| `kind` | `d` directory, `f` file, `l` symlink, `o` other |
| `size` | apparent bytes, `K`/`M`/`G`/`T`, one decimal below 100 |
| `lines` | line count for text files, `-` for directories, links, binaries and oversized files |
| `tokens` | `~` plus estimated tokens to read the whole file (`bytes / 4`), text only |
| `age` | time since mtime: `5m`, `3h`, `2d`, `4mo`, `1y` |
| `flags` | `i` ignored, `b` binary, `x` executable, `-` none |
| `lang` | language guessed from the name, `-` when unknown |

`--long` inserts `mode` (an `ls`-style permission string) after `kind` and
an ISO-8601 UTC `mtime` before `age`.

Paths containing a tab, newline, backslash or control byte are escaped as
`\t`, `\n`, `\\` and `\xNN` so a row can never break its columns. JSON
carries the exact bytes.

### CSV

`--csv` uses the same columns and values as the tab-separated table, with
standard CSV quoting for every field. Embedded quotes are doubled, and
commas or newlines in paths remain inside their quoted field. It emits no
summary rows, so the output can be read directly as CSV. `--no-header` and
`--long` work with CSV too.

### JSON

```sh
al --json --depth 2 .
```

```json
[
  {
    "root": ".",
    "entries": [
      {
        "path": "src/main.go",
        "kind": "file",
        "mode": "644",
        "size": 1820,
        "lines": 64,
        "tokens": 455,
        "mtime": 1794537517,
        "depth": 2,
        "ignored": false,
        "binary": false,
        "lang": "go"
      }
    ],
    "summary": {
      "entries": 1, "dirs": 0, "files": 1, "links": 0, "other": 0,
      "bytes": 1820, "tokens": 455, "ignored": 0, "errors": 0,
      "truncated": false
    }
  }
]
```

`size` is `null` for directories; `lines`, `tokens` and `lang` are `null`
when unknown. With several roots the array has one object per root, in the
order given.

### Exit codes

`0` success, `1` at least one path could not be listed (others are still
printed), `2` a usage error.

## Options

```
al [options] [path ...]
al git [git options] ...

  git [args ...]    run git with token-saving defaults (see `al git --help`)

  -d, --depth N     levels below the root (default 1, 0 = the root only)
  -R                recurse (depth 64)
  -a, --all         include VCS internals and build/vendor noise
      --ignored     show ignored entries, marked i, without descending
  -T, --table       tab-separated metadata table
      --csv         CSV metadata table for machine consumption
  -s, --sort KEY    name (default), size, time, kind
      --reverse     reverse the order
  -N, --limit N     show at most N entries per root
      --ext LIST    only files with these extensions (go,ts,py)
  -l, --long        CSV with mode and an ISO-8601 UTC mtime
      --no-lines    skip reads; no line counts, token estimates or binary flags
      --no-header   omit the header row (table and CSV)
      --no-summary  omit the # summary row (table only)
  -q, --quiet       plain names only (the default), even with -l
  -j, --json        JSON array, one object per root, with a summary
  -h, --help        full help
  -v, --version     print the version
```

Short boolean flags may be clustered (`-qR`). Value options accept both
`-d 2` and `-d2`, and `--depth=2`.

Sorting: `name` is ascending, `size` is largest first, `time` is newest
first, and `kind` groups directories before files before links. `--reverse`
flips the result.

## Install

```sh
make
make test
make install                 # ~/.local/bin/al
make install PREFIX=/usr/local
```

Or build and copy by hand:

```sh
goose build al.goose
install -m 755 al ~/.local/bin/al
```

The build produces one self-contained executable. `src/fs.c` includes
`goose.h` from the compiler's toolchain; no other dependency is involved.

For development, `goose al.goose -- --depth 2 .` runs from source and
rebuilds the C shim in-process.

## Design

- `al.goose` is the whole tool: CLI parsing, ignoring, walking,
  sorting, text/JSON rendering, and the output contract.
- `src/fs.c` is the only native code. Goose's `os` module can list names but
  has no `stat`, so this adds `listdir + lstat` records, a root `stat`, a
  line counter with a binary probe, and UTC time formatting.
- Paths are interned in one grow-only `u8[>..]` pool, and `Item` stores them
  as slices. Every `Item` is therefore fixed-size, so the array can be
  sorted in place. Because Goose's grow-only arrays never move existing
  bytes, those slices stay valid for the run.
- The walker is an explicit stack of directories, not recursion, so each
  directory's listing buffer can be freed at the end of its iteration.
- Collections are capped at 200,000 entries; unreadable directories are
  reported per path, and the rest of the listing still completes.

## Limitations

- Symlinks are listed (`l`) but never followed or descended, which avoids
  cycles; their targets are not shown yet.
- `.gitignore` files are not parsed. Noise is a fixed, documented list;
  `--all` bypasses it entirely.
- `tokens` is the usual `bytes / 4` heuristic, not a model tokenizer.
- Files larger than 4 MiB are not read for line counts; their `lines` and
  `tokens` are `-`.
- Text/binary classification uses an extension table plus a NUL probe of the
  first 8 KiB of files whose extension is not known to be binary.
- The C shim has a Windows branch, but only macOS has been exercised here.
- Not yet: git status markers, link targets, content previews, and a
  listing token budget. The fixed-column output and JSON schema leave room
  for them.

## Tests

```sh
make test
```

`test/run.sh` builds a fixture tree with hidden files, ignored directories,
a symlink, a binary, an executable, empty files, a tab in a name and a
newline in a name. It checks depth, filters, sorting, limits, escaping,
exit codes, and validates the JSON with Python.
