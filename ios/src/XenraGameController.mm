#import "XenraScreens.h"
#import "XenraStrings.h"

#import <GameController/GameController.h>
#import <QuartzCore/QuartzCore.h>

#include <cstdlib>
#include <fcntl.h>
#include <unistd.h>
#include <initializer_list>

#import "XenraAmbient.h"
#import "XenraLogs.h"
#import "XenraMetalView.h"
#import "XenraNetplay.h"
#import "XenraPadNav.h"
#import "XenraSampler.h"
#import "XenraSettings.h"
#import "XenraTheme.h"
#import "XenraTouchPad.h"
#import "XenraUI.h"
#import "XenraXemu.h"
#include "ios_emu.h"

// Radial, and rescaled, so a stick still reaches full travel and starts from nothing
// just past the edge of the zone.
static NSString* const kPendingGameKey = @"xenra.pendingGame";

// One core per launch: after Exit Game the process stays alive for the library
// and settings, but a second boot would land on a torn-down core.
static BOOL g_core_exited = NO;
BOOL XenraCoreExited(void) { return g_core_exited; }
// Long enough to finish in StikDebug, short enough that a later launch of the app
// does not start a game out of nowhere.
static const NSTimeInterval kPendingGameLife = 600;

// A controller the guest can use. Some only offer a micro gamepad.
static BOOL HasGamepad(void) {
  for (GCController* controller in GCController.controllers) {
    if (controller.extendedGamepad) return YES;
  }
  return NO;
}

// Whether the game file can really be read, before a core finds out the hard way.
// Files from iCloud Drive can be listed while their contents are still in the
// cloud, and then every read fails. Returns a reason for the user, or nil.
static NSString* XenraGameFileProblem(NSString* path) {
  NSURL* url = [NSURL fileURLWithPath:path];
  NSDictionary* values = [url resourceValuesForKeys:@[
    NSURLIsUbiquitousItemKey, NSURLUbiquitousItemDownloadingStatusKey, NSURLFileSizeKey,
    NSURLIsDirectoryKey
  ] error:nil];
  const BOOL cloud = [values[NSURLIsUbiquitousItemKey] boolValue];
  NSString* status = values[NSURLUbiquitousItemDownloadingStatusKey];
  if ([values[NSURLIsDirectoryKey] boolValue]) return nil;
  const int fd = open(path.fileSystemRepresentation, O_RDONLY);
  const int open_errno = fd < 0 ? errno : 0;
  ssize_t got = -1;
  int read_errno = 0;
  if (fd >= 0) {
    char probe[2048];
    got = pread(fd, probe, sizeof(probe), 0);
    if (got < 0) read_errno = errno;
    close(fd);
  }
  XenraLog([NSString stringWithFormat:@"game file: %@ size=%@ icloud=%d status=%@ "
                                      @"open=%d read=%zd/%d",
                                      path.lastPathComponent, values[NSURLFileSizeKey],
                                      cloud, status ?: @"-", open_errno, got, read_errno]);
  if (cloud && status && ![status isEqual:NSURLUbiquitousItemDownloadingStatusCurrent]) {
    [NSFileManager.defaultManager startDownloadingUbiquitousItemAtURL:url error:nil];
    return XS(@"This game is still in iCloud Drive, so it cannot be read yet. Xenra "
              "asked iOS to download it: wait until it shows as downloaded in "
              "Files, then start it again.");
  }
  if (fd < 0 || got <= 0) {
    return [NSString stringWithFormat:
        XS(@"The game file could not be read (%s). Choose the games folder again "
           "in the library, or copy the game into Xenra's own folder in Files."),
        strerror(open_errno ?: read_errno ?: EIO)];
  }
  return nil;
}

static void RememberForJit(NSString* path, NSString* name) {
  [NSUserDefaults.standardUserDefaults
      setObject:@{@"path" : path, @"name" : name, @"when" : [NSDate date]}
         forKey:kPendingGameKey];
  [NSUserDefaults.standardUserDefaults synchronize];
}

