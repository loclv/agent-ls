// al: a directory listing for AI agents, not humans.
//
// ls answers "what is here?" for eyes. An agent needs more: how big is it,
// is it text, how many lines and roughly how many tokens will reading it
// cost, how old is it, and is it noise it should skip. al answers that
// in one deterministic, tab-separated table, or as JSON.
//
// Build:  goose build al.goose
// Run:    al --depth 2 .
//
// The native half (src/fs.c) supplies the stat metadata and text probe that
// the standard library's `os` module does not expose.

import std;
import os;

// ---------------------------------------------------------------- C boundary

extern "al_list" fn fs_list(path: const u8[:], out: u8[>..]&) -> bool;
extern "al_meta" fn fs_meta(path: const u8[:], out: u8[>..]&) -> i64;
extern "al_count_lines" fn fs_count_lines(path: const u8[:], max_bytes: i64) -> i64;
extern "al_time" fn fs_time(seconds: i64, out: u8[>..]&);
// Run a NUL-separated argv without a shell; captures stdout and stderr apart.
extern "al_run" fn fs_run(args: const u8[:], out: u8[>..]&, err: u8[>..]&) -> i64;

// ------------------------------------------------------------------- limits

const VERSION = "1.1.0";
const DEFAULT_DEPTH = 1;
const MAX_DEPTH = 64;
const MAX_ITEMS = 200000;
const MAX_LINE_BYTES = 4 * 1024 * 1024;   // don't read huge files just to count lines

// -------------------------------------------------------------------- types

enum SortKey { Name, Size, Time, Kind }

struct Options {
    depth: i64 = DEFAULT_DEPTH,
    json: bool = false,
    csv: bool = false,
    quiet: bool = false,
    table: bool = false,
    long: bool = false,
    lines: bool = true,
    all: bool = false,
    show_ignored: bool = false,
    summary: bool = true,
    header: bool = true,
    reverse: bool = false,
    limit: i64 = 0,
    sort: SortKey = SortKey.Name,
}

struct Item {
    path: const u8[:],       // display path, relative to the root the user gave
    kind: u8,                // d, f, l, o
    mode: i64,
    size: i64,
    mtime: i64,
    depth: i64,
    lines: i64,              // -1 when unknown
    tokens: i64,             // estimated text tokens, -1 when unknown
    lang: const u8[:],
    ignored: bool = false,
    binary: bool = false,
}

struct DirFrame {
    rel: const u8[:],        // path below the root, "" for the root itself
    depth: i64,              // 0 for the root's own listing
}

struct Meta {
    kind: u8,
    mode: i64,
    size: i64,
    mtime: i64,
    ok: bool,
}

struct RootResult {
    root: const u8[:],
    start: i64,
    end: i64,
    dirs: i64 = 0,
    files: i64 = 0,
    links: i64 = 0,
    other: i64 = 0,
    bytes: i64 = 0,
    tokens: i64 = 0,
    ignored: i64 = 0,
    errors: i64 = 0,
    truncated: bool = false,
}

// ----------------------------------------------------------------- globals

// Every path we print or stat is a slice into this grow-only pool, so an
// Item is fixed-size and arrays of Items can be sorted. Growth never moves
// earlier bytes, which is what makes the slices safe.
var text_pool: u8[>..] = [];
var items: Item[>..] = [];
var roots: RootResult[>..] = [];
var dir_stack: DirFrame[>..<] = [];
var ext_filter: const u8[:][>..] = [];
var total_errors = 0;

// Sort comparator state, set once from the CLI.
var sort_key = SortKey.Name;
var sort_reverse = false;

// ------------------------------------------------------------------- text

const HELP: const u8[:] = """
al - a directory listing for AI agents

usage: al [options] [path ...]

Defaults to the current directory and one level of entries. The default
output is plain names, one per line, like `ls` when piped: no header, no
summary, no metadata, no padding. Use --table for the rich tab-separated
table with sizes, line counts and token estimates.

Table columns (--table): path, kind, size, lines, tokens, age, flags, lang
  kind   d directory, f file, l symlink, o other
  size   apparent bytes (K/M/G, one decimal below 100)
  lines  line count for text files, - otherwise
  tokens estimated tokens to read the whole file (bytes/4), text only
  age    time since last modification: 5m, 3h, 2d, 4mo, 1y
  flags  i ignored, b binary, x executable, - none
  lang   language guessed from the name

commands:
  git [args ...]    run git with token-saving defaults; see `al git --help`
  grep [args ...]   run grep with color stripped and blank runs collapsed
  rg [args ...]     run rg with color stripped and blank runs collapsed

options:
  -d, --depth N     levels below the root (default 1, 0 = the root only)
  -R                recurse (depth 64)
  -a, --all         include VCS internals and build/vendor noise
      --ignored     show ignored entries, marked i, without descending
  -T, --table       tab-separated metadata table (old default)
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
      --help        this text
  -v, --version     print the version

Sorting: name is ascending, size is largest first, time is newest first.
--reverse flips that. Directories and files sort together by full path.

examples:
  al                       plain names, like ls
  al -T                    what is in this directory, with costs
  al -T -d 2 src           two levels, with line counts and tokens
  al -q --ext go,ts .      just the source paths
  al -j -R --limit 500 .   machine-readable, bounded

  al git                   git status --short --branch
  al git log               one line per commit, at most 30
  al git diff              --stat instead of a patch
""";

fn fatal(msg: const u8[:]) {
    var e: u8[>..] = [];
    format(e, "al: ", msg, "\nTry 'al --help'.\n");
    write_stderr(e);
    exit(2);
}

fn report_error(path: const u8[:], msg: const u8[:]) {
    var e: u8[>..] = [];
    format(e, "al: ", path, ": ", msg, "\n");
    write_stderr(e);
    total_errors += 1;
}

// ------------------------------------------------------------------- paths

fn pool_copy(s: const u8[:]) -> const u8[:] {
    let start = text_pool.len;
    text_pool.append(s);
    return text_pool[start..];
}

// a / b, with exactly one separator at the join.
fn pool_join(a: const u8[:], b: const u8[:]) -> const u8[:] {
    if a.len == 0 { return pool_copy(b); }
    if b.len == 0 { return pool_copy(a); }
    let start = text_pool.len;
    text_pool.append(a);
    if a[a.len - 1] != '/' && a[a.len - 1] != '\\' { text_pool.push('/'); }
    text_pool.append(b);
    return text_pool[start..];
}

