/**
 ******************************************************************************
 * Xenia : Xbox 360 Emulator Research Project                                 *
 ******************************************************************************
 * Copyright 2026 Ben Vanik. All rights reserved.                             *
 * Released under the BSD license - see LICENSE in the root for more details. *
 ******************************************************************************
 */

#include "xenia/cpu/testing/util.h"

#include <cstring>

using namespace xe;
using namespace xe::cpu;
using namespace xe::cpu::hir;
using namespace xe::cpu::testing;
using xe::cpu::ppc::PPCContext;

namespace {

// Denormal in every lane. With NJM on (the default) VMX mode flushes it, the
// scalar mode keeps it.
const vec128_t kDenormal = vec128i(1, 1, 1, 1);

// A processor whose test module generates one function per resolve, in order.
// Calls end their HIR block and nothing branches past them, so CF
// simplification would drop the code after a call.
struct MultiFunctionTest {
  explicit MultiFunctionTest(
      std::function<bool(uint32_t)> contains_address,
      std::function<void(HIRBuilder&, int invocation)> generate) {
    memory = std::make_unique<Memory>();
    memory->Initialize();
    processor = std::make_unique<Processor>(memory.get(), nullptr);
    processor->Setup(CreateBackend());
    auto module = std::make_unique<TestModule>(
        processor.get(), "Test", std::move(contains_address),
        [this, generate](HIRBuilder& b) {
          generate(b, invocation++);
          return true;
        },
        /*skip_cf_simplification=*/true);
    processor->AddModule(std::move(module));
    processor->backend()->CommitExecutableRange(0x80000000, 0x80010000);
    stack_address = memory->SystemHeapAlloc(kStackSize);
    thread_state = std::make_unique<ThreadState>(processor.get(), 0x100,
                                                 stack_address + kStackSize);
  }
  ~MultiFunctionTest() {
    thread_state.reset();
    memory->SystemHeapFree(stack_address);
    processor.reset();
    memory.reset();
  }

  PPCContext* ctx() { return thread_state->context(); }
  void Call(Function* fn) {
    ctx()->lr = 0xBCBCBCBC;
    fn->Call(thread_state.get(), uint32_t(ctx()->lr));
  }

  static constexpr uint32_t kStackSize = 64 * 1024;
  std::unique_ptr<Memory> memory;
  std::unique_ptr<Processor> processor;
  std::unique_ptr<ThreadState> thread_state;
  uint32_t stack_address = 0;
  int invocation = 0;
};

void NoopBuiltin(PPCContext* ctx, void* arg0, void* arg1) {}

void RequireFlushed(const vec128_t& v) {
  for (int n = 0; n < 4; ++n) {
    REQUIRE(v.u32[n] == 0);
  }
}

}  // namespace

// =============================================================================
// VMX mode after a host call
// =============================================================================
// The guest-to-host thunk returns with the scalar mode loaded. A VMX op after
// the call must load the VMX mode again rather than trust what was tracked
// before it.

TEST_CASE("VMX_MODE_RELOADED_AFTER_CALL_EXTERN", "[backend]") {
  Function* builtin = nullptr;
  MultiFunctionTest test([](uint32_t address) { return address == 0x80000000; },
                         [&builtin](HIRBuilder& b, int) {
                           StoreVR(b, 3, b.Add(LoadVR(b, 4), LoadVR(b, 5)));
                           b.CallExtern(builtin);
                           StoreVR(b, 8, b.Add(LoadVR(b, 6), LoadVR(b, 7)));
                           b.Return();
                         });
  builtin =
      test.processor->DefineBuiltin("Noop", NoopBuiltin, nullptr, nullptr);
  auto fn = test.processor->ResolveFunction(0x80000000);
  REQUIRE(fn != nullptr);

  test.ctx()->v[4] = vec128f(1.0f);
  test.ctx()->v[5] = vec128f(2.0f);
  test.ctx()->v[6] = kDenormal;
  test.ctx()->v[7] = vec128f(0.0f);
  test.Call(fn);

  REQUIRE(test.ctx()->v[3] == vec128f(3.0f));
  RequireFlushed(test.ctx()->v[8]);
}

