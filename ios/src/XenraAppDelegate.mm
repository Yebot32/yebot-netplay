/**
 ******************************************************************************
 * Xenra : iOS shell                                                          *
 ******************************************************************************
 *
 * Milestone 2: the launcher.
 *
 * Two screens, one view controller:
 *   - Library: the pipeline-check readout (JIT signature state, Metal, the
 *     JIT-probe detail), a StikDebug handoff button, and the game list from
 *     Documents/Games. Launching a title is gated on the live JIT probe - the
 *     360 core has no PowerPC interpreter, so booting without JIT is a
 *     guaranteed hang, not a risk.
 *   - Game: the Metal view fullscreen plus a minimal on-screen controller,
 *     driven through ios_emu.mm's C API. One title per process; "Exit" ends
 *     the process (config, saves and shader caches are all on disk).
 */

#import "XenraAppDelegate.h"

#import <Metal/Metal.h>
#import <UIKit/UIKit.h>

#include <cstdlib>    // quick_exit, for the boot-phase exit path
#include <string>
#include <sys/sysctl.h>
#include <unistd.h>  // getpid, for the StikDebug handoff URL

#include "XenraBladeCell.h"
#include "XenraBladeView.h"
#include "XenraGameScanner.h"
#include "XenraMetalView.h"
#include "XenraTheme.h"
#include "ios_emu.h"

#include "xenia/base/memory.h"
#include "xenia/hid/input.h"  // X_INPUT_GAMEPAD_* for the virtual pad
#include "xenia/ui/surface_ios.h"

namespace {

// iOS 26 and later carry TXM/SPTM on supported hardware, where JIT needs the
// universal breakpoint protocol and therefore the enabler's script - not just
// a debugger attach. On those versions the StikDebug handoff always names the
// script; on older iOS a plain attach is enough and the parameter is omitted,
// exactly as the StikJIT integration guide specifies.
bool IsIos26OrLater() {
  return [NSProcessInfo processInfo].operatingSystemVersion.majorVersion >= 26;
}

// Monotonic per-launch session number, persisted across launches. Every entry
// into the app increments it once; it prefixes everything the app shows and
// logs, so reports sent for debugging are ordered unambiguously.
NSInteger SessionNumber() {
  static NSInteger n = 0;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    n = [[NSUserDefaults standardUserDefaults]
            integerForKey:@"xenra_session_counter"] + 1;
    [[NSUserDefaults standardUserDefaults] setInteger:n
                                               forKey:@"xenra_session_counter"];
  });
  return n;
}

// The rolling diagnostics file: one numbered block per session, one line per
// probe whose result changed. Lives in Documents so it is visible in the
// Files app (UIFileSharingEnabled) and can be sent whole.
NSString* DiagnosticsLogPath() {
  static NSString* path = nil;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    NSString* docs = NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    // MRC: stringByAppendingPathComponent returns an AUTORELEASED string.
    // Stored in a static it would be freed at the next pool drain and leave
    // this pointer dangling - the second caller would message whatever
    // object reused the memory (crash 2026-08-29 16:42:07, reported as
    // "-[UILayoutGuide fileSystemRepresentation]"). Retain for the static.
    path = [[docs stringByAppendingPathComponent:@"xenra-jit-log.txt"] retain];
  });
  return path;
}

void AppendDiagnostics(NSString* line) {
  // Pure C file I/O: the Foundation stat/bridge path aborted under MRC once
  // already (crash 2026-08-29 16:01:16 - _NSFileManagerBridge forwarding),
  // and a diagnostics writer must be the most robust code in the app.
  NSString* path = DiagnosticsLogPath();
  const char* cpath = path.fileSystemRepresentation;

  // Rotate before the file gets silly; .old keeps the previous half.
  FILE* probe = fopen(cpath, "rb");
  if (probe) {
    fseek(probe, 0, SEEK_END);
    long size = ftell(probe);
    fclose(probe);
    if (size > 256 * 1024) {
      NSString* old = [path stringByAppendingString:@".old"];
      [[NSFileManager defaultManager] removeItemAtPath:old error:nil];
      rename(cpath, old.fileSystemRepresentation);
    }
  }

  FILE* f = fopen(cpath, "a");
  if (!f) {
    return;
  }
  fprintf(f, "%s\n", line.UTF8String);
  fclose(f);
}

NSString* DeviceAndOsLine() {
  char model[64] = {0};
  size_t len = sizeof(model) - 1;
  sysctlbyname("hw.model", model, &len, nullptr, 0);
  NSOperatingSystemVersion v =
      [NSProcessInfo processInfo].operatingSystemVersion;
  return [NSString stringWithFormat:@"%s | iOS %ld.%ld", model,
                                    (long)v.majorVersion,
                                    (long)v.minorVersion];
}

NSString* DocumentsGamesDir() {
  NSArray* dirs = NSSearchPathForDirectoriesInDomains(
      NSDocumentDirectory, NSUserDomainMask, YES);
  return [dirs.firstObject stringByAppendingPathComponent:@"Games"];
}