// What the user sees: bare paths under ".", rooted paths otherwise.
fn display_join(root: const u8[:], rel: const u8[:]) -> const u8[:] {
    if rel.len == 0 { return pool_copy(root); }
    if root == "." { return pool_copy(rel); }
    return pool_join(root, rel);
}

fn basename(p: const u8[:]) -> const u8[:] {
    var cut = -1;
    for c, i in p {
        if c == '/' || c == '\\' { cut = i; }
    }
    if cut < 0 { return p; }
    return p[cut + 1..];
}

fn file_ext(name: const u8[:]) -> const u8[:] {
    var dot = -1;
    for c, i in name {
        if c == '.' { dot = i; }
    }
    if dot <= 0 || dot + 1 >= name.len { return ""; }
    return name[dot + 1..];
}

// ------------------------------------------------------------------ parsing

fn hex_val(c: u8) -> i64 {
    if c >= '0' && c <= '9' { return c - '0'; }
    if c >= 'a' && c <= 'f' { return c - 'a' + 10; }
    if c >= 'A' && c <= 'F' { return c - 'A' + 10; }
    return -1;
}

fn unescape_into(out: u8[>..]&, s: const u8[:]) {
    var i = 0;
    while i < s.len {
        let c = s[i];
        if c == '\\' && i + 1 < s.len {
            let d = s[i + 1];
            if d == 't' { out.push('\t'); i += 2; }
            else if d == 'n' { out.push('\n'); i += 2; }
            else if d == 'r' { out.push('\r'); i += 2; }
            else if d == '\\' { out.push('\\'); i += 2; }
            else if d == 'x' && i + 3 < s.len {
                let hi = hex_val(s[i + 2]);
                let lo = hex_val(s[i + 3]);
                if hi >= 0 && lo >= 0 {
                    out.push((hi * 16 + lo) as u8);
                    i += 4;
                } else {
                    out.push(c);
                    i += 1;
                }
            } else {
                out.push(c);
                i += 1;
            }
        } else {
            out.push(c);
            i += 1;
        }
    }
}

fn parse_meta(text: const u8[:]) -> Meta {
    let line = trim(text);
    let parts = split(line, '\t');
    if parts.len < 4 { return Meta { kind: 'o', mode: 0, size: 0, mtime: 0, ok: false }; }
    let mode, mok = parse_int(parts[1], 8);
    let size, sok = parse_int(parts[2]);
    let mtime, tok = parse_int(parts[3]);
    return Meta {
        kind: parts[0][0],
        mode: mode,
        size: size,
        mtime: mtime,
        ok: mok && sok && tok,
    };
}

// ------------------------------------------------------------- name tables

fn known_binary(name: const u8[:]) -> bool {
    let e = file_ext(name);
    return e == "png" || e == "jpg" || e == "jpeg" || e == "gif" || e == "webp"
        || e == "ico" || e == "bmp" || e == "tiff" || e == "psd"
        || e == "pdf" || e == "zip" || e == "gz" || e == "tgz" || e == "bz2"
        || e == "xz" || e == "zst" || e == "7z" || e == "rar" || e == "tar"
        || e == "jar" || e == "war" || e == "o" || e == "a" || e == "so"
        || e == "dylib" || e == "dll" || e == "exe" || e == "bin"
        || e == "wasm" || e == "pyc" || e == "pyo" || e == "class"
        || e == "woff" || e == "woff2" || e == "ttf" || e == "otf" || e == "eot"
        || e == "mp3" || e == "mp4" || e == "m4a" || e == "wav" || e == "flac"
        || e == "ogg" || e == "webm" || e == "mov" || e == "avi" || e == "mkv"
        || e == "sqlite" || e == "db";
}

fn lang_of(name: const u8[:]) -> const u8[:] {
    if name == "Dockerfile" || ends_with(name, ".Dockerfile") { return "docker"; }
    if name == "Makefile" || name == "GNUmakefile" { return "make"; }
    if name == "CMakeLists.txt" { return "cmake"; }
    if name == "Justfile" || name == "justfile" { return "just"; }
    if name == ".gitignore" || name == ".dockerignore" || name == ".npmignore" { return "ignore"; }
    if name == ".env" || starts_with(name, ".env.") { return "dotenv"; }
    if name == "README" || name == "LICENSE" || name == "CHANGELOG" || name == "NOTICE" { return "text"; }

    let e = file_ext(name);
    if e == "go" { return "go"; }
    if e == "mod" { return "gomod"; }
    if e == "sum" { return "checksum"; }
    if e == "build" { return "config"; }
    if e == "rs" { return "rust"; }
    if e == "c" || e == "h" { return "c"; }
    if e == "cc" || e == "cpp" || e == "cxx" || e == "hpp" || e == "hh" { return "cpp"; }
    if e == "m" { return "objc"; }
    if e == "mm" { return "objcpp"; }
    if e == "swift" { return "swift"; }
    if e == "py" || e == "pyi" { return "python"; }
    if e == "rb" { return "ruby"; }
    if e == "php" { return "php"; }
    if e == "java" { return "java"; }
    if e == "kt" || e == "kts" { return "kotlin"; }
    if e == "scala" { return "scala"; }
    if e == "cs" { return "csharp"; }
    if e == "fs" || e == "fsx" { return "fsharp"; }
    if e == "js" || e == "jsx" || e == "mjs" || e == "cjs" { return "javascript"; }
    if e == "ts" || e == "tsx" || e == "mts" || e == "cts" { return "typescript"; }
    if e == "vue" { return "vue"; }
    if e == "svelte" { return "svelte"; }
    if e == "goose" { return "goose"; }
    if e == "lua" { return "lua"; }
    if e == "pl" || e == "pm" { return "perl"; }
    if e == "r" { return "r"; }
    if e == "jl" { return "julia"; }
    if e == "dart" { return "dart"; }
    if e == "ex" || e == "exs" { return "elixir"; }
    if e == "erl" || e == "hrl" { return "erlang"; }
    if e == "hs" { return "haskell"; }
    if e == "ml" || e == "mli" { return "ocaml"; }
    if e == "clj" || e == "cljs" { return "clojure"; }
    if e == "elm" { return "elm"; }
    if e == "zig" { return "zig"; }
    if e == "nim" { return "nim"; }
    if e == "v" { return "v"; }
    if e == "sol" { return "solidity"; }
    if e == "sh" || e == "bash" || e == "zsh" || e == "fish" { return "shell"; }
    if e == "ps1" { return "powershell"; }
    if e == "bat" || e == "cmd" { return "batch"; }
    if e == "html" || e == "htm" { return "html"; }
    if e == "css" { return "css"; }
    if e == "scss" || e == "sass" || e == "less" { return "scss"; }
    if e == "xml" { return "xml"; }
    if e == "svg" { return "svg"; }
    if e == "yaml" || e == "yml" { return "yaml"; }
    if e == "toml" { return "toml"; }
    if e == "ini" || e == "cfg" || e == "conf" { return "config"; }
    if e == "json" || e == "jsonc" || e == "json5" || e == "ndjson" { return "json"; }
    if e == "csv" { return "csv"; }
    if e == "tsv" { return "tsv"; }
    if e == "md" || e == "markdown" || e == "mdx" { return "markdown"; }
    if e == "rst" { return "rst"; }
    if e == "txt" { return "text"; }
    if e == "tex" { return "tex"; }
    if e == "adoc" { return "asciidoc"; }
    if e == "sql" { return "sql"; }
    if e == "graphql" || e == "gql" { return "graphql"; }
    if e == "proto" { return "protobuf"; }
    if e == "thrift" { return "thrift"; }
    if e == "lock" { return "lock"; }
    return "";
}