static void ApplyDeadzone(float zone, short* x, short* y) {
  const float fx = *x / 32767.0f, fy = *y / 32767.0f;
  const float length = hypotf(fx, fy);
  const float scale =
      length <= zone ? 0 : fminf(1, (length - zone) / (1 - zone)) / length;
  *x = short(fx * scale * 32767);
  *y = short(fy * scale * 32767);
}

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
  UILabel* hud_;
  int hudTicks_;
  BOOL padWanted_;
  UIButton* cancel_;
  NSTimer* menuTimer_;
  NSTimer* jitTimer_;
  // Set by Exit Game; stops the background sampler loop.
  BOOL exited_;
  // The latest state from each source; the guest sees them merged.
  int padButtons_;
  short padAxes_[4];
  unsigned char padTriggers_[2];
  float deadzone_;
  // Started by the relaunch after StikDebug, not by a tap.
  BOOL resumed_;
  // Paused because the app left the front, so coming back resumes it.
  BOOL pausedForBackground_;
  // A physical pad was feeding the guest on the last tick.
  BOOL hadGamepad_;
  // JIT or JIT-less is settled for this launch (from settings or the sheet).
  BOOL modeDecided_;
  BOOL jitless_;
  // The JIT / JIT-less sheet is up.
  BOOL choosingMode_;
}

