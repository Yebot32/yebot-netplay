#import "XenraScreens.h"

#import <QuartzCore/QuartzCore.h>

#include <cmath>
#include <cstdlib>

#import "XenraAmbient.h"
#import "XenraBladeView.h"
#import "XenraLogs.h"
#import "XenraMotion.h"
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
                                               errorHandler:nil];
}

@implementation XenraDashboardController {
  XenraBladeButton* onlineBlade_;
  XenraBladeButton* consoleBlade_;
  NSArray<XenraBladeButton*>* blades_;
  UIImageView* logo_;
  NSLayoutConstraint* logoSize_;
  UIButton* orientation_;
  UIStackView* body_;
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

  __weak XenraDashboardController* weak = self;
  XenraBladeButton* library =
      [[XenraBladeButton alloc] initWithTitle:@"Game Library"
                                       action:^{
                                         [weak.navigationController
                                             pushViewController:
                                                 [[XenraLibraryController alloc] init]
                                                       animated:YES];
                                       }];
  onlineBlade_ = [[XenraBladeButton alloc] initWithTitle:@""
                                                  action:^{
                                                    [weak showOnlineNotice];
                                                  }];
  XenraBladeButton* settings =
      [[XenraBladeButton alloc] initWithTitle:@"Settings"
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

  UIStackView* menu = [[UIStackView alloc] initWithArrangedSubviews:blades_];
  menu.axis = UILayoutConstraintAxisVertical;
  menu.spacing = 16;
  menu.translatesAutoresizingMaskIntoConstraints = NO;
  for (UIView* blade in blades_) {
    [blade.heightAnchor constraintEqualToConstant:64].active = YES;
  }

  body_ = [[UIStackView alloc] initWithArrangedSubviews:@[ logo_, menu ]];
  body_.spacing = 40;
  body_.translatesAutoresizingMaskIntoConstraints = NO;
  [self.view addSubview:body_];

  orientation_ = [UIButton buttonWithType:UIButtonTypeSystem];
  orientation_.tintColor = XenraAccent();
  orientation_.titleLabel.font = [UIFont systemFontOfSize:13
                                                   weight:UIFontWeightBold];
  orientation_.backgroundColor = XenraPick(0xFF12100C, 0xC4E2EFB4, 0xFF12100C);
  orientation_.layer.cornerRadius = 8;
  orientation_.layer.borderWidth = 1;
  orientation_.layer.borderColor = XenraAccentAlpha(0x88).CGColor;
  orientation_.contentEdgeInsets = UIEdgeInsetsMake(8, 14, 8, 16);
  orientation_.titleEdgeInsets = UIEdgeInsetsMake(0, 8, 0, -8);
  orientation_.translatesAutoresizingMaskIntoConstraints = NO;
  [orientation_ addTarget:self
                   action:@selector(cycleOrientation)
         forControlEvents:UIControlEventTouchUpInside];
  [self.view addSubview:orientation_];

  XenraHintBar* hints = [[XenraHintBar alloc] initWithFrame:CGRectZero];
  hints.onBack = ^{
    [weak showBackChoice];
  };
  [self.view addSubview:hints];

  logoSize_ = [logo_.widthAnchor constraintEqualToConstant:240];
  UILayoutGuide* safe = self.view.safeAreaLayoutGuide;
  [NSLayoutConstraint activateConstraints:@[
    [body_.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:32],
    [body_.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor
                                         constant:-32],
    [body_.centerYAnchor constraintEqualToAnchor:safe.centerYAnchor],
    logoSize_,
    [logo_.heightAnchor constraintEqualToAnchor:logo_.widthAnchor],
    [orientation_.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor
                                               constant:16],
    [orientation_.topAnchor constraintEqualToAnchor:safe.topAnchor constant:16],
    [hints.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
    [hints.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
    [hints.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-8],
  ]];
  [self updateBlades];
  [self updateOrientationButton];
}

- (void)viewWillLayoutSubviews {
  [super viewWillLayoutSubviews];
  const CGSize size = self.view.bounds.size;
  const BOOL landscape = size.width > size.height;
  body_.axis = landscape ? UILayoutConstraintAxisHorizontal
                         : UILayoutConstraintAxisVertical;
  body_.alignment =
      landscape ? UIStackViewAlignmentCenter : UIStackViewAlignmentFill;
  logoSize_.constant = landscape ? 240 : 164;
}

- (void)viewWillAppear:(BOOL)animated {
  [super viewWillAppear:animated];
  [self updateBlades];
  if (entered_) return;
  entered_ = YES;
  switch (_entry) {
    case XenraDashboardEntryPlain:
      XenraEnter(blades_, 150, 0, 0, 0.1, 0.35, XenraCurveDecelerate);
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
      XenraAnimate(0.56, 0.17, XenraCurveDecelerate,
                   ^{
                     logo.alpha = 1;
                     logo.transform = CGAffineTransformIdentity;
                   },
                   ^{
                     [weak settle];
                   });
      XenraEnter(blades_, 28, 0, 0.26, 0.06, 0.34, XenraCurveDecelerate);
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
  [XenraBladeSheet showIn:self.view
                    title:@"Last Run"
                  message:notice
                    items:@[
                      [XenraBladeItem title:@"Share Logs"
                                     action:^{
                                       XenraShareLogs(weak, nil);
                                     }],
                      [XenraBladeItem title:@"Not Now" action:nil],
                    ]];
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
  onlineBlade_.title = x360 ? @"Netplay" : @"Xbox Live";
  consoleBlade_.title = [NSString
      stringWithFormat:@"Console — %@", x360 ? @"Xbox 360" : @"Xbox Original"];
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
                  message:@"Not on iOS yet. It is part of the parity phase in "
                          "the port plan."
                    items:@[]];
}

// The root screen has nowhere further back to go, so say what the ways out are.
- (void)showBackChoice {
  __weak XenraDashboardController* weak = self;
  XenraBladeItem* setup = [XenraBladeItem title:@"Setup Wizard"
                                         action:^{
                                           XenraRestartSetup(weak.view.window);
                                         }];
  XenraBladeItem* close = [XenraBladeItem title:@"Close App"
                                         action:^{
                                           exit(0);
                                         }];
  [XenraBladeSheet showIn:self.view title:nil message:nil items:@[ setup, close ]];
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
  NSString* symbol = [current isEqual:@"auto"] ? @"arrow.triangle.2.circlepath"
                     : [current isEqual:@"portrait"] ? @"rectangle.portrait"
                                                     : @"rectangle";
  [orientation_ setImage:[UIImage systemImageNamed:symbol]
                forState:UIControlStateNormal];
  [orientation_ setTitle:current.uppercaseString forState:UIControlStateNormal];
}

@end
