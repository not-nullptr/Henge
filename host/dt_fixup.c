#include "dt_fixup.h"

#include <stdio.h>
#include <string.h>
#include <time.h>

/* See dt_fixup.h. While iBoot runs, a pass every 50 ms scans guest RAM for the
   tree (page-aligned anywhere in the first GB, and 16-byte aligned in the low
   256 MB where iBoot's heap sits: boot_args lands near 142 MB in, and the tree
   sits just below it). Separately, vm.c watches for boot_args and hands us the
   exact tree it names (hv_dt_fixup_tree); from then on that one blob is
   re-patched every tick, which catches a tree iBoot only finalises at the
   handoff. The caller stops us when the GPU draws; GIVE_UP is the backstop. */

#define STOCK_NAME "Apple Virtual Machine 1"
#define STOCK_MODEL "VirtualMac2,1"
#define SCAN_WINDOW (256ull << 20)
#define PAGE_WINDOW (1ull << 30)
#define SCAN_EVERY 0.05
#define GIVE_UP 120.0

static uint8_t *ram;
static uint64_t ram_size;
static char want_name[32], want_model[32];
static int active, total_changed, diag;
static double started, last_pass;
static uint64_t tracked[8];
static int ntracked;
static uint64_t final_off, final_len; /* the tree boot_args names, once known */
static int have_final;

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
   in place, and device-tree strings are read as C strings. The slot may be
   larger than the stock string (a fixed-size field), so only its prefix needs
   to match. Only the stock value is replaced, so another pass changes nothing,
   and a value iBoot put back is replaced again. */
static int replace(uint8_t *data, uint32_t len, const char *stock, const char *want) {
    uint32_t sl = (uint32_t)strlen(stock) + 1, n = (uint32_t)strlen(want) + 1;
    if (n > len || len < sl || memcmp(data, stock, sl)) return 0;
    memcpy(data, want, n);
    memset(data + n, 0, len - n);
    return 1;
}

/* One mismatch is worth the whole story: the slot's real size and value say
   whether the firmware differs from what this expects. A value already rewritten
   is not a mismatch. */
static void mismatch(const char *prop, const uint8_t *data, uint32_t len, const char *stock, const char *want) {
    if (diag) return;
    uint32_t wl = (uint32_t)strlen(want) + 1;
    if (len >= wl && memcmp(data, want, wl) == 0) return;
    diag = 1;
    fprintf(stderr, "hengevm: device tree: %s is %u bytes \"%.*s\" (stock \"%s\", wanted \"%s\"); leaving it\n",
            prop, len, (int)(len < 60 ? len : 60), (const char *)data, stock, want);
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
        if (depth == 1 && want_model[0] && !strcmp(pname, "model")) {
            int r = replace(data, len, STOCK_MODEL, want_model);
            if (r) changed += r;
            else mismatch("model", data, len, STOCK_MODEL, want_model);
        } else if (depth == 2 && in_product && want_name[0] && !strcmp(pname, "product-name")) {
            int r = replace(data, len, STOCK_NAME, want_name);
            if (r) changed += r;
            else mismatch("product-name", data, len, STOCK_NAME, want_name);
        }
    }
    return changed;
}

int hv_dt_fixup_start(uint8_t *r, uint64_t size, const char *product_name, const char *model_id) {
    ram = r;
    ram_size = size;
    want_name[0] = want_model[0] = 0;
    active = total_changed = ntracked = have_final = diag = 0;
    final_off = final_len = 0;
    started = last_pass = 0;
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
    if (active) {
        started = now();
        fprintf(stderr, "hengevm: device tree: watching for the guest's tree (name \"%s\", model \"%s\")\n",
                want_name[0] ? want_name : "-", want_model[0] ? want_model : "-");
    }
    return active;
}

