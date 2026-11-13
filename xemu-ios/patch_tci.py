# JIT-less (TCI) speed and profiling for DukeX's tree. Run by patch.py, which
# provides replace() and root. tci.c is only compiled into the TCI core, and the
# cputlb.c addition is guarded, so the JIT core is untouched.

# A TLB fast path the interpreter can call. The JIT backends inline this compare
# in generated code; TCI went through helper_*_mmu -> mmu_lookup for every guest
# load and store. Exact compare against the entry: any flag (invalid, MMIO,
# not-dirty code page, watchpoint, forced slow) makes it miss, and the slow path
# handles it exactly as before. Unaligned accesses that cross a page, or that the
# memop wants aligned, also take the slow path.
replace(
    "accel/tcg/cputlb.c",
    '#include "ldst_common.c.inc"\n',
    r'''#include "ldst_common.c.inc"

#ifdef CONFIG_TCG_INTERPRETER
void *xemu_tci_tlb_fast(CPUArchState *env, uint64_t addr, MemOpIdx oi,
                        int store);
void *xemu_tci_tlb_fast(CPUArchState *env, uint64_t addr, MemOpIdx oi,
                        int store)
{
    CPUState *cpu = env_cpu(env);
    MemOp mop = get_memop(oi);
    unsigned size = memop_size(mop);
    CPUTLBEntry *entry;
    uint64_t cmp;

    if (mop & MO_BSWAP) {
        return NULL;
    }
    if ((addr & (size - 1)) &&
        ((mop & MO_AMASK) ||
         (addr & ~TARGET_PAGE_MASK) + size > TARGET_PAGE_SIZE)) {
        return NULL;
    }
    entry = tlb_entry(cpu, get_mmuidx(oi), addr);
    cmp = tlb_read_idx(entry, store ? MMU_DATA_STORE : MMU_DATA_LOAD);
    if (cmp != (addr & TARGET_PAGE_MASK)) {
        return NULL;
    }
    return (void *)((uintptr_t)addr + entry->addend);
}
#endif
''',
)

