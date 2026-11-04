#import "XenraScreens.h"

#import "XenraBladeView.h"
#import "XenraLogs.h"
#import "XenraSettings.h"
#import "XenraTheme.h"
#import "XenraUI.h"

@implementation XenraDashboardController {
  XenraBladeButton* onlineBlade_;
  XenraBladeButton* consoleBlade_;
  UIStackView* body_;
}

- (void)viewDidLoad {
  [super viewDidLoad];
  XenraDashboardBackground* background =
      [[XenraDashboardBackground alloc] initWithFrame:self.view.bounds];
  background.autoresizingMask =
      UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  [self.view addSubview:background];

  UIImageView* logo =
      [[UIImageView alloc] initWithImage:XenraBundleImage(@"xanite_gold_x.png")];
  logo.contentMode = UIViewContentModeScaleAspectFit;
  logo.translatesAutoresizingMaskIntoConstraints = NO;

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
  onlineBlade_.dimmed = YES;
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

  UIStackView* blades = [[UIStackView alloc] initWithArrangedSubviews:@[
    library, onlineBlade_, settings, consoleBlade_
  ]];
  blades.axis = UILayoutConstraintAxisVertical;
  blades.spacing = 14;
  blades.translatesAutoresizingMaskIntoConstraints = NO;
  for (UIView* blade in blades.arrangedSubviews) {
    [blade.heightAnchor constraintEqualToConstant:72].active = YES;
  }

  body_ = [[UIStackView alloc] initWithArrangedSubviews:@[ logo, blades ]];
  body_.spacing = 32;
  body_.alignment = UIStackViewAlignmentCenter;
  body_.distribution = UIStackViewDistributionFill;
  body_.translatesAutoresizingMaskIntoConstraints = NO;
  [self.view addSubview:body_];

  XenraHintBar* hints = [[XenraHintBar alloc] initWithFrame:CGRectZero];
  [self.view addSubview:hints];

  UILayoutGuide* safe = self.view.safeAreaLayoutGuide;
  [NSLayoutConstraint activateConstraints:@[
    [body_.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:24],
    [body_.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
    [body_.centerYAnchor constraintEqualToAnchor:safe.centerYAnchor],
    [logo.widthAnchor constraintEqualToConstant:170],
    [logo.heightAnchor constraintEqualToConstant:170],
    [blades.widthAnchor constraintGreaterThanOrEqualToConstant:280],
    [hints.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
    [hints.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
    [hints.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-8],
  ]];
  [blades setContentHuggingPriority:UILayoutPriorityDefaultLow - 1
                            forAxis:UILayoutConstraintAxisHorizontal];
  [self updateBlades];
}

- (void)viewWillLayoutSubviews {
  [super viewWillLayoutSubviews];
  const CGSize size = self.view.bounds.size;
  body_.axis = size.width > size.height ? UILayoutConstraintAxisHorizontal
                                        : UILayoutConstraintAxisVertical;
  body_.alignment = size.width > size.height ? UIStackViewAlignmentCenter
                                             : UIStackViewAlignmentFill;
}

- (void)viewWillAppear:(BOOL)animated {
  [super viewWillAppear:animated];
  [self updateBlades];
}

- (void)viewDidAppear:(BOOL)animated {
  [super viewDidAppear:animated];
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

- (void)updateBlades {
  const BOOL x360 = [XenraSettings console] == XenraConsole360;
  // The 360 has no Xbox Live here, only a community session broker.
  onlineBlade_.title = x360 ? @"Netplay" : @"Xbox Live";
  consoleBlade_.title = [NSString
      stringWithFormat:@"Console — %@", x360 ? @"Xbox 360" : @"Xbox Original"];
}

- (void)toggleConsole {
  const BOOL x360 = [XenraSettings console] == XenraConsole360;
  [XenraSettings setConsole:x360 ? XenraConsoleOG : XenraConsole360];
  [self updateBlades];
}

- (void)showOnlineNotice {
  [XenraBladeSheet showIn:self.view
                    title:onlineBlade_.title
                  message:@"Not on iOS yet. It is part of the parity phase in "
                          "the port plan."
                    items:@[]];
}

@end