fn junk_dir(name: const u8[:]) -> bool {
    return name == ".git" || name == ".hg" || name == ".svn" || name == ".jj"
        || name == "node_modules" || name == "bower_components"
        || name == "__pycache__" || name == ".mypy_cache" || name == ".pytest_cache"
        || name == ".ruff_cache" || name == ".tox" || name == ".venv" || name == "venv"
        || name == ".next" || name == ".nuxt" || name == ".svelte-kit"
        || name == "dist" || name == "build" || name == "out" || name == "target"
        || name == "vendor" || name == "Pods" || name == "DerivedData"
        || name == ".gradle" || name == ".idea" || name == "coverage"
        || name == ".cache" || name == ".parcel-cache" || name == "obj";
}

fn junk_file(name: const u8[:]) -> bool {
    if name == ".DS_Store" || name == "Thumbs.db" || name == "desktop.ini" { return true; }
    if name == ".git" || name == ".hg" || name == ".svn" || name == ".jj" { return true; }
    return ends_with(name, ".pyc") || ends_with(name, ".pyo")
        || ends_with(name, ".o") || ends_with(name, ".a") || ends_with(name, ".so")
        || ends_with(name, ".dylib") || ends_with(name, ".dll") || ends_with(name, ".exe")
        || ends_with(name, ".class") || ends_with(name, ".wasm");
}

fn should_ignore(name: const u8[:], kind: u8, opt: Options) -> bool {
    if opt.all { return false; }
    if kind == 'd' { return junk_dir(name); }
    return junk_file(name);
}

fn ext_allowed(name: const u8[:]) -> bool {
    if ext_filter.len == 0 { return true; }
    let e = file_ext(name);
    for x in ext_filter {
        if x == e { return true; }
    }
    return false;
}

// ------------------------------------------------------------------ walking

fn kind_rank(kind: u8) -> i64 {
    if kind == 'd' { return 0; }
    if kind == 'f' { return 1; }
    if kind == 'l' { return 2; }
    return 3;
}

fn cmp_i64(a: i64, b: i64) -> i64 {
    if a < b { return -1; }
    if a > b { return 1; }
    return 0;
}

fn item_less(a: const Item&, b: const Item&) -> bool {
    var c = 0;
    if sort_key == SortKey.Name {
        c = compare(a.path, b.path);
    } else if sort_key == SortKey.Size {
        c = cmp_i64(b.size, a.size);
    } else if sort_key == SortKey.Time {
        c = cmp_i64(b.mtime, a.mtime);
    } else {
        c = cmp_i64(kind_rank(a.kind), kind_rank(b.kind));
    }
    if c == 0 { c = compare(a.path, b.path); }
    if sort_reverse { c = -c; }
    return c < 0;
}

fn add_item(display: const u8[:], fs_path: const u8[:], name: const u8[:],
            meta: Meta, depth: i64, ignored: bool, opt: Options) -> Item {
    var it = Item {
        path: display,
        kind: meta.kind,
        mode: meta.mode,
        size: if meta.kind == 'd' { 0 } else { meta.size },
        mtime: meta.mtime,
        depth: depth,
        lines: -1,
        tokens: -1,
        lang: "",
        ignored: ignored,
        binary: false,
    };
    if meta.kind == 'f' {
        it.lang = lang_of(name);
        if opt.lines {
            if known_binary(name) {
                it.binary = true;
            } else {
                let count = fs_count_lines(fs_path, MAX_LINE_BYTES);
                if count >= 0 {
                    it.lines = count;
                    it.tokens = (meta.size + 3) / 4;
                } else {
                    it.binary = true;
                }
            }
        }
    }
    items.push(it);
    return it;
}

fn count_item(res: RootResult&, it: const Item&) {
    if it.kind == 'd' {
        res.dirs += 1;
    } else if it.kind == 'f' {
        res.files += 1;
        res.bytes += it.size;
        if it.tokens > 0 { res.tokens += it.tokens; }
    } else if it.kind == 'l' {
        res.links += 1;
    } else {
        res.other += 1;
    }
}