// Runs the same probe the emulator would, fresh each call, so what is
// displayed here is not a separate reimplementation that could drift from the
// real answer. One probe per refresh: on iOS 26+ every probe prepares a page
// through the enabler's script, so the caller probes exactly once.
NSString* DescribeJitStatus(const xe::memory::JitStatus& status) {
  const char* label =
      xe::memory::JitCapabilityToShortString(status.capability);
  NSString* detail = [NSString stringWithUTF8String:status.detail.c_str()];

  // The raw signature state, straight from csops - the two bits that decide
  // everything, so a "no" on this screen says WHICH precondition failed.
  const xe::memory::JitSignatureState sig =
      xe::memory::QueryJitSignatureState();
  NSString* signature;
  if (!sig.queried) {
    signature = @"Signature: unknown (csops unavailable)";
  } else {
    signature = [NSString
        stringWithFormat:@"Signature: get-task-allow=%@  cs_debugged=%@",
                         sig.get_task_allow ? @"YES" : @"NO",
                         sig.cs_debugged ? @"YES" : @"NO"];
  }

  if (status.capability == xe::memory::JitCapability::kUnavailable) {
    return [NSString
        stringWithFormat:@"JIT: %s\n%@\n%@\n\nThe 360 core cannot run without "
                         @"it - there is no PowerPC interpreter to fall back "
                         @"on.",
                         label, signature, detail];
  }
  return [NSString stringWithFormat:@"JIT: %s\n%@\n%@", label, signature,
                                    detail];
}

NSString* DescribeMetal(id<MTLDevice> device) {
  if (!device) {
    return @"Metal: NO DEVICE";
  }
  // Apple7 is the M1 family. The Metal backend gates mesh shaders and a few
  // other paths on this, so it is worth reporting rather than inferring from
  // the model name.
  NSString* family = @"below Apple7";
  if ([device supportsFamily:MTLGPUFamilyApple9]) {
    family = @"Apple9+";
  } else if ([device supportsFamily:MTLGPUFamilyApple8]) {
    family = @"Apple8";
  } else if ([device supportsFamily:MTLGPUFamilyApple7]) {
    family = @"Apple7";
  }
  return [NSString stringWithFormat:@"Metal: %@ (%@)", device.name, family];
}

}  // namespace

@interface XenraAppDelegate () <UITableViewDataSource, UITableViewDelegate>
@property(nonatomic, retain) UIViewController* rootController;
@property(nonatomic, retain) XenraDashboardBackground* dashboard;
@property(nonatomic, retain) UILabel* titleLabel;
@property(nonatomic, retain) UIButton* menuButton;
@property(nonatomic, retain) UIButton* stikDebugButton;
@property(nonatomic, retain) UIView* statusPanel;
@property(nonatomic, retain) UILabel* statusLabel;
@property(nonatomic, retain) UITableView* gamesTable;
@property(nonatomic, retain) UILabel* emptyLabel;
@property(nonatomic, retain) id<MTLDevice> device;
@property(nonatomic, assign) NSInteger probeCount;
@property(nonatomic, retain) NSTimer* probeTimer;
@property(nonatomic, retain) XenraGameScanner* scanner;
@property(nonatomic, retain) NSArray<NSString*>* games;
@property(nonatomic, retain) UIView* gameView;
@property(nonatomic, retain) XenraMetalView* metalView;
@property(nonatomic, retain) CADisplayLink* displayLink;
@property(nonatomic, retain) UILabel* hudLabel;
@property(nonatomic, assign) int coreInitRc;
@property(nonatomic, retain) NSString* lastLoggedProbe;
@end

// Private methods used before their definitions (called from blocks /
// selectors), so the strict-prototype build has them declared.
@interface XenraAppDelegate ()
- (void)gamesScanned:(NSArray<XenraGameEntry*>*)games;
- (void)showOverflowMenu;
@end

// Manual reference counting (see ios/CMakeLists.txt), matching the rest of
// the tree.
@implementation XenraAppDelegate {
  // Virtual-pad touch bookkeeping (main thread only).
  int buttons_;
  short stickLX_, stickLY_, stickRX_, stickRY_;
  unsigned char triggerLT_, triggerRT_;
}

- (BOOL)application:(UIApplication*)application
    didFinishLaunchingWithOptions:(NSDictionary*)launchOptions {
  self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];

  UIViewController* root = [[UIViewController alloc] init];
  root.view.backgroundColor = UIColor.blackColor;
  self.rootController = root;

  [self buildLibraryScreen];

  self.window.rootViewController = root;
  [self.window makeKeyAndVisible];

  self.device = MTLCreateSystemDefaultDevice();

  int rc = xe_ios_initialize(
      DocumentsGamesDir().stringByDeletingLastPathComponent.UTF8String,
      NSTemporaryDirectory().UTF8String);
  self.coreInitRc = rc;

  // Background library scan (Android's background gather), delivered as a
  // batch to the main thread.
  XenraGameScanner* scanner = [[XenraGameScanner alloc] init];
  self.scanner = scanner;
  [scanner release];
  [self.scanner scanWithCompletion:^(NSArray<XenraGameEntry*>* games) {
    [self gamesScanned:games];
  }];

  {
    const xe::memory::JitSignatureState sig =
        xe::memory::QueryJitSignatureState();
    AppendDiagnostics([NSString
        stringWithFormat:
            @"=== session #%ld | %@ | %@ | bundle %@ | get-task-allow=%@ "
             "cs_debugged=%@ | core init %d ===",
            (long)SessionNumber(), [NSDate date], DeviceAndOsLine(),
            NSBundle.mainBundle.bundleIdentifier,
            sig.get_task_allow ? @"YES" : @"NO",
            sig.cs_debugged ? @"YES" : @"NO", rc]);
  }

  [self refreshStatus];

  // The JIT answer is a moving target on iOS: the enabler attaches seconds
  // after launch, and only that attach (plus, on iOS 26+, its script
  // preparing the executable regions) lets generated code run. Re-probe on a
  // timer until the answer is known; each pass is cheap.
  self.probeTimer =
      [NSTimer scheduledTimerWithTimeInterval:2.0
                                       target:self
                                     selector:@selector(refreshStatus)
                                     userInfo:nil
                                      repeats:YES];

  return YES;
}

