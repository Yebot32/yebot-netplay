#import "XenraLogs.h"
#import "XenraStrings.h"

#import <Metal/Metal.h>

#include <atomic>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <dlfcn.h>
#include <fcntl.h>
#include <initializer_list>
#include <mach-o/dyld.h>
#include <mach/mach.h>
#include <signal.h>
#include <sys/sysctl.h>
#include <sys/ucontext.h>
#include <unistd.h>

#import "XenraScreens.h"
#import "XenraSettings.h"
#import "XenraXemu.h"
#include "ios_emu.h"
#include "xenia/base/memory.h"

#ifndef XENRA_BUILD_ID
#define XENRA_BUILD_ID "unknown"
#endif

// Runs of each log kept. A crash is usually followed by a launch or two
// before anyone thinks of sharing, and those must not push it out.
static const int kKeptRuns = 3;
// Per log in the report. The head has the device and GPU setup, the tail has
// whatever went wrong.
static const unsigned long long kHeadBytes = 128 * 1024;
static const unsigned long long kTailBytes = 3 * 1024 * 1024;

static NSString* g_notice;
// Filled before the handlers go in: a signal handler cannot build a path.
static char g_crash_path[1024];
static std::atomic_flag g_crashing = ATOMIC_FLAG_INIT;

static NSString* LogsDir(void) {
  NSString* docs = NSSearchPathForDirectoriesInDomains(
                       NSDocumentDirectory, NSUserDomainMask, YES)
                       .firstObject;
  return [docs stringByAppendingPathComponent:@"logs"];
}

static NSString* LogPath(NSString* name) {
  return [LogsDir() stringByAppendingPathComponent:name];
}

static NSString* RunPath(NSString* stem, int run) {
  return LogPath(run ? [NSString stringWithFormat:@"%@.%d.txt", stem, run]
                     : [stem stringByAppendingString:@".txt"]);
}

NSString* XenraLogsCorePath(void) { return RunPath(@"xenra-core", 0); }

static void ShelveRuns(NSString* stem) {
  NSFileManager* files = NSFileManager.defaultManager;
  [files removeItemAtPath:RunPath(stem, kKeptRuns) error:nil];
  for (int run = kKeptRuns - 1; run >= 0; run--) {
    [files moveItemAtPath:RunPath(stem, run)
                   toPath:RunPath(stem, run + 1)
                    error:nil];
  }
}

// --- Crash capture ----------------------------------------------------------
// Async-signal-safe from here to the handler's end: write() and nothing that
// allocates.

static void Put(int fd, const char* text) { write(fd, text, strlen(text)); }

static void PutHex(int fd, uint64_t value) {
  char text[19] = "0x";
  for (int i = 0; i < 16; i++) {
    text[2 + i] = "0123456789abcdef"[(value >> (60 - i * 4)) & 0xF];
  }
  write(fd, text, 18);
}

static void PutField(int fd, const char* name, uint64_t value) {
  Put(fd, name);
  Put(fd, " ");
  PutHex(fd, value);
  Put(fd, "\n");
}

static const char* SignalName(int signal_number) {
  switch (signal_number) {
    case SIGSEGV:
      return "SIGSEGV";
    case SIGBUS:
      return "SIGBUS";
    case SIGILL:
      return "SIGILL";
    case SIGABRT:
      return "SIGABRT";
    case SIGTRAP:
      return "SIGTRAP";
    case SIGFPE:
      return "SIGFPE";
  }
  return "signal";
}

static void CrashHandler(int signal_number, siginfo_t* info, void* context) {
  // Also what stops a bad frame pointer below from recursing: the nested
  // fault lands here and dies with what has been written so far.
  if (g_crashing.test_and_set()) {
    signal(signal_number, SIG_DFL);
    return;
  }
  const int fd = open(g_crash_path, O_WRONLY | O_CREAT | O_APPEND, 0644);
  if (fd >= 0) {
    Put(fd, "Crash: ");
    Put(fd, SignalName(signal_number));
    Put(fd, "\n");
    PutField(fd, "si_code", uint64_t(int64_t(info->si_code)));
    PutField(fd, "fault address", uint64_t(info->si_addr));
    // Subtract from a pc or frame inside the app to get a file offset. One
    // that does not land in the app is generated guest code.
    PutField(fd, "image slide", uint64_t(_dyld_get_image_vmaddr_slide(0)));
    const auto& state = static_cast<ucontext_t*>(context)->uc_mcontext->__ss;
    PutField(fd, "pc", state.__pc);
    PutField(fd, "lr", state.__lr);
    PutField(fd, "sp", state.__sp);
    PutField(fd, "fp", state.__fp);
    for (int i = 0; i < 29; i++) {
      char name[] = "x00";
      name[1] = char('0' + i / 10);
      name[2] = char('0' + i % 10);
      PutField(fd, name, state.__x[i]);
    }
    Put(fd, "frames:\n");
    uint64_t frame = state.__fp;
    for (int i = 0; i < 48 && frame && !(frame & 7); i++) {
      const uint64_t* record = reinterpret_cast<const uint64_t*>(frame);
      PutHex(fd, record[1]);
      Put(fd, "\n");
      if (record[0] <= frame) break;
      frame = record[0];
    }
    close(fd);
  }
  // The logger runs on its own thread: let it reach the disk with the lines
  // leading up to this.
  usleep(200000);
  // Returning re-runs the faulting instruction, or falls back into abort(),
  // and the default action ends the process with a real crash report.
  signal(signal_number, SIG_DFL);
}

