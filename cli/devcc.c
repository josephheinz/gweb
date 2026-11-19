/* gweb's dev C compile (docs/dev-builds.md): the program's one C file from goose, split after goose into a shared
   header and units of function bodies, the units compiled in parallel at -O0, each object kept by a hash of what
   it was compiled from, and the objects linked as goose would link main.c. Dev builds and gweb test (goose -O0)
   only; `gweb build` keeps goose's -O2 C whole, and only reuses the last binary. Any surprise in the C (a layout this file does not know) returns nonzero, and the dev compiler then
   compiles the C as one file, as before. POSIX only.

   The split, from what goose emits (goose -o, GS_SEPARATE_RUNTIME):
   - Everything before "---- code ----" (runtime header, types, data, prototypes) is the header, pre.h, with three
     changes. A file-scope static variable that is not const (the data-stack state, the globals' main instance) is
     declared extern there and defined once, in unit 0, so every unit shares one. An embedded file is declared extern
     and defined in ublob.c, which needs no header and rarely changes. Every
     prototype after "---- prototypes ----" loses `static` (and `inline`) for hidden visibility, so units call each
     other's functions.
   - Each function after "---- code ----" that has a prototype goes to one of the units, in order, without `static`
     (the cuts: see below). The rest (gs_init_globals, gs_program_init, main) stay static, in the last unit.
   - String constants and embedded files are renamed by content (see "constants by content").
   Static functions and static consts of the header stay static: a copy per unit, which C allows (none keeps state
   but gs_simd_level's cache of a CPU probe). */
#define _XOPEN_SOURCE 700
#define _DARWIN_C_SOURCE
#include "goose.h"

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <spawn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

typedef struct { const uint8_t *data; int64_t len; } gweb_bytes;

typedef struct { char *p; size_t n, cap; } buf;

static void put(buf *b, const char *s, size_t n) {
    if (b->n + n + 1 > b->cap) {
        size_t c = b->cap ? b->cap : 4096;
        while (c < b->n + n + 1) c *= 2;
        char *q = realloc(b->p, c);
        if (!q) { fprintf(stderr, "gweb: out of memory\n"); exit(1); }
        b->p = q;
        b->cap = c;
    }
    memcpy(b->p + b->n, s, n);
    b->n += n;
    b->p[b->n] = 0;
}
static void puts_(buf *b, const char *s) { put(b, s, strlen(s)); }

static double now(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return tv.tv_sec + tv.tv_usec / 1e6;
}

static int read_all(const char *path, buf *b) {
    FILE *f = fopen(path, "rb");
    if (!f) return 0;
    char tmp[1 << 16];
    size_t r;
    while ((r = fread(tmp, 1, sizeof tmp, f)) > 0) put(b, tmp, r);
    fclose(f);
    if (!b->p) put(b, "", 0);
    return 1;
}

/* Writes the file only when its bytes differ, so an unchanged unit keeps its mtime. */
static int write_if_changed(const char *path, const char *p, size_t n) {
    buf cur = {0};
    if (read_all(path, &cur) && cur.n == n && memcmp(cur.p, p, n) == 0) { free(cur.p); return 1; }
    free(cur.p);
    char tmp[4096];
    snprintf(tmp, sizeof tmp, "%s.tmp%d", path, (int)getpid());
    FILE *f = fopen(tmp, "wb");
    if (!f) return 0;
    int ok = fwrite(p, 1, n, f) == n;
    ok = fclose(f) == 0 && ok;
    if (!ok || rename(tmp, path) != 0) { unlink(tmp); return 0; }
    return 1;
}

/* 128 bits: FNV-1a 64 and a second multiply-xorshift hash, each with the length. */
typedef struct { uint64_t a, b; } h128;
static void hmix(h128 *h, const void *data, size_t n) {
    const uint8_t *p = data;
    uint64_t a = h->a, b = h->b;
    for (size_t i = 0; i < n; i++) {
        a = (a ^ p[i]) * 1099511628211ULL;
        b = (b + p[i] + 1) * 0x9E3779B97F4A7C15ULL;
        b ^= b >> 29;
    }
    a = (a ^ n) * 1099511628211ULL;
    b = (b ^ n) * 0xBF58476D1CE4E5B9ULL;
    h->a = a;
    h->b = b;
}

/* ---- the C scan ---- */

typedef struct { size_t s, e; int pp; } item;   /* [s, e) of the source; pp: a preprocessor line */

/* Splits src into top-level items: preprocessor lines (with their continuations), declarations ending in ';' at
   depth 0, and definitions whose closing '}' at depth 0 ends its line. Comments, strings and character literals
   are skipped. 0 when the braces do not balance. */