# Counters, a 5 s report on stderr (it lands in Share Logs), direct helper calls.
replace(
    "tcg/tci.c",
    "#include <ffi.h>\n",
    r'''#include <ffi.h>
#include <dlfcn.h>
#include <mach/mach.h>
#include <pthread.h>
#include <time.h>

/*
 * xemu-ios JIT-less profile. The core runs thread=single under TCI, so one
 * thread owns all of this and plain counters are enough. Every line starts
 * with "xemu-tci:". XEMU_IOS_TCI_PROFILE=0 turns off the per-helper table
 * (the per-op counts are one increment and always on).
 */
void *xemu_tci_tlb_fast(CPUArchState *env, uint64_t addr, MemOpIdx oi,
                        int store);

typedef struct TciStats {
    uint64_t execs;
    uint64_t calls_direct, calls_ffi;
    uint64_t ld_fast, ld_slow, st_fast, st_slow;
    uint64_t goto_tb, goto_ptr, exits;
    uint64_t ops[256];
} TciStats;
static TciStats tci_stats;
static int tci_profile = -1;
static uint64_t tci_stats_last_ns, tci_stats_start_ns;
static double tci_stats_last_cpu;
static size_t tci_stats_last_tbs;

#define TCI_HELPER_SLOTS 1024
typedef struct TciHelperCount {
    void *fn;
    uint64_t n;
} TciHelperCount;
static TciHelperCount tci_helpers[TCI_HELPER_SLOTS];

static inline void tci_count_helper(void *fn)
{
    unsigned h = (unsigned)(((uintptr_t)fn >> 2) * 0x9E3779B1u) &
                 (TCI_HELPER_SLOTS - 1);
    for (unsigned probe = 0; probe < 16; probe++) {
        TciHelperCount *slot =
            &tci_helpers[(h + probe) & (TCI_HELPER_SLOTS - 1)];
        if (slot->fn == fn) {
            slot->n++;
            return;
        }
        if (!slot->fn) {
            slot->fn = fn;
            slot->n = 1;
            return;
        }
    }
}

static double tci_thread_cpu_seconds(void)
{
    thread_basic_info_data_t info;
    mach_msg_type_number_t count = THREAD_BASIC_INFO_COUNT;
    if (thread_info(pthread_mach_thread_np(pthread_self()), THREAD_BASIC_INFO,
                    (thread_info_t)&info, &count) != KERN_SUCCESS) {
        return 0;
    }
    return info.user_time.seconds + info.user_time.microseconds / 1e6 +
           info.system_time.seconds + info.system_time.microseconds / 1e6;
}

static void tci_describe(void *fn, char *out, size_t size)
{
    Dl_info info;
    if (dladdr(fn, &info) && info.dli_fbase) {
        uintptr_t offset = (uintptr_t)fn - (uintptr_t)info.dli_fbase;
        if (info.dli_sname && info.dli_saddr == fn) {
            snprintf(out, size, "%s", info.dli_sname);
        } else {
            snprintf(out, size, "+0x%lx(%s)", (unsigned long)offset,
                     info.dli_sname ? info.dli_sname : "?");
        }
    } else {
        snprintf(out, size, "%p", fn);
    }
}

static __attribute__((noinline, cold)) void tci_stats_report(void)
{
    uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    if (!tci_stats_last_ns) {
        tci_stats_last_ns = tci_stats_start_ns = now;
        tci_stats_last_cpu = tci_thread_cpu_seconds();
        tci_stats_last_tbs = tcg_nb_tbs();
        fprintf(stderr, "xemu-tci: profiling on (helpers %s)\n",
                tci_profile ? "on" : "off");
        return;
    }
    if (now - tci_stats_last_ns < 5000000000ull) {
        return;
    }
    double secs = (now - tci_stats_last_ns) / 1e9;
    double cpu = tci_thread_cpu_seconds();
    size_t tbs = tcg_nb_tbs();
    uint64_t ops = 0;
    for (int i = 0; i < 256; i++) {
        ops += tci_stats.ops[i];
    }
    uint64_t calls = tci_stats.calls_direct + tci_stats.calls_ffi;
    uint64_t lds = tci_stats.ld_fast + tci_stats.ld_slow;
    uint64_t sts = tci_stats.st_fast + tci_stats.st_slow;
    uint64_t execs = tci_stats.execs;
    fprintf(stderr,
            "xemu-tci: t=%.0fs ops %.1fM/s tb-exec %.2fM/s ops/exec %.1f "
            "goto_tb %.2fM/s goto_ptr %.2fM/s exit %.2fM/s | "
            "calls %.2fM/s (ffi %.1f%%) | ld %.2fM/s slow %.1f%% | "
            "st %.2fM/s slow %.1f%% | tbs %zu (+%zu) | vcpu-thread %.0f%%\n",
            (now - tci_stats_start_ns) / 1e9, ops / secs / 1e6,
            execs / secs / 1e6, execs ? (double)ops / execs : 0.0,
            tci_stats.goto_tb / secs / 1e6, tci_stats.goto_ptr / secs / 1e6,
            tci_stats.exits / secs / 1e6, calls / secs / 1e6,
            calls ? 100.0 * tci_stats.calls_ffi / calls : 0.0,
            lds / secs / 1e6, lds ? 100.0 * tci_stats.ld_slow / lds : 0.0,
            sts / secs / 1e6, sts ? 100.0 * tci_stats.st_slow / sts : 0.0,
            tbs, tbs >= tci_stats_last_tbs ? tbs - tci_stats_last_tbs : 0,
            100.0 * (cpu - tci_stats_last_cpu) / secs);

    /* The ops that dominate: these decide what the interpreter optimises. */
    if (ops) {
        char line[1024];
        int len = snprintf(line, sizeof(line), "xemu-tci: top ops");
        unsigned char taken[256] = { 0 };
        for (int k = 0; k < 14 && len < (int)sizeof(line) - 64; k++) {
            int best = -1;
            for (int i = 0; i < 256; i++) {
                if (!taken[i] && tci_stats.ops[i] &&
                    (best < 0 || tci_stats.ops[i] > tci_stats.ops[best])) {
                    best = i;
                }
            }
            if (best < 0) {
                break;
            }
            taken[best] = 1;
            len += snprintf(line + len, sizeof(line) - len, " %s=%.1f%%",
                            best < NB_OPS ? tcg_op_defs[best].name : "?",
                            100.0 * tci_stats.ops[best] / ops);
        }
        fprintf(stderr, "%s\n", line);
    }

    /* The helpers called most, by name or by offset into the core dylib. */
    if (tci_profile && calls) {
        char line[2048];
        int len = snprintf(line, sizeof(line), "xemu-tci: top helpers");
        for (int k = 0; k < 12 && len < (int)sizeof(line) - 200; k++) {
            TciHelperCount *best = NULL;
            for (int i = 0; i < TCI_HELPER_SLOTS; i++) {
                TciHelperCount *slot = &tci_helpers[i];
                if (slot->fn && slot->n && (!best || slot->n > best->n)) {
                    best = slot;
                }
            }
            if (!best) {
                break;
            }
            char name[160];
            tci_describe(best->fn, name, sizeof(name));
            len += snprintf(line + len, sizeof(line) - len, " %s=%.1f%%",
                            name, 100.0 * best->n / calls);
            best->n = 0;
        }
        fprintf(stderr, "%s\n", line);
        memset(tci_helpers, 0, sizeof(tci_helpers));
    }

    tci_stats_last_ns = now;
    tci_stats_last_cpu = cpu;
    tci_stats_last_tbs = tbs;
    memset(&tci_stats, 0, sizeof(tci_stats));
}

#if defined(__aarch64__)
/*
 * Helpers take only integer and pointer arguments of up to 64 bits, one stack
 * slot each, and AAPCS64 passes the first eight in x0-x7 whatever their
 * declared width (a callee reads a 32-bit argument from a w-register and never
 * relies on the upper half). So a helper with at most eight such arguments can
 * be called directly with the slots as registers; libffi was doing the same
 * thing the slow way, for every call. Int128 results or arguments, and longer
 * argument lists, still go through libffi.
 */
typedef uint64_t (*TciDirectFn)(uint64_t, uint64_t, uint64_t, uint64_t,
                                uint64_t, uint64_t, uint64_t, uint64_t);

static inline bool tci_cif_is_direct(const ffi_cif *cif)
{
    if (cif->nargs > 8) {
        return false;
    }
    for (unsigned i = 0; i < cif->nargs; i++) {
        if (cif->arg_types[i]->size > 8) {
            return false;
        }
    }
    return true;
}
#endif
''',
)
replace(
    "tcg/tci.c",
    "                n = cif->nargs;\n"
    "                for (i = s = 0; i < n; ++i) {\n"
    "                    ffi_type *t = cif->arg_types[i];\n"
    "                    call_slots[i] = &stack[s];\n"
    "                    s += DIV_ROUND_UP(t->size, 8);\n"
    "                }\n"
    "\n"
    "                /* Helper functions may need to access the \"return address\" */\n"
    "                tci_tb_ptr = (uintptr_t)tb_ptr;\n"
    "                ffi_call(cif, func, stack, call_slots);\n",
    r'''                /* Helper functions may need to access the "return address" */
                tci_tb_ptr = (uintptr_t)tb_ptr;
                if (tci_profile) {
                    tci_count_helper(func);
                }
#if defined(__aarch64__)
                if (likely(len != 3 && tci_cif_is_direct(cif))) {
                    /* The result goes where libffi would leave it. */
                    stack[0] = ((TciDirectFn)func)(stack[0], stack[1], stack[2],
                                                   stack[3], stack[4], stack[5],
                                                   stack[6], stack[7]);
                    tci_stats.calls_direct++;
                } else
#endif
                {
                    n = cif->nargs;
                    for (i = s = 0; i < n; ++i) {
                        ffi_type *t = cif->arg_types[i];
                        call_slots[i] = &stack[s];
                        s += DIV_ROUND_UP(t->size, 8);
                    }
                    ffi_call(cif, func, stack, call_slots);
                    tci_stats.calls_ffi++;
                }
''',
)
replace(
    "tcg/tci.c",
    "    regs[TCG_AREG0] = (tcg_target_ulong)env;\n",
    r'''    if (unlikely(tci_profile < 0)) {
        const char *env_profile = getenv("XEMU_IOS_TCI_PROFILE");
        tci_profile = !(env_profile && !strcmp(env_profile, "0"));
        tci_stats_report();
    }
    if (unlikely((++tci_stats.execs & 0x3ffff) == 0)) {
        tci_stats_report();
    }
    regs[TCG_AREG0] = (tcg_target_ulong)env;
''',
)
replace(
    "tcg/tci.c",
    "        insn = *tb_ptr++;\n        opc = extract32(insn, 0, 8);\n",
    "        insn = *tb_ptr++;\n        opc = extract32(insn, 0, 8);\n"
    "        tci_stats.ops[opc]++;\n",
)
replace(
    "tcg/tci.c",
    "        case INDEX_op_exit_tb:\n"
    "            tci_args_l(insn, tb_ptr, &ptr);\n"
    "            return (uintptr_t)ptr;\n",
    "        case INDEX_op_exit_tb:\n"
    "            tci_args_l(insn, tb_ptr, &ptr);\n"
    "            tci_stats.exits++;\n"
    "            return (uintptr_t)ptr;\n",
)
replace(
    "tcg/tci.c",
    "            tb_ptr = *(void **)ptr;\n            break;\n",
    "            tb_ptr = *(void **)ptr;\n            tci_stats.goto_tb++;\n"
    "            break;\n",
)
replace(
    "tcg/tci.c",
    "            if (!ptr) {\n                return 0;\n            }\n"
    "            tb_ptr = ptr;\n            break;\n",
    "            if (!ptr) {\n                return 0;\n            }\n"
    "            tb_ptr = ptr;\n            tci_stats.goto_ptr++;\n"
    "            break;\n",
)

