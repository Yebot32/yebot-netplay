#import "XenraSampler.h"

#include <cstdint>
#include <dlfcn.h>
#include <mach/mach.h>
#include <pthread.h>

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