static int scan(const char *src, size_t n, item **out, size_t *count) {
    size_t cap = 1 << 14, k = 0;
    item *it = malloc(cap * sizeof *it);
    size_t i = 0, start = 0;
    int depth = 0, bol = 1;
#define ADD(S, E, PP) do { if (k == cap) { cap *= 2; it = realloc(it, cap * sizeof *it); } \
                           it[k].s = (S); it[k].e = (E); it[k].pp = (PP); k++; } while (0)
    while (i < n) {
        char c = src[i];
        if (c == '\n') { bol = 1; i++; continue; }
        if (c == ' ' || c == '\t' || c == '\r' || c == '\f' || c == '\v') { i++; continue; }
        if (bol && c == '#') {
            size_t j = i;
            for (;;) {
                const char *nl = memchr(src + j, '\n', n - j);
                size_t e = nl ? (size_t)(nl - src) : n;
                if (e > j && src[e - 1] == '\\' && e < n) { j = e + 1; continue; }
                j = e;
                break;
            }
            if (depth == 0) {
                /* Only text that is all space and comments may stand before it in the item. */
                ADD(i, j < n ? j + 1 : n, 1);
                start = j < n ? j + 1 : n;
            }
            i = j;
            continue;
        }
        bol = 0;
        if (c == '/' && i + 1 < n && src[i + 1] == '*') {
            const char *e = strstr(src + i + 2, "*/");
            if (!e) { free(it); return 0; }
            i = (size_t)(e - src) + 2;
            continue;
        }
        if (c == '/' && i + 1 < n && src[i + 1] == '/') {
            const char *nl = memchr(src + i, '\n', n - i);
            i = nl ? (size_t)(nl - src) : n;
            continue;
        }
        if (c == '"' || c == '\'') {
            size_t j = i + 1;
            while (j < n && src[j] != c) {
                if (src[j] == '\\') j++;
                else if (src[j] == '\n') { free(it); return 0; }
                j++;
            }
            if (j >= n) { free(it); return 0; }
            i = j + 1;
            continue;
        }
        if (c == '{') depth++;
        else if (c == '}') {
            if (--depth < 0) { free(it); return 0; }
            if (depth == 0) {
                size_t j = i + 1;
                while (j < n && (src[j] == ' ' || src[j] == '\t' || src[j] == '\r')) j++;
                if (j >= n || src[j] == '\n') { ADD(start, i + 1, 0); start = i + 1; }
            }
        } else if (c == ';' && depth == 0) { ADD(start, i + 1, 0); start = i + 1; }
        i++;
    }
#undef ADD
    if (depth != 0) { free(it); return 0; }
    *out = it;
    *count = k;
    return 1;
}

/* The item's text without leading space and comments. */
static size_t skip_lead(const char *src, size_t s, size_t e) {
    for (;;) {
        while (s < e && (src[s] == ' ' || src[s] == '\t' || src[s] == '\n' || src[s] == '\r')) s++;
        if (s + 1 < e && src[s] == '/' && src[s + 1] == '*') {
            const char *x = strstr(src + s + 2, "*/");
            if (!x || (size_t)(x - src) >= e) return e;
            s = (size_t)(x - src) + 2;
            continue;
        }
        if (s + 1 < e && src[s] == '/' && src[s + 1] == '/') {
            while (s < e && src[s] != '\n') s++;
            continue;
        }
        return s;
    }
}

static int starts(const char *p, size_t n, const char *w) {
    size_t l = strlen(w);
    return n >= l && memcmp(p, w, l) == 0;
}

