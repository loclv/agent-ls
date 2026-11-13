/* The native half of al: directory listing with metadata, one stat
   per entry, and a fast text/binary probe for line counting.

   Goose's `os` module can list names but not sizes, modes or mtimes, so this
   file fills that gap. Everything it hands back is line-oriented text; the
   Goose side owns parsing, filtering, sorting and rendering.

   Record for al_list   (one per entry, name last so it may contain tabs):
       kind \t mode \t size \t mtime \t escaped-name \n
   Record for al_meta   (the root itself, no name):
       kind \t mode \t size \t mtime \n

   kind is d (directory), f (file), l (symlink) or o (other). mode is the
   permission bits in octal. Names escape \\, \t, \n, \r and other control
   bytes as \xNN; the Goose side reverses that exactly. */

#include "goose.h"
#include <stdint.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
/* A slice as C sees it. goose.h exposes the builder but not every slice
   typedef, and this struct is the documented layout. */
typedef struct {
    const uint8_t *data;
    int64_t len;
} al_sl_u8;

#ifndef _WIN32
#include <dirent.h>
#include <errno.h>
#include <poll.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>
#else
#include <windows.h>
#endif

static char *al_cstr(al_sl_u8 s) {
    char *p = (char *)malloc((size_t)s.len + 1);
    if (!p) return NULL;
    if (s.len) memcpy(p, s.data, (size_t)s.len);
    p[s.len] = 0;
    return p;
}

static void al_append_escaped(gs_rref out, const char *name) {
    char buf[512];
    size_t n = 0;
    for (const char *p = name; *p; p++) {
        unsigned char c = (unsigned char)*p;
        const char *rep = NULL;
        char hex[5];
        switch (c) {
            case '\\': rep = "\\\\"; break;
            case '\t': rep = "\\t"; break;
            case '\n': rep = "\\n"; break;
            case '\r': rep = "\\r"; break;
            default:
                if (c < 0x20 || c == 0x7f) {
                    static const char digits[] = "0123456789abcdef";
                    hex[0] = '\\'; hex[1] = 'x';
                    hex[2] = digits[(c >> 4) & 0xf];
                    hex[3] = digits[c & 0xf];
                    hex[4] = 0;
                    rep = hex;
                }
                break;
        }
        size_t rl = rep ? strlen(rep) : 1;
        if (n + rl > sizeof(buf)) {
            gs_bld_append(out, buf, (int64_t)n);
            n = 0;
        }
        if (rep) memcpy(buf + n, rep, rl);
        else buf[n] = (char)c;
        n += rl;
    }
    if (n) gs_bld_append(out, buf, (int64_t)n);
}

static void al_append_record(gs_rref out, const char *name, char kind,
                              uint64_t mode, int64_t size, int64_t mtime) {
    char head[160];
    int n = snprintf(head, sizeof(head), "%c\t%03o\t%lld\t%lld\t",
                     kind, (unsigned)(mode & 0777), (long long)size,
                     (long long)mtime);
    if (n > 0) gs_bld_append(out, head, (int64_t)n);
    al_append_escaped(out, name);
    gs_bld_append(out, "\n", 1);
}

#ifndef _WIN32

bool al_list(al_sl_u8 path, gs_rref out) {
    char *base = al_cstr(path);
    if (!base) return false;
    DIR *dir = opendir(base);
    if (!dir) {
        free(base);
        return false;
    }
    size_t base_len = strlen(base);
    bool add_slash = base_len > 0 && base[base_len - 1] != '/';
    struct dirent *ent;
    bool ok = true;
    while ((ent = readdir(dir)) != NULL) {
        if (!strcmp(ent->d_name, ".") || !strcmp(ent->d_name, "..")) continue;
        size_t name_len = strlen(ent->d_name);
        size_t full_len = base_len + (add_slash ? 1 : 0) + name_len + 1;
        char *full = (char *)malloc(full_len);
        if (!full) {
            ok = false;
            break;
        }
        memcpy(full, base, base_len);
        size_t at = base_len;
        if (add_slash) full[at++] = '/';
        memcpy(full + at, ent->d_name, name_len + 1);

        struct stat st;
        if (lstat(full, &st) == 0) {
            char kind = S_ISDIR(st.st_mode) ? 'd'
                      : S_ISLNK(st.st_mode) ? 'l'
                      : S_ISREG(st.st_mode) ? 'f'
                      : 'o';
            al_append_record(out, ent->d_name, kind, (uint64_t)st.st_mode,
                              (int64_t)st.st_size, (int64_t)st.st_mtime);
        }
        free(full);
    }
    closedir(dir);
    free(base);
    return ok;
}

