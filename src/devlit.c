/* A dev build's template text (docs/dev-builds.md): gweb dev compiles each literal run of a page, layout or view
   template to gweb::_dev_lit(out, T, N), template T's run N, and writes the runs to .gweb/lits as "T N LEN:BYTES",
   T and N ascending. The server reads the file once, as it starts and before any thread, and never changes it, so
   workers read it without a lock. A change to template text alone then leaves the C as it was. */
#include "goose.h"

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct { const uint8_t *data; int64_t len; } gweb_lit_bytes;

typedef struct { int64_t at, len; } lit_run;
static char *lit_buf;
static lit_run *lit_runs;
static int64_t *lit_first, *lit_count;   /* per template: its first run in lit_runs, and how many */
static int64_t lit_tpls;

static int num(const char *b, size_t n, size_t *i, int64_t *v, char end) {
    size_t j = *i;
    int64_t x = 0;
    while (j < n && b[j] >= '0' && b[j] <= '9') {
        x = x * 10 + (b[j] - '0');
        if (x > (1LL << 40)) return 0;
        j++;
    }
    if (j == *i || j >= n || b[j] != end) return 0;
    *v = x;
    *i = j + 1;
    return 1;
}

/* The number of runs, or -1 when the file is missing or malformed. */
int64_t gweb_dev_lits_load(gweb_lit_bytes path) {
    char p[4096];
    if (path.len <= 0 || path.len >= (int64_t)sizeof p) return -1;
    memcpy(p, path.data, (size_t)path.len);
    p[path.len] = 0;
    FILE *f = fopen(p, "rb");
    if (!f) return -1;
    size_t cap = 1 << 16, n = 0, r;
    char *b = malloc(cap);
    while (b && (r = fread(b + n, 1, cap - n, f)) > 0) {
        n += r;
        if (n == cap) { cap *= 2; b = realloc(b, cap); }
    }
    fclose(f);
    if (!b) return -1;
    /* Two passes: count, then fill. */
    int64_t runs = 0, tpls = 0;
    for (int pass = 0; pass < 2; pass++) {
        size_t i = 0;
        int64_t k = 0, last_t = -1, last_n = -1;
        while (i < n) {
            int64_t t, id, len;
            if (!num(b, n, &i, &t, ' ') || !num(b, n, &i, &id, ' ') || !num(b, n, &i, &len, ':') ||
                (size_t)len > n - i || t < last_t || (t == last_t && id <= last_n)) { free(b); return -1; }
            if (pass == 0) { if (t + 1 > tpls) tpls = t + 1; }
            else {
                if (t != last_t) { lit_first[t] = k; }
                if (id != lit_count[t]) { free(b); return -1; }   /* runs are numbered 0, 1, ... */
                lit_count[t]++;
                lit_runs[k].at = (int64_t)i;
                lit_runs[k].len = len;
            }
            last_t = t;
            last_n = id;
            k++;
            i += (size_t)len;
        }
        if (pass == 0) {
            runs = k;
            lit_runs = malloc((size_t)(runs + 1) * sizeof *lit_runs);
            lit_first = calloc((size_t)(tpls + 1), sizeof *lit_first);
            lit_count = calloc((size_t)(tpls + 1), sizeof *lit_count);
            if (!lit_runs || !lit_first || !lit_count) { free(b); return -1; }
        }
    }
    lit_buf = b;
    lit_tpls = tpls;
    return runs;
}

/* Appends template tpl's run id to out. */
void gweb_dev_lit(int64_t tpl, int64_t id, gs_rref out) {
    if (tpl < 0 || tpl >= lit_tpls || id < 0 || id >= lit_count[tpl]) {
        static const char miss[] = "[gweb: template text missing: start a dev build's server from its project folder]";
        gs_bld_append(out, miss, (int64_t)sizeof miss - 1);
        return;
    }
    const lit_run *r = &lit_runs[lit_first[tpl] + id];
    if (r->len > 0) gs_bld_append(out, lit_buf + r->at, r->len);
}