fn process_root(root: const u8[:], opt: Options) -> RootResult {
    let start = items.len;
    var res = RootResult { root: root, start: start, end: start };

    var meta_text: u8[>..] = [];
    let meta_status = fs_meta(root, meta_text);
    if meta_status != 0 {
        if meta_status == 1 { report_error(root, "no such file or directory"); }
        else { report_error(root, "cannot access path"); }
        res.errors = 1;
        res.end = items.len;
        return res;
    }
    let meta = parse_meta(meta_text);
    if !meta.ok {
        report_error(root, "cannot read metadata");
        res.errors = 1;
        res.end = items.len;
        return res;
    }

    let root_display = display_join(root, "");
    if meta.kind != 'd' {
        let it = add_item(root_display, pool_copy(root), basename(root), meta, 0, false, opt);
        count_item(res, it);
        res.end = items.len;
        return res;
    }

    if opt.depth == 0 {
        let it = add_item(root_display, pool_copy(root), basename(root), meta, 0, false, opt);
        count_item(res, it);
        res.end = items.len;
        return res;
    }

    dir_stack.clear();
    dir_stack.push(DirFrame { rel: "", depth: 0 });
    var stop = false;
    while dir_stack.len > 0 && !stop {
        let frame = dir_stack.pop();
        let dir_fs = if frame.rel.len == 0 { pool_copy(root) } else { pool_join(root, frame.rel) };

        var listing: u8[>..] = [];
        if !fs_list(dir_fs, listing) {
            report_error(dir_fs, "cannot read directory");
            res.errors += 1;
            continue;
        }

        for line in split(listing, '\n') {
            if line.len == 0 { continue; }
            if items.len >= MAX_ITEMS {
                res.truncated = true;
                stop = true;
                break;
            }

            let parts = split(line, '\t');
            if parts.len < 5 { continue; }
            let mode, mok = parse_int(parts[1], 8);
            let size, sok = parse_int(parts[2]);
            let mtime, tok = parse_int(parts[3]);
            if !(mok && sok && tok) { continue; }

            var name_buf: u8[>..] = [];
            unescape_into(name_buf, parts[parts.len - 1]);
            let name = pool_copy(name_buf);
            let kind = parts[0][0];
            if kind == 'f' && !ext_allowed(name) { continue; }

            let child_depth = frame.depth + 1;
            let rel = pool_join(frame.rel, name);
            let display = display_join(root, rel);
            let ignored = should_ignore(name, kind, opt);

            if ignored {
                res.ignored += 1;
                if opt.show_ignored {
                    add_item(display, pool_join(root, rel), name,
                             Meta { kind: kind, mode: mode, size: size, mtime: mtime, ok: true },
                             child_depth, true, opt);
                }
                continue;
            }

            let it = add_item(display, pool_join(root, rel), name,
                              Meta { kind: kind, mode: mode, size: size, mtime: mtime, ok: true },
                              child_depth, false, opt);
            count_item(res, it);

            if kind == 'd' && child_depth < opt.depth {
                dir_stack.push(DirFrame { rel: rel, depth: child_depth });
            }
        }
    }

    res.end = items.len;
    sort(items[res.start..res.end]) { a, b => item_less(a, b) };
    return res;
}

// ---------------------------------------------------------------- rendering

fn format_size(out: u8[>..]&, b: i64) {
    if b < 1024 {
        format(out, b, "B");
        return;
    }
    let units = ["K", "M", "G", "T"];
    var unit = 0;
    var base = 1024;
    while unit < 3 && b >= base * 1024 {
        base *= 1024;
        unit += 1;
    }
    let scaled = (b * 10) / base;
    if scaled >= 100 {
        format(out, scaled / 10, units[unit]);
    } else {
        format(out, scaled / 10, ".", scaled % 10, units[unit]);
    }
}

// Compact count without a unit: 999, 1.2k, 41k, 3.1M.
fn format_compact(out: u8[>..]&, n: i64) {
    if n < 1000 {
        format(out, n);
        return;
    }
    let units = ["k", "M", "G", "T"];
    var unit = 0;
    var base = 1000;
    while unit < 3 && n >= base * 1000 {
        base *= 1000;
        unit += 1;
    }
    let tenths = (n * 10 + base / 2) / base;
    if tenths >= 100 {
        format(out, tenths / 10, units[unit]);
    } else {
        format(out, tenths / 10, ".", tenths % 10, units[unit]);
    }
}

fn format_age(out: u8[>..]&, mtime: i64, now: i64) {
    let age = if now > mtime { now - mtime } else { 0 };
    if age < 60 {
        format(out, age, "s");
    } else if age < 3600 {
        format(out, age / 60, "m");
    } else if age < 86400 {
        format(out, age / 3600, "h");
    } else if age < 86400 * 30 {
        format(out, age / 86400, "d");
    } else if age < 86400 * 365 {
        format(out, age / (86400 * 30), "mo");
    } else {
        format(out, age / (86400 * 365), "y");
    }
}

fn format_mode(out: u8[>..]&, kind: u8, mode: i64) {
    if kind == 'd' { out.push('d'); }
    else if kind == 'l' { out.push('l'); }
    else { out.push('-'); }
    let bits = [256, 128, 64, 32, 16, 8, 4, 2, 1];
    let chars: u8[9] = ['r', 'w', 'x', 'r', 'w', 'x', 'r', 'w', 'x'];
    for i in 9 {
        if (mode & bits[i]) != 0 { out.push(chars[i]); }
        else { out.push('-'); }
    }
}

fn write_flags(out: u8[>..]&, it: const Item&) {
    let start = out.len;
    if it.ignored { out.push('i'); }
    if it.binary { out.push('b'); }
    if it.kind == 'f' && (it.mode & 73) != 0 { out.push('x'); }
    if out.len == start { out.push('-'); }
}

// Text modes escape control bytes so a tab or newline in a name cannot
// break a row. JSON escapes independently and needs no help here.
fn write_escaped_path(out: u8[>..]&, path: const u8[:]) {
    for c in path {
        if c == '\\' { out.append("\\\\"); }
        else if c == '\t' { out.append("\\t"); }
        else if c == '\n' { out.append("\\n"); }
        else if c == '\r' { out.append("\\r"); }
        else if c < 0x20 || c == 0x7f {
            out.append("\\x");
            format_int(out, c, 16, 2, '0');
        } else {
            out.push(c);
        }
    }
}

fn write_path(out: u8[>..]&, it: const Item&) {
    write_escaped_path(out, it.path);
    if it.kind == 'd' && (it.path.len == 0 || it.path[it.path.len - 1] != '/') { out.push('/'); }
}

// Plain mode is `ls`-shaped: just the name, no trailing slash, no metadata.
fn write_plain_path(out: u8[>..]&, it: const Item&) {
    write_escaped_path(out, it.path);
}