TEST_CASE("VMX_MODE_RELOADED_AFTER_LOAD_CLOCK", "[backend]") {
  // LOAD_CLOCK is a host call inside one block, so the mode tracker carries
  // across it.
  TestFunction test([](HIRBuilder& b) {
    StoreVR(b, 3, b.Add(LoadVR(b, 4), LoadVR(b, 5)));
    StoreGPR(b, 10, b.LoadClock());
    StoreVR(b, 8, b.Add(LoadVR(b, 6), LoadVR(b, 7)));
    b.Return();
  });
  test.Run(
      [](PPCContext* ctx) {
        ctx->v[4] = vec128f(1.0f);
        ctx->v[5] = vec128f(2.0f);
        ctx->v[6] = kDenormal;
        ctx->v[7] = vec128f(0.0f);
      },
      [](PPCContext* ctx) {
        REQUIRE(ctx->v[3] == vec128f(3.0f));
        RequireFlushed(ctx->v[8]);
      });
}

// =============================================================================
// CALL_INDIRECT with a constant target
// =============================================================================
// The frontend emits this for a direct call no module owns at translation
// time. Constant propagation turns it into a direct call whenever a module
// claims the target, so the callee is only claimed after the callers compile.

TEST_CASE("CALL_INDIRECT_CONSTANT_TARGET", "[backend]") {
  constexpr uint32_t kCallerAddr = 0x80000000;
  constexpr uint32_t kCondCallerAddr = 0x80001000;
  constexpr uint32_t kCalleeAddr = 0x80002000;
  constexpr uint64_t kCanary = 0x1234567887654321ull;

  bool callee_claimed = false;
  MultiFunctionTest test(
      [&callee_claimed](uint32_t address) {
        return address == kCallerAddr || address == kCondCallerAddr ||
               (callee_claimed && address == kCalleeAddr);
      },
      [](HIRBuilder& b, int invocation) {
        switch (invocation) {
          case 0:
            b.CallIndirect(b.LoadConstantUint64(kCalleeAddr));
            StoreGPR(b, 20, LoadGPR(b, 4));
            break;
          case 1:
            b.CallIndirectTrue(b.IsTrue(LoadGPR(b, 9)),
                               b.LoadConstantUint64(kCalleeAddr));
            StoreGPR(b, 21, LoadGPR(b, 4));
            break;
          default:
            // Callee: count the calls in r3.
            StoreGPR(b, 3, b.Add(LoadGPR(b, 3), b.LoadConstantUint64(1)));
            break;
        }
        b.Return();
      });

  auto caller = test.processor->ResolveFunction(kCallerAddr);
  REQUIRE(caller != nullptr);
  auto cond_caller = test.processor->ResolveFunction(kCondCallerAddr);
  REQUIRE(cond_caller != nullptr);
  callee_claimed = true;

  auto ctx = test.ctx();
  ctx->r[4] = kCanary;

  SECTION("unconditional") {
    ctx->r[3] = 0;
    test.Call(caller);
    REQUIRE(ctx->r[3] == 1);
    REQUIRE(ctx->r[20] == kCanary);
  }

  SECTION("conditional, taken") {
    ctx->r[3] = 0;
    ctx->r[9] = 1;
    test.Call(cond_caller);
    REQUIRE(ctx->r[3] == 1);
    REQUIRE(ctx->r[21] == kCanary);
  }

  SECTION("conditional, not taken") {
    ctx->r[3] = 0;
    ctx->r[9] = 0;
    test.Call(cond_caller);
    REQUIRE(ctx->r[3] == 0);
    REQUIRE(ctx->r[21] == kCanary);
  }
}

// =============================================================================
// Merging compares against float constants
// =============================================================================
// SimplificationPass merges an OR of two compares on the same operands. Two
// different float constants are not the same operand.

TEST_CASE("OR_OF_FLOAT_COMPARES_NOT_MERGED_ACROSS_CONSTANTS", "[simplify]") {
  TestFunction test([](HIRBuilder& b) {
    auto x = LoadFPR(b, 4);
    // Wrongly merged, this becomes x <= 1.0.
    auto lt_or_eq = b.Or(b.CompareSLT(x, b.LoadConstantFloat64(1.0)),
                         b.CompareEQ(x, b.LoadConstantFloat64(2.0)));
    // Wrongly merged, this becomes always true.
    auto eq_or_ne = b.Or(b.CompareEQ(x, b.LoadConstantFloat64(1.0)),
                         b.CompareNE(x, b.LoadConstantFloat64(2.0)));
    StoreGPR(b, 3, b.ZeroExtend(lt_or_eq, INT64_TYPE));
    StoreGPR(b, 4, b.ZeroExtend(eq_or_ne, INT64_TYPE));
    b.Return();
  });
  test.Run([](PPCContext* ctx) { ctx->f[4] = 2.0; },
           [](PPCContext* ctx) {
             REQUIRE(ctx->r[3] == 1);
             REQUIRE(ctx->r[4] == 0);
           });
}
