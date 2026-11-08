#import "XenraScreens.h"
#import "XenraStrings.h"

#import <QuartzCore/QuartzCore.h>

#include <cmath>
#include <cstdlib>

#import "XenraAmbient.h"
#import "XenraBladeView.h"
#import "XenraLogs.h"
#import "XenraMotion.h"
#import "XenraNetplay.h"
#import "XenraSettings.h"
#import "XenraTheme.h"
#import "XenraUI.h"

// ConsoleSwitchTransition: the eye needs longer going from dark to light.
static const NSTimeInterval kToLight = 0.52;
static const NSTimeInterval kToDark = 0.34;

UIViewController* XenraMakeRoot(XenraDashboardEntry entry) {
  [XenraSettings applyTheme];
  UIViewController* top;
  if ([XenraSettings setupComplete]) {
    XenraDashboardController* dashboard = [[XenraDashboardController alloc] init];
    dashboard.entry = entry;
    top = dashboard;
  } else {
    top = [[XenraSetupController alloc] init];
  }
  return [[XenraNavigationController alloc] initWithRootViewController:top];
}

void XenraApplyOrientation(UIViewController* controller) {
  UIViewController* root = controller.view.window.rootViewController;
  [root setNeedsUpdateOfSupportedInterfaceOrientations];
  UIWindowSceneGeometryPreferencesIOS* geometry =
      [[UIWindowSceneGeometryPreferencesIOS alloc]
          initWithInterfaceOrientations:root.supportedInterfaceOrientations];
  [controller.view.window.windowScene requestGeometryUpdateWithPreferences:geometry
                                               errorHandler:^(NSError* error) {
                                                 XenraLog([NSString
                                                     stringWithFormat:
                                                         @"orientation: %@",
                                                         error]);
                                               }];
}

@implementation XenraDashboardController {
  XenraBladeButton* onlineBlade_;
  XenraBladeButton* consoleBlade_;
  NSArray<XenraBladeButton*>* blades_;
  NSArray<NSLayoutConstraint*>* bladeHeights_;
  UIImageView* logo_;
  UIStackView* menu_;
  XenraChromeButton* orientation_;
  NSLayoutConstraint* logoSize_;
  NSLayoutConstraint* logoX_;
  NSLayoutConstraint* logoY_;
  NSLayoutConstraint* menuLeft_;
  NSLayoutConstraint* menuWidth_;
  NSLayoutConstraint* menuY_;
  NSLayoutConstraint* hintsBottom_;
  BOOL entered_;
  BOOL settled_;
}