+ (instancetype)takePendingAfterJit {
  NSUserDefaults* defaults = NSUserDefaults.standardUserDefaults;
  NSDictionary* pending = [defaults dictionaryForKey:kPendingGameKey];
  // Opened again before StikDebug attached: the attach still brings a relaunch.
  if (!pending || !XenraJitActive()) return nil;
  [defaults removeObjectForKey:kPendingGameKey];
  NSString* path = pending[@"path"];
  NSString* name = pending[@"name"];
  NSDate* when = pending[@"when"];
  if (!path || !name || !when) return nil;
  if (-when.timeIntervalSinceNow > kPendingGameLife) return nil;
  if (![NSFileManager.defaultManager fileExistsAtPath:path]) return nil;
  XenraLog([NSString stringWithFormat:@"resume after JIT: %@", path.lastPathComponent]);
  XenraGameController* game = [[self alloc] initWithPath:path name:name];
  game->resumed_ = YES;
  return game;
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
  pad_.alpha = [[XenraSettings stringForKey:@"pad.opacity" fallback:@"0.85"] doubleValue];
  deadzone_ =
      [[XenraSettings stringForKey:@"pad.deadzone" fallback:@"0.12"] floatValue];
  pad_.hapticsEnabled =
      [[XenraSettings stringForKey:@"pad.haptics" fallback:@"true"]
          isEqual:@"true"];
  pad_.hidden = ![[XenraSettings stringForKey:@"pad.visible" fallback:@"true"]
      isEqual:@"true"];
  __weak XenraGameController* weak = self;
  padWanted_ = !pad_.hidden;
  pad_.hidden = YES;
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

  cancel_ = [UIButton buttonWithType:UIButtonTypeSystem];
  [cancel_ setTitle:XS(@"Cancel") forState:UIControlStateNormal];
  cancel_.tintColor = UIColor.whiteColor;
  cancel_.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
  cancel_.layer.cornerRadius = 22;
  cancel_.layer.borderWidth = 1;
  cancel_.layer.borderColor = UIColor.whiteColor.CGColor;
  cancel_.translatesAutoresizingMaskIntoConstraints = NO;
  cancel_.hidden = YES;
  [cancel_ addTarget:self
                action:@selector(cancelWaiting)
      forControlEvents:UIControlEventTouchUpInside];
  [self.view addSubview:cancel_];
  [NSLayoutConstraint activateConstraints:@[
    [cancel_.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
    [cancel_.topAnchor constraintEqualToAnchor:status_.bottomAnchor constant:20],
    [cancel_.widthAnchor constraintEqualToConstant:140],
    [cancel_.heightAnchor constraintEqualToConstant:44],
  ]];

  UISwipeGestureRecognizer* swipe = [[UISwipeGestureRecognizer alloc]
      initWithTarget:self
              action:@selector(swiped:)];
  swipe.direction = UISwipeGestureRecognizerDirectionUp;
  [self.view addGestureRecognizer:swipe];
  for (GCController* controller in GCController.controllers) {
    [self watchController:controller];
  }
  [NSNotificationCenter.defaultCenter
      addObserverForName:GCControllerDidConnectNotification
                  object:nil
                   queue:NSOperationQueue.mainQueue
              usingBlock:^(NSNotification* note) {
                [weak watchController:note.object];
                [weak controllersChanged];
              }];
  // iOS refuses GPU work from an app in the background, and MoltenVK answers a refused
  // submit by losing the device, which xemu treats as fatal. Seen on the M1: home
  // button mid-game, then an abort in pgraph_vk_finish. So stop the guest first.
  [NSNotificationCenter.defaultCenter
      addObserverForName:UIApplicationWillResignActiveNotification
                  object:nil
                   queue:NSOperationQueue.mainQueue
              usingBlock:^(NSNotification*) {
                [weak leavingFront];
              }];
  [NSNotificationCenter.defaultCenter
      addObserverForName:UIApplicationDidBecomeActiveNotification
                  object:nil
                   queue:NSOperationQueue.mainQueue
              usingBlock:^(NSNotification*) {
                [weak backInFront];
              }];
  [NSNotificationCenter.defaultCenter
      addObserverForName:GCControllerDidDisconnectNotification
                  object:nil
                   queue:NSOperationQueue.mainQueue
              usingBlock:^(NSNotification*) {
                [weak controllersChanged];
              }];

  // Android's PerfHud, for the part of it the core can report.
  hud_ = XenraMakeLabel(nil, 12, UIFontWeightSemibold, UIColor.whiteColor);
  hud_.shadowColor = UIColor.blackColor;
  hud_.shadowOffset = CGSizeMake(0, 1);
  hud_.hidden = ![[XenraSettings stringForKey:@"hud.fps" fallback:@"true"]
      isEqual:@"true"];
  [self.view addSubview:hud_];
  [NSLayoutConstraint activateConstraints:@[
    [hud_.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
    [hud_.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor
                                   constant:8],
  ]];

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
  if (booted_ || jitTimer_ || choosingMode_) return;
  if (!modeDecided_) {
    // Back from StikDebug, or a debugger already attached: JIT is there for
    // free, so only an explicit JIT-less setting turns it down.
    NSString* mode = resumed_ ? @"jit"
                              : [XenraSettings valueForKey:@"cpu.mode"
                                                      game:name_
                                                  fallback:@"jit"];
    if ([mode isEqual:@"ask"] && !XenraJitActive()) {
      [self askCpuMode];
      return;
    }
    modeDecided_ = YES;
    jitless_ = [mode isEqual:@"jitless"];
    XenraLog([NSString stringWithFormat:@"cpu mode: %@ (setting %@)",
                                        jitless_ ? @"jitless" : @"jit", mode]);
  }
  if (jitless_) {
    [self startJitless];
    return;
  }
  if (og_) {
    NSString* problem = XenraXemuPrepare();
    if (problem) {
      [self showFailure:problem];
      return;
    }
  }
  if (XenraJitActive()) {
    if (XenraXemuNeedsScript()) {
      [self askForScript];
      return;
    }
    if (resumed_ && XenraXemuNeedsSettle()) {
      [self settleThenBoot];
    } else {
      [self boot];
    }
    return;
  }
  // The tool attaches seconds after the handoff, from another app, so the
  // only way to learn it did is to keep asking.
  status_.text = XenraJitStatusText();
  cancel_.hidden = NO;
  RememberForJit(path_, name_);
  XenraOpenJitEnabler();
  __weak XenraGameController* weak = self;
  jitTimer_ = [NSTimer scheduledTimerWithTimeInterval:1
                                              repeats:YES
                                                block:^(NSTimer*) {
                                                  [weak checkJit];
                                                }];
}

// The CPU mode setting is on "Ask each time". JIT is offered first; JIT-less
// only exists for the original Xbox so far (the 360 core has no interpreter).
- (void)askCpuMode {
  choosingMode_ = YES;
  __weak XenraGameController* weak = self;
  __block BOOL chosen = NO;
  void (^pick)(BOOL, BOOL) = ^(BOOL jitless, BOOL remember) {
    chosen = YES;
    [weak chooseCpuMode:jitless remember:remember];
  };
  XenraBladeItem* jit = [XenraBladeItem title:XS(@"JIT (recommended)")
                                       action:^{
                                         pick(NO, NO);
                                       }];
  jit.subtitle = XS(@"Full speed. Opens StikDebug.");
  jit.primary = YES;
  XenraBladeItem* jitAlways = [XenraBladeItem title:XS(@"Always JIT for this game")
                                             action:^{
                                               pick(NO, YES);
                                             }];
  XenraBladeItem* jitless = nil;
  XenraBladeItem* jitlessAlways = nil;
  if (og_) {
    jitless = [XenraBladeItem title:XS(@"JIT-less (slower)")
                             action:^{
                               pick(YES, NO);
                             }];
    jitless.subtitle = XS(@"No debugger needed, but many games run far below "
                          "full speed. A fallback, not a performance mode.");
    jitlessAlways = [XenraBladeItem title:XS(@"Always JIT-less for this game")
                                   action:^{
                                     pick(YES, YES);
                                   }];
  } else {
    // Unavailable: the tap only dismisses, and onDismiss asks again.
    jitless = [XenraBladeItem title:XS(@"JIT-less (coming later)")
                             action:^{
                             }];
    jitless.subtitle = XS(@"Xbox 360 games need JIT for now.");
    jitless.dimmed = YES;
  }
  NSMutableArray* items = [NSMutableArray arrayWithObjects:jit, jitless, nil];
  [items addObject:jitAlways];
  if (jitlessAlways) [items addObject:jitlessAlways];
  XenraBladeSheet* sheet = [XenraBladeSheet showIn:self.view
                                             title:XS(@"How should this game run?")
                                           message:nil
                                             items:items];
  // Tapped away without a choice: this screen has no other way on, so ask
  // again. A row dismisses first and runs its action after, hence the async.
  sheet.onDismiss = ^{
    dispatch_async(dispatch_get_main_queue(), ^{
      XenraGameController* strong = weak;
      if (!strong || chosen || !strong->choosingMode_) return;
      strong->choosingMode_ = NO;
      [strong askCpuMode];
    });
  };
  XenraPadNavScreenChanged();
}

- (void)chooseCpuMode:(BOOL)jitless remember:(BOOL)remember {
  choosingMode_ = NO;
  modeDecided_ = YES;
  jitless_ = jitless;
  if (remember) {
    for (XenraSettingSection* section in [XenraSettings perGameSections]) {
      for (XenraSettingRow* row in section.rows) {
        if ([row.key isEqual:@"cpu.mode"]) {
          [XenraSettings setValue:jitless ? @"jitless" : @"jit" row:row game:name_];
        }
      }
    }
  }
  XenraLog([NSString stringWithFormat:@"cpu mode: %@ (asked%@)",
                                      jitless ? @"jitless" : @"jit",
                                      remember ? @", remembered" : @""]);
  [self viewDidAppear:NO];
}

// No debugger and no executable memory: the OG core's TCG-interpreter build.
// The 360 core has no interpreter yet, so it says so instead of hanging.
- (void)startJitless {
  if (!og_) {
    [self showFailure:XS(@"JIT-less mode is not available for Xbox 360 games "
                         "yet: the 360 core has no CPU interpreter. Set CPU mode "
                         "to JIT in Settings (or for this game) and enable JIT "
                         "with StikDebug.")];
    return;
  }
  XenraXemuSetJitless(YES);
  if (!XenraXemuAvailable()) {
    [self showFailure:XS(@"This build of Xenra does not include the JIT-less "
                         "original Xbox core. Set CPU mode to JIT in Settings.")];
    return;
  }
  if (NSString* problem = XenraXemuPrepare()) {
    [self showFailure:problem];
    return;
  }
  [self boot];
}

// JIT came on without the script, so ask StikDebug to attach it to this process.
// It goes by pid, so the app stays as it is, and the game starts once it is there.
- (void)askForScript {
  status_.text = XS(@"Waiting for StikDebug's universal script…");
  cancel_.hidden = NO;
  RememberForJit(path_, name_);
  XenraLog(@"JIT is on without the script: asking StikDebug for it");
  XenraOpenJitEnabler();
  __weak XenraGameController* weak = self;
  __block int seconds = 0;
  jitTimer_ = [NSTimer scheduledTimerWithTimeInterval:1
                                              repeats:YES
                                                block:^(NSTimer* timer) {
                                                  [weak checkScript:++seconds];
                                                }];
}

- (void)checkScript:(int)seconds {
  const BOOL attached = XenraXemuNeedsSettle();
  if (!attached && seconds < 90) return;
  [jitTimer_ invalidate];
  jitTimer_ = nil;
  XenraLog([NSString stringWithFormat:@"script %@ after %d s",
                                      attached ? @"attached" : @"never attached", seconds]);
  if (attached) {
    [self settleThenBoot];
  } else {
    [self showFailure:XenraXemuFileProblem()];
  }
}

- (void)checkJit {
  if (!XenraJitActive()) return;
  [jitTimer_ invalidate];
  jitTimer_ = nil;
  if (!XenraXemuNeedsSettle()) {
    [self boot];
    return;
  }
  [self settleThenBoot];
}

// The script is still starting when CS_DEBUGGED appears, and a brk sent before it
// is listening goes unanswered. DukeX waits the same 6 seconds. Without TXM there
// is no script and so nothing to wait for.
- (void)settleThenBoot {
  status_.text = XS(@"Waiting for StikDebug to settle…");
  cancel_.hidden = NO;
  [self performSelector:@selector(boot) withObject:nil afterDelay:6];
}

- (void)boot {
  [NSUserDefaults.standardUserDefaults removeObjectForKey:kPendingGameKey];
  NSUserDefaults* defaults = NSUserDefaults.standardUserDefaults;
  const NSInteger attempts = [defaults integerForKey:XenraBootAttemptsKey] + 1;
  [defaults setInteger:attempts forKey:XenraBootAttemptsKey];
  [defaults synchronize];
  XenraLog([NSString stringWithFormat:@"boot attempt %ld", (long)attempts]);
  // Surviving ten seconds means this was not a boot crash loop; clear the
  // count. A crash before this leaves it for the next launch and the report.
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC),
                 dispatch_get_main_queue(), ^{
                   [NSUserDefaults.standardUserDefaults
                       removeObjectForKey:XenraBootAttemptsKey];
                 });
  cancel_.hidden = YES;
  pad_.hidden = !padWanted_;
  if (og_) {
    [self bootXemu];
    return;
  }
  [XenraSettings applyForGame:name_];
  // A 360 title expects slot 0 to be signed in. Reuse the existing standalone
  // profile, or create the default one on a fresh install, before the kernel
  // reads logged_profile_slot_0_xuid at boot.
  NSString* docs = NSSearchPathForDirectoriesInDomains(
                       NSDocumentDirectory, NSUserDomainMask, YES)
                       .firstObject;
  // The name chosen on the Netplay screen. A profile is created with it on the
  // first launch and cannot be renamed afterwards, so this is only read when
  // there is nothing to reuse.
  NSString* gamertag =
      [NSUserDefaults.standardUserDefaults stringForKey:@"xenra.gamertag"];
  if (!XenraNetplayGamertagValid(gamertag)) gamertag = @"Xenra";
  NSString* xuid = XenraNetplayEnsureProfile(
      [docs stringByAppendingPathComponent:@"content"], gamertag);
  XenraLog([NSString stringWithFormat:@"360 profile: %@",
                                      xuid.length ? xuid : @"none"]);
  // The 360 core's own detection goes by chip and calls this one TXM-free. The script
  // being attached is the better evidence: it is waiting for the core's prepare.
  if (XenraXemuNeedsSettle()) setenv("HAS_TXM", "1", 1);
  if (NSString* problem = XenraGameFileProblem(path_)) {
    [self showFailure:problem];
    return;
  }
  xe_ios_set_game_view(metal_);
  XenraLog([NSString stringWithFormat:@"boot: %@", path_.lastPathComponent]);
  XenraLogsBeginSession();
  const int rc = xe_ios_boot(path_.UTF8String);
  if (rc != 0) {
    [self showFailure:@(xe_ios_status_detail())];
    return;
  }
  booted_ = YES;
  [self watchLoad];
  link_ = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick)];
  link_.preferredFramesPerSecond = 60;
  [link_ addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
}