/* 0 on success, 1 when the path does not exist, 2 for any other failure
   (permission denied, a path component that is not a directory, I/O error).
   The caller can then say "not found" only when that is what happened. */
int64_t al_meta(al_sl_u8 path, gs_rref out) {
    char *p = al_cstr(path);
    if (!p) return 2;
    struct stat st;
    if (stat(p, &st) != 0) {
        int64_t why = (errno == ENOENT || errno == ENOTDIR) ? 1 : 2;
        free(p);
        return why;
    }
    free(p);
    char kind = S_ISDIR(st.st_mode) ? 'd'
              : S_ISLNK(st.st_mode) ? 'l'
              : S_ISREG(st.st_mode) ? 'f'
              : 'o';
    char line[160];
    int n = snprintf(line, sizeof(line), "%c\t%03o\t%lld\t%lld\n",
                     kind, (unsigned)(st.st_mode & 0777),
                     (long long)st.st_size, (long long)st.st_mtime);
    if (n > 0) gs_bld_append(out, line, (int64_t)n);
    return n > 0 ? 0 : 2;
}

#else /* _WIN32 */

static int64_t al_filetime_to_unix(FILETIME ft) {
    uint64_t t = ((uint64_t)ft.dwHighDateTime << 32) | ft.dwLowDateTime;
    return (int64_t)(t / 10000000ULL) - 11644473600LL;
}

bool al_list(al_sl_u8 path, gs_rref out) {
    char *base = al_cstr(path);
    if (!base) return false;
    size_t base_len = strlen(base);
    bool add_slash = base_len > 0 && base[base_len - 1] != '\\' &&
                     base[base_len - 1] != '/';
    size_t pat_len = base_len + 3;
    char *pattern = (char *)malloc(pat_len);
    if (!pattern) {
        free(base);
        return false;
    }
    memcpy(pattern, base, base_len);
    size_t at = base_len;
    if (add_slash) pattern[at++] = '\\';
    pattern[at++] = '*';
    pattern[at] = 0;

    WIN32_FIND_DATAA fd;
    HANDLE h = FindFirstFileA(pattern, &fd);
    free(pattern);
    if (h == INVALID_HANDLE_VALUE) {
        free(base);
        return false;
    }
    bool ok = true;
    do {
        if (!strcmp(fd.cFileName, ".") || !strcmp(fd.cFileName, "..")) continue;
        uint64_t size = ((uint64_t)fd.nFileSizeHigh << 32) | fd.nFileSizeLow;
        int64_t mtime = al_filetime_to_unix(fd.ftLastWriteTime);
        char kind;
        if (fd.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) kind = 'l';
        else if (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) kind = 'd';
        else kind = 'f';
        uint64_t mode = (fd.dwFileAttributes & FILE_ATTRIBUTE_READONLY) ? 0444 : 0644;
        al_append_record(out, fd.cFileName, kind, mode, (int64_t)size, mtime);
    } while (FindNextFileA(h, &fd));
    FindClose(h);
    free(base);
    return ok;
}

int64_t al_meta(al_sl_u8 path, gs_rref out) {
    char *p = al_cstr(path);
    if (!p) return 2;
    WIN32_FILE_ATTRIBUTE_DATA fd;
    if (!GetFileAttributesExA(p, GetFileExInfoStandard, &fd)) {
        DWORD why = GetLastError();
        free(p);
        return (why == ERROR_FILE_NOT_FOUND || why == ERROR_PATH_NOT_FOUND) ? 1 : 2;
    }
    free(p);
    uint64_t size = ((uint64_t)fd.nFileSizeHigh << 32) | fd.nFileSizeLow;
    int64_t mtime = al_filetime_to_unix(fd.ftLastWriteTime);
    char kind;
    if (fd.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) kind = 'l';
    else if (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) kind = 'd';
    else kind = 'f';
    uint64_t mode = (fd.dwFileAttributes & FILE_ATTRIBUTE_READONLY) ? 0444 : 0644;
    char line[160];
    int n = snprintf(line, sizeof(line), "%c\t%03o\t%lld\t%lld\n",
                     kind, (unsigned)mode, (long long)size, (long long)mtime);
    if (n > 0) gs_bld_append(out, line, (int64_t)n);
    return n > 0 ? 0 : 2;
}

