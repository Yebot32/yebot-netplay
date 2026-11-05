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