- (void)bootXemu {
  NSString* missing = XenraXemuMissingFiles();
  if (missing) {
    [self showFailure:[NSString stringWithFormat:XS(@"Still needed: %@. Choose "
                                                  "them in the Setup Wizard, "
                                                  "from Settings."),
                                                 missing]];
    return;
  }
  if (NSString* problem = XenraXemuFileProblem()) {
    [self showFailure:problem];
    return;
  }
  XenraLog([NSString stringWithFormat:@"boot: %@", path_.lastPathComponent]);
  XenraLogsBeginSession();
  booted_ = YES;
  metal_.tracksBounds = YES;
  [metal_ setNeedsLayout];
  [metal_ layoutIfNeeded];
  status_.text = XS(@"Booting…");
  [self sendPad];
  __weak XenraGameController* weak = self;
  sdlTimer_ = [NSTimer scheduledTimerWithTimeInterval:0.2
                                              repeats:YES
                                                block:^(NSTimer*) {
                                                  [weak keepSdlAway];
                                                }];
  // A hang leaves no crash report, so take the evidence while it is happening.
  for (int64_t seconds : {20, 45}) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, seconds * NSEC_PER_SEC),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                     if (!XenraXemuStatsLine()) XenraSamplerDump(@"no frame yet");
                   });
  }
  [self watchLoad];
  // A timer, not a dispatch: see XenraXemuRun.
  [self performSelector:@selector(runXemu) withObject:nil afterDelay:0.1];
}

