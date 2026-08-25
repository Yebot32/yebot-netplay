/**
 ******************************************************************************
 * Xenra : iOS port                                                           *
 ******************************************************************************
 * Released under the BSD license - see LICENSE in the root for more details. *
 ******************************************************************************
 */

// iOS replacement for <XEN>/src/xenia/base/system_mac.cc.
//
// system_mac.cc cannot cross to iOS: it shells out via system() for both
// LaunchWebBrowser ("open <url>") and ShowSimpleMessageBox ("osascript -e
// 'display dialog ...'"). system() is declared __API_UNAVAILABLE(ios) in the
// iOS SDK - a hard compile error, not a runtime no-op - and osascript has
// never existed on iOS. Everything else in base's *_mac.cc set
// (autorelease_pool_mac, debugging_mac's sysctl is-debugger-attached probe)
// is correct on iOS unchanged, so this file replaces exactly one TU.
//
// It lives HERE, in XenDroid/ios/, rather than as
// <XEN>/src/xenia/base/system_ios.mm, for the same reason upnp.cc is wired
// from XenDroid/emulator-core/src/main/cpp/CMakeLists.txt: the vendored xenia
// tree stays byte-identical to upstream and keeps merging cleanly. If the iOS
// port graduates past milestone 1 this should move into the tree proper and
// `_ios` should be added to XE_PLATFORM_SUFFIXES in cmake/XeniaHelpers.cmake -
// see XenDroid/docs/ios-build.md.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#include "xenia/base/logging.h"
#include "xenia/base/system.h"

namespace xe {

void LaunchWebBrowser(const std::string_view url) {
  @autoreleasepool {
    NSString* string = [[NSString alloc]
        initWithBytes:url.data()
               length:static_cast<NSUInteger>(url.size())
             encoding:NSUTF8StringEncoding];
    NSURL* ns_url = [NSURL URLWithString:string];
    if (!ns_url) {
      XELOGE("LaunchWebBrowser: not a URL: {}", url);
      return;
    }
    // openURL: is main-thread-only and asynchronous. Callers of this are all
    // UI-initiated, but the emulator calls a lot of things off the main
    // thread, so hop explicitly rather than trip an assertion inside UIKit.
    dispatch_async(dispatch_get_main_queue(), ^{
      [[UIApplication sharedApplication] openURL:ns_url
                                         options:@{}
                               completionHandler:nil];
    });
  }
}

void LaunchFileExplorer(const std::filesystem::path& path) {
  // There is no Finder on iOS. The nearest equivalent is a UIDocumentPicker
  // rooted at the path, which needs a view controller to present from and so
  // belongs in the app shell, not in base. Log rather than silently do
  // nothing, so a caller that expected this to work leaves a trace.
  XELOGW("LaunchFileExplorer is not implemented on iOS (path: {})",
         path.string());
}

void ShowSimpleMessageBox(SimpleMessageBoxType type, std::string_view message) {
  // The contract in system.h is "blocks the caller until the message box is
  // closed". A UIAlertController cannot honour that: it needs the main thread
  // to pump in order to be dismissed, so blocking the caller when the caller
  // IS the main thread deadlocks the app - and blocking a worker thread on a
  // UI event is exactly how the NetDll_select fiber starvation bug looked.
  //
  // Milestone 1 therefore logs instead. Milestone 2 should give the app shell
  // a real presenter and route this through it; the honest fix is to change
  // the contract to non-blocking, not to fake a semaphore here.
  const char* level;
  switch (type) {
    case SimpleMessageBoxType::Help:
      level = "help";
      break;
    case SimpleMessageBoxType::Warning:
      level = "warning";
      break;
    default:
    case SimpleMessageBoxType::Error:
      level = "error";
      break;
  }
  XELOGE("ShowSimpleMessageBox [{}]: {}", level, message);
}

bool SetProcessPriorityClass(const uint32_t priority_class) {
  // Same answer as macOS: there is no process priority class to set. iOS
  // additionally will not let a foreground app raise its own QoS.
  return true;
}

bool IsUseNexusForGameBarEnabled() {
  // Windows Game Bar. Always false off Windows.
  return false;
}

}  // namespace xe