static void UncaughtException(NSException* exception) {
  XenraLog([NSString stringWithFormat:@"Uncaught exception: %@: %@\n%@",
                                      exception.name, exception.reason,
                                      exception.callStackSymbols]);
}

static NSString* CrashPath(void) { return LogPath(@"xenra-crash.txt"); }
static NSString* CrashHistoryPath(void) {
  return LogPath(@"xenra-crash-history.txt");
}
static NSString* SessionPath(void) { return LogPath(@"session-open"); }

// Names for the frames, which the handler could not safely look up. System
// libraries keep their addresses until a reboot, so this still works a launch
// later; the app's own frames are named by file offset from "image slide".
static NSString* Symbolicate(NSData* crash) {
  NSString* text = [[NSString alloc] initWithData:crash
                                         encoding:NSUTF8StringEncoding];
  NSMutableString* names = [NSMutableString stringWithString:@"symbols:\n"];
  for (NSString* line in [text componentsSeparatedByString:@"\n"]) {
    NSString* field = [line componentsSeparatedByString:@" "].lastObject;
    if (![field hasPrefix:@"0x"] || [line hasPrefix:@"si_code"]) continue;
    const uint64_t address = strtoull(field.UTF8String, nullptr, 16);
    Dl_info info;
    if (!address || !dladdr(reinterpret_cast<void*>(address), &info) ||
        !info.dli_fname) {
      continue;
    }
    [names appendFormat:@"%@ %s %s+0x%llx\n", field,
                        strrchr(info.dli_fname, '/')
                            ? strrchr(info.dli_fname, '/') + 1
                            : info.dli_fname,
                        info.dli_sname ?: "?",
                        address - uint64_t(info.dli_saddr ?: info.dli_fbase)];
  }
  return names;
}