// Every 15 seconds while the game runs, off the main thread, which the core owns.
- (void)watchLoad {
  __weak XenraGameController* weak = self;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC),
                 dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                   XenraGameController* strong = weak;
                   if (!strong || strong->exited_) return;
                   static NSProcessInfoThermalState last_thermal =
                       NSProcessInfoThermalStateNominal;
                   const NSProcessInfoThermalState thermal =
                       NSProcessInfo.processInfo.thermalState;
                   if (thermal != last_thermal) {
                     last_thermal = thermal;
                     XenraLog([NSString
                         stringWithFormat:@"thermal: %@",
                                          XenraThermalStateName(thermal)]);
                   }
                   XenraSamplerLoad();
                   // Every other time, a profile of the emulated CPU as well.
                   static int round;
                   if (++round % 2 == 0) XenraSamplerProfile(4);
                   [weak watchLoad];
                 });
}

- (void)keepSdlAway {
  XenraXemuHideSdlWindows(self.view.window);
  if (status_.text.length && ++sdlTicks_ > 40) status_.text = nil;
  if (++hudTicks_ % 5) return;
  NSString* line = XenraXemuStatsLine();
  if (!line) return;
  status_.text = nil;
  hud_.text = line;
  if (hudTicks_ % 50 == 0) XenraLog(line);
}