- (void)buildLibraryScreen {
  UIView* view = self.rootController.view;

  // The Android dashboard base: gradient + radial gold glow.
  self.dashboard = [[XenraDashboardBackground alloc] initWithFrame:CGRectZero];
  self.dashboard.translatesAutoresizingMaskIntoConstraints = NO;
  [view addSubview:self.dashboard];
  [self.dashboard release];

  // Header: the app title in the accent colour, and the overflow menu on the
  // right (Android's library header).
  self.titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
  self.titleLabel.text = @"XENRA";
  self.titleLabel.textColor = XenraAccent();
  self.titleLabel.font =
      [UIFont systemFontOfSize:24.0 weight:UIFontWeightBold];
  self.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
  [view addSubview:self.titleLabel];
  [self.titleLabel release];

  self.menuButton = [UIButton buttonWithType:UIButtonTypeSystem];
  [self.menuButton setTitle:@"···" forState:UIControlStateNormal];
  self.menuButton.titleLabel.font =
      [UIFont boldSystemFontOfSize:20.0];
  [self.menuButton setTitleColor:XenraAccent() forState:UIControlStateNormal];
  [self.menuButton addTarget:self
                      action:@selector(showOverflowMenu)
            forControlEvents:UIControlEventTouchUpInside];
  self.menuButton.translatesAutoresizingMaskIntoConstraints = NO;
  [view addSubview:self.menuButton];
  [self.menuButton release];

  // Status panel: the pipeline-check readout, in a blade.
  self.statusPanel = [[XenraBladeView alloc] initWithFrame:CGRectZero];
  self.statusPanel.translatesAutoresizingMaskIntoConstraints = NO;
  [view addSubview:self.statusPanel];
  [self.statusPanel release];

  self.statusLabel = [[UILabel alloc] initWithFrame:CGRectZero];
  self.statusLabel.numberOfLines = 0;
  self.statusLabel.textColor = XenraText();
  self.statusLabel.font = [UIFont monospacedSystemFontOfSize:11.0
                                                      weight:UIFontWeightRegular];
  self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
  [self.statusPanel addSubview:self.statusLabel];
  [self.statusLabel release];

  UITapGestureRecognizer* tap =
      [[UITapGestureRecognizer alloc] initWithTarget:self
                                              action:@selector(refreshStatus)];
  [self.statusPanel addGestureRecognizer:tap];
  self.statusPanel.userInteractionEnabled = YES;
  [tap release];

  // JIT handoff as a compact blade-style button under the status panel.
  self.stikDebugButton = [UIButton buttonWithType:UIButtonTypeSystem];
  [self.stikDebugButton setTitle:@"⚡ Enable JIT via StikDebug"
                        forState:UIControlStateNormal];
  self.stikDebugButton.titleLabel.font =
      [UIFont boldSystemFontOfSize:14.0];
  [self.stikDebugButton setTitleColor:XenraBladeSelectedText()
                             forState:UIControlStateNormal];
  self.stikDebugButton.backgroundColor = XenraAccent();
  self.stikDebugButton.layer.cornerRadius = 8.0;
  self.stikDebugButton.contentEdgeInsets =
      UIEdgeInsetsMake(8.0, 14.0, 8.0, 14.0);
  [self.stikDebugButton addTarget:self
                           action:@selector(openStikDebug)
                 forControlEvents:UIControlEventTouchUpInside];
  self.stikDebugButton.translatesAutoresizingMaskIntoConstraints = NO;
  [view addSubview:self.stikDebugButton];
  [self.stikDebugButton release];

  self.gamesTable = [[UITableView alloc] initWithFrame:CGRectZero
                                                 style:UITableViewStylePlain];
  self.gamesTable.backgroundColor = UIColor.clearColor;
  self.gamesTable.separatorStyle = UITableViewCellSeparatorStyleNone;
  self.gamesTable.dataSource = self;
  self.gamesTable.delegate = self;
  self.gamesTable.translatesAutoresizingMaskIntoConstraints = NO;
  [view addSubview:self.gamesTable];
  [self.gamesTable release];

  self.emptyLabel = [[UILabel alloc] initWithFrame:CGRectZero];
  self.emptyLabel.numberOfLines = 0;
  self.emptyLabel.textAlignment = NSTextAlignmentCenter;
  self.emptyLabel.textColor = XenraTextMuted();
  self.emptyLabel.font = [UIFont systemFontOfSize:14.0];
  self.emptyLabel.text =
      @"No games yet.\n\nCopy .iso / .god / .xex files into the app's "
      @"Documents/Games folder (Files app, or Finder over USB), then tap "
      @"the status panel to rescan.";
  self.emptyLabel.translatesAutoresizingMaskIntoConstraints = NO;
  [view addSubview:self.emptyLabel];
  [self.emptyLabel release];

  UILayoutGuide* safe = view.safeAreaLayoutGuide;
  [NSLayoutConstraint activateConstraints:@[
    [self.dashboard.leadingAnchor constraintEqualToAnchor:view.leadingAnchor],
    [self.dashboard.trailingAnchor
        constraintEqualToAnchor:view.trailingAnchor],
    [self.dashboard.topAnchor constraintEqualToAnchor:view.topAnchor],
    [self.dashboard.bottomAnchor
        constraintEqualToAnchor:view.bottomAnchor],

    [self.titleLabel.leadingAnchor
        constraintEqualToAnchor:safe.leadingAnchor constant:16.0],
    [self.titleLabel.topAnchor constraintEqualToAnchor:safe.topAnchor
                                              constant:8.0],
    [self.menuButton.trailingAnchor
        constraintEqualToAnchor:safe.trailingAnchor constant:-12.0],
    [self.menuButton.centerYAnchor
        constraintEqualToAnchor:self.titleLabel.centerYAnchor],

    [self.statusPanel.leadingAnchor
        constraintEqualToAnchor:safe.leadingAnchor constant:16.0],
    [self.statusPanel.trailingAnchor
        constraintEqualToAnchor:safe.trailingAnchor constant:-16.0],
    [self.statusPanel.topAnchor
        constraintEqualToAnchor:self.titleLabel.bottomAnchor constant:10.0],

    [self.statusLabel.leadingAnchor
        constraintEqualToAnchor:self.statusPanel.leadingAnchor constant:14.0],
    [self.statusLabel.trailingAnchor
        constraintEqualToAnchor:self.statusPanel.trailingAnchor constant:-14.0],
    [self.statusLabel.topAnchor
        constraintEqualToAnchor:self.statusPanel.topAnchor constant:12.0],
    [self.statusLabel.bottomAnchor
        constraintEqualToAnchor:self.statusPanel.bottomAnchor constant:-12.0],

    [self.stikDebugButton.centerXAnchor
        constraintEqualToAnchor:view.centerXAnchor],
    [self.stikDebugButton.topAnchor
        constraintEqualToAnchor:self.statusPanel.bottomAnchor constant:10.0],

    [self.gamesTable.leadingAnchor
        constraintEqualToAnchor:safe.leadingAnchor],
    [self.gamesTable.trailingAnchor
        constraintEqualToAnchor:safe.trailingAnchor],
    [self.gamesTable.topAnchor
        constraintEqualToAnchor:self.stikDebugButton.bottomAnchor constant:10.0],
    [self.gamesTable.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor],

    [self.emptyLabel.centerXAnchor constraintEqualToAnchor:view.centerXAnchor],
    [self.emptyLabel.centerYAnchor
        constraintEqualToAnchor:self.gamesTable.centerYAnchor],
    [self.emptyLabel.leadingAnchor
        constraintEqualToAnchor:safe.leadingAnchor constant:32.0],
    [self.emptyLabel.trailingAnchor
        constraintEqualToAnchor:safe.trailingAnchor constant:-32.0],
  ]];
}

