#import "XenraAppDelegate.h"

#include <cstdio>
#include <sys/sysctl.h>
#include <unistd.h>

#import "XenraLogs.h"
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
    return @"JIT is on.";
  }
  if (!state.get_task_allow) {
    return @"This install has no get-task-allow, so iOS will refuse JIT. "
            "Reinstall with a development certificate, as SideStore, AltStore "
            "or Sideloadly use. Distribution certificates cannot carry it.";
  }
  return @"Waiting for JIT.\nEnable it in StikDebug, with universal.js assigned "
          "to Xenra, then come back. Keep the tool attached until the game "
          "has started.";
}

void XenraOpenJitEnabler(void) {
  // The bundle id is read at runtime because signers add their own suffix.
  NSURLComponents* url = [[NSURLComponents alloc] init];
  url.scheme = @"stikjit";
  url.host = @"enable-jit";
  url.queryItems = @[ [NSURLQueryItem
      queryItemWithName:@"bundle-id"
                  value:NSBundle.mainBundle.bundleIdentifier] ];
  XenraLog([NSString stringWithFormat:@"JIT handoff: %@", url.URL]);
  [UIApplication.sharedApplication openURL:url.URL
                                   options:@{}
                         completionHandler:nil];
}

@implementation XenraAppDelegate

- (BOOL)application:(UIApplication*)application
    didFinishLaunchingWithOptions:(NSDictionary*)launchOptions {
  XenraLogsBegin();

  self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
  self.window.backgroundColor = UIColor.blackColor;

  [XenraSettings holdGameFolder];
  self.window.rootViewController = XenraMakeRoot(XenraDashboardEntryPlain);
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
  return YES;
}

@end
