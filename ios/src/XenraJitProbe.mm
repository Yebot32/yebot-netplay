#import "XenraJitProbe.h"

#include <atomic>
#include <cstdint>
#include <cstring>
#include <libkern/OSCacheControl.h>
#include <mach/mach.h>
#include <mach/vm_map.h>
#include <pthread.h>
#include <setjmp.h>
#include <signal.h>
#include <sys/mman.h>

#import "XenraScreens.h"

namespace {

constexpr size_t kRegionSize = 1 << 20;
constexpr int64_t kTimeoutNs = 2 * NSEC_PER_SEC;
// Keyed by OS version: an update may change the answer.
NSString* const kBadKey = @"jit.probe.bad";
NSString* const kTryingKey = @"jit.probe.trying";

const char* const kNames[] = {"rx-first", "rwx", "rw-first"};

struct Probe {
  XenraJitScheme scheme;
  dispatch_semaphore_t done;
  // 0 running, 1 passed, otherwise a failure from below.
  std::atomic<int> result{0};
  char detail[96] = {0};
};

thread_local sigjmp_buf* t_escape;
struct sigaction g_saved[4];
constexpr int kSignals[] = {SIGBUS, SIGSEGV, SIGILL, SIGTRAP};

void OnFault(int signal_number, siginfo_t*, void*) {
  if (t_escape) siglongjmp(*t_escape, signal_number);
  // Another thread crashed for its own reasons: put things back and let it.
  for (size_t i = 0; i < 4; i++) sigaction(kSignals[i], &g_saved[i], nullptr);
}

// Writable and executable views of one region, or false.
bool Allocate(XenraJitScheme scheme, uint8_t*& rw, uint8_t*& rx) {
  void* first = nullptr;
  vm_address_t alias = 0;
  vm_prot_t current = 0, maximum = 0;
  switch (scheme) {
    case XenraJitRwx:
      first = mmap(nullptr, kRegionSize, PROT_READ | PROT_WRITE,
                   MAP_PRIVATE | MAP_ANON, -1, 0);
      if (first == MAP_FAILED) return false;
      if (mprotect(first, kRegionSize, PROT_READ | PROT_WRITE | PROT_EXEC) != 0) {
        munmap(first, kRegionSize);
        return false;
      }
      rw = rx = static_cast<uint8_t*>(first);
      return true;
    case XenraJitRxFirst:
    case XenraJitRwFirst: {
      const int born = scheme == XenraJitRxFirst ? PROT_READ | PROT_EXEC
                                                 : PROT_READ | PROT_WRITE;
      const int other = scheme == XenraJitRxFirst ? PROT_READ | PROT_WRITE
                                                  : PROT_READ | PROT_EXEC;
      first = mmap(nullptr, kRegionSize, born, MAP_PRIVATE | MAP_ANON, -1, 0);
      if (first == MAP_FAILED) return false;
      if (vm_remap(mach_task_self(), &alias, kRegionSize, 0, VM_FLAGS_ANYWHERE,
                   mach_task_self(), vm_address_t(first), FALSE, &current,
                   &maximum, VM_INHERIT_NONE) != KERN_SUCCESS) {
        munmap(first, kRegionSize);
        return false;
      }
      if (mprotect(reinterpret_cast<void*>(alias), kRegionSize, other) != 0) {
        munmap(first, kRegionSize);
        munmap(reinterpret_cast<void*>(alias), kRegionSize);
        return false;
      }
      rw = reinterpret_cast<uint8_t*>(scheme == XenraJitRxFirst
                                          ? alias
                                          : vm_address_t(first));
      rx = reinterpret_cast<uint8_t*>(scheme == XenraJitRxFirst
                                          ? vm_address_t(first)
                                          : alias);
      return true;
    }
    default:
      return false;
  }
}

void Emit(uint8_t* rw, uint8_t* rx, uint16_t value) {
  // mov x0, #value; ret
  const uint32_t code[2] = {0xD2800000u | (uint32_t(value) << 5), 0xD65F03C0u};
  memcpy(rw, code, sizeof(code));
  sys_dcache_flush(rw, sizeof(code));
  sys_icache_invalidate(rx, sizeof(code));
}

uint64_t Run(uint8_t* rx) {
  return reinterpret_cast<uint64_t (*)(void)>(rx)();
}

void* ProbeThread(void* opaque) {
  Probe* probe = static_cast<Probe*>(opaque);
  sigjmp_buf escape;
  uint8_t *rw = nullptr, *rx = nullptr;
  const int fault = sigsetjmp(escape, 1);
  if (fault) {
    t_escape = nullptr;
    snprintf(probe->detail, sizeof(probe->detail), "signal %d", fault);
    probe->result = 2;
  } else {
    t_escape = &escape;
    if (!Allocate(probe->scheme, rw, rx)) {
      t_escape = nullptr;
      snprintf(probe->detail, sizeof(probe->detail), "allocate failed");
      probe->result = 3;
    } else {
      // Run, patch in place, run again: the core does exactly this, and the
      // write after an execution is as likely to stall as the execution.
      Emit(rw, rx, 42);
      const uint64_t first = Run(rx);
      Emit(rw, rx, 43);
      const uint64_t second = Run(rx);
      t_escape = nullptr;
      snprintf(probe->detail, sizeof(probe->detail), "rw=%p rx=%p got %llu %llu",
               rw, rx, first, second);
      probe->result = first == 42 && second == 43 ? 1 : 4;
    }
  }
  dispatch_semaphore_signal(probe->done);
  return nullptr;
}

// A stalled thread stays stalled, so it is left behind on purpose, suspended so
// that a thread stuck retrying a fault does not burn a core for the whole game.
bool RunProbe(XenraJitScheme scheme, NSMutableString* report) {
  Probe* probe = new Probe();
  probe->scheme = scheme;
  probe->done = dispatch_semaphore_create(0);
  pthread_t thread;
  if (pthread_create(&thread, nullptr, ProbeThread, probe) != 0) {
    [report appendFormat:@"%s: no thread\n", kNames[scheme]];
    return false;
  }
  if (dispatch_semaphore_wait(probe->done, dispatch_time(DISPATCH_TIME_NOW,
                                                         kTimeoutNs)) != 0) {
    thread_suspend(pthread_mach_thread_np(thread));
    [report appendFormat:@"%s: HUNG\n", kNames[scheme]];
    return false;
  }
  pthread_join(thread, nullptr);
  const bool passed = probe->result == 1;
  [report appendFormat:@"%s: %s (%s)\n", kNames[scheme],
                       passed ? "ok" : "failed", probe->detail];
  delete probe;
  return passed;
}

NSString* OsKey(void) {
  return NSProcessInfo.processInfo.operatingSystemVersionString;
}

NSMutableString* g_report;

}  // namespace

