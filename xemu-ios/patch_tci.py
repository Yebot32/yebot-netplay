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
 * with "xemu-tci:". XEMU_IOS_TCI_PROFILE=0 turns off the per-helper table.
 * The per-op and op-pair histograms cost a memory increment per guest op, so
 * they only run for a 1 s window in each 5 s report period; the rest of the
 * time the interpreter runs uncounted.
 */
void *xemu_tci_tlb_fast(CPUArchState *env, uint64_t addr, MemOpIdx oi,
                        int store);

typedef struct TciStats {
    uint64_t execs;
    uint64_t calls_direct, calls_ffi;
    uint64_t ld_fast, ld_slow, st_fast, st_slow;
    uint64_t goto_tb, goto_ptr, exits;
    uint64_t mb_ld, mb_st, mb_full;
    uint64_t ops[256];
} TciStats;
static TciStats tci_stats;
static uint32_t tci_pairs[256 * 256];
static int tci_profile = -1;
static bool tci_sample_ops;
static uint64_t tci_sample_start_ns, tci_sample_ns;
static uint64_t tci_stats_last_ns, tci_stats_start_ns;
static double tci_stats_last_cpu;
static size_t tci_stats_last_tbs;

static inline void tci_count_op(unsigned *prev, unsigned opc)
{
    tci_stats.ops[opc]++;
    tci_pairs[(*prev << 8) | opc]++;
    *prev = opc;
}

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
        tci_sample_ops = true;
        tci_sample_start_ns = now;
        fprintf(stderr, "xemu-tci: profiling on (helpers %s, op sample 1s/5s,"
                " computed-goto dispatch, typed barriers, oi word)\n",
                tci_profile ? "on" : "off");
        return;
    }
    if (tci_sample_ops && now - tci_sample_start_ns >= 1000000000ull) {
        tci_sample_ops = false;
        tci_sample_ns += now - tci_sample_start_ns;
    }
    if (now - tci_stats_last_ns < 5000000000ull) {
        return;
    }
    if (tci_sample_ops) {
        tci_sample_ns += now - tci_sample_start_ns;
        tci_sample_ops = false;
    }
    double secs = (now - tci_stats_last_ns) / 1e9;
    double sample_secs = tci_sample_ns ? tci_sample_ns / 1e9 : secs;
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
    uint64_t mbs = tci_stats.mb_ld + tci_stats.mb_st + tci_stats.mb_full;
    fprintf(stderr,
            "xemu-tci: t=%.0fs ops %.1fM/s (in %.1fs sample) tb-exec %.2fM/s "
            "goto_tb %.2fM/s goto_ptr %.2fM/s exit %.2fM/s | "
            "calls %.2fM/s (ffi %.1f%%) | ld %.2fM/s slow %.1f%% | "
            "st %.2fM/s slow %.1f%% | mb %.2fM/s (ld %.0f%% st %.0f%%) | "
            "tbs %zu (+%zu) | vcpu-thread %.0f%%\n",
            (now - tci_stats_start_ns) / 1e9, ops / sample_secs / 1e6,
            sample_secs, execs / secs / 1e6,
            tci_stats.goto_tb / secs / 1e6, tci_stats.goto_ptr / secs / 1e6,
            tci_stats.exits / secs / 1e6, calls / secs / 1e6,
            calls ? 100.0 * tci_stats.calls_ffi / calls : 0.0,
            lds / secs / 1e6, lds ? 100.0 * tci_stats.ld_slow / lds : 0.0,
            sts / secs / 1e6, sts ? 100.0 * tci_stats.st_slow / sts : 0.0,
            mbs / secs / 1e6, mbs ? 100.0 * tci_stats.mb_ld / mbs : 0.0,
            mbs ? 100.0 * tci_stats.mb_st / mbs : 0.0,
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

        /* Adjacent op pairs: candidates for fused interpreter ops. */
        len = snprintf(line, sizeof(line), "xemu-tci: top pairs");
        for (int k = 0; k < 12 && len < (int)sizeof(line) - 80; k++) {
            unsigned best = 0;
            for (unsigned i = 1; i < 256 * 256; i++) {
                if (tci_pairs[i] > tci_pairs[best]) {
                    best = i;
                }
            }
            if (!tci_pairs[best]) {
                break;
            }
            unsigned a = best >> 8, b = best & 0xff;
            len += snprintf(line + len, sizeof(line) - len, " %s>%s=%.1f%%",
                            a < NB_OPS ? tcg_op_defs[a].name : "?",
                            b < NB_OPS ? tcg_op_defs[b].name : "?",
                            100.0 * tci_pairs[best] / ops);
            tci_pairs[best] = 0;
        }
        fprintf(stderr, "%s\n", line);
    }
    memset(tci_pairs, 0, sizeof(tci_pairs));

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
    tci_sample_ns = 0;
    tci_sample_ops = true;
    tci_sample_start_ns = now;
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
    if (unlikely((++tci_stats.execs & 0x3fff) == 0)) {
        tci_stats_report();
    }
    /* Read once per entry: the sample window moves between entries only. */
    const bool tci_prof = tci_sample_ops;
    unsigned tci_prev = 0;
    regs[TCG_AREG0] = (tcg_target_ulong)env;
