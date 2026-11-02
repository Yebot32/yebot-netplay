/**
 ******************************************************************************
 * Xenia : Xbox 360 Emulator Research Project                                 *
 ******************************************************************************
 * Released under the BSD license - see LICENSE in the root for more details. *
 ******************************************************************************
 */

#ifndef XENIA_BASE_GUEST_GPU_PROGRESS_H_
#define XENIA_BASE_GUEST_GPU_PROGRESS_H_

#include <atomic>
#include <cstdint>

#if defined(__linux__)
#include <linux/futex.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>
#endif

namespace xe {

// Wake-on-progress for guest threads parked in a GPU wait (see
// spin_park_guest_functions in the A64 backend). The command processor bumps
// the generation whenever it publishes something a guest GPU wait can observe
// (fence and memory writes, scratch register writeback, the ring read pointer
// writeback), and a parked waiter sleeps on the generation with a short
// timeout, so a wake that is missed or never comes only costs the timeout.
inline std::atomic<uint32_t> guest_gpu_progress_generation{0};
inline std::atomic<uint32_t> guest_gpu_progress_waiters{0};

inline void NotifyGuestGpuProgress() {
  guest_gpu_progress_generation.fetch_add(1, std::memory_order_seq_cst);
  // Seq-cst pairs with the waiter's increment of the waiter count before its
  // futex wait: either the waiter is counted here, or its futex wait sees the
  // new generation and returns at once.
  if (guest_gpu_progress_waiters.load(std::memory_order_seq_cst)) {
#if defined(__linux__)
    syscall(SYS_futex, &guest_gpu_progress_generation, FUTEX_WAKE_PRIVATE,
            INT32_MAX, nullptr, nullptr, 0);
#endif
  }
}

// Returns once the generation differs from `seen`, after the timeout, or on a
// spurious wake - the caller re-checks its own condition either way.
inline void WaitGuestGpuProgress(uint32_t seen, int64_t timeout_ns) {
#if defined(__linux__)
  guest_gpu_progress_waiters.fetch_add(1, std::memory_order_seq_cst);
  if (guest_gpu_progress_generation.load(std::memory_order_seq_cst) == seen) {
    timespec timeout;
    timeout.tv_sec = time_t(timeout_ns / 1000000000);
    timeout.tv_nsec = long(timeout_ns % 1000000000);
    syscall(SYS_futex, &guest_gpu_progress_generation, FUTEX_WAIT_PRIVATE,
            seen, &timeout, nullptr, 0);
  }
  guest_gpu_progress_waiters.fetch_sub(1, std::memory_order_seq_cst);
#endif
}

}  // namespace xe

#endif  // XENIA_BASE_GUEST_GPU_PROGRESS_H_
