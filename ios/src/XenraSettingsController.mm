#import "XenraScreens.h"

#include <mach/mach.h>
#import "XenraLanguage.h"
#import "XenraStrings.h"

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#import "XenraAmbient.h"
#import "XenraBladeView.h"
#import "XenraLogs.h"
#import "XenraMotion.h"
#import "XenraPadNav.h"
#import "XenraSettings.h"
#import "XenraTheme.h"
#import "XenraUI.h"

// ConsoleSwitchTransition, as the dashboard runs it.
static const NSTimeInterval kToLight = 0.52;
static const NSTimeInterval kToDark = 0.34;

static UILabel* HintLabel(NSString* text) {
  UILabel* label = XenraMakeLabel(text, 11, UIFontWeightRegular, XenraTextMuted());
  label.numberOfLines = 0;
  label.hidden = text.length == 0;
  return label;
}

static UILabel* RowTitle(NSString* text) {
  UILabel* label = XenraMakeLabel(text, 14, UIFontWeightRegular, XenraTextPrimary());
  label.numberOfLines = 0;
  return label;
}

// A title with its hint under it.
static UIStackView* RowText(NSString* title, NSString* detail) {
  UIStackView* text = [[UIStackView alloc]
      initWithArrangedSubviews:@[ RowTitle(title), HintLabel(detail) ]];
  text.axis = UILayoutConstraintAxisVertical;
  text.spacing = 2;
  return text;
}

// One tab. A rail blade in the sidebar, a pill in the phone's portrait strip:
// settings_tab_bg.xml says why those two are not the same drawable.
@interface XenraSettingsTabView : XenraPressControl
@property(nonatomic, assign) BOOL chosen;
- (instancetype)initWithTitle:(NSString*)title
                         chip:(BOOL)chip
                       action:(void (^)(void))action;
@end

@implementation XenraSettingsTabView {
  BOOL chip_;
  XenraBladeView* blade_;
  UILabel* label_;
}