fn write_row(out: u8[>..]&, it: const Item&, now: i64, opt: Options) {
    write_path(out, it);
    out.push('\t');
    out.push(it.kind);
    out.push('\t');
    if opt.long {
        format_mode(out, it.kind, it.mode);
        out.push('\t');
    }
    if it.kind == 'd' { out.push('-'); }
    else { format_size(out, it.size); }
    out.push('\t');
    if it.lines >= 0 { format(out, it.lines); }
    else { out.push('-'); }
    out.push('\t');
    if it.tokens >= 0 {
        out.push('~');
        format_compact(out, it.tokens);
    } else {
        out.push('-');
    }
    out.push('\t');
    if opt.long {
        fs_time(it.mtime, out);
        out.push('\t');
    }
    format_age(out, it.mtime, now);
    out.push('\t');
    write_flags(out, it);
    out.push('\t');
    if it.lang.len > 0 { out.append(it.lang); }
    else { out.push('-'); }
    out.push('\n');
}

fn write_header(out: u8[>..]&, opt: Options) {
    out.append("# path\tkind\t");
    if opt.long { out.append("mode\t"); }
    out.append("size\tlines\ttokens\t");
    if opt.long { out.append("mtime\t"); }
    out.append("age\tflags\tlang\n");
}

// CSV fields are quoted uniformly, with embedded quotes doubled. This keeps
// paths containing commas, quotes or newlines valid in a standard CSV reader.
fn write_csv_field(out: u8[>..]&, value: const u8[:]) {
    out.push('"');
    for c in value {
        if c == '"' { out.append("\"\""); }
        else { out.push(c); }
    }
    out.push('"');
}

fn csv_field(out: u8[>..]&, value: const u8[:], first: bool) {
    if !first { out.push(','); }
    write_csv_field(out, value);
}

fn write_csv_row(out: u8[>..]&, it: const Item&, now: i64, opt: Options) {
    var field: u8[>..] = [];
    write_path(field, it);
    csv_field(out, field, true);
    field = [];
    field.push(it.kind);
    csv_field(out, field, false);
    field = [];
    if opt.long { format_mode(field, it.kind, it.mode); }
    if opt.long { csv_field(out, field, false); field = []; }
    if it.kind == 'd' { field.push('-'); }
    else { format_size(field, it.size); }
    csv_field(out, field, false);
    field = [];
    if it.lines >= 0 { format(field, it.lines); }
    else { field.push('-'); }
    csv_field(out, field, false);
    field = [];
    if it.tokens >= 0 { field.push('~'); format_compact(field, it.tokens); }
    else { field.push('-'); }
    csv_field(out, field, false);
    field = [];
    if opt.long { fs_time(it.mtime, field); csv_field(out, field, false); field = []; }
    format_age(field, it.mtime, now);
    csv_field(out, field, false);
    field = [];
    write_flags(field, it);
    csv_field(out, field, false);
    field = [];
    if it.lang.len > 0 { field.append(it.lang); }
    else { field.push('-'); }
    csv_field(out, field, false);
    out.push('\n');
}

fn write_csv_header(out: u8[>..]&, opt: Options) {
    out.append("\"path\",\"kind\",");
    if opt.long { out.append("\"mode\","); }
    out.append("\"size\",\"lines\",\"tokens\",");
    if opt.long { out.append("\"mtime\","); }
    out.append("\"age\",\"flags\",\"lang\"\n");
}

fn append_count(out: u8[>..]&, n: i64, word: const u8[:]) {
    if n == 1 {
        format(out, n, " ", word);
    } else if word == "entry" {
        format(out, n, " entries");
    } else {
        format(out, n, " ", word, "s");
    }
}

fn write_summary(out: u8[>..]&, res: const RootResult&, opt: Options) {
    let tracked = res.dirs + res.files + res.links + res.other;
    let rows = res.end - res.start;
    var visible = rows;
    if opt.limit > 0 && visible > opt.limit { visible = opt.limit; }

    format(out, "# ", res.root, ": ");
    append_count(out, tracked, "entry");
    out.append(" (");
    append_count(out, res.dirs, "dir");
    out.append(", ");
    append_count(out, res.files, "file");
    if res.links > 0 {
        out.append(", ");
        append_count(out, res.links, "link");
    }
    if res.other > 0 {
        out.append(", ");
        append_count(out, res.other, "other");
    }
    out.append("), ");
    format_size(out, res.bytes);
    if res.tokens > 0 {
        out.append(", ~");
        format_compact(out, res.tokens);
        out.append(" tokens");
    }
    if res.ignored > 0 {
        format(out, ", ", res.ignored, " ignored");
        if opt.show_ignored { out.append(" (shown)"); }
    }
    if res.errors > 0 {
        out.append(", ");
        append_count(out, res.errors, "error");
    }
    if res.truncated { format(out, ", stopped at ", MAX_ITEMS, " entries"); }
    if visible < rows { format(out, ", showing ", visible, " of ", rows); }
    out.push('\n');
}

// --------------------------------------------------------------------- JSON

fn json_str(out: u8[>..]&, s: const u8[:]) {
    out.push('"');
    for c in s {
        if c == '"' { out.append("\\\""); }
        else if c == '\\' { out.append("\\\\"); }
        else if c == '\n' { out.append("\\n"); }
        else if c == '\t' { out.append("\\t"); }
        else if c == '\r' { out.append("\\r"); }
        else if c < 0x20 {
            out.append("\\u00");
            format_int(out, c, 16, 2, '0');
        } else {
            out.push(c);
        }
    }
    out.push('"');
}

fn json_kind(out: u8[>..]&, kind: u8) {
    if kind == 'd' { out.append("\"dir\""); }
    else if kind == 'f' { out.append("\"file\""); }
    else if kind == 'l' { out.append("\"link\""); }
    else { out.append("\"other\""); }
}

fn json_opt_i64(out: u8[>..]&, v: i64) {
    if v < 0 { out.append("null"); }
    else { format(out, v); }
}

fn write_json_item(out: u8[>..]&, it: const Item&) {
    out.append("{\"path\":");
    json_str(out, it.path);
    out.append(",\"kind\":");
    json_kind(out, it.kind);
    out.append(",\"mode\":\"");
    format_int(out, it.mode, 8, 3, '0');
    out.append("\",\"size\":");
    if it.kind == 'd' { out.append("null"); }
    else { format(out, it.size); }
    out.append(",\"lines\":");
    json_opt_i64(out, it.lines);
    out.append(",\"tokens\":");
    json_opt_i64(out, it.tokens);
    out.append(",\"mtime\":");
    format(out, it.mtime);
    out.append(",\"depth\":");
    format(out, it.depth);
    out.append(",\"ignored\":");
    out.append(if it.ignored { "true" } else { "false" });
    out.append(",\"binary\":");
    out.append(if it.binary { "true" } else { "false" });
    out.append(",\"lang\":");
    if it.lang.len == 0 { out.append("null"); }
    else { json_str(out, it.lang); }
    out.push('}');
}

