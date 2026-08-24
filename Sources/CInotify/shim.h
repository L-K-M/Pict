#ifndef PICTKIT_CINOTIFY_SHIM_H
#define PICTKIT_CINOTIFY_SHIM_H

/* Exposes the inotify(7) syscalls (inotify_init1 / inotify_add_watch /
 * inotify_rm_watch) to the Swift IconStoreWatcher on Linux.
 *
 * Deliberately just the header: the IN_* mask macros are NOT relied on from here
 * (Swift can't import C object-like macros as constants reliably) — they are
 * hard-coded in the Swift watcher — and `struct inotify_event`'s trailing flexible
 * array member is parsed by hand out of the read buffer rather than through the
 * imported struct. See docs/linux-port §Part 10.
 *
 * Guarded on __linux__ so the module is empty (and harmless) if it is ever
 * modularised on a non-Linux host; on macOS the target isn't in the build graph at
 * all (the PictKit dependency on it is Linux-conditioned). */
#if defined(__linux__)
#include <sys/inotify.h>
#endif

#endif /* PICTKIT_CINOTIFY_SHIM_H */