static int ident(char c) { return c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9'); }

/* The name before the first '(' of a function's declaration or definition (n bytes at p). */
static int fn_name(const char *p, size_t n, const char **name, size_t *len) {
    const char *paren = memchr(p, '(', n);
    if (!paren) return 0;
    const char *e = paren;
    while (e > p && (e[-1] == ' ' || e[-1] == '\t')) e--;
    const char *s = e;
    while (s > p && ident(s[-1])) s--;
    if (s == e) return 0;
    *name = s;
    *len = (size_t)(e - s);
    return 1;
}

/* A sorted set of names, for the prototypes. */
typedef struct { const char *p; size_t n; } span;
static int span_cmp(const void *a, const void *b) {
    const span *x = a, *y = b;
    size_t m = x->n < y->n ? x->n : y->n;
    int c = memcmp(x->p, y->p, m);
    return c ? c : (x->n < y->n ? -1 : x->n > y->n);
}

/* ---- processes ---- */

static pid_t spawn(char **argv, const char *log) {
    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_addopen(&fa, 1, log, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    posix_spawn_file_actions_adddup2(&fa, 1, 2);
    pid_t pid;
    int rc = posix_spawn(&pid, argv[0], &fa, NULL, argv, environ);
    if (rc != 0 && strchr(argv[0], '/') == NULL) rc = posix_spawnp(&pid, argv[0], &fa, NULL, argv, environ);
    posix_spawn_file_actions_destroy(&fa);
    return rc == 0 ? pid : -1;
}

static int wait_ok(pid_t pid) {
    int st;
    while (waitpid(pid, &st, 0) < 0) { if (errno != EINTR) return 0; }
    return WIFEXITED(st) && WEXITSTATUS(st) == 0;
}

static int is_link_arg(const char *a) {
    size_t l = strlen(a);
    if (a[0] == '@') return 1;
    if (starts(a, l, "-l") || starts(a, l, "-L") || starts(a, l, "-Wl,") || strcmp(a, "-framework") == 0) return 1;
    if (l > 2 && (strcmp(a + l - 2, ".o") == 0 || strcmp(a + l - 2, ".a") == 0)) return 1;
    if (l > 6 && strcmp(a + l - 6, ".dylib") == 0) return 1;
    if (l > 3 && strcmp(a + l - 3, ".so") == 0) return 1;
    return 0;
}

/* ---- constants by content ----
   goose numbers string constants (gs_strN) and embedded files (gs_blobN) across the program, so one new string
   renumbers every later one and changes most of the C. They are renamed here by their content (gw_s and gw_b and
   16 hex digits), so a unit's text changes only when its own code does. A string is defined in each unit that uses
   it (static const, as goose has it), or in the header when the header uses it; an embedded file once, in ublob.c. */

typedef struct { uint64_t h; int blob; size_t def_at, def_len; int in_header; size_t mark; const char *src; size_t src_len; } konst;
typedef struct { konst *k; size_t n, cap; uint64_t *slot_h; int64_t *slot_i; size_t slots; } konsts;

static int64_t konst_find(const konsts *t, uint64_t h) {
    if (t->slots == 0) return -1;
    size_t i = (size_t)(h ^ (h >> 29)) & (t->slots - 1);
    while (t->slot_i[i] >= 0) {
        if (t->slot_h[i] == h) return t->slot_i[i];
        i = (i + 1) & (t->slots - 1);
    }
    return -1;
}

static int64_t konst_add(konsts *t, uint64_t h, int blob) {
    int64_t f = konst_find(t, h);
    if (f >= 0) return f;
    if (t->n == t->cap) { t->cap = t->cap ? t->cap * 2 : 1024; t->k = realloc(t->k, t->cap * sizeof *t->k); }
    if ((t->n + 1) * 2 > t->slots) {
        size_t ns = t->slots ? t->slots * 2 : 4096;
        uint64_t *sh = malloc(ns * sizeof *sh);
        int64_t *si = malloc(ns * sizeof *si);
        for (size_t i = 0; i < ns; i++) si[i] = -1;
        for (size_t j = 0; j < t->n; j++) {
            size_t i = (size_t)(t->k[j].h ^ (t->k[j].h >> 29)) & (ns - 1);
            while (si[i] >= 0) i = (i + 1) & (ns - 1);
            sh[i] = t->k[j].h;
            si[i] = (int64_t)j;
        }
        free(t->slot_h);
        free(t->slot_i);
        t->slot_h = sh;
        t->slot_i = si;
        t->slots = ns;
    }
    size_t i = (size_t)(h ^ (h >> 29)) & (t->slots - 1);
    while (t->slot_i[i] >= 0) i = (i + 1) & (t->slots - 1);
    t->slot_h[i] = h;
    t->slot_i[i] = (int64_t)t->n;
    konst *k = &t->k[t->n];
    memset(k, 0, sizeof *k);
    k->h = h;
    k->blob = blob;
    k->mark = (size_t)-1;
    return (int64_t)t->n++;
}

/* Calls f for each identifier of [p, p + n) outside comments, strings and character literals. */
typedef void (*ident_fn)(void *ctx, const char *id, size_t len);
static void each_ident(const char *p, size_t n, ident_fn f, void *ctx) {
    size_t i = 0;
    while (i < n) {
        char c = p[i];
        if (c == '/' && i + 1 < n && p[i + 1] == '*') {
            const char *e = strstr(p + i + 2, "*/");
            i = e && (size_t)(e - p) < n ? (size_t)(e - p) + 2 : n;
            continue;
        }
        if (c == '/' && i + 1 < n && p[i + 1] == '/') { while (i < n && p[i] != '\n') i++; continue; }
        if (c == '"' || c == '\'') {
            i++;
            while (i < n && p[i] != c) { if (p[i] == '\\') i++; i++; }
            i++;
            continue;
        }
        if (ident(c) && !(c >= '0' && c <= '9')) {
            size_t j = i;
            while (j < n && ident(p[j])) j++;
            f(ctx, p + i, j - i);
            i = j;
            continue;
        }
        if (c >= '0' && c <= '9') { while (i < n && (ident(p[i]) || p[i] == '.')) i++; continue; }
        i++;
    }
}

/* gs_strN or gs_blobN: its number and kind (1 blob), or -1. */
static int64_t numbered(const char *id, size_t len, int *blob) {
    size_t pre;
    if (len > 6 && memcmp(id, "gs_str", 6) == 0) { pre = 6; *blob = 0; }
    else if (len > 7 && memcmp(id, "gs_blob", 7) == 0) { pre = 7; *blob = 1; }
    else return -1;
    int64_t v = 0;
    for (size_t i = pre; i < len; i++) {
        if (id[i] < '0' || id[i] > '9' || v > (1LL << 40)) return -1;
        v = v * 10 + (id[i] - '0');
    }
    return v;
}

/* A renamed constant: gw_s or gw_b and 16 hex digits. Its table index, or -1. */
static int64_t renamed(const konsts *t, const char *id, size_t len) {
    if (len != 20 || memcmp(id, "gw_", 3) != 0 || (id[3] != 's' && id[3] != 'b')) return -1;
    uint64_t h = 0;
    for (size_t i = 4; i < 20; i++) {
        char c = id[i];
        int d = c >= '0' && c <= '9' ? c - '0' : c >= 'a' && c <= 'f' ? c - 'a' + 10 : -1;
        if (d < 0) return -1;
        h = h * 16 + (uint64_t)d;
    }
    return konst_find(t, h);
}

typedef struct { konsts *t; int64_t *str_id, *blob_id; size_t nstr, nblob; buf *out; const char *base; size_t copied; } rename_ctx;

/* Copies the text up to each numbered constant and its new name in its place. */
static void rename_one(void *v, const char *id, size_t len) {
    rename_ctx *c = v;
    int blob;
    int64_t n = numbered(id, len, &blob);
    if (n < 0) return;
    int64_t k = blob ? ((size_t)n < c->nblob ? c->blob_id[n] : -1) : ((size_t)n < c->nstr ? c->str_id[n] : -1);
    if (k < 0) return;
    size_t at = (size_t)(id - c->base);
    put(c->out, c->base + c->copied, at - c->copied);
    char nm[24];
    snprintf(nm, sizeof nm, "gw_%c%016llx", blob ? 'b' : 's', (unsigned long long)c->t->k[k].h);
    puts_(c->out, nm);
    c->copied = at + len;
}

typedef struct { konsts *t; size_t mark; buf *defs; const char *S; } use_ctx;

/* For a header item: marks each string it uses as defined in the header. */
static void header_use(void *v, const char *id, size_t len) {
    use_ctx *c = v;
    int64_t k = renamed(c->t, id, len);
    if (k >= 0 && !c->t->k[k].blob) c->t->k[k].in_header = 1;
}

/* For a unit: appends the definition of each string it uses, once, unless the header has it. */
static void unit_use(void *v, const char *id, size_t len) {
    use_ctx *c = v;
    int64_t k = renamed(c->t, id, len);
    if (k < 0) return;
    konst *q = &c->t->k[k];
    if (q->blob || q->in_header || q->mark == c->mark || q->def_len == 0) return;
    q->mark = c->mark;
    put(c->defs, c->S + q->def_at, q->def_len);
    puts_(c->defs, "\n");
}

/* ---- the entry point ---- */

/* GWEB_DEVCC_DEBUG=1 says why the split compile gave up (the dev compiler then compiles the C whole). */
#define BAIL(code) do { if (getenv("GWEB_DEVCC_DEBUG")) fprintf(stderr, "gweb __devcc: gave up at devcc.c:%d\n", __LINE__); \
                        return (code); } while (0)

/* args: the C compiler's arguments as goose gave them (-O already -O0), one per line. units: how many units of
   function bodies, all compiled at once. times: where to write what it did, or "". 0 when out is linked. */
int32_t gweb_devcc(gweb_bytes cc_b, gweb_bytes args_b, int64_t units, gweb_bytes times_b) {
    double t0 = now();
    char *cc = malloc((size_t)cc_b.len + 1);
    memcpy(cc, cc_b.data, (size_t)cc_b.len);
    cc[cc_b.len] = 0;
    char *times = malloc((size_t)times_b.len + 1);
    memcpy(times, times_b.data, (size_t)times_b.len);
    times[times_b.len] = 0;
    /* The arguments. */
    char *al = malloc((size_t)args_b.len + 1);
    memcpy(al, args_b.data, (size_t)args_b.len);
    al[args_b.len] = 0;
    size_t na = 0, capa = 64;
    char **args = malloc(capa * sizeof *args);
    for (char *p = al; *p;) {
        char *nl = strchr(p, '\n');
        if (nl) *nl = 0;
        if (*p) { if (na + 1 >= capa) { capa *= 2; args = realloc(args, capa * sizeof *args); } args[na++] = p; }
        if (!nl) break;
        p = nl + 1;
    }
    const char *src = NULL, *out = NULL;
    for (size_t i = 0; i < na; i++) {
        size_t l = strlen(args[i]);
        if (strcmp(args[i], "-o") == 0 && i + 1 < na) out = args[i + 1];
        if (l > 2 && strcmp(args[i] + l - 2, ".c") == 0 && strstr(args[i], "/build/prog/")) src = args[i];
        if (strcmp(args[i], "-c") == 0 || strcmp(args[i], "-E") == 0 || strcmp(args[i], "-S") == 0) BAIL(2);
    }
    if (!src || !out) BAIL(2);
    if (units < 1) units = 1;
    if (units > 256) units = 256;

    buf in = {0};
    if (!read_all(src, &in)) BAIL(2);
    const char *S = in.p;
    const char *proto_m = strstr(S, "\n/* ---- prototypes ---- */\n");
    const char *code_m = proto_m ? strstr(proto_m, "\n/* ---- code ---- */\n") : NULL;
    if (!code_m || !strstr(S, "#define GS_SEPARATE_RUNTIME 1\n")) BAIL(2);
    size_t proto = (size_t)(proto_m - S) + 1, code = (size_t)(code_m - S) + 1;
    item *it;
    size_t ni;
    if (!scan(S, proto, &it, &ni)) BAIL(2);       /* the constants are all before the prototypes */

    /* The numbered constants, by content, and the C with their new names. */
    konsts kt = {0};
    size_t nstr = 0, nblob = 0;
    int64_t *str_id = NULL, *blob_id = NULL;
    for (size_t k = 0; k < ni; k++) {
        if (it[k].pp) continue;
        size_t b = skip_lead(S, it[k].s, it[k].e), e = it[k].e;
        if (b >= proto) break;
        const char *p = S + b;
        size_t len = e - b;
        if (!starts(p, len, "static const uint8_t gs_")) continue;
        const char *id = p + 21, *br = memchr(id, '[', len - 21);
        if (!br) continue;
        int blob;
        int64_t n = numbered(id, (size_t)(br - id), &blob);
        if (n < 0) continue;
        h128 h = { 14695981039346656037ULL, 0x243F6A8885A308D3ULL };
        hmix(&h, br, (size_t)(p + len - br));
        int64_t q = konst_add(&kt, h.a ^ (h.b * 31) ^ (uint64_t)blob, blob);
        size_t cl = (size_t)(p + len - br);
        if (!kt.k[q].src) { kt.k[q].src = br; kt.k[q].src_len = cl; }
        else if (kt.k[q].src_len != cl || memcmp(kt.k[q].src, br, cl) != 0) BAIL(2);   /* two contents, one hash */
        int64_t **ids = blob ? &blob_id : &str_id;
        size_t *cnt = blob ? &nblob : &nstr;
        if ((size_t)n >= *cnt) {
            size_t nc = (size_t)n + 1 > *cnt * 2 ? (size_t)n + 1 : *cnt * 2;
            *ids = realloc(*ids, nc * sizeof **ids);
            for (size_t i = *cnt; i < nc; i++) (*ids)[i] = -1;
            *cnt = nc;
        }
        if ((*ids)[n] >= 0) BAIL(2);               /* defined twice: not a layout this knows */
        (*ids)[n] = q;
    }
    buf ren = {0};
    rename_ctx rc = { &kt, str_id, blob_id, nstr, nblob, &ren, S, 0 };
    each_ident(S, in.n, rename_one, &rc);
    put(&ren, S + rc.copied, in.n - rc.copied);
    free(it);
    S = ren.p;
    in.n = ren.n;
    proto_m = strstr(S, "\n/* ---- prototypes ---- */\n");
    code_m = proto_m ? strstr(proto_m, "\n/* ---- code ---- */\n") : NULL;
    if (!code_m) BAIL(2);
    proto = (size_t)(proto_m - S) + 1;
    code = (size_t)(code_m - S) + 1;
    if (!scan(S, in.n, &it, &ni)) BAIL(2);

    buf hdr = {0}, defs = {0}, blob = {0};
    puts_(&hdr, "#define GW_HID __attribute__((visibility(\"hidden\")))\n");
    puts_(&blob, "#include <stdint.h>\n");
    size_t last = 0, nproto = 0, cproto = 1024;
    span *protos = malloc(cproto * sizeof *protos);
    size_t first_code = ni, str_at = 0;
    int str_at_set = 0;
    for (size_t k = 0; k < ni; k++) {
        size_t s = it[k].s, e = it[k].e;
        size_t b = it[k].pp ? s : skip_lead(S, s, e);   /* regions go by where the item's text starts */
        if (b >= code) { first_code = k; break; }
        if (it[k].pp) continue;
        const char *p = S + b;
        size_t len = e - b;
        if (!starts(p, len, "static const uint8_t gw_")) {
            use_ctx uc = { &kt, 0, NULL, S };
            each_ident(p, len, header_use, &uc);
        }
        if (b < proto && starts(p, len, "static ") && p[len - 1] == ';') {
            const char *eq = memchr(p, '=', len);
            const char *paren = memchr(p, '(', eq ? (size_t)(eq - p) : len);
            if (paren && paren[1] == '*') BAIL(2);         /* a function pointer: not a layout this knows */
            if (paren) continue;                            /* a static function's prototype: stays static */
            const char *br = memchr(p, '[', len);
            int64_t q = len > 21 && br ? renamed(&kt, p + 21, (size_t)(br - p - 21)) : -1;
            if (starts(p, len, "static const uint8_t gw_s") && q >= 0) {
                /* A string: defined where it is used. */
                if (kt.k[q].def_len == 0) { kt.k[q].def_at = b; kt.k[q].def_len = len; }
                /* Its line goes too (and any comment before it), so the header's text does not count strings. */
                if (!str_at_set) { str_at = hdr.n + (b - last); str_at_set = 1; put(&hdr, S + last, b - last); }
                last = e;
                continue;
            }
            if (starts(p, len, "static const uint8_t gw_b") && q >= 0 && eq) {
                /* An embedded file: defined in ublob.c. */
                if (kt.k[q].def_len) { put(&hdr, S + last, b - last); last = e; continue; }
                kt.k[q].def_len = len;
                put(&hdr, S + last, b - last);
                puts_(&hdr, "extern ");
                const char *d = p + 7, *de = eq;
                while (de > d && de[-1] == ' ') de--;
                put(&hdr, d, (size_t)(de - d));
                puts_(&hdr, ";");
                put(&blob, p + 7, len - 7);
                puts_(&blob, "\n");
                last = e;
                continue;
            }
            if (starts(p, len, "static const ")) {          /* read-only: a copy per unit */
                use_ctx uc = { &kt, 0, NULL, S };
                each_ident(p, len, header_use, &uc);
                continue;
            }
            /* A mutable static: one definition, in unit 0. */
            const char *de = eq ? eq : p + len - 1;
            for (const char *q = p; q < de; q++) if (*q == ',' || *q == '{') BAIL(2);
            while (de > p && de[-1] == ' ') de--;
            put(&hdr, S + last, b - last);
            puts_(&hdr, "extern ");
            put(&hdr, p + 7, (size_t)(de - p - 7));
            puts_(&hdr, ";");
            put(&defs, p + 7, len - 7);
            puts_(&defs, "\n");
            last = e;
            continue;
        }
        if (b >= proto) {
            if (!starts(p, len, "static ") || p[len - 1] != ';') BAIL(2);
            const char *nm;
            size_t nl;
            if (!fn_name(p, len, &nm, &nl)) BAIL(2);
            if (nproto == cproto) { cproto *= 2; protos = realloc(protos, cproto * sizeof *protos); }
            protos[nproto].p = nm;
            protos[nproto].n = nl;
            nproto++;
            put(&hdr, S + last, b - last);
            puts_(&hdr, "GW_HID ");
            size_t skip = 7;
            if (starts(p + 7, len - 7, "inline ")) skip += 7;
            put(&hdr, p + skip, len - skip);
            last = e;
        }
    }
    put(&hdr, S + last, (first_code < ni ? it[first_code].s : code) - last);
    qsort(protos, nproto, sizeof *protos, span_cmp);
    {
        /* The strings the header uses, where goose had its strings. */
        buf h2 = {0}, hd = {0};
        for (size_t q = 0; q < kt.n; q++) {
            if (kt.k[q].blob || !kt.k[q].in_header || kt.k[q].def_len == 0) continue;
            put(&hd, S + kt.k[q].def_at, kt.k[q].def_len);
            puts_(&hd, "\n");
        }
        put(&h2, hdr.p, str_at);
        put(&h2, hd.p ? hd.p : "", hd.n);
        put(&h2, hdr.p + str_at, hdr.n - str_at);
        free(hdr.p);
        free(hd.p);
        hdr = h2;
    }

    /* The code: functions with a prototype to the units, the rest to the last. A unit ends before a function whose
       name, digits left out, hashes to 0 mod R once the unit holds half its share, or at two shares, the share
       and R rounded down to powers of two. The cuts follow the code rather than byte counts, so an edit
       that grows one function moves no other cut, and the other units keep their cached objects. */
    size_t total = 0, nfn = 0;
    for (size_t k = first_code; k < ni; k++) {
        if (it[k].pp) BAIL(2);
        total += it[k].e - it[k].s;
        nfn++;
    }
    size_t share = 1;
    while (share * 2 <= total / (size_t)units + 1) share *= 2;
    size_t avg = total / (nfn ? nfn : 1) + 1;
    uint64_t R = 1;
    while (R * 2 * avg <= share / 2) R *= 2;
    size_t ucap = 16, nunits = 1;
    buf *u = calloc(ucap, sizeof *u);
    buf tail = {0};
    puts_(&u[0], "#include \"pre.h\"\n");
    put(&u[0], defs.p ? defs.p : "", defs.n);
    size_t acc = 0;
    for (size_t k = first_code; k < ni; k++) {
        size_t b = skip_lead(S, it[k].s, it[k].e), e = it[k].e;
        const char *p = S + b;
        size_t len = e - b;
        span nm;
        if (!fn_name(p, len, &nm.p, &nm.n)) BAIL(2);
        if (bsearch(&nm, protos, nproto, sizeof *protos, span_cmp)) {
            uint64_t h = 14695981039346656037ULL;
            for (size_t c = 0; c < nm.n; c++) if (nm.p[c] < '0' || nm.p[c] > '9') h = (h ^ (uint8_t)nm.p[c]) * 1099511628211ULL;
            h ^= h >> 31;
            if (acc >= share * 2 || (acc >= share / 2 && h % R == 0)) {
                if (nunits == ucap) { ucap *= 2; u = realloc(u, ucap * sizeof *u); }
                memset(&u[nunits], 0, sizeof *u);
                puts_(&u[nunits], "#include \"pre.h\"\n");
                nunits++;
                acc = 0;
            }
            acc += len;
            size_t skip = 0;
            if (starts(p, len, "static ")) skip = 7;
            if (starts(p + skip, len - skip, "inline ")) skip += 7;
            put(&u[nunits - 1], p + skip, len - skip);
            puts_(&u[nunits - 1], "\n\n");
        } else {
            put(&tail, p, len);
            puts_(&tail, "\n\n");
        }
    }
    put(&u[nunits - 1], tail.p ? tail.p : "", tail.n);
    units = (int64_t)nunits;
    for (size_t j = 0; j < nunits; j++) {
        /* After the #include line: the strings the unit uses. */
        buf d = {0}, w = {0};
        use_ctx uc = { &kt, j, &d, S };
        each_ident(u[j].p, u[j].n, unit_use, &uc);
        const char *nl = strchr(u[j].p, '\n') + 1;
        put(&w, u[j].p, (size_t)(nl - u[j].p));
        put(&w, d.p ? d.p : "", d.n);
        put(&w, nl, u[j].n - (size_t)(nl - u[j].p));
        free(u[j].p);
        free(d.p);
        u[j] = w;
    }

    /* The files, beside goose's C file. */
    char dir[4096], path[4096];
    snprintf(dir, sizeof dir, "%.*s/gweb-units", (int)(strrchr(src, '/') - src), src);
    mkdir(dir, 0755);
    snprintf(path, sizeof path, "%s/o", dir);
    mkdir(path, 0755);
    snprintf(path, sizeof path, "%s/pre.h", dir);
    if (!write_if_changed(path, hdr.p, hdr.n)) BAIL(2);

    /* The compile flags: the arguments without the source, the output and the link inputs. */
    size_t nf = 0;
    char **flags = malloc((na + 1) * sizeof *flags);
    for (size_t i = 0; i < na; i++) {
        if (args[i] == src) continue;
        if (strcmp(args[i], "-o") == 0) { i++; continue; }
        if (is_link_arg(args[i])) continue;
        flags[nf++] = args[i];
    }
    h128 base = { 14695981039346656037ULL, 0x243F6A8885A308D3ULL };
    hmix(&base, cc, strlen(cc) + 1);
    for (size_t i = 0; i < nf; i++) hmix(&base, flags[i], strlen(flags[i]) + 1);

    size_t nu = (size_t)units + 1;    /* the units, then ublob.c */
    char (*objs)[4200] = malloc(nu * sizeof *objs);
    char (*srcs)[4200] = malloc(nu * sizeof *srcs);
    int *need = calloc(nu, sizeof *need);
    size_t compiled = 0;
    double t1 = now();
    for (size_t j = 0; j < nu; j++) {
        buf *t = j < (size_t)units ? &u[j] : &blob;
        h128 h = base;
        if (j < (size_t)units) hmix(&h, hdr.p, hdr.n);
        hmix(&h, t->p, t->n);
        snprintf(srcs[j], sizeof srcs[j], j < (size_t)units ? "%s/u%zu.c" : "%s/ublob.c", dir, j);
        snprintf(objs[j], sizeof objs[j], "%s/o/%016llx%016llx.o", dir, (unsigned long long)h.a, (unsigned long long)h.b);
        if (!write_if_changed(srcs[j], t->p, t->n)) BAIL(2);
        struct stat st;
        need[j] = stat(objs[j], &st) != 0;
    }
    /* Compile what is missing. Each object is written beside its name and renamed, so an
       interrupted compile leaves no object behind. */
    size_t jobs = nu;     /* all at once: with two units per hardware thread that beat one compile per thread */
    pid_t *pids = calloc(nu, sizeof *pids);
    char (*tmps)[4300] = malloc(nu * sizeof *tmps);
    size_t running = 0, next = 0;
    int ok = 1;
    for (;;) {
        while (ok && next < nu && running < jobs) {
            size_t j = next++;
            if (!need[j]) continue;
            snprintf(tmps[j], sizeof tmps[j], "%s.%d.tmp", objs[j], (int)getpid());
            char log[4300];
            snprintf(log, sizeof log, "%s/u%zu.log", dir, j);
            char **argv = malloc((nf + 6) * sizeof *argv);
            size_t a = 0;
            argv[a++] = cc;
            for (size_t i = 0; i < nf; i++) argv[a++] = flags[i];
            argv[a++] = "-c";
            argv[a++] = srcs[j];
            argv[a++] = "-o";
            argv[a++] = tmps[j];
            argv[a] = NULL;
            pids[j] = spawn(argv, log);
            free(argv);
            if (pids[j] < 0) { ok = 0; break; }
            running++;
            compiled++;
        }
        if (running == 0) break;
        int st;
        pid_t p = wait(&st);
        if (p < 0) { if (errno == EINTR) continue; ok = 0; break; }
        for (size_t j = 0; j < nu; j++) {
            if (pids[j] != p) continue;
            pids[j] = 0;
            running--;
            if (!(WIFEXITED(st) && WEXITSTATUS(st) == 0) || rename(tmps[j], objs[j]) != 0) { ok = 0; unlink(tmps[j]); }
        }
    }
    for (size_t j = 0; j < nu; j++) if (pids[j] > 0) { wait_ok(pids[j]); unlink(tmps[j]); }
    if (!ok) BAIL(1);
    double t2 = now();

    /* The link: goose's command with the objects in place of main.c. */
    char **argv = malloc((na + nu + 2) * sizeof *argv);
    size_t a = 0;
    argv[a++] = cc;
    for (size_t i = 0; i < na; i++) {
        if (args[i] == src) { for (size_t j = 0; j < nu; j++) argv[a++] = objs[j]; continue; }
        argv[a++] = args[i];
    }
    argv[a] = NULL;
    char log[4300];
    snprintf(log, sizeof log, "%s/link.log", dir);
    pid_t lp = spawn(argv, log);
    free(argv);
    if (lp < 0 || !wait_ok(lp)) BAIL(1);
    double t3 = now();

    /* Keep the objects of this build and the one before; drop the rest. */
    buf keep = {0}, prev = {0};
    for (size_t j = 0; j < nu; j++) { puts_(&keep, strrchr(objs[j], '/') + 1); puts_(&keep, "\n"); }
    snprintf(path, sizeof path, "%s/objects.txt", dir);
    read_all(path, &prev);
    char prevpath[4300];
    snprintf(prevpath, sizeof prevpath, "%s/objects-1.txt", dir);
    write_if_changed(prevpath, prev.p ? prev.p : "", prev.n);
    write_if_changed(path, keep.p, keep.n);
    snprintf(path, sizeof path, "%s/o", dir);
    {
        DIR *d = opendir(path);
        if (d) {
            struct dirent *de;
            while ((de = readdir(d))) {
                size_t l = strlen(de->d_name);
                if (l < 3 || strcmp(de->d_name + l - 2, ".o") != 0) continue;
                if ((keep.p && strstr(keep.p, de->d_name)) || (prev.p && strstr(prev.p, de->d_name))) continue;
                char f[4400];
                snprintf(f, sizeof f, "%s/%s", path, de->d_name);
                unlink(f);
            }
            closedir(d);
        }
    }
    if (times[0]) {
        FILE *f = fopen(times, "w");
        if (f) {
            fprintf(f, "split %d\ncompile %d\nunits %zu %zu\nlink %d\n", (int)((t1 - t0) * 1000),
                    (int)((t2 - t1) * 1000), compiled, nu, (int)((t3 - t2) * 1000));
            fclose(f);
        }
    }
    return 0;
}