fn write_json(out: u8[>..]&, opt: Options) {
    out.push('[');
    for res, ri in roots {
        if ri > 0 { out.push(','); }
        out.append("{\"root\":");
        json_str(out, res.root);
        out.append(",\"entries\":[");
        var shown = 0;
        for i in res.start..res.end {
            if opt.limit > 0 && shown >= opt.limit { break; }
            if shown > 0 { out.push(','); }
            write_json_item(out, items[i]);
            shown += 1;
        }
        out.append("],\"summary\":{\"entries\":");
        format(out, res.end - res.start);
        out.append(",\"dirs\":");
        format(out, res.dirs);
        out.append(",\"files\":");
        format(out, res.files);
        out.append(",\"links\":");
        format(out, res.links);
        out.append(",\"other\":");
        format(out, res.other);
        out.append(",\"bytes\":");
        format(out, res.bytes);
        out.append(",\"tokens\":");
        format(out, res.tokens);
        out.append(",\"ignored\":");
        format(out, res.ignored);
        out.append(",\"errors\":");
        format(out, res.errors);
        out.append(",\"truncated\":");
        out.append(if res.truncated { "true" } else { "false" });
        out.append("}}");
    }
    out.append("]\n");
}

// --------------------------------------------------------------------- git

// `al git` runs the real git but asks for the formats an agent reads most:
// short status, one-line log, stat diffs. Everything else is passed through
// untouched, so add/commit/push/checkout behave exactly like git. Defaults
// only fill in when the user has not chosen a format already, so `al git diff
// -p` still prints a patch and `al git log --format=fuller` works too.

const GIT_LOG_LIMIT: const u8[:] = "30";   // one line per commit cap

const GIT_HELP: const u8[:] = """
al git - git output with fewer tokens

usage: al git [git arguments ...]

Runs git, strips color codes and blank lines, and returns git's exit code.
The defaults save tokens; they never hide an error:

  al git                   git status --short --branch
  al git status            short rows, branch line first
  al git log               one line per commit, newest first, at most 30
  al git diff              --stat instead of a patch
  al git show              --stat instead of a patch

Everything else (add, commit, push, checkout, ...) is passed through
unchanged. Override a default the usual git way: `al git diff -p` for the
patch, `al git log --format=oneline`, `al git status --long`.
""";

// `git -C <dir>` style globals take a value; skip past it to find the command.
fn git_global_takes_value(a: const u8[:]) -> bool {
    return a == "-C" || a == "-c" || a == "--git-dir" || a == "--work-tree"
        || a == "--namespace" || a == "--exec-path" || a == "--config-env";
}

fn git_subcommand_index(args: const u8[:][>..]&) -> i64 {
    var k = 0;
    while k < args.len {
        let a = args[k];
        if a.len > 0 && a[0] != '-' { return k; }
        if git_global_takes_value(a) && k + 1 < args.len { k += 2; }
        else { k += 1; }
    }
    return -1;
}

// The flag itself or `--name=value`. Short flags also match the clustered
// forms (`-np`, `-n5`), which is how people type them.
fn git_flag(args: const u8[:][>..]&, from: i64, name: const u8[:]) -> bool {
    for k in from..args.len {
        let a = args[k];
        if a == name { return true; }
        if a.len > name.len && starts_with(a, name) {
            if name.len == 2 || a[name.len] == '=' { return true; }
        }
    }
    return false;
}

fn git_has_limit(args: const u8[:][>..]&, from: i64) -> bool {
    if git_flag(args, from, "-n") || git_flag(args, from, "--max-count") { return true; }
    for k in from..args.len {
        let a = args[k];
        if a.len > 1 && a[0] == '-' && a[1] >= '0' && a[1] <= '9' { return true; }
    }
    return false;
}

fn git_argv(user: const u8[:][>..]&) -> const u8[:][>..] {
    var out: const u8[:][>..] = [];
    out.push("git");
    out.push("--no-pager");
    out.push("-c");
    out.push("color.ui=false");

    if user.len == 0 {
        out.push("status");
        out.push("--short");
        out.push("--branch");
        return out;
    }

    let sidx = git_subcommand_index(user);
    if sidx < 0 {
        // Only globals were given, as in `al git -C some/dir`: read status.
        // A pure query like `al git --version` is passed through instead.
        var info_only = false;
        for a in user {
            if a == "--version" || a == "-v" || a == "--help" || a == "-h"
                || a == "--exec-path" || a == "--html-path" || a == "--man-path"
                || a == "--info-path" { info_only = true; }
        }
        for a in user { out.push(a); }
        if !info_only {
            out.push("status");
            out.push("--short");
            out.push("--branch");
        }
        return out;
    }

    var k = 0;
    while k <= sidx { out.push(user[k]); k += 1; }

    let sub = user[sidx];
    if sub == "status" {
        if !git_flag(user, sidx, "--short") && !git_flag(user, sidx, "-s")
            && !git_flag(user, sidx, "--porcelain") && !git_flag(user, sidx, "--long")
            && !git_flag(user, sidx, "-v") && !git_flag(user, sidx, "--verbose") {
            out.push("--short");
            out.push("--branch");
        }
    } else if sub == "log" {
        if !git_flag(user, sidx, "--format") && !git_flag(user, sidx, "--pretty")
            && !git_flag(user, sidx, "--oneline") && !git_flag(user, sidx, "--stat")
            && !git_flag(user, sidx, "--shortstat") && !git_flag(user, sidx, "--numstat")
            && !git_flag(user, sidx, "--name-only") && !git_flag(user, sidx, "--name-status")
            && !git_flag(user, sidx, "--raw") && !git_flag(user, sidx, "--graph")
            && !git_flag(user, sidx, "-p") && !git_flag(user, sidx, "--patch")
            && !git_flag(user, sidx, "--word-diff") && !git_flag(user, sidx, "--color-words") {
            out.push("--oneline");
            out.push("--no-decorate");
        }
        if !git_has_limit(user, sidx) {
            out.push("-n");
            out.push(GIT_LOG_LIMIT);
        }
    } else if sub == "diff" || sub == "show" {
        if !git_flag(user, sidx, "--stat") && !git_flag(user, sidx, "--numstat")
            && !git_flag(user, sidx, "--shortstat") && !git_flag(user, sidx, "--name-only")
            && !git_flag(user, sidx, "--name-status") && !git_flag(user, sidx, "--raw")
            && !git_flag(user, sidx, "-p") && !git_flag(user, sidx, "--patch")
            && !git_flag(user, sidx, "--word-diff") && !git_flag(user, sidx, "--color-words")
            && !git_flag(user, sidx, "--oneline") && !git_flag(user, sidx, "--summary") {
            out.push("--stat");
        }
    }

    while k < user.len { out.push(user[k]); k += 1; }
    return out;
}

