#ifndef HENGEVM_DT_FIXUP_H
#define HENGEVM_DT_FIXUP_H

#include <stdint.h>

/* The guest's device tree hardcodes two identity strings the config region
   cannot reach: /product/product-name ("Apple Virtual Machine 1", the About
   This Mac title and System Information's Model Name) and the root `model`
   ("VirtualMac2,1", hw.model and the Model Identifier). iBoot verifies the
   tree's signature once when it loads it, then fixes it up in place (serial,
   MACs, memory: the firmware's placeholders are sized for exactly that) and
   hands the same buffer to the kernel. While iBoot runs, this rewrites those
   two strings in guest RAM the same way. Nothing on disk changes.

   The window is iBoot's run: once the kernel has copied the tree into the
   IORegistry, editing the blob no longer reaches userspace. */

/* Copies the strings (NULL or empty: leave that one alone). Returns 1 if there
   is anything to do. ram is the guest's RAM, which the poll reads and writes. */
int hv_dt_fixup_start(uint8_t *ram, uint64_t ram_size, const char *product_name, const char *model_id);
/* CPU 0's thread, each tick: scans while iBoot runs. Stop calling once the
   guest's GPU has drawn (the kernel has the tree in its registry by then). */
void hv_dt_fixup_poll(void);
/* Rewrites one blob in place; returns how many strings changed. (Also tests.) */
int hv_dt_fixup_blob(uint8_t *blob, uint64_t avail);

#endif