int hv_dt_fixup_tree(uint64_t offset, uint64_t len) {
    if (!active || have_final) return have_final;
    if (offset + 40 > ram_size || len < 40 || len > (1u << 20) || offset + len > ram_size ||
        !is_dtb(ram + offset, len)) {
        fprintf(stderr, "hengevm: device tree: boot_args names +%llx (%llu bytes), not a tree there yet\n",
                (unsigned long long)offset, (unsigned long long)len);
        return 0;
    }
    have_final = 1;
    final_off = offset;
    final_len = len;
    fprintf(stderr, "hengevm: device tree: boot_args names the final tree at RAM +%llx (%llu bytes)\n",
            (unsigned long long)offset, (unsigned long long)len);
    return 1;
}

/* Patch a tree found by the scan, remembering it so a value iBoot puts back is
   replaced again. */
static void consider(uint64_t off, uint64_t avail) {
    if (!is_dtb(ram + off, avail)) return;
    int known = 0;
    for (int i = 0; i < ntracked; i++) known |= tracked[i] == off;
    if (!known && ntracked < 8) tracked[ntracked++] = off;
    int n = hv_dt_fixup_blob(ram + off, avail);
    if (n) {
        fprintf(stderr, "hengevm: device tree at RAM +%llx: rewrote %d identity string%s\n",
                (unsigned long long)off, n, n == 1 ? "" : "s");
        total_changed += n;
    }
}

void hv_dt_fixup_poll(void) {
    if (!active) return;
    double t = now();
    if (t - started > GIVE_UP) {
        fprintf(stderr, "hengevm: device tree: giving up after %.0f s (%d rewritten)\n", GIVE_UP, total_changed);
        active = 0;
        return;
    }
    /* The final tree, once boot_args has named it: every tick, no throttle.
       This is the blob the kernel takes; re-patching catches a late rebuild. */
    if (have_final) {
        int n = hv_dt_fixup_blob(ram + final_off, final_len);
        if (n) {
            fprintf(stderr, "hengevm: device tree (final) at RAM +%llx: rewrote %d string%s\n",
                    (unsigned long long)final_off, n, n == 1 ? "" : "s");
            total_changed += n;
        }
        return;
    }
    if (t - last_pass < SCAN_EVERY) return;
    last_pass = t;
    /* Trees already found may have had a value put back. */
    for (int i = 0; i < ntracked; i++) {
        if (tracked[i] + 40 > ram_size || !is_dtb(ram + tracked[i], ram_size - tracked[i])) continue;
        int n = hv_dt_fixup_blob(ram + tracked[i], ram_size - tracked[i]);
        if (n) {
            fprintf(stderr, "hengevm: device tree at RAM +%llx: rewrote %d string%s again\n",
                    (unsigned long long)tracked[i], n, n == 1 ? "" : "s");
            total_changed += n;
        }
    }
    /* Page-aligned trees anywhere in the first GB (the tree sits below boot_args). */
    uint64_t page_limit = ram_size < PAGE_WINDOW ? ram_size : PAGE_WINDOW;
    for (uint64_t off = 0; off + 40 <= page_limit; off += 0x1000) {
        const uint8_t *b = ram + off;
        if (b[0] == 0xd0 && b[1] == 0x0d && b[2] == 0xfe && b[3] == 0xed) consider(off, page_limit - off);
    }
    /* Finer: iBoot's heap allocations are 16-byte aligned, not always page-aligned. */
    uint64_t limit = ram_size < SCAN_WINDOW ? ram_size : SCAN_WINDOW;
    for (uint64_t off = 0; off + 40 <= limit; off += 16) {
        const uint8_t *b = ram + off;
        if (b[0] == 0xd0 && b[1] == 0x0d && b[2] == 0xfe && b[3] == 0xed) consider(off, limit - off);
    }
}

void hv_dt_fixup_stop(void) {
    if (!active) return;
    if (total_changed)
        fprintf(stderr, "hengevm: device tree: the GPU drew; %d string%s rewritten\n", total_changed,
                total_changed == 1 ? "" : "s");
    else
        fprintf(stderr, "hengevm: device tree: the GPU drew; no tree was rewritten, the guest keeps its own name\n");
    active = 0;
}