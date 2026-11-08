#import "XenraAppDelegate.h"
#import "XenraStrings.h"

#include <cstdio>
#include <mach/mach.h>
#include <sys/sysctl.h>
#include <unistd.h>

#import "XenraJitProbe.h"
#import "XenraLogs.h"
#import "XenraSampler.h"
#import "XenraScreens.h"
#import "XenraSettings.h"
#include "ios_emu.h"
#include "xenia/base/memory.h"

// Pure C file I/O on purpose: the log has to work when the rest does not.
NSString* XenraLogPath(void) {
  static NSString* path;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    NSString* docs = NSSearchPathForDirectoriesInDomains(
                         NSDocumentDirectory, NSUserDomainMask, YES)
                         .firstObject;
    path = [docs stringByAppendingPathComponent:@"xenra-jit-log.txt"];
  });
  return path;
}

void XenraLog(NSString* line) {
  const char* path = XenraLogPath().fileSystemRepresentation;
  if (FILE* f = fopen(path, "a")) {
    fprintf(f, "%s\n", line.UTF8String);
    fclose(f);
  }
}

BOOL XenraJitActive(void) {
  return xe::memory::QueryJitSignatureState().cs_debugged;
}

NSString* XenraJitStatusText(void) {
  const xe::memory::JitSignatureState state =
      xe::memory::QueryJitSignatureState();
  if (state.cs_debugged) {
    return XS(@"JIT is on.");
  }
  if (!state.get_task_allow) {
    return XS(@"This install has no get-task-allow, so iOS will refuse JIT. "
            "Reinstall with a development certificate, as SideStore, AltStore "
            "or Sideloadly use. Distribution certificates cannot carry it.");
  }
  return XS(@"Waiting for JIT.\nEnable it for Xenra in StikDebug, then come back. "
          "The game starts by itself.");
}

void XenraOpenJitEnabler(void) {
  // The bundle id is read at runtime because signers add their own suffix.
  NSURLComponents* url = [[NSURLComponents alloc] init];
  url.scheme = @"stikjit";
  url.host = @"enable-jit";
  NSMutableArray<NSURLQueryItem*>* items = [NSMutableArray arrayWithObjects:
      [NSURLQueryItem queryItemWithName:@"bundle-id"
                                  value:NSBundle.mainBundle.bundleIdentifier],
      [NSURLQueryItem queryItemWithName:@"pid"
                                  value:@(getpid()).stringValue], nil];
  // Always from iOS 26, as DukeX does. StikDebug skips the script where it thinks
  // the device has no TXM, and it thinks that of an M1: without the script the M1 on
  // iOS 27 shows CS_DEBUGGED but faults on every page of generated code.
  if (NSProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26) {
    [items addObject:[NSURLQueryItem queryItemWithName:@"script-name"
                                                 value:@"universal.js"]];
  }
  url.queryItems = items;
  XenraLog([NSString stringWithFormat:@"JIT handoff: %@", url.URL]);
  [UIApplication.sharedApplication openURL:url.URL
                                   options:@{}
                         completionHandler:nil];
}

#ifdef XENRA_UITEST
void XenraTourStart(UIWindow* window);
#endif

@implementation XenraAppDelegate

- (BOOL)application:(UIApplication*)application
    didFinishLaunchingWithOptions:(NSDictionary*)launchOptions {
  XenraLogsBegin();

  self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
  self.window.backgroundColor = UIColor.blackColor;

  [XenraSettings holdPickedFiles];
  self.window.rootViewController = XenraMakeRoot(XenraDashboardEntryPlain);
#ifdef XENRA_UITEST
  XenraJitChooseScheme();
  XenraLog(XenraJitReport());
  XenraSamplerDump(@"tour");
  XenraTourStart(self.window);
#endif
  [self.window makeKeyAndVisible];

  NSString* docs = NSSearchPathForDirectoriesInDomains(
                       NSDocumentDirectory, NSUserDomainMask, YES)
                       .firstObject;
  NSString* caches = NSSearchPathForDirectoriesInDomains(
                         NSCachesDirectory, NSUserDomainMask, YES)
                         .firstObject;
  const int rc = xe_ios_initialize(docs.UTF8String, caches.UTF8String,
                                   XenraLogsCorePath().UTF8String);

  char model[64] = {0};
  size_t size = sizeof(model) - 1;
  sysctlbyname("hw.model", model, &size, nullptr, 0);
  const NSOperatingSystemVersion os =
      NSProcessInfo.processInfo.operatingSystemVersion;
  const xe::memory::JitSignatureState jit =
      xe::memory::QueryJitSignatureState();
  XenraLog([NSString
      stringWithFormat:@"=== %@ | %s | iOS %ld.%ld | %@ | get-task-allow=%d "
                        "cs_debugged=%d | core init %d ===",
                       [NSDate date], model, (long)os.majorVersion,
                       (long)os.minorVersion,
                       NSBundle.mainBundle.bundleIdentifier, jit.get_task_allow,
                       jit.cs_debugged, rc]);
#ifndef XENRA_UITEST
  // StikDebug relaunches the app rather than returning to it, so the game that
  // asked for JIT has to be picked up again here. After the first layout pass:
  // the root screen has to exist before anything is pushed on it.
  dispatch_async(dispatch_get_main_queue(), ^{
    XenraGameController* game = [XenraGameController takePendingAfterJit];
    auto* navigation = (UINavigationController*)self.window.rootViewController;
    if (game && [XenraSettings setupComplete]) {
      [navigation pushViewController:game animated:NO];
    }
  });
#endif
  return YES;
}

- (void)applicationDidReceiveMemoryWarning:(UIApplication*)application {
  task_vm_info_data_t vm = {};
  mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
  double footprint_gb = 0.0;
  if (task_info(mach_task_self(), TASK_VM_INFO,
                reinterpret_cast<task_info_t>(&vm),
                &count) == KERN_SUCCESS) {
    footprint_gb = vm.phys_footprint / 1073741824.0;
  }
  XenraLog([NSString
      stringWithFormat:@"memory warning: footprint %.2f GB", footprint_gb]);
}

@end