- (void)refreshStatus {
  ++self.probeCount;

  // Exactly one probe per refresh - see DescribeJitStatus.
  const xe::memory::JitStatus fresh = xe::memory::QueryJitStatusRefresh();

  NSMutableString* text = [NSMutableString string];
  [text appendFormat:@"re-test #%ld  (tap to re-test)\n\n",
                     (long)self.probeCount];
  [text appendFormat:@"%@\n\n", DescribeJitStatus(fresh)];
  // eSign appends its team-id suffix to the bundle id, and StikDebug matches
  // scripts to apps BY bundle id - the assignment has to target exactly this
  // string, so show it rather than make anyone guess.
  [text appendFormat:@"Bundle ID for StikDebug script assignment: %@\n\n",
                     NSBundle.mainBundle.bundleIdentifier];
  [text appendFormat:@"%@\n\n", DescribeMetal(self.device)];

  const int status = xe_ios_status();
  if (status != 0) {
    [text appendFormat:@"Core: %d (%s)\n", status, xe_ios_status_detail()];
  }
  if (self.coreInitRc != 0) {
    [text appendFormat:@"Core init FAILED (%d) - see xenra-jit-log.txt\n",
                       self.coreInitRc];
  }

  // Log the probe: the first of the session, and any change afterwards.
  NSString* probeLine = [NSString
      stringWithFormat:@"session #%ld probe #%ld: %s | %@",
                       (long)SessionNumber(), (long)self.probeCount,
                       xe::memory::JitCapabilityToShortString(
                           fresh.capability),
                       [NSString stringWithUTF8String:fresh.detail.c_str()]];
  if (!self.lastLoggedProbe ||
      ![probeLine isEqualToString:self.lastLoggedProbe]) {
    AppendDiagnostics(probeLine);
    self.lastLoggedProbe = probeLine;
  }

  self.statusLabel.text = text;
  [self.statusPanel.superview bringSubviewToFront:self.statusPanel];

  if (self.games.count == 0) {
    self.emptyLabel.hidden = NO;
  } else {
    self.emptyLabel.hidden = YES;
  }

  if (fresh.capability != xe::memory::JitCapability::kUnavailable &&
      fresh.capability != xe::memory::JitCapability::kUnknown) {
    [self.probeTimer invalidate];
    self.probeTimer = nil;
  }
  [self.gamesTable reloadData];
}