# Guest loads and stores: host memory directly when the TLB entry is plain RAM.
replace(
    "tcg/tci.c",
    "    MemOp mop = get_memop(oi);\n    uintptr_t ra = (uintptr_t)tb_ptr;\n\n"
    "    switch (mop & MO_SSIZE) {\n",
    r'''    MemOp mop = get_memop(oi);
    uintptr_t ra = (uintptr_t)tb_ptr;
    void *host = xemu_tci_tlb_fast(env, taddr, oi, 0);

    if (likely(host)) {
        tci_stats.ld_fast++;
        switch (mop & MO_SSIZE) {
        case MO_UB:
            return *(uint8_t *)host;
        case MO_SB:
            return (int8_t)*(uint8_t *)host;
        case MO_UW:
            return (uint16_t)lduw_he_p(host);
        case MO_SW:
            return (int16_t)lduw_he_p(host);
        case MO_UL:
            return (uint32_t)ldl_he_p(host);
        case MO_SL:
            return (int32_t)ldl_he_p(host);
        case MO_UQ:
            return ldq_he_p(host);
        default:
            break;
        }
    }
    tci_stats.ld_slow++;

    switch (mop & MO_SSIZE) {
''',
)
replace(
    "tcg/tci.c",
    "    MemOp mop = get_memop(oi);\n    uintptr_t ra = (uintptr_t)tb_ptr;\n\n"
    "    switch (mop & MO_SIZE) {\n",
    r'''    MemOp mop = get_memop(oi);
    uintptr_t ra = (uintptr_t)tb_ptr;
    void *host = xemu_tci_tlb_fast(env, taddr, oi, 1);

    if (likely(host)) {
        switch (mop & MO_SIZE) {
        case MO_UB:
            *(uint8_t *)host = val;
            tci_stats.st_fast++;
            return;
        case MO_UW:
            stw_he_p(host, val);
            tci_stats.st_fast++;
            return;
        case MO_UL:
            stl_he_p(host, val);
            tci_stats.st_fast++;
            return;
        case MO_UQ:
            stq_he_p(host, val);
            tci_stats.st_fast++;
            return;
        default:
            break;
        }
    }
    tci_stats.st_slow++;

    switch (mop & MO_SIZE) {
''',
)