XenraJitScheme XenraJitChooseScheme(void) {
  static XenraJitScheme chosen = XenraJitNone;
  static BOOL decided;
  if (decided) return chosen;
  decided = YES;
  g_report = [NSMutableString string];

  NSUserDefaults* defaults = NSUserDefaults.standardUserDefaults;
  NSMutableDictionary* bad =
      [[defaults dictionaryForKey:kBadKey] mutableCopy] ?: [NSMutableDictionary dictionary];
  // A probe that was running when the last launch ended took the process with it.
  if (NSString* killed = [defaults stringForKey:kTryingKey]) {
    bad[killed] = OsKey();
    [g_report appendFormat:@"%@: killed the app last launch\n", killed];
  }

  struct sigaction action;
  memset(&action, 0, sizeof(action));
  action.sa_sigaction = OnFault;
  action.sa_flags = SA_SIGINFO | SA_NODEFER;
  for (size_t i = 0; i < 4; i++) sigaction(kSignals[i], &action, &g_saved[i]);

  for (XenraJitScheme scheme : {XenraJitRxFirst, XenraJitRwx, XenraJitRwFirst}) {
    NSString* name = @(kNames[scheme]);
    if ([bad[name] isEqual:OsKey()]) {
      [g_report appendFormat:@"%@: skipped, failed before\n", name];
      continue;
    }
    [defaults setObject:name forKey:kTryingKey];
    [defaults synchronize];
    const bool passed = RunProbe(scheme, g_report);
    [defaults removeObjectForKey:kTryingKey];
    if (passed) {
      chosen = scheme;
      break;
    }
    bad[name] = OsKey();
  }

  for (size_t i = 0; i < 4; i++) sigaction(kSignals[i], &g_saved[i], nullptr);
  [defaults setObject:bad forKey:kBadKey];
  [defaults synchronize];
  XenraLog([@"jit probe:\n" stringByAppendingString:g_report]);
  return chosen;
}

NSString* XenraJitReport(void) { return g_report ?: @"not run"; }