''',
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

# Barriers: TCI dropped the barrier kind and ran a full `dmb ish` for every
# one. x86 guests put a load-load barrier before every guest load, and a full
# barrier also waits for the store buffer to drain. Keep the kind in the insn
# and pick the same instruction the AArch64 JIT backend does for it.
replace(
    "tcg/tci/tcg-target.c.inc",
    "static void tcg_out_mb(TCGContext *s, unsigned a0)\n"
    "{\n    tcg_out_op_v(s, INDEX_op_mb);\n}\n",
    "static void tcg_out_mb(TCGContext *s, unsigned a0)\n"
    "{\n"
    "    tcg_out32(s, (uint8_t)INDEX_op_mb | ((a0 & TCG_MO_ALL) << 8));\n"
    "}\n",
)
replace(
    "tcg/tci.c",
    "        case INDEX_op_mb:\n"
    "            /* Ensure ordering for all kinds */\n"
    "            smp_mb();\n"
    "            break;\n",
    r'''        case INDEX_op_mb:
#if defined(__aarch64__)
            /*
             * Only store->load ordering needs a full dmb ish (it waits for
             * the store buffer to drain). ishld orders earlier loads before
             * later loads and stores; ishst orders stores before stores.
             * x86 stores ask for LD_ST|ST_ST: ishld + ishst covers that,
             * where tcg/aarch64 emits a full barrier.
             */
            tmp32 = extract32(insn, 8, 4);
            if (tmp32 == 0 || (tmp32 & TCG_MO_ST_LD)) {
                smp_mb();
                tci_stats.mb_full++;
            } else {
                if (tmp32 & (TCG_MO_LD_LD | TCG_MO_LD_ST)) {
                    asm volatile("dmb ishld" ::: "memory");
                }
                if (tmp32 & TCG_MO_ST_ST) {
                    asm volatile("dmb ishst" ::: "memory");
                    tci_stats.mb_st++;
                } else {
                    tci_stats.mb_ld++;
                }
            }
#else
            smp_mb();
#endif
            break;
''',
)

# Guest loads and stores whose MemOpIdx does not fit the 16-bit field (on x86
# that is every one carrying atomicity bits) cost a tci_movi of the MemOpIdx
# into a temp before the access: one extra interpreted op per guest access.
# Put the MemOpIdx in the word after the insn instead. ra still lands inside
# the same guest insn: it points past the extra word, like the movi form.
replace(
    "tcg/tci/tcg-target-opc.h.inc",
    "DEF(tci_qemu_st_rrr, 0, 3, 0, TCG_OPF_NOT_PRESENT)\n",
    "DEF(tci_qemu_st_rrr, 0, 3, 0, TCG_OPF_NOT_PRESENT)\n"
    "DEF(tci_qemu_ld_x, 1, 1, 0, TCG_OPF_NOT_PRESENT)\n"
    "DEF(tci_qemu_st_x, 0, 2, 0, TCG_OPF_NOT_PRESENT)\n",
)
#
# A 32-bit guest address also cost an extract (zero-extend to 64 bits) before
# every access: tci_extend_addr in tcg-op-ldst.c, 6.4% of all ops. The _x
# form carries an "address is 32-bit" bit instead and the interpreter
# zero-extends while loading the register. Only the i32/i64 load/store paths
# drop the extend; the i128 paths keep it (they also feed helper calls).
replace(
    "tcg/tci/tcg-target.c.inc",
    "    if (oi & ~0xffff) {\n"
    "        tcg_out_movi(s, TCG_TYPE_I32, TCG_REG_TMP, oi);\n"
    "        tcg_out_op_rrr(s, INDEX_op_tci_qemu_ld_rrr, data, addr, TCG_REG_TMP);\n",
    "    if ((oi & ~0xffff) || s->addr_type == TCG_TYPE_I32) {\n"
    "        tci_out_ldst_x(s, INDEX_op_tci_qemu_ld_x, data, addr, oi);\n",
)
replace(
    "tcg/tci/tcg-target.c.inc",
    "    if (oi & ~0xffff) {\n"
    "        tcg_out_movi(s, TCG_TYPE_I32, TCG_REG_TMP, oi);\n"
    "        tcg_out_op_rrr(s, INDEX_op_tci_qemu_st_rrr, data, addr, TCG_REG_TMP);\n",
    "    if ((oi & ~0xffff) || s->addr_type == TCG_TYPE_I32) {\n"
    "        tci_out_ldst_x(s, INDEX_op_tci_qemu_st_x, data, addr, oi);\n",
)
replace(
    "tcg/tci/tcg-target.c.inc",
    "static void tgen_qemu_ld(TCGContext *s, TCGType type, TCGReg data,\n",
    r'''static void tci_out_ldst_x(TCGContext *s, TCGOpcode op, TCGReg data,
                           TCGReg addr, MemOpIdx oi)
{
    tcg_insn_unit insn = 0;

    insn = deposit32(insn, 0, 8, op);
    insn = deposit32(insn, 8, 4, data);
    insn = deposit32(insn, 12, 4, addr);
    if (TCG_TARGET_REG_BITS == 64 && s->addr_type == TCG_TYPE_I32) {
        insn |= TCI_X_ADDR32;
    }
    tcg_out32(s, insn);
    tcg_out32(s, oi);
}