# Breadcrumbs for the first few translations and executions, so a JIT-less run
# that dies early says at which stage. Only the TCI core prints them.
replace(
    "accel/tcg/translate-all.c",
    "    return tcg_gen_code(tcg_ctx, tb, pc);\n}\n",
    "#ifdef CONFIG_TCG_INTERPRETER\n"
    "    static int xemu_tci_gen_logged;\n"
    "    if (xemu_tci_gen_logged < 3) {\n"
    "        fprintf(stderr, \"xemu-tci: gen #%d begin pc=0x%llx\\n\",\n"
    "                xemu_tci_gen_logged + 1, (unsigned long long)pc);\n"
    "    }\n"
    "    int xemu_tci_gen_size = tcg_gen_code(tcg_ctx, tb, pc);\n"
    "    if (xemu_tci_gen_logged < 3) {\n"
    "        fprintf(stderr, \"xemu-tci: gen #%d end size=%d\\n\",\n"
    "                ++xemu_tci_gen_logged, xemu_tci_gen_size);\n"
    "    }\n"
    "    return xemu_tci_gen_size;\n"
    "#else\n"
    "    return tcg_gen_code(tcg_ctx, tb, pc);\n"
    "#endif\n"
    "}\n",
)
replace(
    "accel/tcg/cpu-exec.c",
    "    qemu_thread_jit_execute();\n    ret = tcg_qemu_tb_exec(cpu_env(cpu), tb_ptr);\n",
    "    qemu_thread_jit_execute();\n"
    "#ifdef CONFIG_TCG_INTERPRETER\n"
    "    {\n"
    "        static int xemu_tci_exec_logged;\n"
    "        if (xemu_tci_exec_logged < 3) {\n"
    "            fprintf(stderr, \"xemu-tci: exec #%d tb=%p\\n\",\n"
    "                    ++xemu_tci_exec_logged, tb_ptr);\n"
    "        }\n"
    "    }\n"
    "#endif\n"
    "    ret = tcg_qemu_tb_exec(cpu_env(cpu), tb_ptr);\n",
)