- (void)viewDidLoad {
  [super viewDidLoad];
  XenraDashboardBackground* background =
      [[XenraDashboardBackground alloc]
          initForDashboardWithFrame:self.view.bounds];
  background.autoresizingMask =
      UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  [self.view addSubview:background];

  const BOOL x360 = [XenraSettings console] == XenraConsole360;
  logo_ = [[UIImageView alloc]
      initWithImage:XenraBundleImage(x360 ? @"xenra_x_360.png" : @"xenra_x.png")];
  logo_.contentMode = UIViewContentModeScaleAspectFit;
  logo_.translatesAutoresizingMaskIntoConstraints = NO;
  [self.view addSubview:logo_];

  __weak XenraDashboardController* weak = self;
  XenraBladeButton* library =
      [[XenraBladeButton alloc] initWithTitle:XS(@"Game Library")
                                       action:^{
                                         [weak.navigationController
                                             pushViewController:
                                                 [[XenraLibraryController alloc] init]
                                                       animated:YES];
                                       }];
  onlineBlade_ = [[XenraBladeButton alloc] initWithTitle:@""
                                                  action:^{
                                                    if ([XenraSettings console] ==
                                                        XenraConsole360) {
                                                      [weak showNetplay];
                                                    } else {
                                                      [weak showOnlineNotice];
                                                    }
                                                  }];
  XenraBladeButton* settings =
      [[XenraBladeButton alloc] initWithTitle:XS(@"Settings")
                                       action:^{
                                         [weak.navigationController
                                             pushViewController:
                                                 [[XenraSettingsController alloc] init]
                                                       animated:YES];
                                       }];
  consoleBlade_ = [[XenraBladeButton alloc] initWithTitle:@""
                                                   action:^{
                                                     [weak toggleConsole];
                                                   }];
  blades_ = @[ library, onlineBlade_, settings, consoleBlade_ ];

  menu_ = [[UIStackView alloc] initWithArrangedSubviews:blades_];
  menu_.axis = UILayoutConstraintAxisVertical;
  menu_.spacing = 12;
  menu_.translatesAutoresizingMaskIntoConstraints = NO;
  [self.view addSubview:menu_];
  NSMutableArray* heights = [NSMutableArray array];
  for (UIView* blade in blades_) {
    [heights addObject:[blade.heightAnchor constraintEqualToConstant:64]];
  }
  bladeHeights_ = heights;

  orientation_ = [[XenraChromeButton alloc] initWithTitle:@""
                                                     icon:nil
                                                   action:^{
                                                     [weak cycleOrientation];
                                                   }];
  [self.view addSubview:orientation_];

  XenraHintBar* hints = [[XenraHintBar alloc] initWithFrame:CGRectZero];
  hints.onBack = ^{
    [weak showBackChoice];
  };
  [self.view addSubview:hints];

  // Every position is a constant worked out in applyLayout, so one layout pass
  // moves the whole screen and a rotation animates it as one piece.
  UIView* root = self.view;
  logoSize_ = [logo_.widthAnchor constraintEqualToConstant:240];
  logoX_ = [logo_.centerXAnchor constraintEqualToAnchor:root.leftAnchor];
  logoY_ = [logo_.centerYAnchor constraintEqualToAnchor:root.topAnchor];
  menuLeft_ = [menu_.leftAnchor constraintEqualToAnchor:root.leftAnchor];
  menuWidth_ = [menu_.widthAnchor constraintEqualToConstant:400];
  menuY_ = [menu_.centerYAnchor constraintEqualToAnchor:root.topAnchor];
  hintsBottom_ = [hints.bottomAnchor constraintEqualToAnchor:root.bottomAnchor];
  UILayoutGuide* safe = root.safeAreaLayoutGuide;
  [NSLayoutConstraint activateConstraints:bladeHeights_];
  [NSLayoutConstraint activateConstraints:@[
    logoSize_,
    [logo_.heightAnchor constraintEqualToAnchor:logo_.widthAnchor],
    logoX_,
    logoY_,
    menuLeft_,
    menuWidth_,
    menuY_,
    [orientation_.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor
                                               constant:16],
    [orientation_.topAnchor constraintEqualToAnchor:safe.topAnchor constant:16],
    [hints.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
    [hints.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
    hintsBottom_,
  ]];
  [self updateBlades];
  [self updateOrientationButton];
}

- (void)viewWillLayoutSubviews {
  [super viewWillLayoutSubviews];
  [self applyLayout];
}

// activity_xbox_dashboard.xml and adaptLayoutForOrientation. Landscape: 45% logo
// column and 55% menu, padding 32 at the sides and 48 under, so the content sits
// 24 above centre. Portrait: logo over menu as one group, centred, padding
// 24, 20, 24, 96. Those paddings assume a screen with room to spare, so wherever
// a screen is short the blades and logo give way rather than reach the hint row.
- (void)applyLayout {
  const CGSize size = self.view.bounds.size;
  const UIEdgeInsets safe = self.view.safeAreaInsets;
  const CGFloat spacing = menu_.spacing;
  const CGFloat hintsInset = XenraHintBarInset(self.view);
  const CGFloat hintsTop = size.height - 80 - hintsInset;
  const CGFloat chromeBottom = safe.top + 16 + 44;
  hintsBottom_.constant = -hintsInset;

  CGFloat blade = 64, logo, logoX, logoY, menuLeft, menuWidth, menuY;
  if (size.width > size.height) {
    const CGFloat left = safe.left + 32;
    const CGFloat width = size.width - safe.right - 32 - left;
    const CGFloat center = safe.top + (size.height - safe.top - 48) / 2;
    const CGFloat room = 2 * MIN(center - safe.top - 8, hintsTop - 8 - center);
    blade = MAX(44, MIN(64, (room - 3 * spacing) / 4));
    logo = MIN(240, 2 * (center - chromeBottom));
    logoX = left + width * 0.45 / 2;
    logoY = center;
    menuLeft = left + width * 0.45;
    menuWidth = width * 0.55;
    menuY = center;
  } else {
    const CGFloat top = MAX(safe.top + 20, chromeBottom);
    const CGFloat bottom = hintsTop - 16;
    const CGFloat gap = 40;
    const CGFloat menu = 4 * blade + 3 * spacing;
    logo = MAX(96, MIN(164, bottom - top - gap - menu));
    const CGFloat group = logo + gap + menu;
    const CGFloat start = top + (bottom - top - group) / 2;
    logoX = size.width / 2;
    logoY = start + logo / 2;
    menuLeft = safe.left + 24;
    menuWidth = size.width - safe.left - safe.right - 48;
    menuY = start + logo + gap + menu / 2;
  }
  for (NSLayoutConstraint* height in bladeHeights_) height.constant = blade;
  logoSize_.constant = logo;
  logoX_.constant = logoX;
  logoY_.constant = logoY;
  menuLeft_.constant = menuLeft;
  menuWidth_.constant = menuWidth;
  menuY_.constant = menuY;
}

- (void)viewWillAppear:(BOOL)animated {
  [super viewWillAppear:animated];
  [self updateBlades];
  if (entered_) return;
  entered_ = YES;
  switch (_entry) {
    case XenraDashboardEntryPlain:
      XenraEnter(blades_, XenraTravelDashboard, 0, 0, 0.1, 0.35,
                 XenraCurveDecelerate);
      settled_ = YES;
      break;
    case XenraDashboardEntryCrossfade:
      // The dissolve is the entrance: anything moving under the old console's
      // frozen copy reads as doubled text.
      settled_ = YES;
      break;
    case XenraDashboardEntryArriving: {
      // SetupHandoffTransition's timings, from the cover starting to clear.
      logo_.alpha = 0;
      logo_.transform = CGAffineTransformMakeScale(0.88, 0.88);
      __weak XenraDashboardController* weak = self;
      UIImageView* logo = logo_;
      XenraAnimate(0.56, 0.17, XenraCurveDecelerate16,
                   ^{
                     logo.alpha = 1;
                     logo.transform = CGAffineTransformIdentity;
                   },
                   ^{
                     [weak settle];
                   });
      XenraEnter(blades_, 28, 0, 0.26, 0.06, 0.34, XenraCurveDecelerate14);
      XenraEnter(@[ orientation_ ], 0, 0, 0.48, 0, 0.28, XenraCurveStandard);
      break;
    }
  }
}

- (void)settle {
  settled_ = YES;
  [self startLogoPulse];
}

- (void)viewDidAppear:(BOOL)animated {
  [super viewDidAppear:animated];
  if (settled_) [self startLogoPulse];
  NSString* notice = XenraLogsTakeUncleanExitNotice();
  if (!notice) return;
  __weak XenraDashboardController* weak = self;
  [XenraBladeSheet showConfirmIn:self.view
                           title:XS(@"Last Run")
                         message:notice
                         leading:[XenraBladeItem title:XS(@"Not Now") action:nil]
                        trailing:[XenraBladeItem title:XS(@"Share Logs")
                                                action:^{
                                                  XenraShareLogs(weak, nil);
                                                }]];
}

- (void)viewDidDisappear:(BOOL)animated {
  [super viewDidDisappear:animated];
  [logo_.layer removeAnimationForKey:@"pulse"];
}

// The logo's idle breath. Symmetric easing, so that a loop played forwards and
// back has no snap at either end.
- (void)startLogoPulse {
  CABasicAnimation* pulse = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
  pulse.fromValue = @1;
  pulse.toValue = @1.06;
  pulse.duration = 1.8;
  pulse.autoreverses = YES;
  pulse.repeatCount = HUGE_VALF;
  pulse.removedOnCompletion = NO;
  pulse.timingFunction = [CAMediaTimingFunction
      functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
  [logo_.layer addAnimation:pulse forKey:@"pulse"];
}

- (void)updateBlades {
  const BOOL x360 = [XenraSettings console] == XenraConsole360;
  // The 360 has no Xbox Live here, only a community session broker.
  onlineBlade_.title = x360 ? XS(@"Netplay") : @"Xbox Live";
  consoleBlade_.title = [NSString
      stringWithFormat:XS(@"Console — %@"), x360 ? @"Xbox 360" : @"Xbox Original"];
}

- (void)toggleConsole {
  const BOOL x360 = [XenraSettings console] == XenraConsole360;
  UIWindow* window = self.view.window;
  // A theme cannot be re-applied to built views, so the dashboard is rebuilt
  // under a picture of this one, as Android does around recreate().
  XenraCrossfade(window, x360 ? kToDark : kToLight, ^{
    [XenraSettings setConsole:x360 ? XenraConsoleOG : XenraConsole360];
    window.rootViewController = XenraMakeRoot(XenraDashboardEntryCrossfade);
    [window layoutIfNeeded];
    XenraAmbientStart();
  });
}

- (void)showOnlineNotice {
  [XenraBladeSheet showIn:self.view
                    title:onlineBlade_.title
                  message:XS(@"Online play isn't available on iPad and iPhone yet. "
                          "Everything else works without it.")
                    items:@[]];
}

// --- Xbox 360 System Link ----------------------------------------------------

- (NSString*)contentRoot {
  NSString* docs = NSSearchPathForDirectoriesInDomains(
                       NSDocumentDirectory, NSUserDomainMask, YES)
                       .firstObject;
  return [docs stringByAppendingPathComponent:@"content"];
}

- (void)showNetplay {
#ifdef XENRA_UITEST
  // The simulator tour has no core to create a profile with; keep the notice
  // and its single OK action so the tour's existing dismissal still works.
  [self showOnlineNotice];
#else
  NSString* content = [self contentRoot];
  NSString* profile = XenraNetplayProfileSummary(content);
  __weak XenraDashboardController* weak = self;
  NSMutableArray<XenraBladeItem*>* items = [NSMutableArray array];
  if (profile.length) {
    [items addObject:[XenraBladeItem title:XS(@"Change Gamertag")
                                    action:^{
                                      [weak changeGamertag:content];
                                    }]];
  } else {
    [items addObject:[XenraBladeItem title:XS(@"Create Profile")
                                    action:^{
                                      [weak createProfile:content];
                                    }]];
  }
  [items addObject:[XenraBladeItem title:XS(@"Check Network")
                                  action:^{
                                    [weak checkNetwork];
                                  }]];
  [items addObject:[XenraBladeItem
                       title:XS(@"Game Library")
                      action:^{
                        [weak.navigationController
                            pushViewController:[[XenraLibraryController alloc] init]
                                  animated:YES];
                      }]];
  [items addObject:[XenraBladeItem
                       title:XS(@"Network Settings")
                      action:^{
                        [weak.navigationController
                            pushViewController:[[XenraSettingsController alloc] init]
                                  animated:YES];
                      }]];
  NSString* message = [NSString
      stringWithFormat:XS(@"System Link is on. Both devices must be on the same "
                          "Wi-Fi. Host or join from the game's System Link menu."
                          "\n\nProfile: %@"),
                       profile.length ? profile : XS(@"No profile")];
  [XenraBladeSheet showIn:self.view
                    title:XS(@"Netplay")
                  message:message
                    items:items];
#endif
}

- (void)createProfile:(NSString*)content {
  [self promptGamertagWithTitle:XS(@"Create Profile")
                        initial:@"Xenra"
                       existing:nil
                        content:content];
}

- (void)changeGamertag:(NSString*)content {
  [self promptGamertagWithTitle:XS(@"Change Gamertag")
                        initial:XenraNetplayProfileSummary(content) ?: @""
                       existing:XenraNetplayProfileXuid(content)
                        content:content];
}

- (void)promptGamertagWithTitle:(NSString*)title
                        initial:(NSString*)initial
                       existing:(NSString*)existingXuid
                        content:(NSString*)content {
  __weak XenraDashboardController* weak = self;
  UIAlertController* alert = [UIAlertController
      alertControllerWithTitle:title
                       message:XS(@"Enter a gamertag (1-15 characters, starting "
                                 "with a letter).")
                preferredStyle:UIAlertControllerStyleAlert];
  [alert addTextFieldWithConfigurationHandler:^(UITextField* field) {
    field.text = initial;
    field.autocapitalizationType = UITextAutocapitalizationTypeWords;
    field.clearButtonMode = UITextFieldViewModeWhileEditing;
  }];
  [alert addAction:[UIAlertAction actionWithTitle:XS(@"Cancel")
                                            style:UIAlertActionStyleCancel
                                          handler:nil]];
  [alert addAction:[UIAlertAction
                       actionWithTitle:XS(@"Create")
                                 style:UIAlertActionStyleDefault
                               handler:^(UIAlertAction* action) {
                                 NSString* tag =
                                     alert.textFields.firstObject.text ?: @"";
                                 NSString* result = nil;
                                 if (existingXuid.length) {
                                   result = XenraNetplayRenameProfile(
                                                content, existingXuid, tag)
                                                ? XenraNetplayProfileXuid(content)
                                                : nil;
                                 } else {
                                   result =
                                       XenraNetplayCreateProfile(content, tag);
                                 }
                                 if (result.length) {
                                   XenraToast(weak.view,
                                              [NSString stringWithFormat:
                                                  XS(@"Profile ready: %@"),
                                                  tag]);
                                   [weak showNetplay];
                                 } else {
                                   XenraToast(
                                       weak.view,
                                       XS(@"That gamertag cannot be used."));
                                 }
                               }]];
  [self presentViewController:alert animated:YES completion:nil];
}

- (void)checkNetwork {
  __weak XenraDashboardController* weak = self;
  XenraToast(self.view, XS(@"Checking the network…"));
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
    NSString* adapter = XenraNetplayAdapterSummary();
    XenraNetplayUPnPDiscover(2000);
    NSString* status = XenraNetplayUPnPStatus();
    NSString* lan = XenraNetplayUPnPLanAddress();
    NSString* external = XenraNetplayUPnPExternalAddress();
    BOOL mapped = XenraNetplayUPnPTestMapping(3074);
    dispatch_async(dispatch_get_main_queue(), ^{
      NSString* message =
          [NSString stringWithFormat:@"%@\n\nUPnP: %@\nLAN: %@\nExternal: %@\n"
                                     @"UDP 3074: %@",
                                     adapter ?: @"no adapter", status ?: @"-",
                                     lan.length ? lan : @"-",
                                     external.length ? external : @"-",
                                     mapped ? @"mapped" : @"not mapped"];
      [XenraBladeSheet showIn:weak.view
                        title:XS(@"Network check")
                      message:message
                        items:@[]];
    });
  });
}

// The root screen has nowhere further back to go, so say what the ways out are.
- (void)showBackChoice {
  __weak XenraDashboardController* weak = self;
  [XenraBladeSheet showConfirmIn:self.view
                           title:XS(@"What would you like to do?")
                         message:nil
                         leading:[XenraBladeItem title:XS(@"Setup Wizard")
                                                action:^{
                                                  XenraRestartSetup(weak.view.window);
                                                }]
                        trailing:[XenraBladeItem title:XS(@"Close App")
                                                action:^{
                                                  exit(0);
                                                }]];
}

- (void)cycleOrientation {
  NSString* current = [XenraSettings stringForKey:@"ui.orientation"
                                         fallback:@"auto"];
  NSString* next = [current isEqual:@"auto"]       ? @"portrait"
                   : [current isEqual:@"portrait"] ? @"landscape"
                                                   : @"auto";
  [XenraSettings setString:next forKey:@"ui.orientation"];
  [self updateOrientationButton];
  XenraApplyOrientation(self);
}

- (void)updateOrientationButton {
  NSString* current = [XenraSettings stringForKey:@"ui.orientation"
                                         fallback:@"auto"];
  // The stored value is a key. These are its names.
  NSDictionary* names = @{
    @"auto" : XS(@"Auto"),
    @"portrait" : XS(@"Portrait"),
    @"landscape" : XS(@"Landscape"),
  };
  NSString* name = names[current] ?: current;
  orientation_.title = name;  // shown in capitals
  orientation_.icon = XenraOrientationIcon(current, 24);
  orientation_.accessibilityLabel =
      [NSString stringWithFormat:XS(@"Orientation: %@. Tap to change."), name];
}

@end