- (instancetype)initWithTitle:(NSString*)title
                         chip:(BOOL)chip
                       action:(void (^)(void))action {
  self = [super initWithFrame:CGRectZero];
  if (self) {
    chip_ = chip;
    self.title = title;
    self.action = action;
    label_ = XenraMakeLabel(title, chip ? 13 : 14, UIFontWeightBold, XenraText());
    if (chip) {
      self.layer.cornerRadius = 17;
      self.layer.borderWidth = 1;
    } else {
      blade_ = [[XenraBladeView alloc] initWithFrame:CGRectZero];
      blade_.userInteractionEnabled = NO;
      blade_.translatesAutoresizingMaskIntoConstraints = NO;
      [self addSubview:blade_];
      [NSLayoutConstraint activateConstraints:@[
        [blade_.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [blade_.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [blade_.topAnchor constraintEqualToAnchor:self.topAnchor],
        [blade_.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
      ]];
    }
    [self addSubview:label_];
    const CGFloat pad = chip ? 20 : 16;
    [NSLayoutConstraint activateConstraints:@[
      [self.heightAnchor constraintEqualToConstant:chip ? 34 : 48],
      [label_.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:pad],
      [label_.trailingAnchor constraintLessThanOrEqualToAnchor:self.trailingAnchor
                                                      constant:-pad],
      [label_.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
    ]];
    if (chip) {
      [label_.trailingAnchor constraintEqualToAnchor:self.trailingAnchor
                                            constant:-pad]
          .active = YES;
    }
    [self paint];
  }
  return self;
}

- (void)paint {
  const BOOL pressed = self.pressed;
  if (blade_) {
    blade_.state = pressed          ? XenraBladePressed
                   : self.padFocused ? XenraBladeFocused
                   : _chosen         ? XenraBladeChosen
                                     : XenraBladeResting;
    return;
  }
  self.backgroundColor = pressed   ? XenraAccentAlpha(0xAA)
                         : _chosen ? XenraAccent()
                                   : XenraAccentAlpha(0x14);
  self.layer.borderColor =
      (_chosen ? XenraAccent() : XenraAccentAlpha(0x33)).CGColor;
  label_.textColor = _chosen ? XenraBg() : XenraText();
}

- (void)setChosen:(BOOL)chosen {
  _chosen = chosen;
  [self paint];
}

- (void)pressedChanged {
  [self paint];
}

- (void)padFocusChanged {
  [super padFocusChanged];
  [self paint];
}

@end

// A setting with too many values for a segment: its title and hint, the value in
// the accent beside them, and a tap opens the list. Xenia360Settings.listRow.
@interface XenraSettingsValueRow : XenraPressControl
@property(nonatomic, copy) NSString* value;
- (instancetype)initWithTitle:(NSString*)title
                       detail:(NSString*)detail
                       action:(void (^)(void))action;
@end

@implementation XenraSettingsValueRow {
  UIView* wash_;
  UILabel* value_;
}

- (instancetype)initWithTitle:(NSString*)title
                       detail:(NSString*)detail
                       action:(void (^)(void))action {
  self = [super initWithFrame:CGRectZero];
  if (self) {
    self.title = title;
    self.action = action;
    wash_ = [[UIView alloc] init];
    wash_.alpha = 0;
    wash_.backgroundColor = XenraAccentAlpha(0x22);
    wash_.layer.cornerRadius = 8;
    wash_.userInteractionEnabled = NO;
    wash_.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:wash_];
    UIStackView* text = RowText(title, detail);
    text.userInteractionEnabled = NO;
    text.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:text];
    value_ = XenraMakeLabel(nil, 13, UIFontWeightBold, XenraAccentText());
    value_.textAlignment = XenraEndAlignment();
    value_.numberOfLines = 2;
    [self addSubview:value_];
    [NSLayoutConstraint activateConstraints:@[
      [wash_.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:-8],
      [wash_.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:8],
      [wash_.topAnchor constraintEqualToAnchor:self.topAnchor constant:-4],
      [wash_.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:4],
      [text.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
      [text.topAnchor constraintGreaterThanOrEqualToAnchor:self.topAnchor],
      [text.bottomAnchor constraintLessThanOrEqualToAnchor:self.bottomAnchor],
      [text.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
      [text.trailingAnchor constraintEqualToAnchor:value_.leadingAnchor constant:-12],
      [value_.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
      [value_.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
      [value_.widthAnchor constraintEqualToConstant:140],
      [self.heightAnchor constraintGreaterThanOrEqualToConstant:32],
    ]];
  }
  return self;
}

- (void)setValue:(NSString*)value {
  _value = [value copy];
  value_.text = value;
}

- (void)pressedChanged {
  const BOOL pressed = self.pressed;
  [UIView animateWithDuration:pressed ? 0.12 : 0.18
                   animations:^{
                     self->wash_.alpha = pressed ? 1 : 0;
                   }];
}

@end

// One line of a dropdown.
@interface XenraDropdownItem : XenraPressControl
- (instancetype)initWithTitle:(NSString*)title
                     selected:(BOOL)selected
                       action:(void (^)(void))action;
@end

@implementation XenraDropdownItem

- (instancetype)initWithTitle:(NSString*)title
                     selected:(BOOL)selected
                       action:(void (^)(void))action {
  self = [super initWithFrame:CGRectZero];
  if (self) {
    self.title = title;
    self.action = action;
    self.translatesAutoresizingMaskIntoConstraints = YES;
    UILabel* label = XenraMakeLabel(
        title, 16, selected ? UIFontWeightSemibold : UIFontWeightRegular, XenraText());
    [self addSubview:label];
    [NSLayoutConstraint activateConstraints:@[
      [label.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:16],
      [label.trailingAnchor constraintLessThanOrEqualToAnchor:self.trailingAnchor
                                                     constant:-16],
      [label.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
    ]];
  }
  return self;
}

- (void)pressedChanged {
  self.backgroundColor = self.pressed ? XenraAccentAlpha(0x33) : nil;
}

@end

// Android's exposed dropdown: the list opens under its field. Goes away on any tap outside and on a rotation,
// when what it is anchored to moves.
@interface XenraDropdown : UIView
@property(nonatomic, copy) void (^onClose)(void);
+ (instancetype)showIn:(UIView*)host
                 field:(XenraFieldButton*)field
                titles:(NSArray<NSString*>*)titles
              selected:(NSInteger)selected
                  pick:(void (^)(NSInteger index))pick;
- (void)dismiss;
@end

@implementation XenraDropdown

+ (instancetype)showIn:(UIView*)host
                 field:(XenraFieldButton*)field
                titles:(NSArray<NSString*>*)titles
              selected:(NSInteger)selected
                  pick:(void (^)(NSInteger index))pick {
  constexpr CGFloat kRow = 48;
  XenraDropdown* dropdown = [[XenraDropdown alloc] initWithFrame:host.bounds];
  dropdown.autoresizingMask =
      UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

  XenraPressControl* outside =
      [[XenraPressControl alloc] initWithFrame:dropdown.bounds];
  outside.translatesAutoresizingMaskIntoConstraints = YES;
  outside.padSkipped = YES;
  outside.autoresizingMask =
      UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  [outside addTarget:dropdown
                action:@selector(dismiss)
      forControlEvents:UIControlEventTouchDown];
  [dropdown addSubview:outside];

  // XenraFieldButton draws its 56 pt box 8 pt down, under the caption's half.
  const CGRect box = [field convertRect:CGRectMake(0, 8, field.bounds.size.width, 56)
                                 toView:host];

  const UIEdgeInsets safe = host.safeAreaInsets;
  const CGFloat full = titles.count * kRow;
  const CGFloat below = host.bounds.size.height - safe.bottom - 12 - CGRectGetMaxY(box) - 4;
  const CGFloat above = CGRectGetMinY(box) - safe.top - 12 - 4;
  const BOOL under = below >= MIN(full, 3 * kRow) || below >= above;
  const CGFloat height = MIN(full, under ? below : above);
  UIScrollView* list = [[XenraScrollView alloc]
      initWithFrame:CGRectMake(box.origin.x - 1,
                               under ? CGRectGetMaxY(box) + 4
                                     : CGRectGetMinY(box) - 4 - height,
                               box.size.width + 2, height)];
  list.backgroundColor = XenraThemeMode == XenraThemeX360 ? XenraSurfaceVariant()
                                                          : XenraOutlineVariant();
  list.layer.cornerRadius = 4;
  list.layer.borderWidth = 1;
  list.layer.borderColor = XenraAccentAlpha(0x66).CGColor;
  list.contentSize = CGSizeMake(box.size.width, full);
  __weak XenraDropdown* weak = dropdown;
  for (NSUInteger i = 0; i < titles.count; i++) {
    XenraDropdownItem* item = [[XenraDropdownItem alloc]
        initWithTitle:titles[i]
             selected:(NSInteger)i == selected
               action:^{
                 [weak dismiss];
                 pick((NSInteger)i);
               }];
    item.frame = CGRectMake(0, i * kRow, box.size.width, kRow);
    [list addSubview:item];
  }
  const CGFloat reach = selected * kRow - (height - kRow) / 2;
  list.contentOffset = CGPointMake(0, MAX(0, MIN(reach, full - height)));
  [dropdown addSubview:list];

  [host addSubview:dropdown];
  dropdown.alpha = 0;
  XenraAnimate(0.12, 0, XenraCurveStandard,
               ^{
                 dropdown.alpha = 1;
               },
               nil);
  return dropdown;
}

- (void)dismiss {
  if (_onClose) _onClose();
  _onClose = nil;
  XenraAnimate(0.1, 0, XenraCurveStandard,
               ^{
                 self.alpha = 0;
               },
               ^{
                 [self removeFromSuperview];
               });
}

@end

void XenraShowAbout(UIView* host) {
  NSString* version =
      NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"] ?: @"";
  NSMutableArray* items = [NSMutableArray array];
  NSArray* links = @[
    @[ @"Discord", @"https://discord.gg/U5kytJ4dub" ],
    @[ @"Telegram", @"https://t.me/xanite_xbox" ],
    @[ @"GitHub", @"https://github.com/dev-Ali2008/xanite-original-android/tree/main" ],
    @[ @"YouTube", @"https://youtube.com/@emulator_xaniteog?si=v1ai9Gay2IsmII4w" ],
    @[ XS(@"Patreon (Donate)"), @"https://www.patreon.com/cw/Xanite/membership" ],
    @[ @"PayPal", @"https://www.paypal.com/paypalme/Yebot32" ],
  ];
  __weak UIView* weak = host;
  for (NSArray* link in links) {
    NSURL* url = [NSURL URLWithString:link[1]];
    [items addObject:[XenraBladeItem
                         title:link[0]
                        action:^{
                          [UIApplication.sharedApplication
                                        openURL:url
                                        options:@{}
                              completionHandler:^(BOOL success) {
                                if (!success && weak) {
                                  XenraToast(weak, XS(@"Unable to open link."));
                                }
                              }];
                        }]];
  }
  [XenraBladeSheet showIn:host
                    title:XS(@"About Xenra")
                  message:[NSString stringWithFormat:
                                        XS(@"Version %@\n\nDeveloper and owner: yebot32\n"
                                         "Founder and previous owner: Ali Alsaadi\n\n"
                                         "Join the community:"),
                                        version]
                    items:items];
}

// The sidebar is sw600dp's, which an iPad is either way up. A phone keeps
// layout-land's narrower one, and in portrait the pill strip.
@interface XenraSettingsController () <UIDocumentPickerDelegate, XenraPadScreen>
@property(nonatomic, assign) NSInteger startTab;
@end

@implementation XenraSettingsController {
  // Settings.
  NSArray<XenraSettingTab*>* tabs_;
  NSInteger current_;
  UIView* sidebar_;
  NSLayoutConstraint* sideWidth_;
  UIScrollView* chipBar_;
  NSMutableArray<XenraSettingsTabView*>* tabViews_;
  XenraHintBar* hints_;
  NSLayoutConstraint* hintsBottom_;
  NSLayoutConstraint* sideHintsBottom_;
  UIScrollView* scroll_;
  UIStackView* content_;
  NSArray<NSLayoutConstraint*>* sideLayout_;
  NSArray<NSLayoutConstraint*>* chipLayout_;
  // How a row that shows a value is told it changed. Only that row repaints.
  NSMutableDictionary<NSString*, void (^)(void)>* updaters_;
  // Per-game settings.
  NSMutableDictionary<NSString*, XenraFieldButton*>* fields_;
  NSArray<XenraSettingSection*>* gameSections_;
  __weak XenraDropdown* dropdown_;
}

- (void)viewDidLoad {
  [super viewDidLoad];
  self.view.backgroundColor = XenraBg();
  updaters_ = [NSMutableDictionary dictionary];
  if (_game) {
    [self buildPerGame];
  } else {
    [self buildSettings];
  }
}

- (void)viewWillTransitionToSize:(CGSize)size
       withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
  [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
  [dropdown_ dismiss];
}

- (void)leave {
  [self.navigationController popViewControllerAnimated:YES];
}

// --- Settings ---------------------------------------------------------------

- (UIView*)buildSidebar {
  __weak XenraSettingsController* weak = self;
  UIView* sidebar = [[UIView alloc] init];
  sidebar.backgroundColor = XenraCharcoal();
  sidebar.translatesAutoresizingMaskIntoConstraints = NO;

  UILabel* title = XenraMakeLabel(nil, 22, UIFontWeightBold, XenraAccentText());
  title.attributedText = [[NSAttributedString alloc]
      initWithString:XS(@"Settings")
          attributes:@{
            NSFontAttributeName : [UIFont systemFontOfSize:22 weight:UIFontWeightBold],
            NSForegroundColorAttributeName : XenraAccentText(),
            NSKernAttributeName : @(XenraKern(22 * 0.06)),
          }];
  [sidebar addSubview:title];

  XenraPressControl* close = [[XenraPressControl alloc] initWithFrame:CGRectZero];
  close.title = XS(@"Close Settings");
  close.accessibilityLabel = XS(@"Back");
  close.action = ^{
    [weak leave];
  };
  UIImageView* arrow = [[UIImageView alloc]
      initWithImage:XenraDirectional(XenraVectorImage(
                        @[ [XenraVectorPath stroke:@"M20,12H5M11,6l-6,6 6,6"
                                             width:2] ],
                        24, 24))];
  arrow.tintColor = XenraAccentText();
  arrow.translatesAutoresizingMaskIntoConstraints = NO;
  [close addSubview:arrow];
  [sidebar addSubview:close];

  UIView* divider = [[UIView alloc] init];
  divider.backgroundColor = XenraAccentAlpha(0x33);
  divider.translatesAutoresizingMaskIntoConstraints = NO;
  [sidebar addSubview:divider];

  UIStackView* stack = [[UIStackView alloc] init];
  stack.axis = UILayoutConstraintAxisVertical;
  stack.translatesAutoresizingMaskIntoConstraints = NO;
  for (NSUInteger i = 0; i < tabs_.count; i++) {
    if (i > 0) {
      UIView* gap = [[UIView alloc] init];
      UIView* line = [[UIView alloc] init];
      line.backgroundColor = XenraAccentAlpha(0x1A);
      line.translatesAutoresizingMaskIntoConstraints = NO;
      [gap addSubview:line];
      [NSLayoutConstraint activateConstraints:@[
        [gap.heightAnchor constraintEqualToConstant:1],
        [line.leadingAnchor constraintEqualToAnchor:gap.leadingAnchor constant:8],
        [line.trailingAnchor constraintEqualToAnchor:gap.trailingAnchor constant:-8],
        [line.topAnchor constraintEqualToAnchor:gap.topAnchor],
        [line.bottomAnchor constraintEqualToAnchor:gap.bottomAnchor],
      ]];
      [stack addArrangedSubview:gap];
    }
    XenraSettingsTabView* tab =
        [[XenraSettingsTabView alloc] initWithTitle:tabs_[i].title
                                               chip:NO
                                             action:^{
                                               [weak selectTab:(NSInteger)i
                                                      animated:YES];
                                             }];
    [stack addArrangedSubview:tab];
    [tabViews_ addObject:tab];
  }
  UIScrollView* rail = [[XenraScrollView alloc] init];
  rail.showsVerticalScrollIndicator = NO;
  rail.translatesAutoresizingMaskIntoConstraints = NO;
  [rail addSubview:stack];
  [sidebar addSubview:rail];

  XenraHintBar* back = [[XenraHintBar alloc] initWithFrame:CGRectZero];
  back.showsSelect = NO;
  back.onBack = ^{
    [weak leave];
  };
  [sidebar addSubview:back];
  sideHintsBottom_ = [back.bottomAnchor constraintEqualToAnchor:sidebar.bottomAnchor];

  UILayoutGuide* safe = sidebar.safeAreaLayoutGuide;
  [NSLayoutConstraint activateConstraints:@[
    [title.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
    [title.centerYAnchor constraintEqualToAnchor:close.centerYAnchor],
    [title.trailingAnchor constraintLessThanOrEqualToAnchor:close.leadingAnchor
                                                   constant:-8],
    [close.trailingAnchor constraintEqualToAnchor:sidebar.trailingAnchor constant:-16],
    [close.topAnchor constraintEqualToAnchor:safe.topAnchor constant:24],
    [close.widthAnchor constraintEqualToConstant:36],
    [close.heightAnchor constraintEqualToConstant:36],
    [arrow.centerXAnchor constraintEqualToAnchor:close.centerXAnchor],
    [arrow.centerYAnchor constraintEqualToAnchor:close.centerYAnchor],
    [divider.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
    [divider.trailingAnchor constraintEqualToAnchor:sidebar.trailingAnchor constant:-16],
    [divider.topAnchor constraintEqualToAnchor:close.bottomAnchor constant:16],
    [divider.heightAnchor constraintEqualToConstant:1],
    [rail.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
    [rail.trailingAnchor constraintEqualToAnchor:sidebar.trailingAnchor constant:-16],
    [rail.topAnchor constraintEqualToAnchor:divider.bottomAnchor constant:16],
    [rail.bottomAnchor constraintEqualToAnchor:back.topAnchor],
    [stack.leadingAnchor constraintEqualToAnchor:rail.contentLayoutGuide.leadingAnchor],
    [stack.trailingAnchor constraintEqualToAnchor:rail.contentLayoutGuide.trailingAnchor],
    [stack.topAnchor constraintEqualToAnchor:rail.contentLayoutGuide.topAnchor],
    [stack.bottomAnchor constraintEqualToAnchor:rail.contentLayoutGuide.bottomAnchor],
    [stack.widthAnchor constraintEqualToAnchor:rail.frameLayoutGuide.widthAnchor],
    [back.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
    [back.trailingAnchor constraintEqualToAnchor:sidebar.trailingAnchor],
    sideHintsBottom_,
  ]];
  return sidebar;
}

- (UIScrollView*)buildChipBar {
  __weak XenraSettingsController* weak = self;
  UIStackView* stack = [[UIStackView alloc] init];
  stack.spacing = 8;
  stack.alignment = UIStackViewAlignmentCenter;
  stack.translatesAutoresizingMaskIntoConstraints = NO;
  for (NSUInteger i = 0; i < tabs_.count; i++) {
    XenraSettingsTabView* chip =
        [[XenraSettingsTabView alloc] initWithTitle:tabs_[i].title
                                               chip:YES
                                             action:^{
                                               [weak selectTab:(NSInteger)i
                                                      animated:YES];
                                             }];
    [stack addArrangedSubview:chip];
    [tabViews_ addObject:chip];
  }
  UIScrollView* bar = [[XenraScrollView alloc] init];
  bar.showsHorizontalScrollIndicator = NO;
  bar.translatesAutoresizingMaskIntoConstraints = NO;
  [bar addSubview:stack];
  [NSLayoutConstraint activateConstraints:@[
    [stack.leadingAnchor constraintEqualToAnchor:bar.contentLayoutGuide.leadingAnchor
                                        constant:12],
    [stack.trailingAnchor constraintEqualToAnchor:bar.contentLayoutGuide.trailingAnchor
                                         constant:-12],
    [stack.topAnchor constraintEqualToAnchor:bar.contentLayoutGuide.topAnchor],
    [stack.bottomAnchor constraintEqualToAnchor:bar.contentLayoutGuide.bottomAnchor],
    [stack.heightAnchor constraintEqualToAnchor:bar.frameLayoutGuide.heightAnchor],
  ]];
  return bar;
}

- (void)buildSettings {
  tabs_ = [XenraSettings tabs];
  tabViews_ = [NSMutableArray array];

  // The dashboard's art at alpha 0.3 over xenraBg, as activity_settings.xml has it.
  XenraDashboardBackground* background =
      [[XenraDashboardBackground alloc] initForDashboardWithFrame:self.view.bounds];
  background.autoresizingMask =
      UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  background.alpha = 0.3;
  [self.view addSubview:background];

  sidebar_ = [self buildSidebar];
  [self.view addSubview:sidebar_];
  chipBar_ = [self buildChipBar];
  [self.view addSubview:chipBar_];

  __weak XenraSettingsController* weak = self;
  hints_ = [[XenraHintBar alloc] initWithFrame:CGRectZero];
  hints_.showsSelect = NO;
  hints_.onBack = ^{
    [weak leave];
  };
  [self.view addSubview:hints_];

  scroll_ = [[XenraScrollView alloc] init];
  scroll_.alwaysBounceVertical = YES;
  scroll_.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
  scroll_.translatesAutoresizingMaskIntoConstraints = NO;
  [self.view addSubview:scroll_];
  content_ = [[UIStackView alloc] init];
  content_.axis = UILayoutConstraintAxisVertical;
  content_.spacing = 12;
  content_.translatesAutoresizingMaskIntoConstraints = NO;
  [scroll_ addSubview:content_];

  UIView* view = self.view;
  UILayoutGuide* safe = view.safeAreaLayoutGuide;
  UIKeyboardLayoutGuide* keyboard = view.keyboardLayoutGuide;
  if (@available(iOS 17.0, *)) keyboard.usesBottomSafeArea = NO;
  sideWidth_ = [sidebar_.widthAnchor constraintEqualToConstant:280];
  hintsBottom_ = [hints_.bottomAnchor constraintEqualToAnchor:view.bottomAnchor];
  NSLayoutConstraint* fill =
      [scroll_.bottomAnchor constraintEqualToAnchor:view.bottomAnchor];
  fill.priority = UILayoutPriorityDefaultHigh;
  [NSLayoutConstraint activateConstraints:@[
    sideWidth_,
    hintsBottom_,
    [sidebar_.leadingAnchor constraintEqualToAnchor:view.leadingAnchor],
    [sidebar_.topAnchor constraintEqualToAnchor:view.topAnchor],
    [sidebar_.bottomAnchor constraintEqualToAnchor:view.bottomAnchor],
    [chipBar_.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
    [chipBar_.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
    [chipBar_.topAnchor constraintEqualToAnchor:safe.topAnchor],
    [chipBar_.heightAnchor constraintEqualToConstant:48],
    [hints_.leadingAnchor constraintEqualToAnchor:view.leadingAnchor],
    [hints_.trailingAnchor constraintEqualToAnchor:view.trailingAnchor],
    [scroll_.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
    [scroll_.bottomAnchor constraintLessThanOrEqualToAnchor:keyboard.topAnchor],
    [content_.leadingAnchor constraintEqualToAnchor:scroll_.contentLayoutGuide.leadingAnchor
                                           constant:20],
    [content_.trailingAnchor constraintEqualToAnchor:scroll_.contentLayoutGuide.trailingAnchor
                                            constant:-20],
    [content_.topAnchor constraintEqualToAnchor:scroll_.contentLayoutGuide.topAnchor
                                       constant:20],
    [content_.bottomAnchor constraintEqualToAnchor:scroll_.contentLayoutGuide.bottomAnchor
                                          constant:-20],
    [content_.widthAnchor constraintEqualToAnchor:scroll_.frameLayoutGuide.widthAnchor
                                         constant:-40],
  ]];
  sideLayout_ = @[
    [scroll_.leadingAnchor constraintEqualToAnchor:sidebar_.trailingAnchor],
    [scroll_.topAnchor constraintEqualToAnchor:safe.topAnchor],
    fill,
  ];
  chipLayout_ = @[
    [scroll_.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
    [scroll_.topAnchor constraintEqualToAnchor:chipBar_.bottomAnchor],
    [scroll_.bottomAnchor constraintEqualToAnchor:hints_.topAnchor],
  ];
  ((NSLayoutConstraint*)chipLayout_[2]).priority = UILayoutPriorityDefaultHigh;
  [self layoutForSize];
  [self selectTab:MIN(_startTab, (NSInteger)tabs_.count - 1) animated:NO];
}

- (void)layoutForSize {
  const CGSize size = self.view.bounds.size;
  const BOOL tablet = MIN(size.width, size.height) >= 600;
  const BOOL chips = !tablet && size.height > size.width;
  sidebar_.hidden = chips;
  chipBar_.hidden = !chips;
  hints_.hidden = !chips;
  sideWidth_.constant = (tablet ? 280 : 200) + self.view.safeAreaInsets.left;
  hintsBottom_.constant = -XenraHintBarInset(self.view);
  sideHintsBottom_.constant = hintsBottom_.constant;
  [NSLayoutConstraint deactivateConstraints:chips ? sideLayout_ : chipLayout_];
  [NSLayoutConstraint activateConstraints:chips ? chipLayout_ : sideLayout_];
}

- (void)viewWillLayoutSubviews {
  [super viewWillLayoutSubviews];
  if (sidebar_) [self layoutForSize];
}

- (void)selectTab:(NSInteger)index animated:(BOOL)animated {
  if (animated && index == current_) return;
  current_ = index;
  // Sidebar first, then the strip's, each in tab order.
  [tabViews_ enumerateObjectsUsingBlock:^(XenraSettingsTabView* tab, NSUInteger i,
                                          BOOL*) {
    tab.chosen = (NSInteger)(i % self->tabs_.count) == index;
  }];
  [self buildPane];
  [self.view layoutIfNeeded];
  scroll_.contentOffset = CGPointMake(0, -scroll_.adjustedContentInset.top);
  if (!animated) return;
  // The pane as one piece, and only here: a value changing moves nothing.
  UIView* pane = content_;
  pane.alpha = 0;
  pane.transform = CGAffineTransformMakeTranslation(0, XenraTravelSettingsPane);
  XenraAnimate(0.25, 0, XenraCurveDecelerate,
               ^{
                 pane.alpha = 1;
                 pane.transform = CGAffineTransformIdentity;
               },
               nil);
}

- (void)buildPane {
  for (UIView* view in content_.arrangedSubviews) {
    [view removeFromSuperview];
  }
  [updaters_ removeAllObjects];
  for (XenraSettingSection* section in tabs_[current_].sections) {
    XenraCardView* card = [[XenraCardView alloc] initWithFrame:CGRectZero];
    card.body.spacing = 14;
    XenraSectionHeader* header =
        [[XenraSectionHeader alloc] initWithTitle:section.title
                                            style:XenraSectionLabel];
    [card.body addArrangedSubview:header];
    [card.body setCustomSpacing:10 afterView:header];
    for (XenraSettingRow* row in section.rows) {
      [card.body addArrangedSubview:[self viewForRow:row]];
    }
    [content_ addArrangedSubview:card];
  }
}

- (UIView*)viewForRow:(XenraSettingRow*)row {
  switch (row.kind) {
    case XenraRowToggle:
      return [self toggleForRow:row];
    case XenraRowChoice:
      return [self choiceForRow:row];
    case XenraRowSegment:
      return [self segmentForRow:row];
    case XenraRowSlider:
      return [self sliderForRow:row];
    case XenraRowText:
      return [self textForRow:row];
    case XenraRowAction:
      return [self actionForRow:row];
  }
  return nil;
}

- (UIView*)toggleForRow:(XenraSettingRow*)row {
  __weak XenraSettingsController* weak = self;
  UISwitch* toggle = [[UISwitch alloc] init];
  toggle.onTintColor = XenraAccent();
  toggle.on = [[XenraSettings valueForRow:row game:nil] isEqual:@"true"];
  [toggle addAction:[UIAction actionWithHandler:^(UIAction* action) {
            [XenraSettings setValue:((UISwitch*)action.sender).on ? @"true"
                                                                  : @"false"
                                row:row
                               game:nil];
            [weak changed:row];
          }]
      forControlEvents:UIControlEventValueChanged];
  UIStackView* line =
      [[UIStackView alloc] initWithArrangedSubviews:@[ RowText(row.title, row.detail),
                                                       toggle ]];
  line.alignment = UIStackViewAlignmentCenter;
  line.spacing = 12;
  return line;
}

- (UIView*)choiceForRow:(XenraSettingRow*)row {
  __weak XenraSettingsController* weak = self;
  XenraSettingsValueRow* view =
      [[XenraSettingsValueRow alloc] initWithTitle:row.title
                                            detail:row.detail
                                            action:^{
                                              [weak pickFor:row];
                                            }];
  __weak XenraSettingsValueRow* weakView = view;
  void (^paint)(void) = ^{
    weakView.value = [XenraSettings titleForValue:[XenraSettings valueForRow:row
                                                                        game:nil]
                                              row:row];
  };
  paint();
  updaters_[row.key] = paint;
  return view;
}

- (void)pickFor:(XenraSettingRow*)row {
  NSString* current = [XenraSettings valueForRow:row game:nil];
  NSMutableArray* items = [NSMutableArray array];
  __weak XenraSettingsController* weak = self;
  for (NSUInteger i = 0; i < row.choiceValues.count; i++) {
    NSString* value = row.choiceValues[i];
    XenraBladeItem* item = [XenraBladeItem title:row.choiceTitles[i]
                                          action:^{
                                            [XenraSettings setValue:value
                                                                row:row
                                                               game:nil];
                                            [weak changed:row];
                                          }];
    item.primary = [value isEqual:current];
    [items addObject:item];
  }
  [XenraBladeSheet showIn:self.view title:row.title message:nil items:items];
}

- (UIView*)segmentForRow:(XenraSettingRow*)row {
  __weak XenraSettingsController* weak = self;
  XenraSegmentView* segment =
      [[XenraSegmentView alloc] initWithTitles:row.choiceTitles];
  const NSUInteger index =
      [row.choiceValues indexOfObject:[XenraSettings valueForRow:row game:nil]];
  segment.selectedIndex = index == NSNotFound ? 0 : (NSInteger)index;
  segment.onChange = ^(NSInteger picked) {
    if ([row.key isEqual:@"ui.console"]) {
      [weak switchConsole:(XenraConsole)row.choiceValues[picked].integerValue];
      return;
    }
    [XenraSettings setValue:row.choiceValues[picked] row:row game:nil];
    [weak changed:row];
  };
  UILabel* title = RowTitle(row.title);
  UIStackView* stack = [[UIStackView alloc]
      initWithArrangedSubviews:@[ title, segment, HintLabel(row.detail) ]];
  stack.axis = UILayoutConstraintAxisVertical;
  stack.spacing = 6;
  [stack setCustomSpacing:8 afterView:title];
  return stack;
}

- (UIView*)sliderForRow:(XenraSettingRow*)row {
  __weak XenraSettingsController* weak = self;
  XenraSliderRow* slider = [[XenraSliderRow alloc] initWithTitle:row.title
                                                          detail:row.detail
                                                         minimum:row.minimum
                                                         maximum:row.maximum
                                                            step:row.step];
  slider.format = row.format;
  slider.value = [XenraSettings valueForRow:row game:nil].floatValue;
  void (^store)(float) = ^(float value) {
    NSString* text = row.step >= 1
                         ? [NSString stringWithFormat:@"%d", (int)lroundf(value)]
                         : [NSString stringWithFormat:@"%.2f", value];
    [XenraSettings setValue:text row:row game:nil];
    [weak changed:row];
  };
  slider.onCommit = store;
  // Heard while it moves, the way Android's seek bar does it.
  if ([row.key hasPrefix:@"music."]) slider.onChange = store;
  return slider;
}

- (UIView*)textForRow:(XenraSettingRow*)row {
  UITextField* field = [[UITextField alloc] init];
  field.text = [XenraSettings valueForRow:row game:nil];
  field.font = [UIFont systemFontOfSize:14];
  field.textColor = XenraText();
  field.tintColor = XenraAccent();
  field.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
  field.autocorrectionType = UITextAutocorrectionTypeNo;
  field.autocapitalizationType = UITextAutocapitalizationTypeNone;
  field.returnKeyType = UIReturnKeyDone;
  field.layer.cornerRadius = 8;
  field.layer.borderWidth = 1;
  field.layer.borderColor = XenraAccentAlpha(0x66).CGColor;
  field.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 12, 1)];
  field.leftViewMode = UITextFieldViewModeAlways;
  field.accessibilityLabel = row.title;
  [field.heightAnchor constraintEqualToConstant:44].active = YES;
  // Return ends the edit by itself only if something answers the event.
  [field addAction:[UIAction actionWithHandler:^(UIAction* action) {
           [(UITextField*)action.sender resignFirstResponder];
         }]
      forControlEvents:UIControlEventEditingDidEndOnExit];
  [field addAction:[UIAction actionWithHandler:^(UIAction* action) {
           UITextField* sender = (UITextField*)action.sender;
           if (!sender.text.length) sender.text = row.defaultValue;
           [XenraSettings setValue:sender.text row:row game:nil];
         }]
      forControlEvents:UIControlEventEditingDidEnd];
  UILabel* title = RowTitle(row.title);
  UIStackView* stack = [[UIStackView alloc]
      initWithArrangedSubviews:@[ title, field, HintLabel(row.detail) ]];
  stack.axis = UILayoutConstraintAxisVertical;
  stack.spacing = 6;
  return stack;
}

// Android's dropdown is a sheet here, and shows the language by its own name.
- (UIView*)languageRow:(XenraSettingRow*)row {
  __weak XenraSettingsController* weak = self;
  XenraSettingsValueRow* view = [[XenraSettingsValueRow alloc] initWithTitle:row.title
                                                                      detail:row.detail
                                                                      action:nil];
  __weak XenraSettingsValueRow* weakView = view;
  void (^paint)(void) = ^{
    weakView.value = XenraLanguageName();
  };
  view.action = ^{
    XenraShowLanguagePicker(weak.view, paint);
  };
  paint();
  return view;
}

- (UIView*)actionForRow:(XenraSettingRow*)row {
  if ([row.key isEqual:@"ui.language"]) return [self languageRow:row];
  __weak XenraSettingsController* weak = self;
  XenraPillButton* pill = [[XenraPillButton alloc] initWithTitle:row.title
                                                           style:XenraPillOutlined
                                                          action:^{
                                                            [weak tapped:row];
                                                          }];
  UILabel* hint = HintLabel(row.detail);
  UIStackView* stack =
      [[UIStackView alloc] initWithArrangedSubviews:@[ pill, hint ]];
  stack.axis = UILayoutConstraintAxisVertical;
  stack.spacing = 2;
  if ([row.key isEqual:@"og.eeprom"]) {
    __weak UILabel* weakHint = hint;
    void (^paint)(void) = ^{
      NSURL* picked = [XenraSettings urlForBookmark:@"eeprom"];
      weakHint.text = picked ? picked.lastPathComponent
                             : XS(@"Using the one the core generated. Choose a file "
                                "only to bring your own.");
      weakHint.hidden = NO;
    };
    paint();
    updaters_[row.key] = paint;
  }
  return stack;
}

// A value was stored. Everything that follows from it, and nothing else.
- (void)changed:(XenraSettingRow*)row {
  if (void (^paint)(void) = updaters_[row.key]) paint();
  if ([row.key hasPrefix:@"music."]) XenraAmbientStart();
  if ([row.key isEqual:@"ui.orientation"]) XenraApplyOrientation(self);
}

// The theme cannot be re-applied to built views, so the stack is rebuilt under a
// picture of this one, as the dashboard's own switch does, and comes back here.
- (void)switchConsole:(XenraConsole)console {
  UIWindow* window = self.view.window;
  const NSInteger tab = current_;
  XenraCrossfade(window, console == XenraConsole360 ? kToLight : kToDark, ^{
    [XenraSettings setConsole:console];
    UINavigationController* root =
        (UINavigationController*)XenraMakeRoot(XenraDashboardEntryCrossfade);
    XenraSettingsController* again = [[XenraSettingsController alloc] init];
    again.startTab = tab;
    [root pushViewController:again animated:NO];
    window.rootViewController = root;
    [window layoutIfNeeded];
    XenraAmbientStart();
  });
}

- (void)tapped:(XenraSettingRow*)row {
  if ([row.key isEqual:@"setup.rerun"]) {
    XenraRestartSetup(self.view.window);
  } else if ([row.key isEqual:@"privacy"]) {
    XenraShowPrivacyPolicy(self.view);
  } else if ([row.key isEqual:@"about"]) {
    XenraShowAbout(self.view);
  } else if ([row.key isEqual:@"jit.enable"]) {
    XenraOpenJitEnabler();
  } else if ([row.key isEqual:@"memory.limit"]) {
    [self showMemoryLimit];
  } else if ([row.key isEqual:@"log.share"]) {
    XenraShareLogs(self, nil);
  } else if ([row.key isEqual:@"cache.clear"]) {
    [self confirmClearCache];
  } else if ([row.key isEqual:@"og.eeprom"]) {
    [self chooseEeprom:row];
  }
}

// Xenra always asks for the increased memory limit; iOS grants it only when the
// Apple ID that signed the app allows it, which GetMoreRam sets and the next
// Sideloadly install picks up. This shows what iOS gives right now.
- (void)showMemoryLimit {
  task_vm_info_data_t vm = {};
  mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
  double limit = 0;
  if (task_info(mach_task_self(), TASK_VM_INFO, reinterpret_cast<task_info_t>(&vm),
                &count) == KERN_SUCCESS) {
    limit = (vm.phys_footprint + vm.limit_bytes_remaining) / 1073741824.0;
  }
  NSString* message = [NSString stringWithFormat:
      XS(@"iOS lets Xenra use %.1f GB. Xbox 360 games need as much as they can get.\n\n"
         "To raise it: run GetMoreRam, sign in with the Apple ID you use in "
         "Sideloadly, turn on Increased Memory Limit for Xenra, then install Xenra "
         "again with Sideloadly. Xenra already asks for the extra memory; iOS gives "
         "it once your Apple ID allows it."),
      limit];
  XenraBladeItem* open = [XenraBladeItem
      title:XS(@"Open GetMoreRam")
      action:^{
        [UIApplication.sharedApplication
                      openURL:[NSURL URLWithString:@"https://github.com/hugeBlack/GetMoreRam"]
                      options:@{}
            completionHandler:nil];
      }];
  [XenraBladeSheet showIn:self.view
                    title:XS(@"Memory limit")
                  message:message
                    items:@[ open ]];
}

- (void)confirmClearCache {
  __weak XenraSettingsController* weak = self;
  [XenraBladeSheet
      showConfirmIn:self.view
              title:XS(@"Clear shader cache?")
            message:XS(@"Games compile their shaders again on next launch, so the "
                     "first minutes of each will stutter.")
            leading:[XenraBladeItem title:XS(@"Cancel") action:nil]
           trailing:[XenraBladeItem title:XS(@"Clear")
                                   action:^{
                                     [weak clearCache];
                                   }]];
}

- (void)clearCache {
  NSFileManager* files = NSFileManager.defaultManager;
  NSString* caches = NSSearchPathForDirectoriesInDomains(
                         NSCachesDirectory, NSUserDomainMask, YES)
                         .firstObject;
  NSMutableArray* doomed = [NSMutableArray array];
  for (NSString* name in [files contentsOfDirectoryAtPath:caches error:nil]) {
    [doomed addObject:[caches stringByAppendingPathComponent:name]];
  }
  // The original Xbox core keeps its pipeline caches with its other files.
  NSString* docs = NSSearchPathForDirectoriesInDomains(
                       NSDocumentDirectory, NSUserDomainMask, YES)
                       .firstObject;
  NSString* shaders = [docs stringByAppendingPathComponent:@"xemu/shaders"];
  for (NSString* name in [files contentsOfDirectoryAtPath:shaders error:nil]) {
    [doomed addObject:[shaders stringByAppendingPathComponent:name]];
  }
  BOOL failed = NO;
  for (NSString* path in doomed) {
    if (![files removeItemAtPath:path error:nil]) failed = YES;
  }
  XenraToast(self.view, failed ? XS(@"Some files could not be removed.")
                               : XS(@"Shader cache cleared."));
}

- (void)chooseEeprom:(XenraSettingRow*)row {
  __weak XenraSettingsController* weak = self;
  if (![XenraSettings urlForBookmark:@"eeprom"]) {
    [self pickEeprom];
    return;
  }
  [XenraBladeSheet
      showIn:self.view
       title:row.title
     message:nil
       items:@[
         [XenraBladeItem title:XS(@"Choose another file")
                        action:^{
                          [weak pickEeprom];
                        }],
         [XenraBladeItem title:XS(@"Use the generated one")
                        action:^{
                          [XenraSettings clearBookmark:@"eeprom"];
                          [XenraSettings holdPickedFiles];
                          [weak changed:row];
                        }],
       ]];
}

- (void)pickEeprom {
  UIDocumentPickerViewController* picker = [[UIDocumentPickerViewController alloc]
      initForOpeningContentTypes:@[ UTTypeData ]];
  picker.delegate = self;
  [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController*)controller
    didPickDocumentsAtURLs:(NSArray<NSURL*>*)urls {
  NSURL* url = urls.firstObject;
  if (!url) return;
  [url startAccessingSecurityScopedResource];
  [XenraSettings storeBookmark:url key:@"eeprom"];
  [url stopAccessingSecurityScopedResource];
  [XenraSettings holdPickedFiles];
  if (void (^paint)(void) = updaters_[@"og.eeprom"]) paint();
}

// --- Per-game settings ------------------------------------------------------

// The light console's panel fill is translucent, so it uses xenraSurface as
// Android's card does.
static UIColor* PerGameFill(void) {
  return XenraThemeMode == XenraThemeX360 ? XenraSurface() : XenraPanelFill();
}

- (void)buildPerGame {
  gameSections_ = [XenraSettings perGameSections];
  fields_ = [NSMutableDictionary dictionary];
  __weak XenraSettingsController* weak = self;

  XenraDashboardBackground* background =
      [[XenraDashboardBackground alloc] initWithFrame:self.view.bounds];
  background.autoresizingMask =
      UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  [self.view addSubview:background];

  XenraHintBar* hints = [[XenraHintBar alloc] initWithFrame:CGRectZero];
  hints.showsSelect = NO;
  hints.panelStyle = YES;
  hints.onBack = ^{
    [weak leave];
  };
  [self.view addSubview:hints];

  UIScrollView* scroll = [[XenraScrollView alloc] init];
  scroll.alwaysBounceVertical = YES;
  scroll.translatesAutoresizingMaskIntoConstraints = NO;
  [self.view addSubview:scroll];
  scroll_ = scroll;

  XenraPanelView* panel = [[XenraPanelView alloc] initWithFrame:CGRectZero];
  panel.rounded = YES;
  [panel setFill:PerGameFill()];
  panel.translatesAutoresizingMaskIntoConstraints = NO;
  [scroll addSubview:panel];

  UIStackView* body = [[UIStackView alloc] init];
  body.axis = UILayoutConstraintAxisVertical;
  body.translatesAutoresizingMaskIntoConstraints = NO;
  [panel addSubview:body];

  UILabel* heading = XenraMakeLabel(XS(@"Per-Game Settings"), 28, UIFontWeightRegular,
                                    XenraText());
  [body addArrangedSubview:heading];
  [body setCustomSpacing:12 afterView:heading];
  UILabel* name = XenraMakeLabel(_game, 22, UIFontWeightRegular, XenraAccentLightText());
  name.numberOfLines = 0;
  [body addArrangedSubview:name];
  [body setCustomSpacing:12 afterView:name];
  if (_gameFile.length) {
    UILabel* file = XenraMakeLabel(_gameFile, 12, UIFontWeightRegular, XenraTextMuted());
    file.numberOfLines = 0;
    [body setCustomSpacing:4 afterView:name];
    [body addArrangedSubview:file];
    [body setCustomSpacing:12 afterView:file];
  }
  UILabel* intro = XenraMakeLabel(
      XS(@"Choose only the settings this game should override. Leave a field on Use "
       "Global to keep the normal app setting."),
      12, UIFontWeightRegular, XenraTextMuted());
  intro.numberOfLines = 0;
  [body addArrangedSubview:intro];
  [body setCustomSpacing:16 afterView:intro];

  for (XenraSettingSection* section in gameSections_) {
    XenraSectionHeader* header =
        [[XenraSectionHeader alloc] initWithTitle:section.title
                                            style:XenraSectionPill];
    [body addArrangedSubview:header];
    [body setCustomSpacing:12 afterView:header];
    for (XenraSettingRow* row in section.rows) {
      __block __weak XenraFieldButton* weakField = nil;
      XenraFieldButton* field =
          [[XenraFieldButton alloc] initWithTitle:row.title
                                           action:^{
                                             [weak openField:weakField row:row];
                                           }];
      weakField = field;
      fields_[row.key] = field;
      [self paintField:row];
      [body addArrangedSubview:field];
      [body setCustomSpacing:12 afterView:field];
    }
    [body setCustomSpacing:20 afterView:body.arrangedSubviews.lastObject];
  }

  XenraPillButton* clear =
      [[XenraPillButton alloc] initWithTitle:XS(@"Clear Overrides")
                                       style:XenraPillOutlined
                                      action:^{
                                        [weak clearOverrides];
                                      }];
  [body addArrangedSubview:clear];

  UIView* view = self.view;
  UILayoutGuide* safe = view.safeAreaLayoutGuide;
  UILayoutGuide* area = scroll.contentLayoutGuide;
  NSLayoutConstraint* hintsBottom =
      [hints.bottomAnchor constraintEqualToAnchor:view.bottomAnchor];
  hintsBottom_ = hintsBottom;
  [NSLayoutConstraint activateConstraints:@[
    hintsBottom,
    [hints.leadingAnchor constraintEqualToAnchor:view.leadingAnchor],
    [hints.trailingAnchor constraintEqualToAnchor:view.trailingAnchor],
    [scroll.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
    [scroll.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
    [scroll.topAnchor constraintEqualToAnchor:safe.topAnchor],
    [scroll.bottomAnchor constraintEqualToAnchor:hints.topAnchor],
    [panel.leadingAnchor constraintEqualToAnchor:area.leadingAnchor constant:24],
    [panel.trailingAnchor constraintEqualToAnchor:area.trailingAnchor constant:-24],
    [panel.topAnchor constraintEqualToAnchor:area.topAnchor constant:20],
    [panel.bottomAnchor constraintEqualToAnchor:area.bottomAnchor constant:-20],
    [panel.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor
                                      constant:-48],
    [body.leadingAnchor constraintEqualToAnchor:panel.leadingAnchor constant:24],
    [body.trailingAnchor constraintEqualToAnchor:panel.trailingAnchor constant:-24],
    [body.topAnchor constraintEqualToAnchor:panel.topAnchor constant:24],
    [body.bottomAnchor constraintEqualToAnchor:panel.bottomAnchor constant:-24],
  ]];
}

- (void)viewDidLayoutSubviews {
  [super viewDidLayoutSubviews];
  // A band, so it meets the bottom edge where the home indicator leaves it room.
  const BOOL tablet = self.traitCollection.userInterfaceIdiom == UIUserInterfaceIdiomPad;
  if (_game) hintsBottom_.constant = tablet ? 0 : -XenraHintBarInset(self.view);
}

- (NSArray<NSString*>*)valuesOf:(XenraSettingRow*)row {
  return row.kind == XenraRowToggle ? @[ @"true", @"false" ] : row.choiceValues;
}

- (void)paintField:(XenraSettingRow*)row {
  XenraFieldButton* field = fields_[row.key];
  NSString* own = [XenraSettings overrideForRow:row game:_game];
  field.value = own ? [XenraSettings titleForValue:own row:row] : XS(@"Use Global");
  field.detail = [NSString
      stringWithFormat:XS(@"Global default: %@"),
                       [XenraSettings titleForValue:[XenraSettings valueForRow:row
                                                                          game:nil]
                                                row:row]];
}

- (void)openField:(XenraFieldButton*)field row:(XenraSettingRow*)row {
  if (!field) return;
  NSArray<NSString*>* values = [self valuesOf:row];
  NSMutableArray<NSString*>* titles = [NSMutableArray arrayWithObject:XS(@"Use Global")];
  for (NSString* value in values) {
    [titles addObject:[XenraSettings titleForValue:value row:row]];
  }
  NSString* own = [XenraSettings overrideForRow:row game:_game];
  const NSUInteger index = own ? [values indexOfObject:own] : NSNotFound;
  __weak XenraSettingsController* weak = self;
  NSString* game = _game;
  dropdown_ = [XenraDropdown showIn:self.view
                              field:field
                             titles:titles
                           selected:index == NSNotFound ? 0 : (NSInteger)index + 1
                               pick:^(NSInteger picked) {
                                 if (picked == 0) {
                                   [XenraSettings clearOverrideForRow:row game:game];
                                 } else {
                                   [XenraSettings setValue:values[picked - 1]
                                                       row:row
                                                      game:game];
                                 }
                                 [weak paintField:row];
                               }];
  // The cursor stays in the list, and a touch outside only closes it.
  UIScrollView* page = scroll_;
  page.userInteractionEnabled = NO;
  field.opened = YES;
  dropdown_.onClose = ^{
    page.userInteractionEnabled = YES;
    field.opened = NO;
  };
}

// B closes an open list before it leaves the screen.
- (BOOL)xenraPadButton:(XenraPadButton)button {
  if (button != XenraPadButtonB || !dropdown_) return NO;
  [dropdown_ dismiss];
  return YES;
}

- (void)clearOverrides {
  [XenraSettings clearOverridesForGame:_game];
  for (XenraSettingSection* section in gameSections_) {
    for (XenraSettingRow* row in section.rows) {
      [self paintField:row];
    }
  }
  XenraToast(self.view, XS(@"Per-game settings cleared"));
}

#ifdef XENRA_UITEST
// The tour's own scroll, to photograph the end of a long pane.
- (void)tourScrollPaneToEnd {
  UIScrollView* scroll = scroll_;
  const CGFloat end = scroll.contentSize.height + scroll.adjustedContentInset.bottom -
                      scroll.bounds.size.height;
  scroll.contentOffset = CGPointMake(0, MAX(-scroll.adjustedContentInset.top, end));
}
#endif

@end