// Main-thread scan completion (XenraGameScanner). Rebuilds the launch-path
// list from the scanned entries and rebinds the table.
- (void)gamesScanned:(NSArray<XenraGameEntry*>*)games {
  NSMutableArray<NSString*>* paths = [NSMutableArray array];
  for (XenraGameEntry* entry in games) {
    [paths addObject:entry.path];
  }
  NSArray<NSString*>* fresh = [paths copy];  // +1, ours
  self.games = fresh;                        // setter retains its own
  [fresh release];
  self.emptyLabel.hidden = (fresh.count != 0);
  [self.gamesTable reloadData];
  AppendDiagnostics([NSString
      stringWithFormat:@"session #%ld: library scan -> %lu games",
                       (long)SessionNumber(), (unsigned long)fresh.count]);
}

- (void)openStikDebug {
  NSURLComponents* components =
      [NSURLComponents componentsWithString:@"stikdebug://enable-jit"];
  NSMutableArray<NSURLQueryItem*>* items = [NSMutableArray array];
  [items addObject:[NSURLQueryItem queryItemWithName:@"bundle-id"
                                               value:NSBundle.mainBundle
                                                         .bundleIdentifier]];
  [items addObject:[NSURLQueryItem queryItemWithName:@"pid"
                                               value:[NSString
                   stringWithFormat:@"%d", getpid()]]];
  if (IsIos26OrLater()) {
    // One developer-defined script, fixed in code - never a user setting.
    [items addObject:[NSURLQueryItem queryItemWithName:@"script-name"
                                                value:@"universal.js"]];
  }
  components.queryItems = items;

  if (![UIApplication.sharedApplication canOpenURL:components.URL]) {
    AppendDiagnostics([NSString
        stringWithFormat:@"session #%ld: StikDebug NOT INSTALLED/blocked",
                         (long)SessionNumber()]);
    self.statusLabel.text = [self.statusLabel.text
        stringByAppendingString:
            @"\n\nStikDebug is not installed (or its scheme is blocked). "
             "Install StikDebug, import a pairing file, connect "
             "LocalDevVPN, then tap again."];
    return;
  }
  AppendDiagnostics([NSString
      stringWithFormat:@"session #%ld: StikDebug handoff: %@",
                       (long)SessionNumber(), components.URL.absoluteString]);
  [UIApplication.sharedApplication openURL:components.URL
                                     options:@{}
                           completionHandler:nil];
}

// ---------------------------------------------------------------------------
// Game screen
// ---------------------------------------------------------------------------

- (void)launchGame:(NSString*)path {
  const xe::memory::JitStatus jit = xe::memory::QueryJitStatusRefresh();
  if (jit.capability == xe::memory::JitCapability::kUnavailable) {
    UIAlertController* alert = [UIAlertController
        alertControllerWithTitle:@"JIT is OFF"
                         message:[NSString
             stringWithFormat:@"%@\n\nUse the StikDebug button, attach with "
                              "universal.js, then try again.",
                              jit.detail.c_str()]
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                              style:UIAlertActionStyleDefault
                                            handler:nil]];
    [self.rootController presentViewController:alert animated:YES completion:nil];
    return;
  }

  [self buildGameScreen];
  int rc = xe_ios_boot(path.UTF8String);
  if (rc != 0) {
    [self teardownGameScreen];
    UIAlertController* alert = [UIAlertController
        alertControllerWithTitle:@"Boot refused"
                         message:[NSString
             stringWithFormat:@"%s", xe_ios_status_detail()]
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                              style:UIAlertActionStyleDefault
                                            handler:nil]];
    [self.rootController presentViewController:alert animated:YES completion:nil];
    return;
  }

  self.displayLink =
      [CADisplayLink displayLinkWithTarget:self
                                  selector:@selector(displayLinkFired)];
  self.displayLink.preferredFramesPerSecond = 60;
  [self.displayLink addToRunLoop:NSRunLoop.mainRunLoop
                         forMode:NSRunLoopCommonModes];
}

- (void)displayLinkFired {
  xe_ios_pump();
  const int status = xe_ios_status();
  if (status < 0) {
    self.hudLabel.text = [NSString
        stringWithFormat:@"FAILED: %s", xe_ios_status_detail()];
  } else if (status == 1) {
    self.hudLabel.text = @"Booting... (first launch compiles shaders; this "
                         "can take a while)";
  } else if (status == 2) {
    self.hudLabel.text = @"";
  }
}

