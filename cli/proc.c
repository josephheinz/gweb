/* Process and file-tree helpers for gweb: run with captured output, spawn,
   kill, wait, exec, symlink, chdir, cwd, remove a tree, and a change stamp
   (file count and newest mtime) for the dev watcher. POSIX only. */
#define _XOPEN_SOURCE 700
#define _DARWIN_C_SOURCE
#include "goose.h"

#include <dirent.h>
#include <errno.h>
#include <ftw.h>
#include <signal.h>
#include <spawn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

typedef struct { const uint8_t *data; int64_t len; } gweb_bytes;

static char *cstr(gweb_bytes s) {
    char *p = malloc((size_t)s.len + 1);
    if (!p) return NULL;
    memcpy(p, s.data, (size_t)s.len);
    p[s.len] = 0;
    return p;
}

/* Runs cmd with /bin/sh, appends its stdout and stderr to out, and returns
   its exit status (-1 when it could not run or did not exit normally). */
int32_t gweb_run(gweb_bytes cmd, gs_rref out) {
    char *c = cstr(cmd);
    if (!c) return -1;
    size_t n = strlen(c);
    char *full = malloc(n + 16);
    memcpy(full, c, n);
    memcpy(full + n, " 2>&1", 6);
    free(c);
    FILE *f = popen(full, "r");
    free(full);
    if (!f) return -1;
    char buf[8192];
    size_t r;
    while ((r = fread(buf, 1, sizeof buf, f)) > 0) gs_bld_append(out, buf, r);
    int st = pclose(f);
    return WIFEXITED(st) ? WEXITSTATUS(st) : -1;
}

/* Starts cmd with /bin/sh -c "exec cmd" and returns its pid, or -1. */
int64_t gweb_spawn(gweb_bytes cmd) {
    char *c = cstr(cmd);
    if (!c) return -1;
    size_t n = strlen(c);
    char *full = malloc(n + 8);
    memcpy(full, "exec ", 5);
    memcpy(full + 5, c, n + 1);
    free(c);
    char *argv[] = { "sh", "-c", full, NULL };
    pid_t pid;
    int rc = posix_spawn(&pid, "/bin/sh", NULL, NULL, argv, environ);
    free(full);
    return rc == 0 ? (int64_t)pid : -1;
}

/* Replaces this process with cmd under /bin/sh. Returns only on failure. */
int32_t gweb_exec(gweb_bytes cmd) {
    char *c = cstr(cmd);
    if (!c) return -1;
    size_t n = strlen(c);
    char *full = malloc(n + 8);
    memcpy(full, "exec ", 5);
    memcpy(full + 5, c, n + 1);
    free(c);
    fflush(stdout);
    execl("/bin/sh", "sh", "-c", full, (char *)NULL);
    free(full);
    return -1;
}

/* gweb dev: SIGTERM, SIGINT and SIGHUP only set a flag, which the watch loop reads to stop its server child. */
static volatile sig_atomic_t term_seen = 0;
static void on_term(int sig) { (void)sig; term_seen = 1; }
void gweb_trap_term(void) {
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_handler = on_term;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGINT, &sa, NULL);
    sigaction(SIGHUP, &sa, NULL);
}
int32_t gweb_term_seen(void) { return term_seen ? 1 : 0; }

int32_t gweb_kill(int64_t pid, int32_t sig) { return kill((pid_t)pid, sig) == 0; }

/* With block 0: -2 while the child runs, else its exit status (or -1). */
int32_t gweb_wait(int64_t pid, int32_t block) {
    int st;
    pid_t r = waitpid((pid_t)pid, &st, block ? 0 : WNOHANG);
    if (r == 0) return -2;
    if (r < 0) return -1;
    return WIFEXITED(st) ? WEXITSTATUS(st) : -1;
}

int32_t gweb_symlink(gweb_bytes target, gweb_bytes path) {
    char *t = cstr(target), *p = cstr(path);
    int ok = t && p && symlink(t, p) == 0;
    free(t); free(p);
    return ok;
}

int32_t gweb_chdir(gweb_bytes path) {
    char *p = cstr(path);
    int ok = p && chdir(p) == 0;
    free(p);
    return ok;
}