- (void)runXemu {
  const int status = XenraXemuRun(path_, name_, metal_.layer);
  XenraLog([NSString stringWithFormat:@"xemu returned %d", status]);
  XenraLogsEndSession();
  exit(0);
}

- (void)showFailure:(NSString*)detail {
  XenraLog([NSString stringWithFormat:@"boot failed: %@", detail]);
  __weak XenraGameController* weak = self;
  XenraBladeItem* share = [XenraBladeItem
      title:XS(@"Share Logs")
      action:^{
        // The sheet closes on any tap, and this screen has no other way out.
        XenraShareLogs(weak, ^{
          [weak showFailure:detail];
        });
      }];
  [XenraBladeSheet showIn:self.view
                    title:XS(@"Could not start the game")
                  message:detail
                    items:@[ share, [XenraBladeItem title:XS(@"Quit App")
                                                   action:^{
                                                     [weak quit];
                                                   }] ]];
  XenraPadNavScreenChanged();
}

- (void)tick {
  xe_ios_pump();
  if (++hudTicks_ % 60 == 0 && xe_ios_fps() > 0) {
    hud_.text = [NSString stringWithFormat:@"%.0f FPS", xe_ios_fps()];
    // Into the log as well, every 5 s, the way the original Xbox core's line is.
    if (hudTicks_ % 300 == 0) {
      XenraLog([NSString stringWithFormat:@"360 FPS %.1f", xe_ios_fps()]);
    }
  }
  [self pollController];
  const int state = xe_ios_status();
  if (state == 1) {
    status_.text = XS(@"Booting…\nThe first launch compiles shaders and can take "
                    "a while.");
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
  ApplyDeadzone(deadzone_, &lx, &ly);
  ApplyDeadzone(deadzone_, &rx, &ry);
  padButtons_ = buttons;
  padAxes_[0] = lx;
  padAxes_[1] = ly;
  padAxes_[2] = rx;
  padAxes_[3] = ry;
  padTriggers_[0] = lt;
  padTriggers_[1] = rt;
  if (og_) {
    [self sendPad];
  } else if (!HasGamepad()) {
    xe_ios_input_set(buttons, lx, ly, rx, ry, lt, rt);
  }
}

// The pad owns port one while it is on screen; otherwise SDL's controller does.
- (void)sendPad {
  XenraXemuSetPad(!pad_.hidden && !HasGamepad(), padButtons_,
                  padAxes_[0], padAxes_[1], padAxes_[2], padAxes_[3],
                  padTriggers_[0], padTriggers_[1]);
}

// Port one changes hands between the touch pad and a controller. The 360 side works
// this out on every tick; the OG side only when told.
- (void)controllersChanged {
  if (og_ && booted_) [self sendPad];
}

- (void)pollController {
  GCExtendedGamepad* g = nil;
  for (GCController* controller in GCController.controllers) {
    if ((g = controller.extendedGamepad)) break;
  }
  if (!g) {
    // Pulled out mid-press: nothing else would let go of what it held. The touch
    // pad's last state is what the guest should see now.
    if (hadGamepad_) {
      hadGamepad_ = NO;
      xe_ios_input_set(padButtons_, padAxes_[0], padAxes_[1], padAxes_[2],
                       padAxes_[3], padTriggers_[0], padTriggers_[1]);
    }
    return;
  }
  hadGamepad_ = YES;
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
  short lx = axis(g.leftThumbstick.xAxis), ly = axis(g.leftThumbstick.yAxis);
  short rx = axis(g.rightThumbstick.xAxis), ry = axis(g.rightThumbstick.yAxis);
  ApplyDeadzone(deadzone_, &lx, &ly);
  ApplyDeadzone(deadzone_, &rx, &ry);
  xe_ios_input_set(b, lx, ly, rx, ry,
                   (unsigned char)(g.leftTrigger.value * 255),
                   (unsigned char)(g.rightTrigger.value * 255));
}

// --- In-game menu -----------------------------------------------------------

- (void)showMenu {
  if (menuTimer_) return;
  [self setGamePaused:YES];
  [self watchMenu];
  __weak XenraGameController* weak = self;
  XenraTouchPad* pad = pad_;
  XenraBladeItem* resume = [XenraBladeItem title:XS(@"Resume") action:nil];
  XenraBladeItem* touch = [XenraBladeItem
      title:pad_.hidden ? XS(@"Show Touch Controls") : XS(@"Hide Touch Controls")
      action:^{
        pad.hidden = !pad.hidden;
        [weak sendPad];
      }];
  XenraBladeItem* share = [XenraBladeItem title:XS(@"Share Logs")
                                         action:^{
                                           XenraShareLogs(weak, nil);
                                         }];
  XenraBladeItem* reset = [XenraBladeItem title:XS(@"Reset")
                                         action:^{
                                           XenraXemuReset();
                                         }];
  // One core per process: Exit Game tears it down and returns to the library,
  // and a later launch explains that the app has to be reopened. Quit App is
  // still the way to end the process.
  XenraBladeItem* exitGame = [XenraBladeItem title:XS(@"Exit Game")
                                            action:^{
                                              [weak exitToLibrary];
                                            }];
  XenraBladeItem* quit = [XenraBladeItem title:XS(@"Quit App")
                                        action:^{
                                          [weak quit];
                                        }];
  quit.destructive = YES;
  [XenraBladeSheet showIn:self.view
                    title:XS(@"Game Menu")
                  message:nil
                    items:og_ ? @[ resume, touch, reset, share, exitGame, quit ]
                              : @[ resume, touch, share, exitGame, quit ]];
  XenraPadNavScreenChanged();
}

- (void)exitToLibrary {
  if (exited_) return;
  exited_ = YES;
  g_core_exited = YES;
  XenraLogsEndSession();
  [link_ invalidate];
  link_ = nil;
  [sdlTimer_ invalidate];
  sdlTimer_ = nil;
  [menuTimer_ invalidate];
  menuTimer_ = nil;
  [jitTimer_ invalidate];
  jitTimer_ = nil;
  [UIApplication.sharedApplication setIdleTimerDisabled:NO];
  [NSUserDefaults.standardUserDefaults removeObjectForKey:kPendingGameKey];
  if (og_) {
    // xemu's shutdown has no join; give it the same three seconds Quit App
    // gives it, then leave the game screen.
    XenraXemuShutdown();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
                     [self.navigationController popViewControllerAnimated:YES];
                     XenraAmbientStart();
                   });
    return;
  }
  xe_ios_exit_to_library();
  [self.navigationController popViewControllerAnimated:YES];
  XenraAmbientStart();
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


