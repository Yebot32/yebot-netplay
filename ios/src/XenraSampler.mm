#import "XenraSampler.h"

#include <algorithm>
#include <cstdint>
#include <dlfcn.h>
#include <mach/mach.h>
#include <pthread.h>
#include <time.h>
#include <unistd.h>

#import "XenraScreens.h"

namespace {

constexpr int kMaxThreads = 96;
constexpr int kMaxFrames = 12;

struct Sample {
  thread_t thread;
  uint64_t pc, lr;
  uint64_t frames[kMaxFrames];
  int frame_count;
  int run_state;
  int cpu;  // tenths of a percent
  char name[48];
};

bool ReadWords(uint64_t address, uint64_t out[2]) {
  vm_size_t size = 0;
  return vm_read_overwrite(mach_task_self(), vm_address_t(address), 16,
                           vm_address_t(out), &size) == KERN_SUCCESS &&
         size == 16;
}

// No allocation in here: a suspended thread may own the malloc lock.
void Read(thread_t thread, Sample& sample) {
  arm_thread_state64_t state;
  mach_msg_type_number_t count = ARM_THREAD_STATE64_COUNT;
  if (thread_get_state(thread, ARM_THREAD_STATE64,
                       reinterpret_cast<thread_state_t>(&state),
                       &count) != KERN_SUCCESS) {
    return;
  }
  sample.pc = arm_thread_state64_get_pc(state);
  sample.lr = arm_thread_state64_get_lr(state);
  uint64_t frame = arm_thread_state64_get_fp(state);
  for (int i = 0; i < kMaxFrames && frame && !(frame & 7); i++) {
    uint64_t record[2];
    if (!ReadWords(frame, record)) break;
    sample.frames[sample.frame_count++] = record[1];
    if (record[0] <= frame) break;
    frame = record[0];
  }
}

NSString* Where(uint64_t address) {
  Dl_info info;
  if (!address || !dladdr(reinterpret_cast<void*>(address), &info) ||
      !info.dli_fname) {
    return [NSString stringWithFormat:@"0x%llx (generated code or unmapped)",
                                      address];
  }
  const char* file = strrchr(info.dli_fname, '/');
  return [NSString
      stringWithFormat:@"0x%llx %s %s+0x%llx", address,
                       file ? file + 1 : info.dli_fname, info.dli_sname ?: "?",
                       address - uint64_t(info.dli_saddr ?: info.dli_fbase)];
}

}  // namespace

void XenraSamplerLoad(void) {
  thread_act_array_t threads;
  mach_msg_type_number_t count = 0;
  if (task_threads(mach_task_self(), &threads, &count) != KERN_SUCCESS) return;
  struct Busy {
    int cpu;
    char name[48];
  } busy[kMaxThreads];
  int taken = 0, total = 0;
  for (mach_msg_type_number_t i = 0; i < count; i++) {
    thread_basic_info_data_t basic;
    mach_msg_type_number_t size = THREAD_BASIC_INFO_COUNT;
    if (thread_info(threads[i], THREAD_BASIC_INFO,
                    reinterpret_cast<thread_info_t>(&basic), &size) == KERN_SUCCESS &&
        !(basic.flags & TH_FLAGS_IDLE)) {
      total += basic.cpu_usage;
      if (basic.cpu_usage >= 30 && taken < kMaxThreads) {
        Busy& b = busy[taken++];
        b.cpu = basic.cpu_usage;
        b.name[0] = 0;
        if (pthread_t handle = pthread_from_mach_thread_np(threads[i])) {
          pthread_getname_np(handle, b.name, sizeof(b.name));
        }
      }
    }
    mach_port_deallocate(mach_task_self(), threads[i]);
  }
  vm_deallocate(mach_task_self(), vm_address_t(threads), count * sizeof(thread_act_t));
  std::sort(busy, busy + taken, [](const Busy& a, const Busy& b) { return a.cpu > b.cpu; });
  NSMutableString* text = [NSMutableString
      stringWithFormat:@"load: total %.0f%% of one core;", total / 10.0];
  for (int i = 0; i < taken && i < 6; i++) {
    [text appendFormat:@" %s %.0f%%", busy[i].name[0] ? busy[i].name : "?",
                       busy[i].cpu / 10.0];
  }
  XenraLog(text);
}

namespace {

// The thread with this name, or the busiest one if none has it.
thread_t FindThread(const char* wanted) {
  thread_act_array_t threads;
  mach_msg_type_number_t count = 0;
  if (task_threads(mach_task_self(), &threads, &count) != KERN_SUCCESS) return 0;
  thread_t found = 0, busiest = 0;
  int most = -1;
  for (mach_msg_type_number_t i = 0; i < count; i++) {
    char name[48] = {0};
    if (pthread_t handle = pthread_from_mach_thread_np(threads[i])) {
      pthread_getname_np(handle, name, sizeof(name));
    }
    thread_basic_info_data_t basic;
    mach_msg_type_number_t size = THREAD_BASIC_INFO_COUNT;
    const int cpu = thread_info(threads[i], THREAD_BASIC_INFO,
                                reinterpret_cast<thread_info_t>(&basic), &size) ==
                            KERN_SUCCESS
                        ? basic.cpu_usage
                        : 0;
    if (!found && strcmp(name, wanted) == 0) found = threads[i];
    if (cpu > most) {
      most = cpu;
      busiest = threads[i];
    }
  }
  const thread_t chosen = found ? found : busiest;
  for (mach_msg_type_number_t i = 0; i < count; i++) {
    if (threads[i] != chosen) mach_port_deallocate(mach_task_self(), threads[i]);
  }
  vm_deallocate(mach_task_self(), vm_address_t(threads), count * sizeof(thread_act_t));
  return chosen;
}

}  // namespace

