#import "XenraScreens.h"

#import <GameController/GameController.h>
#import <QuartzCore/QuartzCore.h>

#include <cstdlib>

#import "XenraLogs.h"
#import "XenraMetalView.h"
#import "XenraSettings.h"
#import "XenraTheme.h"
#import "XenraTouchPad.h"
#import "XenraUI.h"
#import "XenraXemu.h"
#include "ios_emu.h"

@implementation XenraGameController {
  NSString* path_;
  NSString* name_;
  XenraMetalView* metal_;
  XenraTouchPad* pad_;
  UILabel* status_;
  CADisplayLink* link_;
  BOOL booted_;
  BOOL og_;
  NSTimer* sdlTimer_;
  int sdlTicks_;
  NSTimer* jitTimer_;
  // The latest state from each source; the guest sees them merged.
  int padButtons_;
  short padAxes_[4];
  unsigned char padTriggers_[2];
}

- (instancetype)initWithPath:(NSString*)path name:(NSString*)name {
  self = [super initWithNibName:nil bundle:nil];
  if (self) {
    path_ = [path copy];
    name_ = [name copy];
    og_ = [XenraSettings console] == XenraConsoleOG;
  }
  return self;
}

- (BOOL)prefersStatusBarHidden {
  return YES;
}
- (BOOL)prefersHomeIndicatorAutoHidden {
  return YES;
}