// --- Ways out -----------------------------------------------------------------

// The pad holds the menu button, so with the pad hidden there has to be another
// way: Android's swipe up, and Start with Back on a controller.
- (void)swiped:(UISwipeGestureRecognizer*)swipe {
  if (pad_.hidden && booted_) [self showMenu];
}

// Before boot the core has no main loop to pause.
- (void)showMenuFromController {
  if (booted_) [self showMenu];
}

- (void)watchController:(GCController*)controller {
  __weak XenraGameController* weak = self;
  controller.extendedGamepad.valueChangedHandler =
      ^(GCExtendedGamepad* pad, GCControllerElement*) {
        if (pad.buttonMenu.pressed && pad.buttonOptions.pressed) {
          [weak showMenuFromController];
        }
      };
}

- (void)cancelWaiting {
  [UIApplication.sharedApplication setIdleTimerDisabled:NO];
  [NSUserDefaults.standardUserDefaults removeObjectForKey:kPendingGameKey];
  [jitTimer_ invalidate];
  jitTimer_ = nil;
  [NSObject cancelPreviousPerformRequestsWithTarget:self
                                           selector:@selector(boot)
                                             object:nil];
  [self.navigationController popViewControllerAnimated:YES];
}

// --- Pausing ------------------------------------------------------------------

