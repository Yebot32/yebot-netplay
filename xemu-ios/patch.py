#!/usr/bin/env python3
"""Changes to DukeX's tree, applied in CI by exact text so a moved line fails."""
import pathlib
import sys

root = pathlib.Path(sys.argv[1])


def replace(path, old, new):
    file = root / path
    text = file.read_text()
    if text.count(old) != 1:
        sys.exit(f"{path}: expected exactly one match for: {old!r}")
    file.write_text(text.replace(old, new))


# StikDebug's prepare on iOS 27 drops the high bits of the address and works on
# the low-memory alias, zeroing the heap there (XeniOS found this). Anything
# below 8 GB survives, so the code region has to be placed there.
replace(
    "tcg/region.c",
    "        buf_rx = mmap(NULL, size, host_prot_read_exec(), flags, -1, 0);\n",
    """        buf_rx = MAP_FAILED;
        for (uintptr_t hint = 1ull << 32;
             buf_rx == MAP_FAILED && hint + size <= (2ull << 32);
             hint += 1ull << 26) {
            void *low = mmap((void *)hint, size, host_prot_read_exec(), flags,
                             -1, 0);
            if (low == MAP_FAILED) {
                continue;
            }
            if ((uintptr_t)low + size <= (2ull << 32)) {
                buf_rx = low;
            } else {
                munmap(low, size);
            }
        }
        if (buf_rx == MAP_FAILED) {
            fprintf(stderr, "xemu-ios: no room below 8 GB for the JIT region\\n");
            buf_rx = mmap(NULL, size, host_prot_read_exec(), flags, -1, 0);
        }
""",
)

# Devices without TXM have no Universal.js: StikDebug only runs scripts with TXM.
# They still need the layout of that block, executable first with a writable
# alias, which is what Dolphin ships for them on iOS 26. Its brk helpers do
# nothing while XEMU_IOS_UNIVERSAL_JIT is 0.
replace(
    "tcg/region.c",
    "    if (xemu_ios_universal_jit_is_enabled()) {\n        void *buf_rw;\n",
    "    if (xemu_ios_universal_jit_is_enabled() || getenv(\"XEMU_IOS_RX_FIRST\")) {\n        void *buf_rw;\n",
)

# QEMU leaves SIGBUS blocked on every thread it starts. On Darwin a blocked
# synchronous fault is not delivered: the thread retries the instruction for ever.
# That was the "hang in the first translation block" with no signal, on the M1.
replace(
    "util/qemu-thread-posix.c",
    "    sigdelset(&set, SIGILL);\n    /* TODO avoid SIGBUS loss on macOS */\n",
    "    sigdelset(&set, SIGILL);\n    sigdelset(&set, SIGBUS);\n",
)
replace(
    "util/main-loop.c",
    "    sigaddset(&set, SIGALRM);\n    sigaddset(&set, SIGBUS);\n",
    "    sigaddset(&set, SIGALRM);\n#ifndef CONFIG_IOS\n    sigaddset(&set, SIGBUS);\n#endif\n",
)

# Without TXM, iOS refuses to execute a page that is writable anywhere: through an
# alias, or RWX. Measured on the M1: rx-first, rw-first and rwx all raise SIGBUS at
# the first run. XeniOS gets by there by never letting a page be both, so do that.
# The hooks QEMU has for this are per thread, and TB structs live in the buffer too,
# so rather than chase every writer this lets the fault say which state a page needs.
# Pages start writable. Running one makes it executable, writing it makes it writable
# again. Once a game's code is chained it stops faulting and this costs nothing.
replace(
    "tcg/region.c",
    "#endif /* USE_STATIC_CODE_GEN_BUFFER, WIN32, POSIX */\n",
    r"""#endif /* USE_STATIC_CODE_GEN_BUFFER, WIN32, POSIX */

#ifdef CONFIG_IOS
#include <signal.h>
#include <sys/ucontext.h>

static uintptr_t flip_start, flip_end, flip_page;
static uintptr_t flip_last_addr;
static unsigned flip_repeats;
static struct sigaction flip_prev_bus, flip_prev_segv;

static bool xemu_ios_flip_enabled(void)
{
    return getenv("XEMU_IOS_JIT_FLIP") != NULL;
}

static void xemu_ios_flip_fault(int sig, siginfo_t *info, void *context)
{
    ucontext_t *uc = context;
    uintptr_t addr = (uintptr_t)info->si_addr;
    struct sigaction *prev = sig == SIGBUS ? &flip_prev_bus : &flip_prev_segv;

    if (addr >= flip_start && addr < flip_end) {
        void *page = (void *)(addr & ~(flip_page - 1));
        bool run = uc->uc_mcontext->__ss.__pc == addr;
        int rc;

        /* The same fault again means the change did not help: a real failure. */
        flip_repeats = addr == flip_last_addr ? flip_repeats + 1 : 0;
        flip_last_addr = addr;
        if (flip_repeats < 64) {
            if (run) {
                rc = mprotect(page, flip_page, PROT_READ | PROT_EXEC);
            } else {
                /* Through read-only, as XeniOS does on these devices. */
                rc = mprotect(page, flip_page, PROT_READ);
                if (rc == 0) {
                    rc = mprotect(page, flip_page, PROT_READ | PROT_WRITE);
                }
            }
            if (rc == 0) {
                return;
            }
        }
    }
    if (prev->sa_flags & SA_SIGINFO) {
        prev->sa_sigaction(sig, info, context);
    } else {
        sigaction(sig, prev, NULL);
    }
}

static void xemu_ios_flip_install(void *start, size_t size)
{
    struct sigaction action = {
        .sa_sigaction = xemu_ios_flip_fault,
        .sa_flags = SA_SIGINFO | SA_NODEFER,
    };

    flip_start = (uintptr_t)start;
    flip_end = flip_start + size;
    flip_page = qemu_real_host_page_size();
    sigemptyset(&action.sa_mask);
    sigaction(SIGBUS, &action, &flip_prev_bus);
    sigaction(SIGSEGV, &action, &flip_prev_segv);
    fprintf(stderr, "xemu-ios: flip JIT active base=%p size=%zu page=%zu\n",
            start, size, (size_t)flip_page);
}
#endif
""",
)
replace(
    "tcg/region.c",
    "    if (tcg_splitwx_diff == 0) {\n        need_prot |= host_prot_read_exec();\n    }\n",
    """    if (tcg_splitwx_diff == 0
#ifdef CONFIG_IOS
        && !xemu_ios_flip_enabled()
#endif
        ) {
        need_prot |= host_prot_read_exec();
    }
""",
)
replace(
    "tcg/region.c",
    "    tcg_region_trees_init();\n\n    /*\n     * Leave the initial context initialized",
    """#ifdef CONFIG_IOS
    if (xemu_ios_flip_enabled()) {
        xemu_ios_flip_install(region.start_aligned, region.total_size);
    }
#endif

    tcg_region_trees_init();

    /*
     * Leave the initial context initialized""",
)

# Input diagnostics are written for every few polls while a button is held: thousands
# of lines a session, each formatted and written on the input path. Only on request.
replace(
    "ui/xemu-input.c",
    "void xemu_ios_input_diagnostic_log(const char *fmt, ...)\n{\n    char message[512];\n    va_list args;\n\n",
    "void xemu_ios_input_diagnostic_log(const char *fmt, ...)\n{\n    char message[512];\n    va_list args;\n\n    static int enabled = -1;\n    if (enabled < 0) {\n        enabled = getenv(\"XEMU_IOS_INPUT_TRACE\") != NULL;\n    }\n    if (!enabled) {\n        return;\n    }\n\n",
)