- (void)viewDidLoad {
  [super viewDidLoad];
  self.view.backgroundColor = UIColor.blackColor;

  metal_ = [[XenraMetalView alloc] initWithFrame:self.view.bounds];
  metal_.autoresizingMask =
      UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  [self.view addSubview:metal_];

  pad_ = [[XenraTouchPad alloc] initWithFrame:self.view.bounds];
  pad_.autoresizingMask =
      UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  pad_.x360Layout = !og_;
  pad_.scaleFactor = [[XenraSettings stringForKey:@"pad.scale"
                                         fallback:@"1.0"] doubleValue];
  pad_.hapticsEnabled =
      [[XenraSettings stringForKey:@"pad.haptics" fallback:@"true"]
          isEqual:@"true"];
  pad_.hidden = ![[XenraSettings stringForKey:@"pad.visible" fallback:@"true"]
      isEqual:@"true"];
  __weak XenraGameController* weak = self;
  pad_.onChange = ^(int buttons, short lx, short ly, short rx, short ry,
                    unsigned char lt, unsigned char rt) {
    [weak padButtons:buttons lx:lx ly:ly rx:rx ry:ry lt:lt rt:rt];
  };
  pad_.onMenu = ^{
    [weak showMenu];
  };
  [self.view addSubview:pad_];


  status_ = XenraMakeLabel(nil, 14, UIFontWeightRegular, UIColor.whiteColor);
  status_.numberOfLines = 0;
  status_.textAlignment = NSTextAlignmentCenter;
  [self.view addSubview:status_];

  [NSLayoutConstraint activateConstraints:@[
    [status_.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
    [status_.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
    [status_.widthAnchor constraintEqualToAnchor:self.view.widthAnchor
                                      multiplier:0.6],
  ]];
}

- (void)viewDidAppear:(BOOL)animated {
  [super viewDidAppear:animated];
  [UIApplication.sharedApplication setIdleTimerDisabled:YES];
  if (booted_ || jitTimer_) return;
  if (og_) {
    NSString* problem = XenraXemuPrepare();
    if (problem) {
      [self showFailure:problem];
      return;
    }
  }
  if (XenraJitActive()) {
    [self boot];
    return;
  }
  // The tool attaches seconds after the handoff, from another app, so the
  // only way to learn it did is to keep asking.
  status_.text = XenraJitStatusText();
  XenraOpenJitEnabler();
  __weak XenraGameController* weak = self;
  jitTimer_ = [NSTimer scheduledTimerWithTimeInterval:1
                                              repeats:YES
                                                block:^(NSTimer*) {
                                                  [weak checkJit];
                                                }];
}

- (void)checkJit {
  if (!XenraJitActive()) return;
  [jitTimer_ invalidate];
  jitTimer_ = nil;
  [self boot];
}

- (void)boot {
  if (og_) {
    [self bootXemu];
    return;
  }
  [XenraSettings applyForGame:name_];
  xe_ios_set_game_view(metal_);
  XenraLog([NSString stringWithFormat:@"boot: %@", path_.lastPathComponent]);
  XenraLogsBeginSession();
  const int rc = xe_ios_boot(path_.UTF8String);
  if (rc != 0) {
    [self showFailure:@(xe_ios_status_detail())];
    return;
  }
  booted_ = YES;
  link_ = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick)];
  link_.preferredFramesPerSecond = 60;
  [link_ addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
}

- (void)bootXemu {
  NSString* missing = XenraXemuMissingFiles();
  if (missing) {
    [self showFailure:[NSString stringWithFormat:@"Still needed: %@. Choose "
                                                  "them in the Setup Wizard, "
                                                  "from Settings.",
                                                 missing]];
    return;
  }
  XenraLog([NSString stringWithFormat:@"boot: %@", path_.lastPathComponent]);
  XenraLogsBeginSession();
  booted_ = YES;
  metal_.tracksBounds = YES;
  [metal_ setNeedsLayout];
  [metal_ layoutIfNeeded];
  status_.text = @"Booting…";
  [self sendPad];
  __weak XenraGameController* weak = self;
  sdlTimer_ = [NSTimer scheduledTimerWithTimeInterval:0.2
                                              repeats:YES
                                                block:^(NSTimer*) {
                                                  [weak keepSdlAway];
                                                }];
  // A timer, not a dispatch: see XenraXemuRun.
  [self performSelector:@selector(runXemu) withObject:nil afterDelay:0.1];
}

- (void)keepSdlAway {
  XenraXemuHideSdlWindows(self.view.window);
  if (status_.text.length && ++sdlTicks_ > 40) status_.text = nil;
}

- (void)runXemu {
  const int status = XenraXemuRun(path_, metal_.layer);
  XenraLog([NSString stringWithFormat:@"xemu returned %d", status]);
  XenraLogsEndSession();
  exit(0);
}

- (void)showFailure:(NSString*)detail {
  XenraLog([NSString stringWithFormat:@"boot failed: %@", detail]);
  __weak XenraGameController* weak = self;
  XenraBladeItem* share = [XenraBladeItem
      title:@"Share Logs"
      action:^{
        // The sheet closes on any tap, and this screen has no other way out.
        XenraShareLogs(weak, ^{
          [weak showFailure:detail];
        });
      }];
  [XenraBladeSheet showIn:self.view
                    title:@"Could not start the game"
                  message:detail
                    items:@[ share, [XenraBladeItem title:@"Quit App"
                                                   action:^{
                                                     [weak quit];
                                                   }] ]];
}

- (void)tick {
  xe_ios_pump();
  [self pollController];
  const int state = xe_ios_status();
  if (state == 1) {
    status_.text = @"Booting…\nThe first launch compiles shaders and can take "
                    "a while.";
  } else if (state == 2) {
    status_.text = nil;
  } else if (state < 0) {
    [link_ invalidate];
    link_ = nil;
    status_.text = nil;
    [self showFailure:@(xe_ios_status_detail())];
  }
}

// --- Input ------------------------------------------------------------------

- (void)padButtons:(int)buttons
                lx:(short)lx ly:(short)ly rx:(short)rx ry:(short)ry
                lt:(unsigned char)lt rt:(unsigned char)rt {
  padButtons_ = buttons;
  padAxes_[0] = lx;
  padAxes_[1] = ly;
  padAxes_[2] = rx;
  padAxes_[3] = ry;
  padTriggers_[0] = lt;
  padTriggers_[1] = rt;
  if (og_) {
    [self sendPad];
  } else if (!GCController.controllers.count) {
    xe_ios_input_set(buttons, lx, ly, rx, ry, lt, rt);
  }
}

// The pad owns port one while it is on screen; otherwise SDL's controller does.
- (void)sendPad {
  XenraXemuSetPad(!pad_.hidden && !GCController.controllers.count, padButtons_,
                  padAxes_[0], padAxes_[1], padAxes_[2], padAxes_[3],
                  padTriggers_[0], padTriggers_[1]);
}

- (void)pollController {
  GCExtendedGamepad* g = GCController.controllers.firstObject.extendedGamepad;
  if (!g) return;
  const auto axis = [](GCControllerAxisInput* a) {
    return short(a.value * 32767);
  };
  int b = padButtons_;
  if (g.buttonA.pressed) b |= 0x1000;
  if (g.buttonB.pressed) b |= 0x2000;
  if (g.buttonX.pressed) b |= 0x4000;
  if (g.buttonY.pressed) b |= 0x8000;
  if (g.leftShoulder.pressed) b |= 0x0100;
  if (g.rightShoulder.pressed) b |= 0x0200;
  if (g.dpad.up.pressed) b |= 0x0001;
  if (g.dpad.down.pressed) b |= 0x0002;
  if (g.dpad.left.pressed) b |= 0x0004;
  if (g.dpad.right.pressed) b |= 0x0008;
  if (g.buttonMenu.pressed) b |= 0x0010;
  if (g.buttonOptions.pressed) b |= 0x0020;
  if (g.leftThumbstickButton.pressed) b |= 0x0040;
  if (g.rightThumbstickButton.pressed) b |= 0x0080;
  xe_ios_input_set(b, axis(g.leftThumbstick.xAxis), axis(g.leftThumbstick.yAxis),
                   axis(g.rightThumbstick.xAxis), axis(g.rightThumbstick.yAxis),
                   (unsigned char)(g.leftTrigger.value * 255),
                   (unsigned char)(g.rightTrigger.value * 255));
}

// --- In-game menu -----------------------------------------------------------

- (void)showMenu {
  __weak XenraGameController* weak = self;
  XenraTouchPad* pad = pad_;
  XenraBladeItem* resume = [XenraBladeItem title:@"Resume" action:nil];
  XenraBladeItem* touch = [XenraBladeItem
      title:pad_.hidden ? @"Show Touch Controls" : @"Hide Touch Controls"
      action:^{
        pad.hidden = !pad.hidden;
        [weak sendPad];
      }];
  XenraBladeItem* share = [XenraBladeItem title:@"Share Logs"
                                         action:^{
                                           XenraShareLogs(weak, nil);
                                         }];
  XenraBladeItem* reset = [XenraBladeItem title:@"Reset"
                                         action:^{
                                           XenraXemuReset();
                                         }];
  // One title per process, so leaving a game ends the app; the same is true
  // of Quit, and Android's Exit to Game Library has no iOS counterpart yet.
  XenraBladeItem* quit = [XenraBladeItem title:@"Quit App"
                                        action:^{
                                          [weak quit];
                                        }];
  quit.destructive = YES;
  [XenraBladeSheet showIn:self.view
                    title:@"Game Menu"
                  message:nil
                    items:og_ ? @[ resume, touch, reset, share, quit ]
                              : @[ resume, touch, share, quit ]];
}

- (void)quit {
  XenraLogsEndSession();
  if (og_) {
    // A clean stop flushes the hard disk image. Give it a moment, no more.
    XenraXemuShutdown();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
                     exit(0);
                   });
    return;
  }
  if (xe_ios_status() == 1) {
    // Boot in flight: the boot thread may be parked in a CallInUIThread
    // marshaled to this very thread, so joining it here would hang.
    std::quick_exit(0);
  }
  xe_ios_shutdown();
  exit(0);
}

@end