#endif

/* Lines in a text file, or -1 when it is larger than max_bytes, unreadable,
   or looks binary (a NUL in the first 8 KiB). An empty file has 0 lines. */
int64_t al_count_lines(al_sl_u8 path, int64_t max_bytes) {
    char *p = al_cstr(path);
    if (!p) return -1;
    FILE *f = fopen(p, "rb");
    free(p);
    if (!f) return -1;

    uint8_t buf[65536];
    int64_t total = 0;
    int64_t lines = 0;
    int last = 0;
    bool binary = false;
    for (;;) {
        size_t n = fread(buf, 1, sizeof(buf), f);
        if (n == 0) break;
        for (size_t i = 0; i < n; i++) {
            if (total < 8192 && buf[i] == 0) {
                binary = true;
                break;
            }
            if (buf[i] == '\n') lines++;
            last = buf[i];
            total++;
            if (total > max_bytes) break;
        }
        if (binary || total > max_bytes) break;
    }
    bool bad = ferror(f) != 0;
    fclose(f);
    if (binary || bad || total > max_bytes) return -1;
    if (total > 0 && last != '\n') lines++;
    return lines;
}

/* An ISO-8601 UTC timestamp into a builder, for --long. */
void al_time(int64_t seconds, gs_rref out) {
    time_t t = (time_t)seconds;
    struct tm tmv;
#ifdef _WIN32
    if (gmtime_s(&tmv, &t) != 0) return;
#else
    if (!gmtime_r(&t, &tmv)) return;
#endif
    char buf[40];
    size_t n = strftime(buf, sizeof(buf), "%Y-%m-%dT%H:%M:%SZ", &tmv);
    if (n) gs_bld_append(out, buf, (int64_t)n);
}

/* -------------------------------------------------------------- processes */

/* "git\0status\0\0" -> {"git", "status", NULL}. An empty piece ends the list,
   so the caller appends one final NUL and never counts pieces by hand. */
static char **al_split_args(al_sl_u8 s, int64_t *count) {
    int64_t n = 0;
    int64_t i = 0;
    while (i < s.len) {
        int64_t start = i;
        while (i < s.len && s.data[i] != 0) i++;
        if (i == start) break;
        n++;
        if (i < s.len) i++;
    }
    if (n == 0) return NULL;
    char **argv = (char **)calloc((size_t)n + 1, sizeof(char *));
    if (!argv) return NULL;
    int64_t k = 0;
    i = 0;
    while (k < n) {
        int64_t start = i;
        while (i < s.len && s.data[i] != 0) i++;
        size_t len = (size_t)(i - start);
        char *a = (char *)malloc(len + 1);
        if (!a) {
            for (int64_t j = 0; j < k; j++) free(argv[j]);
            free(argv);
            return NULL;
        }
        memcpy(a, s.data + start, len);
        a[len] = 0;
        argv[k++] = a;
        if (i < s.len) i++;
    }
    *count = n;
    return argv;
}

static void al_free_argv(char **argv, int64_t n) {
    if (!argv) return;
    for (int64_t i = 0; i < n; i++) free(argv[i]);
    free(argv);
}

#ifndef _WIN32

/* Run argv without a shell, capturing stdout and stderr separately. Returns
   the exit status (128 + signal when killed), or -1 when it could not be
   started at all. A failed exec reports through stderr as exit code 127. */