- (void)buildGameScreen {
  UIView* view = self.rootController.view;

  self.gameView = [[UIView alloc] initWithFrame:view.bounds];
  self.gameView.autoresizingMask =
      UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  self.gameView.backgroundColor = UIColor.blackColor;

  self.metalView =
      [[XenraMetalView alloc] initWithFrame:view.bounds];
  self.metalView.autoresizingMask =
      UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  [self.gameView addSubview:self.metalView];
  [self.metalView release];

  self.hudLabel = [[UILabel alloc] initWithFrame:CGRectZero];
  self.hudLabel.numberOfLines = 2;
  self.hudLabel.textColor = UIColor.whiteColor;
  self.hudLabel.font = [UIFont systemFontOfSize:12.0];
  self.hudLabel.textAlignment = NSTextAlignmentCenter;
  self.hudLabel.translatesAutoresizingMaskIntoConstraints = NO;
  [self.gameView addSubview:self.hudLabel];
  [self.hudLabel release];

  UIButton* exit = [UIButton buttonWithType:UIButtonTypeSystem];
  [exit setTitle:@"Exit" forState:UIControlStateNormal];
  [exit addTarget:self
           action:@selector(exitGame)
 forControlEvents:UIControlEventTouchUpInside];
  exit.translatesAutoresizingMaskIntoConstraints = NO;
  [self.gameView addSubview:exit];

  // Point the core's surface at the view that is actually on screen.
  xe_ios_set_game_view(self.metalView);

  [self buildVirtualPad];

  [view addSubview:self.gameView];
  [self.gameView release];

  [NSLayoutConstraint activateConstraints:@[
    [self.hudLabel.centerXAnchor constraintEqualToAnchor:view.centerXAnchor],
    [self.hudLabel.topAnchor constraintEqualToAnchor:view.safeAreaLayoutGuide
                                                          .topAnchor
                                            constant:8.0],
    [exit.trailingAnchor
        constraintEqualToAnchor:view.safeAreaLayoutGuide.trailingAnchor
                       constant:-12.0],
    [exit.topAnchor constraintEqualToAnchor:view.safeAreaLayoutGuide.topAnchor
                                   constant:4.0],
  ]];
}

- (void)teardownGameScreen {
  [self.displayLink invalidate];
  self.displayLink = nil;
  [self.gameView removeFromSuperview];
  self.gameView = nil;
  self.metalView = nil;
  self.hudLabel = nil;
}

- (void)exitGame {
  if (xe_ios_status() == 1) {
    // Boot in flight: the boot thread may be parked in a synchronous
    // CallInUIThread that was marshaled to this very (main, blocked) thread -
    // Setup and CompleteLaunch both marshal, and joining the boot thread from
    // a button tap stops the runloop pump that un-parks it. quick_exit is the
    // engine's own teardown semantic here (KernelState::TerminateTitle is
    // std::quick_exit), and one title per process makes that final anyway;
    // config, saves and shader caches are all on disk.
    std::quick_exit(0);
  }
  xe_ios_shutdown();
  [self teardownGameScreen];
  exit(0);  // One title per process; state is all on disk.
}

// --- Virtual pad ------------------------------------------------------------

// Builds one draggable stick disc (base + centered thumb). Returns the
// disc; the caller positions it and the pan selector feeds the axes.
- (UIView*)makeStickWithPanSelector:(SEL)selector {
  UIView* stick = [[UIView alloc] initWithFrame:CGRectZero];
  stick.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.10];
  stick.layer.cornerRadius = 48.0;
  stick.layer.borderWidth = 1.5;
  stick.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.35].CGColor;
  stick.translatesAutoresizingMaskIntoConstraints = NO;

  // The thumb: a smaller disc that follows the finger within the base.
  UIView* thumb = [[UIView alloc] initWithFrame:CGRectZero];
  thumb.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.22];
  thumb.layer.cornerRadius = 20.0;
  thumb.translatesAutoresizingMaskIntoConstraints = NO;
  thumb.userInteractionEnabled = NO;
  [stick addSubview:thumb];
  [thumb release];
  [NSLayoutConstraint activateConstraints:@[
    [thumb.centerXAnchor constraintEqualToAnchor:stick.centerXAnchor],
    [thumb.centerYAnchor constraintEqualToAnchor:stick.centerYAnchor],
    [thumb.widthAnchor constraintEqualToConstant:40.0],
    [thumb.heightAnchor constraintEqualToConstant:40.0],
  ]];

  UIPanGestureRecognizer* pan =
      [[UIPanGestureRecognizer alloc] initWithTarget:self action:selector];
  [stick addGestureRecognizer:pan];
  [pan release];
  return stick;
}