int32_t gweb_cwd(gs_rref out) {
    char buf[4096];
    if (!getcwd(buf, sizeof buf)) return 0;
    gs_bld_append(out, buf, strlen(buf));
    return 1;
}

static int rm_one(const char *path, const struct stat *sb, int flag, struct FTW *ftw) {
    (void)sb; (void)ftw;
    return (flag == FTW_DP ? rmdir(path) : unlink(path)) == 0 ? 0 : -1;
}

/* Removes path and everything under it, without following symlinks. */
int32_t gweb_remove_tree(gweb_bytes path) {
    char *p = cstr(path);
    if (!p) return 0;
    struct stat st;
    int ok = 1;
    if (lstat(p, &st) == 0) ok = nftw(p, rm_one, 32, FTW_DEPTH | FTW_PHYS) == 0;
    free(p);
    return ok;
}

static int64_t stamp_count, stamp_newest;
static int stamp_one(const char *path, const struct stat *sb, int flag, struct FTW *ftw) {
    (void)path; (void)ftw;
    if (flag == FTW_F || flag == FTW_D || flag == FTW_SL) {
        stamp_count++;
#ifdef __APPLE__
        int64_t t = (int64_t)sb->st_mtimespec.tv_sec * 1000000000 + sb->st_mtimespec.tv_nsec;
#else
        int64_t t = (int64_t)sb->st_mtim.tv_sec * 1000000000 + sb->st_mtim.tv_nsec;
#endif
        if (t > stamp_newest) stamp_newest = t;
    }
    return 0;
}

/* Adds the number of entries under path to count and returns the newest
   mtime in nanoseconds (0 when path is missing). Follows symlinks. A file
   counts as one entry (nftw refuses a file on macOS). */
int64_t gweb_tree_stamp(gweb_bytes path, int64_t *count) {
    char *p = cstr(path);
    if (!p) return 0;
    stamp_count = 0;
    stamp_newest = 0;
    struct stat st;
    if (stat(p, &st) == 0) {
        if (S_ISDIR(st.st_mode)) nftw(p, stamp_one, 32, 0);
        else stamp_one(p, &st, FTW_F, NULL);
    }
    free(p);
    *count += stamp_count;
    return stamp_newest;
}

/* Like gweb_tree_stamp for a tool's sources: skips names that start with a dot (.git, .gweb*) and does not
   follow a link to a folder, so an app inside the package, or a tree of links back into it, is not walked. */
static void src_walk(const char *dir, int64_t *count, int64_t *newest, int depth) {
    if (depth > 32) return;
    DIR *d = opendir(dir);
    if (!d) return;
    struct dirent *e;
    while ((e = readdir(d)) != NULL) {
        if (e->d_name[0] == '.') continue;
        size_t n = strlen(dir) + strlen(e->d_name) + 2;
        char *p = malloc(n);
        if (!p) break;
        snprintf(p, n, "%s/%s", dir, e->d_name);
        struct stat st;
        if (lstat(p, &st) == 0) {
            int is_link = S_ISLNK(st.st_mode);
            if (is_link && stat(p, &st) != 0) { free(p); continue; }
            (*count)++;
#ifdef __APPLE__
            int64_t t = (int64_t)st.st_mtimespec.tv_sec * 1000000000 + st.st_mtimespec.tv_nsec;
#else
            int64_t t = (int64_t)st.st_mtim.tv_sec * 1000000000 + st.st_mtim.tv_nsec;
#endif
            /* A folder's own mtime moves when a dot entry (.gweb) is made in it; its files tell. */
            if (!S_ISDIR(st.st_mode) && t > *newest) *newest = t;
            if (S_ISDIR(st.st_mode) && !is_link) src_walk(p, count, newest, depth + 1);
        }
        free(p);
    }
    closedir(d);
}

int64_t gweb_src_stamp(gweb_bytes path, int64_t *count) {
    char *p = cstr(path);
    if (!p) return 0;
    int64_t newest = 0;
    src_walk(p, count, &newest, 0);
    free(p);
    return newest;
}