void XenraSamplerProfile(double seconds) {
  // xemu names it so with -name debug-threads=on; single-threaded TCG.
  const thread_t target = FindThread("ALL CPUs/TCG");
  if (!target) return;
  constexpr int kMax = 8192;
  constexpr int kDepth = 8;
  static uint64_t pcs[kMax];
  // Return addresses, for samples that stop in the kernel: which core function
  // was waiting, and on what.
  static uint64_t callers[kMax][kDepth];
  int taken = 0;
  const uint64_t end = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) + uint64_t(seconds * 1e9);
  while (taken < kMax && clock_gettime_nsec_np(CLOCK_UPTIME_RAW) < end) {
    if (thread_suspend(target) == KERN_SUCCESS) {
      arm_thread_state64_t state;
      mach_msg_type_number_t count = ARM_THREAD_STATE64_COUNT;
      if (thread_get_state(target, ARM_THREAD_STATE64,
                           reinterpret_cast<thread_state_t>(&state), &count) ==
          KERN_SUCCESS) {
        uint64_t* chain = callers[taken];
        memset(chain, 0, sizeof(callers[taken]));
        chain[0] = arm_thread_state64_get_lr(state);
        uint64_t frame = arm_thread_state64_get_fp(state);
        for (int d = 1; d < kDepth && frame && !(frame & 7); d++) {
          uint64_t record[2];
          if (!ReadWords(frame, record)) break;
          chain[d] = record[1];
          if (record[0] <= frame) break;
          frame = record[0];
        }
        pcs[taken++] = arm_thread_state64_get_pc(state);
      }
      thread_resume(target);
    }
    usleep(1000);
  }
  mach_port_deallocate(mach_task_self(), target);
  if (!taken) return;

  // Resolved after sampling: dladdr is not safe while the thread is stopped.
  NSMutableDictionary<NSString*, NSNumber*>* counts = [NSMutableDictionary dictionary];
  for (int i = 0; i < taken; i++) {
    Dl_info info;
    NSString* key;
    if (dladdr(reinterpret_cast<void*>(pcs[i]), &info) && info.dli_fname) {
      const char* file = strrchr(info.dli_fname, '/');
      key = [NSString stringWithFormat:@"%s %s", file ? file + 1 : info.dli_fname,
                                       info.dli_sname ?: "?"];
      // A wait is only useful with the core function that waited.
      if (strstr(info.dli_fname, "libsystem_")) {
        for (int d = 0; d < kDepth && callers[i][d]; d++) {
          Dl_info up;
          if (dladdr(reinterpret_cast<void*>(callers[i][d]), &up) && up.dli_fname &&
              strstr(up.dli_fname, "libxemu")) {
            key = [NSString stringWithFormat:@"%@ <- %s", key, up.dli_sname ?: "?"];
            break;
          }
        }
      }
    } else {
      key = @"(generated code)";
    }
    counts[key] = @(counts[key].intValue + 1);
  }
  NSArray<NSString*>* order = [counts keysSortedByValueUsingComparator:^(id a, id b) {
    return [b compare:a];
  }];
  NSMutableString* text = [NSMutableString
      stringWithFormat:@"cpu profile: %d samples over %.0f s\n", taken, seconds];
  for (NSUInteger i = 0; i < order.count && i < 30; i++) {
    [text appendFormat:@"  %5.1f%% %@\n", counts[order[i]].intValue * 100.0 / taken,
                       order[i]];
  }
  XenraLog(text);
}

void XenraSamplerDump(NSString* reason) {
  thread_act_array_t threads;
  mach_msg_type_number_t count = 0;
  if (task_threads(mach_task_self(), &threads, &count) != KERN_SUCCESS) return;

  static Sample samples[kMaxThreads];
  int taken = 0;
  const thread_t self = mach_thread_self();
  for (mach_msg_type_number_t i = 0; i < count && taken < kMaxThreads; i++) {
    if (threads[i] == self) continue;
    Sample& sample = samples[taken++];
    memset(&sample, 0, sizeof(sample));
    sample.thread = threads[i];
    thread_basic_info_data_t basic;
    mach_msg_type_number_t size = THREAD_BASIC_INFO_COUNT;
    if (thread_info(threads[i], THREAD_BASIC_INFO,
                    reinterpret_cast<thread_info_t>(&basic), &size) ==
        KERN_SUCCESS) {
      sample.run_state = basic.run_state;
      sample.cpu = basic.cpu_usage;
    }
    if (pthread_t handle = pthread_from_mach_thread_np(threads[i])) {
      pthread_getname_np(handle, sample.name, sizeof(sample.name));
    }
    if (thread_suspend(threads[i]) == KERN_SUCCESS) {
      Read(threads[i], sample);
      thread_resume(threads[i]);
    }
  }
  mach_port_deallocate(mach_task_self(), self);

  NSMutableString* text = [NSMutableString
      stringWithFormat:@"threads (%@):\n", reason];
  for (int i = 0; i < taken; i++) {
    const Sample& sample = samples[i];
    [text appendFormat:@"[%d] %s state=%d cpu=%.1f%%\n  pc %@\n  lr %@\n", i,
                       sample.name, sample.run_state, sample.cpu / 10.0,
                       Where(sample.pc), Where(sample.lr)];
    for (int f = 0; f < sample.frame_count; f++) {
      [text appendFormat:@"  %@\n", Where(sample.frames[f])];
    }
  }
  for (mach_msg_type_number_t i = 0; i < count; i++) {
    mach_port_deallocate(mach_task_self(), threads[i]);
  }
  vm_deallocate(mach_task_self(), vm_address_t(threads),
                count * sizeof(thread_act_t));
  XenraLog(text);
}
