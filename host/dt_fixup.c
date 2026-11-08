#include "dt_fixup.h"

#include <stdio.h>
#include <string.h>
#include <time.h>

/* See dt_fixup.h. The tree is found by its magic in the low part of guest RAM
   (iBoot's heap: boot_args lands near 142 MB in), and patched in place. A pass
   every 50 ms while iBoot runs is plenty: the tree sits there for seconds while
   iBoot loads the kernel, and iBoot does not rewrite these two static strings.
   Once a tree is found, passes only re-check it (cheap) and rescan fully once a
   second in case iBoot moved it. The caller stops polling when the GPU draws;
   GIVE_UP is the backstop for a boot that never gets there. */

#define STOCK_NAME "Apple Virtual Machine 1"
#define STOCK_MODEL "VirtualMac2,1"
#define SCAN_WINDOW (256ull << 20)
#define SCAN_EVERY 0.05
#define FULL_EVERY 1.0
#define GIVE_UP 120.0

static uint8_t *ram;
static uint64_t ram_size;
static char want_name[32], want_model[32];
static int active, total_changed;
static double started, last_pass, last_full;
static uint64_t tracked[8];
static int ntracked;

static double now(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
}

static uint32_t be32(const uint8_t *p) {
    return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | (uint32_t)p[3];
}

/* A flattened device tree (v17 header), whole within avail. */
static int is_dtb(const uint8_t *b, uint64_t avail) {
    if (avail < 40 || be32(b) != 0xd00dfeed) return 0;
    uint32_t total = be32(b + 4), off_struct = be32(b + 8), off_strings = be32(b + 12);
    uint32_t version = be32(b + 20), size_strings = be32(b + 32), size_struct = be32(b + 36);
    if (version < 16 || version > 18 || total < 40 || total > (1u << 20) || total > avail) return 0;
    return off_struct < total && off_strings < total && size_struct <= total - off_struct &&
           size_strings <= total - off_strings;
}

/* A shorter string is NUL-padded to the property's length: the tree is edited
   in place, and device-tree strings are read as C strings. Only the stock value
   is replaced, so another pass changes nothing, and a value iBoot put back is
   replaced again. */
static int replace(uint8_t *data, uint32_t len, const char *stock, const char *want) {
    uint32_t n = (uint32_t)strlen(want) + 1;
    if (n > len || len != (uint32_t)strlen(stock) + 1 || memcmp(data, stock, len)) return 0;
    memcpy(data, want, n);
    memset(data + n, 0, len - n);
    return 1;
}

int hv_dt_fixup_blob(uint8_t *b, uint64_t avail) {
    if (!is_dtb(b, avail)) return 0;
    uint32_t off_struct = be32(b + 8), off_strings = be32(b + 12);
    uint32_t size_strings = be32(b + 32), size_struct = be32(b + 36);
    const uint8_t *strings = b + off_strings, *stop = b + off_struct + size_struct;
    const uint8_t *p = b + off_struct;
    int depth = 0, in_product = 0, changed = 0;
    while (p + 4 <= stop) {
        uint32_t tok = be32(p);
        p += 4;
        if (tok == 9) break;    /* FDT_END */
        if (tok == 4) continue; /* FDT_NOP */
        if (tok == 1) {         /* FDT_BEGIN_NODE: name, NUL-terminated, padded to 4 */
            const uint8_t *name = p;
            while (p < stop && *p) p++;
            if (p >= stop) break;
            p++;
            p += (4 - ((uintptr_t)p & 3)) & 3;
            if (p > stop) break;
            depth++;
            if (depth == 2) in_product = !strcmp((const char *)name, "product");
            continue;
        }
        if (tok == 2) { /* FDT_END_NODE */
            if (depth == 2) in_product = 0;
            depth--;
            continue;
        }
        if (tok != 3 || p + 8 > stop) break; /* FDT_PROP: {len, nameoff, data} */
        uint32_t len = be32(p), nameoff = be32(p + 4);
        p += 8;
        if (len > (uint64_t)(stop - p) || nameoff >= size_strings ||
            !memchr(strings + nameoff, 0, size_strings - nameoff)) break;
        uint8_t *data = (uint8_t *)p;
        p += (len + 3) & ~3u;
        if (p > stop) break;
        const char *pname = (const char *)(strings + nameoff);
        if (depth == 1 && want_model[0] && !strcmp(pname, "model"))
            changed += replace(data, len, STOCK_MODEL, want_model);
        else if (depth == 2 && in_product && want_name[0] && !strcmp(pname, "product-name"))
            changed += replace(data, len, STOCK_NAME, want_name);
    }
    return changed;
}

int hv_dt_fixup_start(uint8_t *r, uint64_t size, const char *product_name, const char *model_id) {
    ram = r;
    ram_size = size;
    want_name[0] = want_model[0] = 0;
    active = total_changed = ntracked = 0;
    started = last_pass = last_full = 0;
    if (!r) return 0;
    if (product_name && *product_name) {
        if (strlen(product_name) > strlen(STOCK_NAME))
            fprintf(stderr, "hengevm: device tree: \"%s\" is longer than the name slot; leaving it\n", product_name);
        else snprintf(want_name, sizeof want_name, "%s", product_name);
    }
    if (model_id && *model_id) {
        if (strlen(model_id) > strlen(STOCK_MODEL))
            fprintf(stderr, "hengevm: device tree: \"%s\" is longer than the model slot; leaving it\n", model_id);
        else snprintf(want_model, sizeof want_model, "%s", model_id);
    }
    active = want_name[0] || want_model[0];
    if (active) started = now();
    return active;
}

void hv_dt_fixup_poll(void) {
    if (!active) return;
    double t = now();
    if (t - started > GIVE_UP) {
        if (!total_changed)
            fprintf(stderr, "hengevm: device tree: none found in %.0f s; the guest keeps its own name\n", GIVE_UP);
        active = 0;
        return;
    }
    if (t - last_pass < SCAN_EVERY) return;
    last_pass = t;
    uint64_t limit = ram_size < SCAN_WINDOW ? ram_size : SCAN_WINDOW;
    /* Trees already found: iBoot may put a value back. One that is gone (moved
       or freed) sends us back to the full scan. */
    int lost = 0;
    for (int i = 0; i < ntracked; i++) {
        uint8_t *b = ram + tracked[i];
        if (tracked[i] + 40 > ram_size || !is_dtb(b, ram_size - tracked[i])) {
            lost = 1;
            continue;
        }
        int n = hv_dt_fixup_blob(b, ram_size - tracked[i]);
        if (n) {
            fprintf(stderr, "hengevm: device tree at RAM +%llx: rewrote %d string%s again\n",
                    (unsigned long long)tracked[i], n, n == 1 ? "" : "s");
            total_changed += n;
        }
    }
    if (lost) ntracked = 0;
    if (ntracked && t - last_full < FULL_EVERY) return;
    last_full = t;
    for (uint64_t off = 0; off + 40 <= limit; off += 16) {
        uint8_t *b = ram + off;
        if (b[0] != 0xd0 || b[1] != 0x0d || b[2] != 0xfe || b[3] != 0xed) continue;
        if (!is_dtb(b, limit - off)) continue;
        int known = 0;
        for (int i = 0; i < ntracked; i++) known |= tracked[i] == off;
        if (!known && ntracked < 8) tracked[ntracked++] = off;
        int n = hv_dt_fixup_blob(b, limit - off);
        if (n) {
            fprintf(stderr, "hengevm: device tree at RAM +%llx: rewrote %d identity string%s\n",
                    (unsigned long long)off, n, n == 1 ? "" : "s");
            total_changed += n;
        }
    }
}