// Strip ANSI escape sequences and collapse blank runs to a single blank line,
// keeping the text exactly otherwise. Leading blanks are dropped, the result
// ends with one newline.
fn compact_into(dst: u8[>..]&, src: const u8[:]) {
    var i = 0;
    var wrote_any = false;
    var pending_blank = false;
    while i < src.len {
        let c = src[i];
        if c == 0x1b && i + 1 < src.len && src[i + 1] == '[' {
            var j = i + 2;
            while j < src.len && !(src[j] >= 0x40 && src[j] <= 0x7e) { j += 1; }
            i = if j < src.len { j + 1 } else { src.len };
            continue;
        }
        if c == '\n' {
            if wrote_any { dst.push('\n'); }
            i += 1;
            var blanks = 0;
            while i < src.len && src[i] == '\n' { blanks += 1; i += 1; }
            if blanks > 0 && wrote_any { pending_blank = true; }
            continue;
        }
        if pending_blank {
            dst.push('\n');
            pending_blank = false;
        }
        dst.push(c);
        wrote_any = true;
        i += 1;
    }
    if wrote_any && (dst.len == 0 || dst[dst.len - 1] != '\n') { dst.push('\n'); }
}

fn git_main(user: const u8[:][>..]&) {
    if user.len == 1 && (user[0] == "--help" || user[0] == "-h") {
        print(GIT_HELP);
        return;
    }

    let argv = git_argv(user);
    var encoded: u8[>..] = [];
    for a in argv {
        encoded.append(a);
        encoded.push('\0');
    }

    var out: u8[>..] = [];
    var err: u8[>..] = [];
    let code = fs_run(encoded, out, err);
    if code < 0 { fatal("cannot run git"); }

    var clean_out: u8[>..] = [];
    compact_into(clean_out, out);
    // A clean tree prints only the branch header ("## main"); drop it so the
    // output is empty, matching plain `git status`.
    var only_branch = true;
    var line_count = 0;
    for line in split(clean_out, '\n') {
        if line.len == 0 { continue; }
        line_count += 1;
        if !(line.len >= 2 && line[0] == '#' && line[1] == '#') { only_branch = false; }
    }
    if only_branch && line_count == 1 { clean_out.clear(); }
    var clean_err: u8[>..] = [];
    compact_into(clean_err, err);
    write_stdout(clean_out);
    write_stderr(clean_err);

    if code != 0 { exit(if code > 255 { 255 } else { code }); }
}

// ------------------------------------------------------------------ search

// `al grep` / `al rg` run the real search tool with color stripped and blank
// runs collapsed, like `al git`. Everything else is passed through unchanged.

const SEARCH_HELP: const u8[:] = """
al grep - content search with fewer tokens
al rg   - ripgrep with fewer tokens

usage: al grep [grep arguments ...]
       al rg   [rg arguments ...]

Runs grep or rg, strips color codes and blank lines, and returns the tool's
exit code. Defaults never hide an error.

  al grep -rn PATTERN .    recursive search, line numbers
  al rg   PATTERN .         ripgrep search
""";

fn search_main(engine: const u8[:], user: const u8[:][>..]&) {
    if user.len == 1 && (user[0] == "--help" || user[0] == "-h") {
        print(SEARCH_HELP);
        return;
    }
    if user.len == 0 {
        print(SEARCH_HELP);
        return;
    }

    var argv: const u8[:][>..] = [];
    argv.push(engine);
    argv.push("--color=never");
    for a in user { argv.push(a); }

    var encoded: u8[>..] = [];
    for a in argv {
        encoded.append(a);
        encoded.push('\0');
    }

    var out: u8[>..] = [];
    var err: u8[>..] = [];
    let code = fs_run(encoded, out, err);
    if code < 0 { fatal("cannot run search tool"); }

    var clean_out: u8[>..] = [];
    compact_into(clean_out, out);
    var clean_err: u8[>..] = [];
    compact_into(clean_err, err);
    write_stdout(clean_out);
    write_stderr(clean_err);

    if code != 0 { exit(if code > 255 { 255 } else { code }); }
}

// ---------------------------------------------------------------------- CLI

fn option_value(args, i: i64, a: const u8[:], name_len: i64) -> const u8[:], i64, bool {
    if a.len > name_len { return a[name_len + 1..], i, true; }
    if i + 1 < args.len { return args[i + 1], i + 1, true; }
    return "", i, false;
}

fn parse_sort(v: const u8[:]) -> SortKey, bool {
    if v == "name" { return SortKey.Name, true; }
    if v == "size" { return SortKey.Size, true; }
    if v == "time" { return SortKey.Time, true; }
    if v == "kind" { return SortKey.Kind, true; }
    return SortKey.Name, false;
}

fn add_exts(list: const u8[:]) {
    for raw in split(list, ',') {
        var e = trim(raw);
        if e.len > 0 && e[0] == '.' { e = e[1..]; }
        if e.len > 0 { ext_filter.push(pool_copy(e)); }
    }
}