int64_t al_run(al_sl_u8 args, gs_rref out, gs_rref err) {
    int64_t n = 0;
    char **argv = al_split_args(args, &n);
    if (!argv) return -1;

    int op[2], ep[2];
    if (pipe(op) != 0) { al_free_argv(argv, n); return -1; }
    if (pipe(ep) != 0) {
        close(op[0]); close(op[1]);
        al_free_argv(argv, n);
        return -1;
    }

    pid_t pid = fork();
    if (pid < 0) {
        close(op[0]); close(op[1]); close(ep[0]); close(ep[1]);
        al_free_argv(argv, n);
        return -1;
    }
    if (pid == 0) {
        close(op[0]); close(ep[0]);
        if (dup2(op[1], STDOUT_FILENO) >= 0 &&
            dup2(ep[1], STDERR_FILENO) >= 0) {
            execvp(argv[0], argv);
        }
        char msg[256];
        int m = snprintf(msg, sizeof(msg), "al: cannot run %s\n",
                         argv[0] ? argv[0] : "command");
        if (m > 0) {
            ssize_t ignored = write(STDERR_FILENO, msg, (size_t)m);
            (void)ignored;
        }
        _exit(127);
    }

    close(op[1]); close(ep[1]);
    al_free_argv(argv, n);

    struct pollfd fds[2];
    fds[0].fd = op[0]; fds[0].events = POLLIN; fds[0].revents = 0;
    fds[1].fd = ep[0]; fds[1].events = POLLIN; fds[1].revents = 0;
    int live = 2;
    char buf[65536];
    while (live > 0) {
        if (poll(fds, 2, -1) < 0) {
            if (errno == EINTR) continue;
            break;
        }
        for (int k = 0; k < 2; k++) {
            if (fds[k].fd < 0 || fds[k].revents == 0) continue;
            ssize_t got = read(fds[k].fd, buf, sizeof(buf));
            if (got > 0) {
                gs_bld_append(k == 0 ? out : err, buf, (int64_t)got);
            } else if (got == 0 || (errno != EINTR && errno != EAGAIN)) {
                close(fds[k].fd);
                fds[k].fd = -1;
                live--;
            }
        }
    }
    if (fds[0].fd >= 0) close(fds[0].fd);
    if (fds[1].fd >= 0) close(fds[1].fd);

    int status = 0;
    while (waitpid(pid, &status, 0) < 0) {
        if (errno != EINTR) return -1;
    }
    if (WIFEXITED(status)) return (int64_t)WEXITSTATUS(status);
    if (WIFSIGNALED(status)) return 128 + (int64_t)WTERMSIG(status);
    return -1;
}

#else /* _WIN32 */

/* Windows has no fork/exec pair here, so this builds one command line with
   MS-style quoting and reads it back through _popen. stderr is merged into
   stdout. */
static size_t al_quoted_len(const char *a) {
    size_t n = 2;   /* the two surrounding quotes */
    size_t bs = 0;
    for (const char *p = a; *p; p++) {
        if (*p == '\\') { bs++; continue; }
        if (*p == '"') { n += 2 * bs + 2; bs = 0; continue; }
        n += bs + 1;
        bs = 0;
    }
    return n + bs;
}

static char *al_quote_into(char *at, const char *a) {
    size_t bs = 0;
    *at++ = '"';
    for (const char *p = a; *p; p++) {
        if (*p == '\\') { bs++; continue; }
        if (*p == '"') {
            for (size_t j = 0; j < 2 * bs + 1; j++) *at++ = '\\';
            *at++ = '"';
            bs = 0;
            continue;
        }
        for (size_t j = 0; j < bs; j++) *at++ = '\\';
        bs = 0;
        *at++ = *p;
    }
    for (size_t j = 0; j < bs; j++) *at++ = '\\';
    *at++ = '"';
    return at;
}

static char *al_join_args(char **argv, int64_t n) {
    size_t len = 6;   /* " 2>&1" plus NUL */
    for (int64_t i = 0; i < n; i++) len += al_quoted_len(argv[i]) + 1;
    char *cmd = (char *)malloc(len);
    if (!cmd) return NULL;
    char *at = cmd;
    for (int64_t i = 0; i < n; i++) {
        if (i > 0) *at++ = ' ';
        at = al_quote_into(at, argv[i]);
    }
    memcpy(at, " 2>&1", 6);
    return cmd;
}

int64_t al_run(al_sl_u8 args, gs_rref out, gs_rref err) {
    int64_t n = 0;
    char **argv = al_split_args(args, &n);
    if (!argv) return -1;

    char *cmd = al_join_args(argv, n);
    al_free_argv(argv, n);
    if (!cmd) return -1;

    FILE *p = _popen(cmd, "r");
    free(cmd);
    if (!p) return -1;
    char buf[65536];
    size_t got;
    while ((got = fread(buf, 1, sizeof(buf), p)) > 0) {
        gs_bld_append(out, buf, (int64_t)got);
    }
    int rc = _pclose(p);
    return (int64_t)rc;
}

#endif