// A new crash moves into the history at the next launch, stamped then: the
// handler has no safe way to format a date.
static BOOL ArchiveCrash(void) {
  NSData* crash = [NSData dataWithContentsOfFile:CrashPath()];
  if (!crash) return NO;
  NSDate* date = [NSFileManager.defaultManager attributesOfItemAtPath:CrashPath()
                                                                error:nil]
                     .fileModificationDate;
  NSMutableData* entry = [[[NSString stringWithFormat:@"--- %@\n", date]
      dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
  [entry appendData:crash];
  [entry appendData:[Symbolicate(crash) dataUsingEncoding:NSUTF8StringEncoding]];
  if (FILE* f = fopen(CrashHistoryPath().fileSystemRepresentation, "a")) {
    fwrite(entry.bytes, 1, entry.length, f);
    fclose(f);
  }
  [NSFileManager.defaultManager removeItemAtPath:CrashPath() error:nil];
  return YES;
}

void XenraLogsBegin(void) {
  NSFileManager* files = NSFileManager.defaultManager;
  [files createDirectoryAtPath:LogsDir()
      withIntermediateDirectories:YES
                       attributes:nil
                            error:nil];
  const BOOL crashed = ArchiveCrash();
  const BOOL session_open = [files fileExistsAtPath:SessionPath()];
  [files removeItemAtPath:SessionPath() error:nil];
  if (crashed) {
    g_notice = XS(@"Xenra crashed the last time it ran.");
  } else if (session_open) {
    g_notice = XS(@"The last game did not exit cleanly. If you did not close it "
                "yourself, iOS ended it.");
  }

  ShelveRuns(@"xenra-core");
  ShelveRuns(@"xenra-stderr");
  // Where libc++ says which exception ended the process, and assert() what
  // failed. Neither reaches the core log.
  if (freopen(RunPath(@"xenra-stderr", 0).fileSystemRepresentation, "w",
              stderr)) {
    setvbuf(stderr, nullptr, _IONBF, 0);
  }

  strlcpy(g_crash_path, CrashPath().fileSystemRepresentation,
          sizeof(g_crash_path));
  struct sigaction action;
  memset(&action, 0, sizeof(action));
  action.sa_sigaction = CrashHandler;
  action.sa_flags = SA_SIGINFO | SA_ONSTACK;
  for (int signal_number : {SIGSEGV, SIGBUS, SIGILL, SIGABRT, SIGTRAP, SIGFPE}) {
    sigaction(signal_number, &action, nullptr);
  }
  NSSetUncaughtExceptionHandler(UncaughtException);
}

void XenraLogsBeginSession(void) {
  [NSFileManager.defaultManager createFileAtPath:SessionPath()
                                        contents:nil
                                      attributes:nil];
}

void XenraLogsEndSession(void) {
  [NSFileManager.defaultManager removeItemAtPath:SessionPath() error:nil];
}

NSString* XenraLogsTakeUncleanExitNotice(void) {
  NSString* notice = g_notice;
  g_notice = nil;
  return notice;
}

// --- The report -------------------------------------------------------------

static void AppendText(NSFileHandle* out, NSString* text) {
  [out writeData:[text dataUsingEncoding:NSUTF8StringEncoding] error:nil];
}

static void AppendLog(NSFileHandle* out, NSString* title, NSString* path) {
  NSFileHandle* in = [NSFileHandle fileHandleForReadingAtPath:path];
  if (!in) return;
  const unsigned long long size = [in seekToEndOfFile];
  if (!size) return;
  AppendText(out, [NSString stringWithFormat:@"\n\n===== %@ (%llu bytes) =====\n",
                                             title, size]);
  [in seekToFileOffset:0];
  if (size <= kHeadBytes + kTailBytes) {
    [out writeData:[in readDataToEndOfFile] error:nil];
  } else {
    [out writeData:[in readDataOfLength:kHeadBytes] error:nil];
    AppendText(out, [NSString stringWithFormat:@"\n[... %llu bytes cut ...]\n",
                                               size - kHeadBytes - kTailBytes]);
    [in seekToFileOffset:size - kTailBytes];
    [out writeData:[in readDataToEndOfFile] error:nil];
  }
  [in closeFile];
}

static NSString* Summary(void) {
  char model[64] = {0};
  size_t size = sizeof(model) - 1;
  sysctlbyname("hw.model", model, &size, nullptr, 0);
  const NSOperatingSystemVersion os =
      NSProcessInfo.processInfo.operatingSystemVersion;
  const xe::memory::JitSignatureState jit =
      xe::memory::QueryJitSignatureState();
  NSDictionary* info = NSBundle.mainBundle.infoDictionary;
  NSString* docs = LogsDir().stringByDeletingLastPathComponent;
  NSNumber* free_bytes =
      [NSFileManager.defaultManager attributesOfFileSystemForPath:docs error:nil]
          [NSFileSystemFreeSize];

  NSMutableString* text = [NSMutableString string];
  [text appendFormat:@"Xenra iOS logs, %@\n", [NSDate date]];
  [text appendFormat:@"Build: %@ (%@), %s, %@\n",
                     info[@"CFBundleShortVersionString"],
                     info[@"CFBundleVersion"], XENRA_BUILD_ID,
                     NSBundle.mainBundle.bundleIdentifier];
  [text appendFormat:@"Device: %s, iOS %ld.%ld.%ld, %.1f GB RAM, %.1f GB free\n",
                     model, (long)os.majorVersion, (long)os.minorVersion,
                     (long)os.patchVersion,
                     NSProcessInfo.processInfo.physicalMemory / 1073741824.0,
                     free_bytes.doubleValue / 1073741824.0];
  [text appendFormat:@"JIT: get-task-allow=%d cs_debugged=%d script_attached=%d\n",
                     jit.get_task_allow, jit.cs_debugged, XenraXemuNeedsSettle()];
  // The memory iOS lets Xenra use before it is killed. GetMoreRam's "Increased
  // Memory Limit" raises it, but only once Xenra is re-signed with a profile that
  // carries it, so this line is the way to see whether that happened.
  task_vm_info_data_t vm = {};
  mach_msg_type_number_t vm_count = TASK_VM_INFO_COUNT;
  if (task_info(mach_task_self(), TASK_VM_INFO, reinterpret_cast<task_info_t>(&vm),
                &vm_count) == KERN_SUCCESS) {
    const double gb = 1073741824.0;
    [text appendFormat:@"Memory: limit %.2f GB (in use %.2f, left %.2f)\n",
                       (vm.phys_footprint + vm.limit_bytes_remaining) / gb,
                       vm.phys_footprint / gb, vm.limit_bytes_remaining / gb];
  }
  int lse = 0;
  size_t lse_size = sizeof(lse);
  sysctlbyname("hw.optional.armv8_1_atomics", &lse, &lse_size, nullptr, 0);
  id<MTLDevice> gpu = MTLCreateSystemDefaultDevice();
  int family = 0;
  for (int i = 1; i <= 9; i++) {
    if ([gpu supportsFamily:MTLGPUFamily(MTLGPUFamilyApple1 + i - 1)]) family = i;
  }
  [text appendFormat:@"CPU: LSE=%d. GPU: %@, Apple%d, argument buffers tier %d\n",
                     lse, gpu.name, family,
                     int(gpu.argumentBuffersSupport) + 1];
  [text appendFormat:@"Core status: %d %s\n", xe_ios_status(),
                     xe_ios_status_detail()];

  [text appendString:@"\nSettings:\n"];
  for (XenraSettingTab* tab in [XenraSettings tabs]) {
    for (XenraSettingSection* section in tab.sections) {
      for (XenraSettingRow* row in section.rows) {
        if (row.kind == XenraRowAction) continue;
        [text appendFormat:@"  %@ = %@\n", row.key,
                           [XenraSettings valueForRow:row game:nil]];
      }
    }
  }

  [text appendString:@"\nGames folder:\n"];
  NSString* games = [docs stringByAppendingPathComponent:@"Games"];
  for (NSString* name in [NSFileManager.defaultManager
           contentsOfDirectoryAtPath:games
                               error:nil]) {
    NSDictionary* attributes = [NSFileManager.defaultManager
        attributesOfItemAtPath:[games stringByAppendingPathComponent:name]
                         error:nil];
    [text appendFormat:@"  %@ (%llu bytes)\n", name, attributes.fileSize];
  }
  return text;
}

static NSURL* BuildReport(void) {
  NSDateFormatter* format = [[NSDateFormatter alloc] init];
  format.dateFormat = @"yyyyMMdd-HHmmss";
  NSString* tmp = NSTemporaryDirectory();
  NSFileManager* files = NSFileManager.defaultManager;
  for (NSString* name in [files contentsOfDirectoryAtPath:tmp error:nil]) {
    if ([name hasPrefix:@"xenra-logs-"]) {
      [files removeItemAtPath:[tmp stringByAppendingPathComponent:name]
                        error:nil];
    }
  }
  NSString* path = [tmp
      stringByAppendingPathComponent:
          [NSString stringWithFormat:@"xenra-logs-%@.txt",
                                     [format stringFromDate:[NSDate date]]]];
  if (![files createFileAtPath:path contents:nil attributes:nil]) return nil;
  NSFileHandle* out = [NSFileHandle fileHandleForWritingAtPath:path];
  AppendText(out, Summary());
  AppendLog(out, @"Crash reports", CrashHistoryPath());
  AppendLog(out, @"App log", XenraLogPath());
  AppendLog(out, @"Core log, this run", RunPath(@"xenra-core", 0));
  AppendLog(out, @"stderr, this run", RunPath(@"xenra-stderr", 0));
  for (int run = 1; run <= kKeptRuns; run++) {
    NSString* age = [NSString stringWithFormat:@"%d run(s) ago", run];
    AppendLog(out, [@"Core log, " stringByAppendingString:age],
              RunPath(@"xenra-core", run));
    AppendLog(out, [@"stderr, " stringByAppendingString:age],
              RunPath(@"xenra-stderr", run));
  }
  [out closeFile];
  return [NSURL fileURLWithPath:path];
}

void XenraShareLogs(UIViewController* controller, void (^done)(void)) {
  xe_ios_flush_log();
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    NSURL* report = BuildReport();
    dispatch_async(dispatch_get_main_queue(), ^{
      if (!report) {
        if (done) done();
        return;
      }
      UIActivityViewController* share =
          [[UIActivityViewController alloc] initWithActivityItems:@[ report ]
                                            applicationActivities:nil];
      share.completionWithItemsHandler =
          ^(UIActivityType, BOOL, NSArray*, NSError*) {
            if (done) done();
          };
      // A popover on iPad: without an anchor UIKit throws.
      UIView* view = controller.view;
      share.popoverPresentationController.sourceView = view;
      share.popoverPresentationController.sourceRect = CGRectMake(
          CGRectGetMidX(view.bounds), CGRectGetMidY(view.bounds), 1, 1);
      share.popoverPresentationController.permittedArrowDirections = 0;
      [controller presentViewController:share animated:YES completion:nil];
    });
  });
}