- (void)buildVirtualPad {
  UIView* view = self.gameView;
  UILayoutGuide* safe = view.safeAreaLayoutGuide;

  // Left stick: movement. Right stick: camera - it was missing entirely,
  // which made every 3D title unplayable from the screen alone.
  UIView* leftStick =
      [self makeStickWithPanSelector:@selector(leftStickPanned:)];
  leftStick.tag = 77;
  [view addSubview:leftStick];
  [leftStick release];

  UIView* rightStick =
      [self makeStickWithPanSelector:@selector(rightStickPanned:)];
  [view addSubview:rightStick];
  [rightStick release];

  // Face buttons, bumpers, start/back: compact grid on the right.
  NSDictionary* actions = @{
    @"A" : @(xe::hid::X_INPUT_GAMEPAD_A),
    @"B" : @(xe::hid::X_INPUT_GAMEPAD_B),
    @"X" : @(xe::hid::X_INPUT_GAMEPAD_X),
    @"Y" : @(xe::hid::X_INPUT_GAMEPAD_Y),
    @"LB" : @(xe::hid::X_INPUT_GAMEPAD_LEFT_SHOULDER),
    @"RB" : @(xe::hid::X_INPUT_GAMEPAD_RIGHT_SHOULDER),
    @"LT" : @(-1),
    @"RT" : @(-2),
    @"ST" : @(xe::hid::X_INPUT_GAMEPAD_START),
    @"BK" : @(xe::hid::X_INPUT_GAMEPAD_BACK),
    @"U" : @(xe::hid::X_INPUT_GAMEPAD_DPAD_UP),
    @"D" : @(xe::hid::X_INPUT_GAMEPAD_DPAD_DOWN),
    @"L" : @(xe::hid::X_INPUT_GAMEPAD_DPAD_LEFT),
    @"R" : @(xe::hid::X_INPUT_GAMEPAD_DPAD_RIGHT),
  };
  NSArray<NSArray<NSString*>*>* rows = @[
    @[ @"LT", @"LB", @"RB", @"RT" ],
    @[ @"BK", @"X", @"Y", @"ST" ],
    @[ @"U", @"A", @"B", @"R" ],
    @[ @"L", @"", @"D", @"" ],
  ];
  NSMutableArray<NSLayoutConstraint*>* pad = [NSMutableArray array];
  UIView* above = nil;
  for (NSUInteger r = 0; r < rows.count; ++r) {
    UIView* leftAnchorView = nil;
    for (NSUInteger c = 0; c < rows[r].count; ++c) {
      NSString* name = rows[r][c];
      if (name.length == 0) {
        continue;
      }
      UIButton* b = [UIButton buttonWithType:UIButtonTypeSystem];
      b.layer.cornerRadius = 20.0;
      b.layer.borderWidth = 1.0;
      b.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.4].CGColor;
      b.titleLabel.font = [UIFont boldSystemFontOfSize:12.0];
      [b setTitle:name forState:UIControlStateNormal];
      int code = [actions[name] intValue];
      bool trigger = code == -1 || code == -2;
      b.tag = code;
      [b addTarget:self
                 action:@selector(padButtonDown:)
       forControlEvents:UIControlEventTouchDown];
      [b addTarget:self
                 action:@selector(padButtonUp:)
       forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside
           | UIControlEventTouchCancel];
      if (trigger) {
        b.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.06];
      }
      b.translatesAutoresizingMaskIntoConstraints = NO;
      [view addSubview:b];

      [pad addObject:[b.widthAnchor constraintEqualToConstant:44.0]];
      [pad addObject:[b.heightAnchor constraintEqualToConstant:44.0]];
      if (leftAnchorView) {
        [pad addObject:[b.leadingAnchor
                            constraintEqualToAnchor:leftAnchorView.trailingAnchor
                                           constant:6.0]];
      } else {
        [pad addObject:[b.trailingAnchor
                            constraintEqualToAnchor:safe.trailingAnchor
                                           constant:-12.0]];
      }
      if (above) {
        [pad addObject:[b.topAnchor constraintEqualToAnchor:above.bottomAnchor
                                                   constant:6.0]];
      } else {
        // Bottom row sits above the right stick, not at the screen edge -
        // the stick owns the bottom-right corner (Android pad layout).
        [pad addObject:[b.bottomAnchor
                            constraintEqualToAnchor:rightStick.topAnchor
                                           constant:-8.0]];
      }
      leftAnchorView = b;
      [b release];
    }
    if (leftAnchorView) {
      above = leftAnchorView;  // walk upward: next row sits above this one
    }
  }
  [NSLayoutConstraint activateConstraints:pad];

  [NSLayoutConstraint activateConstraints:@[
    [leftStick.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor
                                            constant:20.0],
    [leftStick.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor
                                           constant:-24.0],
    [leftStick.widthAnchor constraintEqualToConstant:96.0],
    [leftStick.heightAnchor constraintEqualToConstant:96.0],

    [rightStick.trailingAnchor
        constraintEqualToAnchor:safe.trailingAnchor constant:-20.0],
    [rightStick.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor
                                           constant:-24.0],
    [rightStick.widthAnchor constraintEqualToConstant:96.0],
    [rightStick.heightAnchor constraintEqualToConstant:96.0],
  ]];
}

// Shared stick-pan logic: normalizes the drag from the disc CENTER (the old
// left-only handler anchored the origin at the first-touch point, which made
// the usable axis range depend on where the finger landed) and writes the
// axis pair through the given out-pointers.
static void XenraStickApply(UIPanGestureRecognizer* pan, short* outX,
                            short* outY) {
  UIView* stick = [pan view];
  if (pan.state == UIGestureRecognizerStateBegan ||
      pan.state == UIGestureRecognizerStateChanged) {
    CGPoint origin = CGPointMake(stick.bounds.size.width / 2.0,
                                 stick.bounds.size.height / 2.0);
    CGPoint p = [pan locationInView:stick];
    float dx = (p.x - origin.x) / 48.0f;
    float dy = (p.y - origin.y) / 48.0f;
    float len = sqrtf(dx * dx + dy * dy);
    if (len > 1.0f) {
      dx /= len;
      dy /= len;
    }
    // Up on the stick is negative Y in X_INPUT.
    *outX = (short)(dx * 32767.0f);
    *outY = (short)(dy * -32767.0f);
  } else if (pan.state == UIGestureRecognizerStateEnded ||
             pan.state == UIGestureRecognizerStateCancelled) {
    *outX = 0;
    *outY = 0;
  }
}

- (void)leftStickPanned:(UIPanGestureRecognizer*)pan {
  XenraStickApply(pan, &stickLX_, &stickLY_);
  [self pushInput];
}

- (void)rightStickPanned:(UIPanGestureRecognizer*)pan {
  XenraStickApply(pan, &stickRX_, &stickRY_);
  [self pushInput];
}

- (void)padButtonDown:(UIButton*)b {
  int code = (int)b.tag;
  if (code == -1) {
    triggerLT_ = 255;
  } else if (code == -2) {
    triggerRT_ = 255;
  } else {
    buttons_ |= code;
  }
  [self pushInput];
}

