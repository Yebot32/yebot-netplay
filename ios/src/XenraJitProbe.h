/**
 ******************************************************************************
 * Xenra : iOS shell - which way of running generated code works here         *
 ******************************************************************************
 *
 * Apple's rules on this differ by chip and iOS version and are undocumented. A
 * wrong guess does not fail cleanly: on an M1 with iOS 27 the core stalled on its
 * first block of generated code with no signal and no crash. So the app asks the
 * hardware: it tries each memory layout on a small region, on a thread it can
 * abandon, and uses the first that really runs code, patches it and runs it again.
 * A layout that hangs, faults or takes the process down is never tried again.
 */

#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, XenraJitScheme) {
  // Born executable, then a writable alias of the same pages. Dolphin's layout
  // for pre-TXM devices on iOS 26.
  XenraJitRxFirst,
  // One mapping, readable, writable and executable at once.
  XenraJitRwx,
  // Born writable, then an executable alias: QEMU's own split-wx.
  XenraJitRwFirst,
  XenraJitNone,
};

// The first layout that works. Needs JIT to be enabled. The result is cached for
// the launch.
XenraJitScheme XenraJitChooseScheme(void);

// One line per layout, for the log.
NSString* XenraJitReport(void);
