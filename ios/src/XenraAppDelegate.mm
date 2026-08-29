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

#include <string>
#include <sys/sysctl.h>
#include <unistd.h>  // getpid, for the StikDebug handoff URL

#include "XenraMetalView.h"
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
    path = [docs stringByAppendingPathComponent:@"xenra-jit-log.txt"];
  });
  return path;
}

void AppendDiagnostics(NSString* line) {
  NSString* path = DiagnosticsLogPath();
  // Rotate before the file gets silly; .old keeps the previous half.
  NSDictionary* attrs =
      [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
  if (attrs && [attrs fileSize] > 256 * 1024) {
    NSString* old = [path stringByAppendingString:@".old"];
    [[NSFileManager defaultManager] removeItemAtPath:old error:nil];
    [[NSFileManager defaultManager] moveItemAtPath:path toPath:old error:nil];
  }
  NSData* data = [[line stringByAppendingString:@"\n"]
      dataUsingEncoding:NSUTF8StringEncoding];
  NSFileHandle* fh = [NSFileHandle fileHandleForWritingAtPath:path];
  if (!fh) {
    [data writeToFile:path atomically:YES];
    return;
  }
  [fh seekToEndOfFile];
  [fh writeData:data];
  [fh closeFile];
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

NSArray<NSString*>* ScanGames() {
  NSString* dir = DocumentsGamesDir();
  NSArray<NSURL*>* contents = [[NSFileManager defaultManager]
      contentsOfDirectoryAtURL:[NSURL fileURLWithPath:dir]
    includingPropertiesForKeys:@[ NSURLIsRegularFileKey ]
                       options:0
                         error:nil];
  NSMutableArray<NSString*>* games = [NSMutableArray array];
  NSArray<NSString*>* extensions = @[ @"iso", @"xex", @"zar", @"god",
                                      @"con", @"live", @"pirs" ];
  for (NSURL* url in contents) {
    NSString* ext = url.pathExtension.lowercaseString;
    if ([extensions containsObject:ext]) {
      [games addObject:url.path];
    }
  }
  // Newest container-first reads best on a TV-sized list; names differ more
  // than dates do.
  [games sortUsingComparator:^NSComparisonResult(NSString* a, NSString* b) {
    return [a.lastPathComponent compare:b.lastPathComponent options:NSCaseInsensitiveSearch];
  }];
  return games;
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
@property(nonatomic, retain) UILabel* statusLabel;
@property(nonatomic, retain) UIButton* stikDebugButton;
@property(nonatomic, retain) UITableView* gamesTable;
@property(nonatomic, retain) id<MTLDevice> device;
@property(nonatomic, assign) NSInteger probeCount;
@property(nonatomic, retain) NSTimer* probeTimer;
@property(nonatomic, retain) NSArray<NSString*>* games;
@property(nonatomic, retain) UIView* gameView;
@property(nonatomic, retain) XenraMetalView* metalView;
@property(nonatomic, retain) CADisplayLink* displayLink;
@property(nonatomic, retain) UILabel* hudLabel;
@property(nonatomic, assign) int coreInitRc;
@property(nonatomic, retain) NSString* lastLoggedProbe;
@end

// Manual reference counting (see ios/CMakeLists.txt), matching the rest of
// the tree.
@implementation XenraAppDelegate {
  // Virtual-pad touch bookkeeping (main thread only).
  CGPoint leftStickOrigin_;
  bool leftStickActive_;
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
  self.games = ScanGames();

  int rc = xe_ios_initialize(
      DocumentsGamesDir().stringByDeletingLastPathComponent.UTF8String,
      NSTemporaryDirectory().UTF8String);
  self.coreInitRc = rc;

  {
    const xe::memory::JitSignatureState sig =
        xe::memory::QueryJitSignatureState();
    AppendDiagnostics([NSString
        stringWithFormat:
            @"=== session #%ld | %@ | %@ | get-task-allow=%@ cs_debugged=%@ "
             "| core init %d ===",
            (long)SessionNumber(), [NSDate date], DeviceAndOsLine(),
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

  self.statusLabel = [[UILabel alloc] initWithFrame:CGRectZero];
  self.statusLabel.numberOfLines = 0;
  self.statusLabel.textColor = UIColor.whiteColor;
  self.statusLabel.font = [UIFont monospacedSystemFontOfSize:12.0
                                                      weight:UIFontWeightRegular];
  self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
  [view addSubview:self.statusLabel];
  [self.statusLabel release];

  UITapGestureRecognizer* tap =
      [[UITapGestureRecognizer alloc] initWithTarget:self
                                              action:@selector(refreshStatus)];
  [self.statusLabel addGestureRecognizer:tap];
  self.statusLabel.userInteractionEnabled = YES;
  [tap release];

  self.stikDebugButton = [UIButton buttonWithType:UIButtonTypeSystem];
  [self.stikDebugButton setTitle:@"Enable JIT via StikDebug"
                        forState:UIControlStateNormal];
  self.stikDebugButton.titleLabel.font = [UIFont boldSystemFontOfSize:15.0];
  self.stikDebugButton.backgroundColor = [UIColor colorWithWhite:0.15 alpha:1.0];
  [self.stikDebugButton setTitleColor:UIColor.systemBlueColor
                             forState:UIControlStateNormal];
  self.stikDebugButton.layer.cornerRadius = 10.0;
  [self.stikDebugButton addTarget:self
                           action:@selector(openStikDebug)
                 forControlEvents:UIControlEventTouchUpInside];
  self.stikDebugButton.translatesAutoresizingMaskIntoConstraints = NO;
  [view addSubview:self.stikDebugButton];
  [self.stikDebugButton release];

  self.gamesTable = [[UITableView alloc] initWithFrame:CGRectZero
                                                 style:UITableViewStylePlain];
  self.gamesTable.backgroundColor = UIColor.clearColor;
  self.gamesTable.separatorColor = [UIColor colorWithWhite:0.3 alpha:1.0];
  self.gamesTable.dataSource = self;
  self.gamesTable.delegate = self;
  self.gamesTable.translatesAutoresizingMaskIntoConstraints = NO;
  [view addSubview:self.gamesTable];
  [self.gamesTable release];

  UILayoutGuide* safe = view.safeAreaLayoutGuide;
  [NSLayoutConstraint activateConstraints:@[
    [self.statusLabel.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor
                                                   constant:16.0],
    [self.statusLabel.trailingAnchor
        constraintEqualToAnchor:safe.trailingAnchor
                       constant:-16.0],
    [self.statusLabel.topAnchor constraintEqualToAnchor:safe.topAnchor
                                               constant:12.0],
    [self.stikDebugButton.centerXAnchor
        constraintEqualToAnchor:view.centerXAnchor],
    [self.stikDebugButton.topAnchor
        constraintEqualToAnchor:self.statusLabel.bottomAnchor constant:12.0],
    [self.gamesTable.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
    [self.gamesTable.trailingAnchor
        constraintEqualToAnchor:safe.trailingAnchor],
    [self.gamesTable.topAnchor
        constraintEqualToAnchor:self.stikDebugButton.bottomAnchor constant:12.0],
    [self.gamesTable.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor],
  ]];
}

- (void)refreshStatus {
  ++self.probeCount;

  // Exactly one probe per refresh - see DescribeJitStatus.
  const xe::memory::JitStatus fresh = xe::memory::QueryJitStatusRefresh();

  NSMutableString* text = [NSMutableString string];
  [text appendFormat:@"Xenra iOS - session #%ld\n", (long)SessionNumber()];
  [text appendFormat:
            @"re-test #%ld  (tap this text to re-test; log: "
             "Documents/xenra-jit-log.txt)\n\n",
            (long)self.probeCount];
  [text appendFormat:@"%@\n\n", DescribeJitStatus(fresh)];
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

  if (self.games.count == 0) {
    [text appendString:@"\nNo games yet.\nCopy .iso / .god files into the "
                        "app's Documents/Games folder (Files app, or Finder "
                        "over USB), then tap this text to rescan."];
    self.statusLabel.text = text;
  }

  if (fresh.capability != xe::memory::JitCapability::kUnavailable &&
      fresh.capability != xe::memory::JitCapability::kUnknown) {
    [self.probeTimer invalidate];
    self.probeTimer = nil;
  }
  [self.gamesTable reloadData];
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
  xe_ios_shutdown();
  [self teardownGameScreen];
  exit(0);  // One title per process; state is all on disk.
}

// --- Virtual pad ------------------------------------------------------------

- (void)buildVirtualPad {
  UIView* view = self.gameView;
  UILayoutGuide* safe = view.safeAreaLayoutGuide;

  // Left stick: one draggable disc.
  UIView* stick = [[UIView alloc] initWithFrame:CGRectZero];
  stick.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.10];
  stick.layer.cornerRadius = 48.0;
  stick.layer.borderWidth = 1.5;
  stick.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.35].CGColor;
  stick.translatesAutoresizingMaskIntoConstraints = NO;
  [view addSubview:stick];
  [stick release];
  stick.tag = 77;

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
        [pad addObject:[b.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor
                                                      constant:-16.0]];
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
    [stick.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor
                                        constant:20.0],
    [stick.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor
                                       constant:-24.0],
    [stick.widthAnchor constraintEqualToConstant:96.0],
    [stick.heightAnchor constraintEqualToConstant:96.0],
  ]];

  // Touch handling: one gesture on the whole game view routes by hit-test.
  UIPanGestureRecognizer* pan = [[UIPanGestureRecognizer alloc]
      initWithTarget:self
              action:@selector(stickPanned:)];
  [stick addGestureRecognizer:pan];
  [pan release];
}

- (void)stickPanned:(UIPanGestureRecognizer*)pan {
  UIView* stick = [pan view];
  if (pan.state == UIGestureRecognizerStateBegan) {
    leftStickOrigin_ = [pan locationInView:stick];
    leftStickActive_ = true;
  } else if (pan.state == UIGestureRecognizerStateChanged) {
    CGPoint p = [pan locationInView:stick];
    float dx = (p.x - leftStickOrigin_.x) / 48.0f;
    float dy = (p.y - leftStickOrigin_.y) / 48.0f;
    float len = sqrtf(dx * dx + dy * dy);
    if (len > 1.0f) {
      dx /= len;
      dy /= len;
    }
    stickLX_ = (short)(dx * 32767.0f);
    stickLY_ = (short)(dy * -32767.0f);
  } else if (pan.state == UIGestureRecognizerStateEnded ||
             pan.state == UIGestureRecognizerStateCancelled) {
    leftStickActive_ = false;
    stickLX_ = 0;
    stickLY_ = 0;
  }
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

// --- UITableViewDataSource / Delegate ---------------------------------------

- (NSInteger)tableView:(UITableView*)tableView
    numberOfRowsInSection:(NSInteger)section {
  return self.games.count;
}

- (UITableViewCell*)tableView:(UITableView*)tableView
        cellForRowAtIndexPath:(NSIndexPath*)indexPath {
  static NSString* reuse = @"game";
  UITableViewCell* cell =
      [tableView dequeueReusableCellWithIdentifier:reuse];
  if (!cell) {
    cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                  reuseIdentifier:reuse];
    [cell release];
    cell.textLabel.textColor = UIColor.whiteColor;
    cell.textLabel.font = [UIFont systemFontOfSize:14.0];
    cell.backgroundColor = UIColor.clearColor;
  }
  NSString* path = self.games[indexPath.row];
  cell.textLabel.text = path.lastPathComponent;
  cell.detailTextLabel.text = [NSString
      stringWithFormat:@"%lu KB", (unsigned long)([[[NSFileManager defaultManager]
          attributesOfItemAtPath:path error:nil] fileSize] / 1024)];
  return cell;
}

- (void)tableView:(UITableView*)tableView
    didSelectRowAtIndexPath:(NSIndexPath*)indexPath {
  [tableView deselectRowAtIndexPath:indexPath animated:YES];
  [self launchGame:self.games[indexPath.row]];
}

- (void)dealloc {
  [self.probeTimer invalidate];
  [self.displayLink invalidate];
  [_statusLabel release];
  [_stikDebugButton release];
  [_gamesTable release];
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