- (void)padButtonUp:(UIButton*)b {
  int code = (int)b.tag;
  if (code == -1) {
    triggerLT_ = 0;
  } else if (code == -2) {
    triggerRT_ = 0;
  } else {
    buttons_ &= ~code;
  }
  [self pushInput];
}

- (void)pushInput {
  xe_ios_input_set(buttons_, stickLX_, stickLY_, stickRX_, stickRY_,
                   triggerLT_, triggerRT_);
}

// --- Overflow menu ------------------------------------------------------------

// Android's library overflow menu, reduced to what the iOS shell currently
// implements. The actions that exist in the Android app but have no iOS
// backend yet (Install Content, Open User Data, Profiles) are listed but
// disabled, so the menu SHAPE matches even where the feature does not.
- (void)showOverflowMenu {
  UIAlertController* menu = [UIAlertController
      alertControllerWithTitle:@"Xenra"
                       message:nil
                preferredStyle:UIAlertControllerStyleActionSheet];

  UIAlertAction* jit = [UIAlertAction
      actionWithTitle:@"Enable JIT via StikDebug"
                style:UIAlertActionStyleDefault
              handler:^(__unused UIAlertAction* a) {
                [self openStikDebug];
              }];
  [menu addAction:jit];

  UIAlertAction* rescan = [UIAlertAction
      actionWithTitle:@"Rescan games"
                style:UIAlertActionStyleDefault
              handler:^(__unused UIAlertAction* a) {
                [self.scanner scanWithCompletion:^(
                                   NSArray<XenraGameEntry*>* games) {
                  [self gamesScanned:games];
                }];
              }];
  [menu addAction:rescan];

  // The remaining entries mirror the Android menu but have no iOS backend
  // yet; they are listed disabled so the menu shape matches the Android
  // library's overflow menu even where the feature does not exist here.
  UIAlertAction* install = [UIAlertAction
      actionWithTitle:@"Install Content"
                style:UIAlertActionStyleDefault
              handler:nil];
  install.enabled = NO;
  [menu addAction:install];

  UIAlertAction* userData = [UIAlertAction
      actionWithTitle:@"Open User Data"
                style:UIAlertActionStyleDefault
              handler:nil];
  userData.enabled = NO;
  [menu addAction:userData];

  [menu addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                           style:UIAlertActionStyleCancel
                                         handler:nil]];
  menu.popoverPresentationController.sourceView = self.menuButton;
  menu.popoverPresentationController.sourceRect = self.menuButton.bounds;
  [self.rootController presentViewController:menu
                                    animated:YES
                                  completion:nil];
}

// --- UITableViewDataSource / Delegate ---------------------------------------

- (NSInteger)tableView:(UITableView*)tableView
    numberOfRowsInSection:(NSInteger)section {
  return self.games.count;
}

- (UITableViewCell*)tableView:(UITableView*)tableView
        cellForRowAtIndexPath:(NSIndexPath*)indexPath {
  static NSString* reuse = @"blade";
  XenraBladeCell* cell =
      [tableView dequeueReusableCellWithIdentifier:reuse];
  if (!cell) {
    cell = [[[XenraBladeCell alloc]
        initWithStyle:UITableViewCellStyleDefault
      reuseIdentifier:reuse] autorelease];
  }
  NSString* path = self.games[indexPath.row];
  NSString* name = path.lastPathComponent.stringByDeletingPathExtension;
  NSString* ext = path.pathExtension.uppercaseString;
  // Metadata came from the background scan (XenraGameScanner); the row bind
  // does no disk I/O - the Android library's per-key/per-cell I/O lesson
  // (session-2 E1/E4) applied here from the start.
  unsigned long long size = 0;
  for (XenraGameEntry* entry in self.scanner.games) {
    if ([entry.path isEqualToString:path]) {
      size = entry.fileSize;
      break;
    }
  }
  NSString* subtitle;
  if (size >= 1024ull * 1024ull * 1024ull) {
    subtitle = [NSString stringWithFormat:@"%.1f GB · %@",
                                          size / (1024.0 * 1024.0 * 1024.0),
                                          ext];
  } else if (size > 0) {
    subtitle = [NSString stringWithFormat:@"%llu MB · %@",
                                          size / (1024ull * 1024ull), ext];
  } else {
    subtitle = ext;
  }
  [cell bindTitle:name
         subtitle:subtitle
            cover:[self.scanner coverForEntryNamed:name]];
  return cell;
}

- (CGFloat)tableView:(UITableView*)tableView
    heightForRowAtIndexPath:(NSIndexPath*)indexPath {
  return 78.0;
}

- (void)tableView:(UITableView*)tableView
    didSelectRowAtIndexPath:(NSIndexPath*)indexPath {
  [tableView deselectRowAtIndexPath:indexPath animated:YES];
  [self launchGame:self.games[indexPath.row]];
}

- (void)dealloc {
  [self.probeTimer invalidate];
  [self.displayLink invalidate];
  [_dashboard release];
  [_titleLabel release];
  [_menuButton release];
  [_statusPanel release];
  [_statusLabel release];
  [_stikDebugButton release];
  [_gamesTable release];
  [_emptyLabel release];
  [_scanner release];
  [_games release];
  [_probeTimer release];
  [_displayLink release];
  [_gameView release];
  [_metalView release];
  [_hudLabel release];
  [_lastLoggedProbe release];
  [_device release];
  [_rootController release];
  [_window release];
  [super dealloc];
}

@end