fn main() {
    let args = args();

    // `al git ...` is the git proxy, not a directory to list.
    if args.len > 1 && (args[1] == "git" || args[1] == "grep" || args[1] == "rg") {
        var user: const u8[:][>..] = [];
        for k in 2..args.len { user.push(args[k]); }
        if args[1] == "git" { git_main(user); }
        else if args[1] == "grep" { search_main("grep", user); }
        else { search_main("rg", user); }
        return;
    }

    var opt = Options {};
    var paths: const u8[:][>..] = [];
    var i = 1;
    var end_options = false;

    while i < args.len {
        let a = args[i];
        if end_options || a.len == 0 || a[0] != '-' || a == "-" {
            paths.push(a);
            i += 1;
            continue;
        }
        if a == "--" {
            end_options = true;
            i += 1;
            continue;
        }

        if a == "--help" { print(HELP); return; }
        if a == "--version" { print("al ", VERSION); return; }

        if a == "--depth" || starts_with(a, "--depth=") {
            let v, ni, ok = option_value(args, i, a, 7);
            if !ok { fatal("--depth needs a value"); }
            let n, nok = parse_int(v);
            if !nok || n < 0 { fatal("--depth needs a number >= 0"); }
            opt.depth = if n > MAX_DEPTH { MAX_DEPTH } else { n };
            i = ni + 1;
            continue;
        }
        if a == "--limit" || starts_with(a, "--limit=") {
            let v, ni, ok = option_value(args, i, a, 7);
            if !ok { fatal("--limit needs a value"); }
            let n, nok = parse_int(v);
            if !nok || n < 0 { fatal("--limit needs a number >= 0"); }
            opt.limit = n;
            i = ni + 1;
            continue;
        }
        if a == "--sort" || starts_with(a, "--sort=") {
            let v, ni, ok = option_value(args, i, a, 6);
            if !ok { fatal("--sort needs a value"); }
            let key, kok = parse_sort(v);
            if !kok { fatal(str("unknown sort key: ", v)); }
            opt.sort = key;
            i = ni + 1;
            continue;
        }
        if a == "--ext" || starts_with(a, "--ext=") {
            let v, ni, ok = option_value(args, i, a, 5);
            if !ok { fatal("--ext needs a value"); }
            add_exts(v);
            i = ni + 1;
            continue;
        }
        if a == "--all" { opt.all = true; i += 1; continue; }
        if a == "--ignored" { opt.show_ignored = true; i += 1; continue; }
        if a == "--reverse" { opt.reverse = true; i += 1; continue; }
        if a == "--no-lines" { opt.lines = false; i += 1; continue; }
        if a == "--no-header" { opt.header = false; i += 1; continue; }
        if a == "--no-summary" { opt.summary = false; i += 1; continue; }
        if a == "--json" { opt.json = true; opt.csv = false; i += 1; continue; }
        if a == "--csv" { opt.csv = true; opt.table = true; i += 1; continue; }
        if a == "--quiet" { opt.quiet = true; opt.csv = false; i += 1; continue; }
        if a == "--table" { opt.table = true; opt.csv = false; i += 1; continue; }
        if a == "--long" { opt.long = true; opt.csv = true; opt.table = true; i += 1; continue; }

        if a[0] == '-' && a.len > 1 && a[1] != '-' {
            let rest = a[1..];
            var k = 0;
            var consumed = false;
            while k < rest.len && !consumed {
                let c = rest[k];
                if c == 'a' { opt.all = true; }
                else if c == 'q' { opt.quiet = true; opt.csv = false; }
                else if c == 'j' { opt.json = true; opt.csv = false; }
                else if c == 'T' { opt.table = true; opt.csv = false; }
                else if c == 'l' { opt.long = true; opt.csv = true; opt.table = true; }
                else if c == 'R' { opt.depth = MAX_DEPTH; }
                else if c == 'h' {
                    var ho: u8[>..] = [];
                    write_csv_field(ho, HELP);
                    ho.push('\n');
                    write_stdout(ho);
                    return;
                }
                else if c == 'v' { print("al ", VERSION); return; }
                else if c == 'd' || c == 's' || c == 'N' {
                    var v: const u8[:] = "";
                    if k + 1 < rest.len {
                        v = rest[k + 1..];
                    } else if i + 1 < args.len {
                        i += 1;
                        v = args[i];
                    } else {
                        fatal("option needs a value");
                    }
                    if c == 'd' {
                        let n, nok = parse_int(v);
                        if !nok || n < 0 { fatal("--depth needs a number >= 0"); }
                        opt.depth = if n > MAX_DEPTH { MAX_DEPTH } else { n };
                    } else if c == 's' {
                        let key, kok = parse_sort(v);
                        if !kok { fatal(str("unknown sort key: ", v)); }
                        opt.sort = key;
                    } else {
                        let n, nok = parse_int(v);
                        if !nok || n < 0 { fatal("--limit needs a number >= 0"); }
                        opt.limit = n;
                    }
                    consumed = true;
                } else {
                    var e: u8[>..] = [];
                    format(e, "unknown option: -");
                    e.push(c);
                    fatal(e);
                }
                k += 1;
            }
            i += 1;
            continue;
        }

        fatal(str("unknown option: ", a));
    }

    if paths.len == 0 { paths.push("."); }

    // Plain output shows no file contents, so skip reading every file just to
    // count lines nobody will see. JSON and the table still need them.
    if !opt.json && !opt.csv && (opt.quiet || !opt.table) { opt.lines = false; }

    sort_key = opt.sort;
    sort_reverse = opt.reverse;

    for root in paths {
        let res = process_root(root, opt);
        roots.push(res);
    }

    let now = time_ns() / 1000000000;
    let empty_failure = items.len == 0 && total_errors > 0;

    var out: u8[>..] = [];
    if opt.json {
        write_json(out, opt);
    } else if opt.csv {
        if opt.header && !empty_failure { write_csv_header(out, opt); }
        for res in roots {
            var shown = 0;
            for i in res.start..res.end {
                if opt.limit > 0 && shown >= opt.limit { break; }
                write_csv_row(out, items[i], now, opt);
                shown += 1;
            }
        }
    } else if opt.quiet || !opt.table {
        for res in roots {
            var shown = 0;
            for i in res.start..res.end {
                if opt.limit > 0 && shown >= opt.limit { break; }
                write_plain_path(out, items[i]);
                out.push('\n');
                shown += 1;
            }
        }
    } else {
        if opt.header && !empty_failure { write_header(out, opt); }
        for res in roots {
            var shown = 0;
            for i in res.start..res.end {
                if opt.limit > 0 && shown >= opt.limit { break; }
                write_row(out, items[i], now, opt);
                shown += 1;
            }
        }
        if opt.summary && !empty_failure {
            for res in roots { write_summary(out, res, opt); }
        }
    }
    write_stdout(out);

    if total_errors > 0 { exit(1); }
}