- (void)leavingFront {
  // The menu already holds the guest, and closing it resumes it.
  if (!booted_ || menuTimer_ || pausedForBackground_) return;
  pausedForBackground_ = YES;
  XenraLog(@"leaving the front: guest paused");
  [self setGamePaused:YES];
}

- (void)backInFront {
  if (!pausedForBackground_) return;
  pausedForBackground_ = NO;
  XenraLog(@"back in front: guest resumed");
  [self setGamePaused:NO];
}

- (void)setGamePaused:(BOOL)paused {
  if (og_) {
    XenraXemuSetPaused(paused);
  } else {
    xe_ios_set_paused(paused ? 1 : 0);
  }
}

// Any way of closing the menu resumes the game, so watch the sheet rather than
// every button in it.
- (void)watchMenu {
  [menuTimer_ invalidate];
  __weak XenraGameController* weak = self;
  menuTimer_ = [NSTimer timerWithTimeInterval:0.1
                                      repeats:YES
                                        block:^(NSTimer*) {
                                          [weak menuTick];
                                        }];
  [NSRunLoop.mainRunLoop addTimer:menuTimer_ forMode:NSRunLoopCommonModes];
}

- (void)menuTick {
  for (UIView* view in self.view.subviews) {
    if ([view isKindOfClass:[XenraBladeSheet class]]) return;
  }
  if (self.presentedViewController) return;
  [menuTimer_ invalidate];
  menuTimer_ = nil;
  [self setGamePaused:NO];
}

#ifdef XENRA_UITEST
- (void)showPadForTour {
  pad_.hidden = NO;
}
#endif

@end

#ifdef XENRA_UITEST
void xe_ios_set_paused(int) {}
float xe_ios_fps(void) { return 0; }
#endif