static void tgen_qemu_ld(TCGContext *s, TCGType type, TCGReg data,
''',
)
replace(
    "tcg/tci/tcg-target.h",
    "#define TCG_TARGET_H\n",
    "#define TCG_TARGET_H\n\n"
    "/* xemu-ios: tci_qemu_{ld,st}_x flag, the guest address is 32-bit. */\n"
    "#define TCI_X_ADDR32 (1u << 16)\n",
)
def _tci_drop_addr_extend():
    path = root / "tcg/tcg-op-ldst.c"
    text = path.read_text()
    old = "\n    addr_new = tci_extend_addr(addr);\n"
    if text.count(old) != 4:
        sys.exit(f"tcg/tcg-op-ldst.c: expected 4 i32/i64 extend sites, "
                 f"found {text.count(old)}")
    path.write_text(text.replace(old, "\n    addr_new = addr;\n"))


_tci_drop_addr_extend()
replace(
    "tcg/tci.c",
    "        case INDEX_op_qemu_ld2:\n",
    r'''        case INDEX_op_tci_qemu_ld_x:
            tci_args_rr(insn, &r0, &r1);
            oi = *tb_ptr++;
            taddr = regs[r1];
            if (insn & TCI_X_ADDR32) {
                taddr = (uint32_t)taddr;
            }
            regs[r0] = tci_qemu_ld(env, taddr, oi, tb_ptr);
            break;
        case INDEX_op_tci_qemu_st_x:
            tci_args_rr(insn, &r0, &r1);
            oi = *tb_ptr++;
            taddr = regs[r1];
            if (insn & TCI_X_ADDR32) {
                taddr = (uint32_t)taddr;
            }
            tci_qemu_st(env, taddr, regs[r0], oi, tb_ptr);
            break;

        case INDEX_op_qemu_ld2:
''',
)
replace(
    "tcg/tci.c",
    "    case 0:\n        /* tcg_out_nop_fill uses zeros */\n",
    r'''    case INDEX_op_tci_qemu_ld_x:
    case INDEX_op_tci_qemu_st_x:
        tci_args_rr(insn, &r0, &r1);
        info->fprintf_func(info->stream, "%-12s  %s, %s, 0x%x",
                           op_name, str_r(r0), str_r(r1), *tb_ptr);
        return 2 * sizeof(insn);

    case 0:
        /* tcg_out_nop_fill uses zeros */
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

# Immediate operands. TCI had none: every constant was a tci_movi into a
# register first (17% of all interpreted ops on Smashing Drive). Two places
# produce most of them on an x86 guest:
#  - stores of constants: syncing globals that hold a known value (eip,
#    cc_op) and immediate call arguments go through tcg_out_sti, which TCI
#    refused, and st/st8/st16/st32 ops with a constant value;
#  - add of a constant (sub of a constant is canonicalised to add).
# Store-immediate: insn = op | base << 8 | s20 offset << 12, then the value in
# the next word (two words for a 64-bit store). An offset outside s20 goes
# through TCG_REG_TMP exactly like tcg_out_ldst. Add-immediate uses the rrs
# layout when the constant fits s16, else the old movi + add.
replace(
    "tcg/tci/tcg-target-con-set.h",
    "C_O0_I2(r, r)\n",
    "C_O0_I2(r, r)\nC_O0_I2(ri, r)\n",
)
replace(
    "tcg/tci/tcg-target-con-set.h",
    "C_O1_I2(r, r, r)\n",
    "C_O1_I2(r, r, r)\nC_O1_I2(r, r, ri)\n",
)
replace(
    "tcg/tci/tcg-target-opc.h.inc",
    "DEF(tci_qemu_st_x, 0, 2, 0, TCG_OPF_NOT_PRESENT)\n",
    "DEF(tci_qemu_st_x, 0, 2, 0, TCG_OPF_NOT_PRESENT)\n"
    "DEF(tci_addi, 1, 1, 1, TCG_OPF_NOT_PRESENT)\n"
    "DEF(tci_st8i, 0, 1, 2, TCG_OPF_NOT_PRESENT)\n"
    "DEF(tci_st16i, 0, 1, 2, TCG_OPF_NOT_PRESENT)\n"
    "DEF(tci_st32i, 0, 1, 2, TCG_OPF_NOT_PRESENT)\n"
    "DEF(tci_sti, 0, 1, 2, TCG_OPF_NOT_PRESENT)\n",
)
replace(
    "tcg/tci/tcg-target.c.inc",
    "    tcg_out_op_rrs(s, op, val, base, offset);\n}\n",
    r'''    tcg_out_op_rrs(s, op, val, base, offset);
}

static void tci_out_sti(TCGContext *s, TCGOpcode op, tcg_target_long val,
                        TCGReg base, intptr_t offset)
{
    tcg_insn_unit insn = 0;

    QEMU_BUILD_BUG_ON(TCG_TARGET_REG_BITS != 64);
    stack_bounds_check(base, offset);
    if (offset != sextract32(offset, 0, 20)) {
        tcg_out_movi(s, TCG_TYPE_PTR, TCG_REG_TMP, offset);
        tcg_out_op_rrr(s, INDEX_op_add, TCG_REG_TMP, TCG_REG_TMP, base);
        base = TCG_REG_TMP;
        offset = 0;
    }
    insn = deposit32(insn, 0, 8, op);
    insn = deposit32(insn, 8, 4, base);
    insn = deposit32(insn, 12, 20, offset);
    tcg_out32(s, insn);
    tcg_out32(s, (uint32_t)val);
    if (op == INDEX_op_tci_sti) {
        tcg_out32(s, (uint32_t)((uint64_t)val >> 32));
    }
}

static void tgen_st8_i(TCGContext *s, TCGType type, tcg_target_long val,
                       TCGReg base, intptr_t offset)
{
    tci_out_sti(s, INDEX_op_tci_st8i, val, base, offset);
}

static void tgen_st16_i(TCGContext *s, TCGType type, tcg_target_long val,
                        TCGReg base, intptr_t offset)
{
    tci_out_sti(s, INDEX_op_tci_st16i, val, base, offset);
}

static void tgen_st_i(TCGContext *s, TCGType type, tcg_target_long val,
                      TCGReg base, intptr_t offset)
{
    tci_out_sti(s, type == TCG_TYPE_I32 ? INDEX_op_tci_st32i
                                        : INDEX_op_tci_sti,
                val, base, offset);
}
''',
)
replace(
    "tcg/tci/tcg-target.c.inc",
    "static inline bool tcg_out_sti(TCGContext *s, TCGType type, TCGArg val,\n"
    "                               TCGReg base, intptr_t ofs)\n"
    "{\n    return false;\n}\n",
    "static inline bool tcg_out_sti(TCGContext *s, TCGType type, TCGArg val,\n"
    "                               TCGReg base, intptr_t ofs)\n"
    "{\n"
    "    if (type != TCG_TYPE_I32 && type != TCG_TYPE_I64) {\n"
    "        return false;\n"
    "    }\n"
    "    tgen_st_i(s, type, val, base, ofs);\n"
    "    return true;\n"
    "}\n",
)
for _op, _out in (("st8", "tgen_st8"), ("st16", "tgen_st16"), ("st", "tcg_out_st")):
    replace(
        "tcg/tci/tcg-target.c.inc",
        f"static const TCGOutOpStore outop_{_op} = {{\n"
        f"    .base.static_constraint = C_O0_I2(r, r),\n"
        f"    .out_r = {_out},\n",
        f"static const TCGOutOpStore outop_{_op} = {{\n"
        f"    .base.static_constraint = C_O0_I2(ri, r),\n"
        f"    .out_r = {_out},\n"
        f"    .out_i = {'tgen_st_i' if _op == 'st' else _out + '_i'},\n",
    )
replace(
    "tcg/tci/tcg-target.c.inc",
    "static const TCGOutOpBinary outop_add = {\n"
    "    .base.static_constraint = C_O1_I2(r, r, r),\n"
    "    .out_rrr = tgen_add,\n",
    r'''static void tgen_addi(TCGContext *s, TCGType type,
                      TCGReg a0, TCGReg a1, tcg_target_long a2)
{
    if (type == TCG_TYPE_I32) {
        /* Only the low 32 bits of an I32 result matter; movi sign-extends
         * the same way, so -16 passed as 0xfffffff0 can still be an addi. */
        a2 = (int32_t)a2;
    }
    if (a2 == sextract64(a2, 0, 16)) {
        tcg_out_op_rrs(s, INDEX_op_tci_addi, a0, a1, a2);
    } else {
        tcg_out_movi(s, type, TCG_REG_TMP, a2);
        tcg_out_op_rrr(s, INDEX_op_add, a0, a1, TCG_REG_TMP);
    }
}

static const TCGOutOpBinary outop_add = {
    .base.static_constraint = C_O1_I2(r, r, ri),
    .out_rrr = tgen_add,
    .out_rri = tgen_addi,
''',
)
replace(
    "tcg/tci.c",
    "        case INDEX_op_tci_qemu_ld_x:\n            tci_args_rr(insn, &r0, &r1);\n",
    r'''        case INDEX_op_tci_addi:
            tci_args_rrs(insn, &r0, &r1, &ofs);
            regs[r0] = regs[r1] + (tcg_target_long)ofs;
            break;
        case INDEX_op_tci_st8i:
            ptr = (void *)(regs[extract32(insn, 8, 4)] +
                           sextract32(insn, 12, 20));
            *(uint8_t *)ptr = *tb_ptr++;
            break;
        case INDEX_op_tci_st16i:
            ptr = (void *)(regs[extract32(insn, 8, 4)] +
                           sextract32(insn, 12, 20));
            *(uint16_t *)ptr = *tb_ptr++;
            break;
        case INDEX_op_tci_st32i:
            ptr = (void *)(regs[extract32(insn, 8, 4)] +
                           sextract32(insn, 12, 20));
            *(uint32_t *)ptr = *tb_ptr++;
            break;
        case INDEX_op_tci_sti:
            ptr = (void *)(regs[extract32(insn, 8, 4)] +
                           sextract32(insn, 12, 20));
            *(uint64_t *)ptr = tb_ptr[0] | ((uint64_t)tb_ptr[1] << 32);
            tb_ptr += 2;
            break;
        case INDEX_op_tci_qemu_ld_x:
            tci_args_rr(insn, &r0, &r1);
''',
)
replace(
    "tcg/tci.c",
    "    case INDEX_op_tci_qemu_ld_x:\n    case INDEX_op_tci_qemu_st_x:\n",
    r'''    case INDEX_op_tci_addi:
        tci_args_rrs(insn, &r0, &r1, &s2);
        info->fprintf_func(info->stream, "%-12s  %s, %s, %d",
                           op_name, str_r(r0), str_r(r1), s2);
        break;
    case INDEX_op_tci_st8i:
    case INDEX_op_tci_st16i:
    case INDEX_op_tci_st32i:
    case INDEX_op_tci_sti:
        info->fprintf_func(info->stream, "%-12s  %s, %d, 0x%x",
                           op_name, str_r(extract32(insn, 8, 4)),
                           sextract32(insn, 12, 20), *tb_ptr);
        return (op == INDEX_op_tci_sti ? 3 : 2) * sizeof(insn);
    case INDEX_op_tci_qemu_ld_x:
    case INDEX_op_tci_qemu_st_x:
''',
)

# Compare-and-branch in one op. TCI emitted brcond as setcond into TMP then
# "branch if TMP != 0": tci_setcond32>brcond was the top op pair (4.5%).
# tci_brcond{32,64}: op | a << 8 | b << 12 | cond << 16 | s12 byte offset <<
# 20. The offset is a 12-bit relocation; a label further away than +-2 KB
# makes patch_reloc fail, and TCG then retranslates the block with half the
# guest instructions (the existing -2 path), so it is never miscompiled.
# setcond also takes a constant: s12 in the same field, else movi + setcond.
replace(
    "tcg/tci/tcg-target.c.inc",
    "    tcg_debug_assert(type == 20);\n",
    "    tcg_debug_assert(type == 20 || type == 12);\n",
)
replace(
    "tcg/tci/tcg-target-opc.h.inc",
    "DEF(tci_sti, 0, 1, 2, TCG_OPF_NOT_PRESENT)\n",
    "DEF(tci_sti, 0, 1, 2, TCG_OPF_NOT_PRESENT)\n"
    "DEF(tci_brcond32, 0, 2, 2, TCG_OPF_NOT_PRESENT)\n"
    "DEF(tci_brcond64, 0, 2, 2, TCG_OPF_NOT_PRESENT)\n"
    "DEF(tci_setcond32i, 1, 1, 2, TCG_OPF_NOT_PRESENT)\n"
    "DEF(tci_setcond64i, 1, 1, 2, TCG_OPF_NOT_PRESENT)\n",
)
replace(
    "tcg/tci/tcg-target.c.inc",
    "static void tgen_brcond(TCGContext *s, TCGType type, TCGCond cond,\n"
    "                        TCGReg arg0, TCGReg arg1, TCGLabel *l)\n"
    "{\n"
    "    tgen_setcond(s, type, cond, TCG_REG_TMP, arg0, arg1);\n"
    "    tcg_out_op_rl(s, INDEX_op_brcond, TCG_REG_TMP, l);\n"
    "}\n",
    r'''static void tgen_brcond(TCGContext *s, TCGType type, TCGCond cond,
                        TCGReg arg0, TCGReg arg1, TCGLabel *l)
{
    tcg_insn_unit insn = 0;

    tcg_out_reloc(s, s->code_ptr, 12, l, 0);
    insn = deposit32(insn, 0, 8, type == TCG_TYPE_I32 ? INDEX_op_tci_brcond32
                                                      : INDEX_op_tci_brcond64);
    insn = deposit32(insn, 8, 4, arg0);
    insn = deposit32(insn, 12, 4, arg1);
    insn = deposit32(insn, 16, 4, cond);
    tcg_out32(s, insn);
}
''',
)
replace(
    "tcg/tci/tcg-target.c.inc",
    "static const TCGOutOpSetcond outop_setcond = {\n"
    "    .base.static_constraint = C_O1_I2(r, r, r),\n"
    "    .out_rrr = tgen_setcond,\n",
    r'''static void tgen_setcondi(TCGContext *s, TCGType type, TCGCond cond,
                          TCGReg dest, TCGReg arg1, tcg_target_long arg2)
{
    tcg_insn_unit insn = 0;

    if (type == TCG_TYPE_I32) {
        arg2 = (int32_t)arg2;
    }
    if (arg2 != sextract64(arg2, 0, 12)) {
        tcg_out_movi(s, type, TCG_REG_TMP, arg2);
        tgen_setcond(s, type, cond, dest, arg1, TCG_REG_TMP);
        return;
    }
    insn = deposit32(insn, 0, 8, type == TCG_TYPE_I32
                                 ? INDEX_op_tci_setcond32i
                                 : INDEX_op_tci_setcond64i);
    insn = deposit32(insn, 8, 4, dest);
    insn = deposit32(insn, 12, 4, arg1);
    insn = deposit32(insn, 16, 4, cond);
    insn = deposit32(insn, 20, 12, arg2);
    tcg_out32(s, insn);
}

static const TCGOutOpSetcond outop_setcond = {
    .base.static_constraint = C_O1_I2(r, r, ri),
    .out_rrr = tgen_setcond,
    .out_rri = tgen_setcondi,
''',
)
replace(
    "tcg/tci.c",
    "        case INDEX_op_tci_addi:\n",
    r'''        case INDEX_op_tci_brcond32:
            if (tci_compare32(regs[extract32(insn, 8, 4)],
                              regs[extract32(insn, 12, 4)],
                              extract32(insn, 16, 4))) {
                tb_ptr = (const void *)((const char *)tb_ptr +
                                        sextract32(insn, 20, 12));
            }
            break;
        case INDEX_op_tci_brcond64:
            if (tci_compare64(regs[extract32(insn, 8, 4)],
                              regs[extract32(insn, 12, 4)],
                              extract32(insn, 16, 4))) {
                tb_ptr = (const void *)((const char *)tb_ptr +
                                        sextract32(insn, 20, 12));
            }
            break;
        case INDEX_op_tci_setcond32i:
            regs[extract32(insn, 8, 4)] =
                tci_compare32(regs[extract32(insn, 12, 4)],
                              (uint32_t)sextract32(insn, 20, 12),
                              extract32(insn, 16, 4));
            break;
        case INDEX_op_tci_setcond64i:
            regs[extract32(insn, 8, 4)] =
                tci_compare64(regs[extract32(insn, 12, 4)],
                              (uint64_t)(int64_t)sextract32(insn, 20, 12),
                              extract32(insn, 16, 4));
            break;
        case INDEX_op_tci_addi:
''',
)
replace(
    "tcg/tci.c",
    "    case INDEX_op_tci_addi:\n        tci_args_rrs(insn, &r0, &r1, &s2);\n",
    r'''    case INDEX_op_tci_brcond32:
    case INDEX_op_tci_brcond64:
        info->fprintf_func(info->stream, "%-12s  %s, %s, %s, %+d",
                           op_name, str_r(extract32(insn, 8, 4)),
                           str_r(extract32(insn, 12, 4)),
                           str_c(extract32(insn, 16, 4)),
                           sextract32(insn, 20, 12));
        break;
    case INDEX_op_tci_setcond32i:
    case INDEX_op_tci_setcond64i:
        info->fprintf_func(info->stream, "%-12s  %s, %s, %d, %s",
                           op_name, str_r(extract32(insn, 8, 4)),
                           str_r(extract32(insn, 12, 4)),
                           sextract32(insn, 20, 12),
                           str_c(extract32(insn, 16, 4)));
        break;
    case INDEX_op_tci_addi:
        tci_args_rrs(insn, &r0, &r1, &s2);
''',
)

# Implicit per-access barriers. tcg_gen_req_mo puts a barrier before every
# guest load and store so a weakly ordered host keeps x86's TSO order towards
# other threads: 22.7M barriers/s on Smashing Drive, one per access. With one
# vCPU (thread=single) the only other observers are device threads (nv2a
# pfifo, APU, DMA), and they hand off with the vCPU through MMIO, which runs
# under QEMU locks whose release/acquire already orders the stores before
# them. JIT-less skips the implicit ones by default; explicit guest fences
# (mfence/lfence/sfence, locked ops) still go through tcg_gen_mb untouched.
# XEMU_IOS_TCI_STRICT_MO=1 restores them.
replace(
    "tcg/tcg-op-ldst.c",
    "static void tcg_gen_req_mo(TCGBar type)\n{\n",
    "#ifdef CONFIG_TCG_INTERPRETER\n"
    "bool xemu_tci_relaxed_mo(void);\n"
    "#endif\n\n"
    "static void tcg_gen_req_mo(TCGBar type)\n{\n"
    "#ifdef CONFIG_TCG_INTERPRETER\n"
    "    if (xemu_tci_relaxed_mo()) {\n"
    "        return;\n"
    "    }\n"
    "#endif\n",
)
replace(
    "tcg/tci.c",
    "static inline void tci_count_op(unsigned *prev, unsigned opc)\n",
    r'''bool xemu_tci_relaxed_mo(void);
bool xemu_tci_relaxed_mo(void)
{
    static int relaxed = -1;
    if (unlikely(relaxed < 0)) {
        const char *strict = getenv("XEMU_IOS_TCI_STRICT_MO");
        relaxed = !(strict && strcmp(strict, "0"));
        fprintf(stderr, "xemu-tci: implicit guest ld/st barriers %s\n",
                relaxed ? "off (XEMU_IOS_TCI_STRICT_MO=1 restores)" : "on");
    }
    return relaxed;
}

static inline void tci_count_op(unsigned *prev, unsigned opc)
''',
)

# Branch on a compare with a constant: tci_movi>tci_brcond32 was 2.6% of ops.
# Same insn as tci_brcond, the constant in the next word. The 12-bit offset
# is relative to the word after the insn (where patch_reloc measures from),
# so the interpreter reads the constant without moving that base.
replace(
    "tcg/tci/tcg-target-con-set.h",
    "C_O0_I2(ri, r)\n",
    "C_O0_I2(ri, r)\nC_O0_I2(r, ri)\n",
)
replace(
    "tcg/tci/tcg-target-opc.h.inc",
    "DEF(tci_setcond64i, 1, 1, 2, TCG_OPF_NOT_PRESENT)\n",
    "DEF(tci_setcond64i, 1, 1, 2, TCG_OPF_NOT_PRESENT)\n"
    "DEF(tci_brcond32i, 0, 1, 3, TCG_OPF_NOT_PRESENT)\n"
    "DEF(tci_brcond64i, 0, 1, 3, TCG_OPF_NOT_PRESENT)\n",
)
replace(
    "tcg/tci/tcg-target.c.inc",
    "static const TCGOutOpBrcond outop_brcond = {\n"
    "    .base.static_constraint = C_O0_I2(r, r),\n"
    "    .out_rr = tgen_brcond,\n",
    r'''static void tgen_brcondi(TCGContext *s, TCGType type, TCGCond cond,
                         TCGReg arg0, tcg_target_long arg1, TCGLabel *l)
{
    tcg_insn_unit insn = 0;

    if (type == TCG_TYPE_I32) {
        arg1 = (int32_t)arg1;
    } else if (arg1 != (int32_t)arg1) {
        tcg_out_movi(s, type, TCG_REG_TMP, arg1);
        tgen_brcond(s, type, cond, arg0, TCG_REG_TMP, l);
        return;
    }
    tcg_out_reloc(s, s->code_ptr, 12, l, 0);
    insn = deposit32(insn, 0, 8, type == TCG_TYPE_I32 ? INDEX_op_tci_brcond32i
                                                      : INDEX_op_tci_brcond64i);
    insn = deposit32(insn, 8, 4, arg0);
    insn = deposit32(insn, 16, 4, cond);
    tcg_out32(s, insn);
    tcg_out32(s, (uint32_t)arg1);
}

static const TCGOutOpBrcond outop_brcond = {
    .base.static_constraint = C_O0_I2(r, ri),
    .out_rr = tgen_brcond,
    .out_ri = tgen_brcondi,
''',
)
replace(
    "tcg/tci.c",
    "        case INDEX_op_tci_setcond32i:\n",
    r'''        case INDEX_op_tci_brcond32i:
            ptr = (void *)((const char *)tb_ptr + sextract32(insn, 20, 12));
            tmp32 = *tb_ptr++;
            if (tci_compare32(regs[extract32(insn, 8, 4)], tmp32,
                              extract32(insn, 16, 4))) {
                tb_ptr = ptr;
            }
            break;
        case INDEX_op_tci_brcond64i:
            ptr = (void *)((const char *)tb_ptr + sextract32(insn, 20, 12));
            tmp64 = (int64_t)(int32_t)*tb_ptr++;
            if (tci_compare64(regs[extract32(insn, 8, 4)], tmp64,
                              extract32(insn, 16, 4))) {
                tb_ptr = ptr;
            }
            break;
        case INDEX_op_tci_setcond32i:
''',
)
replace(
    "tcg/tci.c",
    "    case INDEX_op_tci_setcond32i:\n    case INDEX_op_tci_setcond64i:\n",
    r'''    case INDEX_op_tci_brcond32i:
    case INDEX_op_tci_brcond64i:
        info->fprintf_func(info->stream, "%-12s  %s, 0x%x, %s, %+d",
                           op_name, str_r(extract32(insn, 8, 4)), *tb_ptr,
                           str_c(extract32(insn, 16, 4)),
                           sextract32(insn, 20, 12));
        return 2 * sizeof(insn);
    case INDEX_op_tci_setcond32i:
    case INDEX_op_tci_setcond64i:
''',
)

# Computed-goto dispatch. The profile put ~90% of JIT-less CPU time in the
# interpreter loop at 7-10 cycles per op, and the single `switch` gives every
# op one shared, bounds-checked indirect jump. Each case now ends in its own
# copy of fetch/decode/jump, so the branch predictor sees the op that came
# before. The switch is kept (never entered) so case code is unchanged; every
# top-level `break;`/`continue;` of the case bodies becomes TCI_NEXT(). Must
# run after every other tci.c edit above.
def _tci_computed_goto():
    import re

    path = root / "tcg/tci.c"
    text = path.read_text()
    fn = text.index("uintptr_t QEMU_DISABLE_CFI tcg_qemu_tb_exec(")
    head = "        switch (opc) {\n"
    sw = text.index(head, fn)
    tail = "        default:\n            g_assert_not_reached();\n        }\n    }\n}\n"
    end = text.index(tail, sw)
    body = text[sw + len(head):end]

    table, out, nexts = [], [], 0
    for line in body.split("\n"):
        m = re.match(r"^        case (INDEX_op_\w+):(.*)$", line)
        if m:
            table.append(f"            [{m.group(1)}] = &&tci_L_{m.group(1)},")
            line = f"        case {m.group(1)}: tci_L_{m.group(1)}:{m.group(2)}"
        elif re.match(r"^#\s*(if|ifdef|ifndef|elif|else|endif)\b", line):
            table.append(line)
        elif line in ("            break;", "            continue;"):
            line = "            TCI_NEXT();"
            nexts += 1
        out.append(line)
    cases = sum(1 for t in table if t.startswith("            ["))
    if cases < 80 or nexts < 80:
        sys.exit(f"tcg/tci.c: computed goto found {cases} cases, {nexts} exits")

    new_head = (
        "        if (unlikely(tci_prof)) {\n"
        "            tci_count_op(&tci_prev, opc);\n"
        "        }\n"
        "        static const void *const tci_dispatch[256] = {\n"
        "            [0 ... 255] = &&tci_L_default,\n"
        + "\n".join(table) + "\n"
        "        };\n"
        "        goto *tci_dispatch[opc];\n"
        "        switch (opc) {\n"
    )
    new_tail = tail.replace("        default:\n",
                            "        default: tci_L_default:\n", 1)
    macro = (
        "#define TCI_NEXT() do {                                   \\\n"
        "        insn = *tb_ptr++;                                 \\\n"
        "        opc = extract32(insn, 0, 8);                      \\\n"
        "        if (unlikely(tci_prof)) {                         \\\n"
        "            tci_count_op(&tci_prev, opc);                 \\\n"
        "        }                                                 \\\n"
        "        goto *tci_dispatch[opc];                          \\\n"
        "    } while (0)\n\n"
    )
    text = (text[:fn] + macro + text[fn:sw] + new_head + "\n".join(out)
            + new_tail + "#undef TCI_NEXT\n" + text[end + len(tail):])
    path.write_text(text)
    print(f"tcg/tci.c: computed goto, {cases} cases, {nexts} dispatch sites")


_tci_computed_goto()
