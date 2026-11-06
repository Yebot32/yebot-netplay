#import "XenraScreens.h"
#import "XenraLanguage.h"
#import "XenraStrings.h"

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#import "XenraBladeView.h"
#import "XenraMotion.h"
#import "XenraSettings.h"
#import "XenraTheme.h"
#import "XenraUI.h"
#include "xenia/base/memory.h"

// Android's five steps. The last was the Vulkan driver, which iOS has no use
// for; what stands between an iOS install and a running game is JIT, so that
// step is the one that changed.
static const NSInteger kSteps = 5;

// Android runs its pages edge to edge, with 24 dp either side. On an iPad a card
// that wide is mostly air, so the column stops here.
static const CGFloat kColumn = 680;

// The silver ramp's own tokens. The wizard is the only screen that is ever silver.
static UIColor* SurfaceContainer(void) { return XenraHex(0xFF212123); }
static UIColor* OutlineShadow(void) { return XenraHex(0xFF2C2D30); }
// xaniteog_notice: the same amber in every palette.
static UIColor* Notice(void) { return XenraHex(0xFFFFD54F); }

static NSString* const kIconMemory =
    @"M360-400v-160q0-17 11.5-28.5T400-600h160q17 0 28.5 11.5T600-560v160q0 "
     "17-11.5 28.5T560-360H400q-17 0-28.5-11.5T360-400Zm80-40h80v-80h-80v80Zm-80 "
     "280v-40h-80q-33 0-56.5-23.5T200-280v-80h-40q-17 0-28.5-11.5T120-400q0-17 "
     "11.5-28.5T160-440h40v-80h-40q-17 0-28.5-11.5T120-560q0-17 "
     "11.5-28.5T160-600h40v-80q0-33 23.5-56.5T280-760h80v-40q0-17 "
     "11.5-28.5T400-840q17 0 28.5 11.5T440-800v40h80v-40q0-17 "
     "11.5-28.5T560-840q17 0 28.5 11.5T600-800v40h80q33 0 56.5 "
     "23.5T760-680v80h40q17 0 28.5 11.5T840-560q0 17-11.5 "
     "28.5T800-520h-40v80h40q17 0 28.5 11.5T840-400q0 17-11.5 "
     "28.5T800-360h-40v80q0 33-23.5 56.5T680-200h-80v40q0 17-11.5 "
     "28.5T560-120q-17 0-28.5-11.5T520-160v-40h-80v40q0 17-11.5 "
     "28.5T400-120q-17 0-28.5-11.5T360-160Zm320-120v-400H280v400h400ZM480-480Z";
static NSString* const kIconUploadFile =
    @"M440-367v127q0 17 11.5 28.5T480-200q17 0 28.5-11.5T520-240v-127l36 36q6 6 "
     "13.5 9t15 2.5q7.5-.5 14.5-3.5t13-9q11-12 "
     "11.5-28T612-388L508-492q-6-6-13-8.5t-15-2.5q-8 0-15 2.5t-13 8.5L348-388q-12 "
     "12-11.5 28t12.5 28q12 11 28 11.5t28-11.5l35-35ZM240-80q-33 "
     "0-56.5-23.5T160-160v-640q0-33 23.5-56.5T240-880h287q16 0 30.5 6t25.5 17l194 "
     "194q11 11 17 25.5t6 30.5v447q0 33-23.5 56.5T720-80H240Zm280-560v-160H240v640"
     "h480v-440H560q-17 0-28.5-11.5T520-640ZM240-800v200-200 640-640Z";
static NSString* const kIconHardDrive =
    @"M560-200q17 0 28.5-11.5T600-240q0-17-11.5-28.5T560-280q-17 0-28.5 "
     "11.5T520-240q0 17 11.5 28.5T560-200Zm120 0q17 0 28.5-11.5T720-240q0-17-11.5"
     "-28.5T680-280q-17 0-28.5 11.5T640-240q0 17 11.5 "
     "28.5T680-200ZM120-440v-360q0-33 23.5-56.5T200-880h560q33 0 56.5 "
     "23.5T840-800v360h-80v-360H200v360h-80Zm80 80v200h560v-200H200Zm0 280q-33 "
     "0-56.5-23.5T120-160v-280h720v280q0 33-23.5 "
     "56.5T760-80H200Zm0-360h560-560Zm0 80h560-560Z";
static NSString* const kIconFolderOpen =
    @"M160-160q-33 0-56.5-23.5T80-240v-480q0-33 23.5-56.5T160-800h207q16 0 30.5 "
     "6t25.5 17l57 57h360q17 0 28.5 11.5T880-680q0 17-11.5 "
     "28.5T840-640H447l-80-80H160v480l79-263q8-26 29.5-41.5T316-560h516q41 0 64.5 "
     "32.5T909-457l-72 240q-8 26-29.5 41.5T760-160H160Zm84-80h516l72-240H316l-72 "
     "240Zm-84-262v-218 218Zm84 262 72-240-72 240Z";
static NSString* const kIconSyncAlt =
    @"m233-280 76 76q12 12 11.5 28T308-148q-12 11-28 "
     "11.5T252-148L108-292q-6-6-8.5-13T97-320q0-8 2.5-15t8.5-13l144-144q11-11 "
     "27.5-11t28.5 11q12 12 12 28.5T308-435l-75 75h567q17 0 28.5 11.5T840-320q0 "
     "17-11.5 28.5T800-280H233Zm494-320H160q-17 0-28.5-11.5T120-640q0-17 "
     "11.5-28.5T160-680h567l-76-76q-12-12-11.5-28t12.5-28q12-11 28-11.5t28 "
     "11.5l144 144q6 6 8.5 13t2.5 15q0 8-2.5 15t-8.5 13L708-468q-11 "
     "11-27.5 11T652-468q-12-12-12-28.5t12-28.5l75-75Z";
static NSString* const kIconPlay =
    @"M320-273v-414q0-17 12-28.5t28-11.5q5 0 10.5 1.5T381-721l326 207q9 6 13.5 "
     "15t4.5 19q0 10-4.5 19T707-446L381-239q-5 3-10.5 "
     "4.5T360-233q-16 0-28-11.5T320-273Zm80-207Zm0 134 210-134-210-134v268Z";
static NSString* const kIconWarning =
    @"M109-120q-11 0-20-5.5T75-140q-5-9-5.5-19.5T75-180l371-640q6-10 "
     "15.5-15t19.5-5q10 0 19.5 5t15.5 15l371 640q6 10 5.5 20.5T887-140q-5 9-14 "
     "14.5t-20 5.5H109Zm69-80h604L480-720 178-200Zm302-40q17 0 "
     "28.5-11.5T520-280q0-17-11.5-28.5T480-320q-17 0-28.5 11.5T440-280q0 17 11.5 "
     "28.5T480-240Zm0-120q17 0 28.5-11.5T520-400v-120q0-17-11.5-28.5T480-560q-17 "
     "0-28.5 11.5T440-520v120q0 17 11.5 28.5T480-360Zm0-100Z";

// BiosFileCheck: advice, not a gate. The file is kept whatever this says.
static NSString* FileWarning(NSString* key, NSURL* url) {
  NSNumber* size = nil;
  [url getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
  if (!size) {
    return XS(@"That file could not be read. It may have been moved, or the app "
            "may not have been granted access to it.");
  }
  const unsigned long long bytes = size.unsignedLongLongValue;
  NSString* shown = [NSByteCountFormatter
      stringFromByteCount:(long long)bytes
               countStyle:NSByteCountFormatterCountStyleBinary];
  if ([key isEqual:@"mcpx"] && bytes != 512) {
    return [NSString stringWithFormat:XS(@"The MCPX boot ROM is exactly 512 bytes. "
                                       "This file is %@, so it is probably not "
                                       "the boot ROM."),
                                      shown];
  }
  if ([key isEqual:@"flash"] && bytes != 256 * 1024 && bytes != 512 * 1024 &&
      bytes != 1024 * 1024) {
    return [NSString stringWithFormat:XS(@"An Xbox BIOS image is 256 KB, 512 KB or "
                                       "1 MB. This file is %@, so it is "
                                       "probably not a BIOS image."),
                                      shown];
  }
  if ([key isEqual:@"hdd"] && bytes < 1024ull * 1024 * 1024 &&
      ![url.pathExtension.lowercaseString isEqual:@"qcow2"]) {
    return [NSString stringWithFormat:XS(@"An Xbox hard-disk image is a .qcow2 "
                                       "file, or a raw image of at least 1 GB. "
                                       "This file is %@ and is not a qcow2."),
                                      shown];
  }
  return nil;
}

static NSString* JitStatus(void) {
  const xe::memory::JitSignatureState state =
      xe::memory::QueryJitSignatureState();
  if (state.cs_debugged || !state.get_task_allow) return XenraJitStatusText();
  return XS(@"Waiting for JIT. Enable it for Xenra in StikDebug, then come back.");
}

// --- Pieces -----------------------------------------------------------------

// Whatever was just added to `stack` keeps this much air under it.
static void Gap(UIStackView* stack, CGFloat gap) {
  [stack setCustomSpacing:gap afterView:stack.arrangedSubviews.lastObject];
}

// Running text. It must take the width of the column and never argue for one: at
// equal priority its single-line width beats the column, and the label keeps the
// height it worked out for that.
static void Wraps(UILabel* label) {
  label.numberOfLines = 0;
  [label setContentCompressionResistancePriority:UILayoutPriorityDefaultLow
                                         forAxis:UILayoutConstraintAxisHorizontal];
}

static UILabel* Paragraph(NSString* text, CGFloat size, UIColor* color,
                          CGFloat lineHeight, NSTextAlignment alignment) {
  NSMutableParagraphStyle* style = [[NSMutableParagraphStyle alloc] init];
  style.lineHeightMultiple = lineHeight;
  style.alignment = alignment;
  UILabel* label = XenraMakeLabel(nil, size, UIFontWeightRegular, color);
  Wraps(label);
  label.attributedText = [[NSAttributedString alloc]
      initWithString:text
          attributes:@{
            NSFontAttributeName : [UIFont systemFontOfSize:size],
            NSForegroundColorAttributeName : color,
            NSParagraphStyleAttributeName : style,
          }];
  return label;
}

// A view that hugs its content, in the middle of a column that stretches.
static UIView* Centred(UIView* view) {
  UIView* row = [[UIView alloc] init];
  row.translatesAutoresizingMaskIntoConstraints = NO;
  view.translatesAutoresizingMaskIntoConstraints = NO;
  [row addSubview:view];
  [NSLayoutConstraint activateConstraints:@[
    [view.centerXAnchor constraintEqualToAnchor:row.centerXAnchor],
    [view.topAnchor constraintEqualToAnchor:row.topAnchor],
    [view.bottomAnchor constraintEqualToAnchor:row.bottomAnchor],
    [view.leadingAnchor constraintGreaterThanOrEqualToAnchor:row.leadingAnchor],
  ]];
  return row;
}

static UIView* Indented(UIView* view, CGFloat indent) {
  UIView* row = [[UIView alloc] init];
  row.translatesAutoresizingMaskIntoConstraints = NO;
  view.translatesAutoresizingMaskIntoConstraints = NO;
  [row addSubview:view];
  [NSLayoutConstraint activateConstraints:@[
    [view.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:indent],
    [view.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
    [view.topAnchor constraintEqualToAnchor:row.topAnchor],
    [view.bottomAnchor constraintEqualToAnchor:row.bottomAnchor],
  ]];
  return row;
}

static UIImageView* Icon(NSString* data, CGFloat size, UIColor* tint) {
  UIImageView* icon =
      [[UIImageView alloc] initWithImage:XenraMaterialIcon(data, size)];
  icon.tintColor = tint;
  icon.translatesAutoresizingMaskIntoConstraints = NO;
  [icon.widthAnchor constraintEqualToConstant:size].active = YES;
  [icon.heightAnchor constraintEqualToConstant:size].active = YES;
  return icon;
}

// The wizard's cards differ from a settings card by these numbers and no others:
// SetupCard is 22 / 1.5 / 18 with 6 of elevation, BiosCard 14 / 1 / 12 with 3.
static XenraCardView* Card(CGFloat radius, CGFloat stroke, CGFloat padding,
                           CGFloat elevation, UIColor* fill) {
  XenraCardView* card = [[XenraCardView alloc] initWithFrame:CGRectZero];
  card.padding = padding;
  card.backgroundColor = fill;
  card.layer.cornerRadius = radius;
  card.layer.borderWidth = stroke;
  card.layer.borderColor = XenraOutlineVariant().CGColor;
  card.layer.shadowColor = XenraShadow().CGColor;
  card.layer.shadowOpacity = 0.4;
  card.layer.shadowRadius = elevation;
  card.layer.shadowOffset = CGSizeMake(0, elevation / 2);
  return card;
}

// setup_wizard_path_background: a rim, and inset from it a 2 pt silver outline.
static UIView* PathPill(UILabel* label, CGFloat radius, CGFloat top, CGFloat bottom) {
  UIView* rim = [[UIView alloc] init];
  rim.translatesAutoresizingMaskIntoConstraints = NO;
  rim.backgroundColor = OutlineShadow();
  rim.layer.cornerRadius = radius;
  UIView* face = [[UIView alloc] init];
  face.translatesAutoresizingMaskIntoConstraints = NO;
  face.backgroundColor = SurfaceContainer();
  face.layer.cornerRadius = radius - 1;
  face.layer.borderWidth = 2;
  face.layer.borderColor = XenraAccent().CGColor;
  [rim addSubview:face];
  [rim addSubview:label];
  [NSLayoutConstraint activateConstraints:@[
    [face.leadingAnchor constraintEqualToAnchor:rim.leadingAnchor constant:1],
    [face.trailingAnchor constraintEqualToAnchor:rim.trailingAnchor constant:-1],
    [face.topAnchor constraintEqualToAnchor:rim.topAnchor constant:1],
    [face.bottomAnchor constraintEqualToAnchor:rim.bottomAnchor constant:-2],
    [label.leadingAnchor constraintEqualToAnchor:rim.leadingAnchor constant:15],
    [label.trailingAnchor constraintEqualToAnchor:rim.trailingAnchor constant:-15],
    [label.topAnchor constraintEqualToAnchor:rim.topAnchor constant:top],
    [label.bottomAnchor constraintEqualToAnchor:rim.bottomAnchor constant:-bottom],
  ]];
  return rim;
}

// Android draws the status as bare coloured text. The capsule is ours: it keeps
// the word from reading as part of the title beside it.
static UIView* StatusPill(UILabel* label) {
  UIView* pill = [[UIView alloc] init];
  pill.translatesAutoresizingMaskIntoConstraints = NO;
  pill.layer.cornerRadius = 10;
  [pill addSubview:label];
  [label setContentHuggingPriority:UILayoutPriorityRequired
                           forAxis:UILayoutConstraintAxisHorizontal];
  [label setContentCompressionResistancePriority:UILayoutPriorityRequired
                                         forAxis:UILayoutConstraintAxisHorizontal];
  [NSLayoutConstraint activateConstraints:@[
    [label.leadingAnchor constraintEqualToAnchor:pill.leadingAnchor constant:9],
    [label.trailingAnchor constraintEqualToAnchor:pill.trailingAnchor constant:-9],
    [label.topAnchor constraintEqualToAnchor:pill.topAnchor constant:3],
    [label.bottomAnchor constraintEqualToAnchor:pill.bottomAnchor constant:-3],
  ]];
  return pill;
}

// The icon, title and subtitle at the head of a step. BIOS has the compact one,
// because three cards have to fit under it.
static void AddHeader(UIStackView* stack, NSString* icon, BOOL compact,
                      NSString* title, NSString* body) {
  [stack addArrangedSubview:Centred(Icon(icon, compact ? 40 : 56, XenraAccent()))];
  Gap(stack, compact ? 6 : 12);
  UILabel* heading = XenraMakeLabel(title, compact ? 22 : 24, UIFontWeightBold,
                                    XenraText());
  Wraps(heading);
  heading.textAlignment = NSTextAlignmentCenter;
  [stack addArrangedSubview:heading];
  if (!body) return;
  Gap(stack, compact ? 2 : 6);
  [stack addArrangedSubview:Paragraph(body, compact ? 12 : 14, XenraTextMuted(),
                                      1.15, NSTextAlignmentCenter)];
}

// What a pick has to touch, so that nothing else on the page moves.
@interface XenraSetupSlot : NSObject
@property(nonatomic, strong) UILabel* status;
@property(nonatomic, strong) UIView* statusPill;
@property(nonatomic, strong) UILabel* path;
@property(nonatomic, strong) UILabel* warning;  // nil for a folder
@property(nonatomic, strong) UIView* warningRow;
@end

@implementation XenraSetupSlot
@end

@interface XenraSetupController () <UIDocumentPickerDelegate>
@end

@implementation XenraSetupController {
  NSInteger step_;
  BOOL moving_;
  UIView* pager_;
  UIView* page_;
  UIStackView* dots_;
  XenraLanguageButton* language_;
  XenraIconToggleGroup* orientation_;
  XenraPillButton* back_;
  XenraPillButton* continue_;
  NSMutableDictionary<NSString*, XenraSetupSlot*>* slots_;
  NSString* pickingKey_;
  UILabel* jitStatus_;
  NSTimer* jitTimer_;
}

- (void)viewDidLoad {
  [super viewDidLoad];
  slots_ = [NSMutableDictionary dictionary];
  XenraDashboardBackground* background =
      [[XenraDashboardBackground alloc] initWithFrame:self.view.bounds];
  background.autoresizingMask =
      UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  [self.view addSubview:background];

  dots_ = [[UIStackView alloc] init];
  dots_.spacing = 5;
  dots_.distribution = UIStackViewDistributionFillEqually;
  dots_.translatesAutoresizingMaskIntoConstraints = NO;
  for (NSInteger i = 0; i < kSteps; i++) {
    UIView* dot = [[UIView alloc] init];
    dot.layer.cornerRadius = 3;
    [dot.heightAnchor constraintEqualToConstant:6].active = YES;
    [dots_ addArrangedSubview:dot];
  }
  [self.view addSubview:dots_];

  __weak XenraSetupController* weak = self;
  language_ = [[XenraLanguageButton alloc] initWithAction:^{
    [weak chooseLanguage];
  }];
  [self.view addSubview:language_];
  orientation_ = [[XenraIconToggleGroup alloc]
      initWithIcons:@[
        XenraOrientationIcon(@"portrait", 22),
        XenraOrientationIcon(@"landscape", 22)
      ]
             titles:@[ XS(@"Vertical"), XS(@"Horizontal") ]];
  orientation_.onChange = ^(NSInteger index) {
    [weak orientationChanged:index];
  };
  [self.view addSubview:orientation_];

  pager_ = [[UIView alloc] init];
  pager_.clipsToBounds = YES;
  pager_.translatesAutoresizingMaskIntoConstraints = NO;
  [self.view addSubview:pager_];

  UIView* divider = [[UIView alloc] init];
  divider.backgroundColor = XenraOutlineVariant();
  divider.translatesAutoresizingMaskIntoConstraints = NO;
  [self.view addSubview:divider];

  back_ = [[XenraPillButton alloc] initWithTitle:XS(@"Back")
                                           style:XenraPillOutlined
                                          action:^{
                                            [weak goBack];
                                          }];
  continue_ = [[XenraPillButton alloc] initWithTitle:XS(@"Continue")
                                               style:XenraPillFilled
                                              action:^{
                                                [weak goOn];
                                              }];
  continue_.icon = XenraMaterialIcon(kIconPlay, 22);
  continue_.iconAtEnd = YES;
  UIView* spacer = [[UIView alloc] init];
  UIStackView* bottom =
      [[UIStackView alloc] initWithArrangedSubviews:@[ back_, spacer, continue_ ]];
  bottom.alignment = UIStackViewAlignmentCenter;
  bottom.translatesAutoresizingMaskIntoConstraints = NO;
  [self.view addSubview:bottom];

  // 18 from the bottom of the screen, or clear of the home indicator if that
  // is further.
  NSLayoutConstraint* lift =
      [bottom.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor
                                          constant:-18];
  lift.priority = UILayoutPriorityDefaultHigh;
  UILayoutGuide* safe = self.view.safeAreaLayoutGuide;
  [NSLayoutConstraint activateConstraints:@[
    [orientation_.topAnchor constraintEqualToAnchor:safe.topAnchor constant:16],
    [orientation_.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor
                                                constant:-20],
    [dots_.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:24],
    [language_.trailingAnchor constraintEqualToAnchor:orientation_.leadingAnchor
                                             constant:-8],
    [language_.centerYAnchor constraintEqualToAnchor:orientation_.centerYAnchor],
    [dots_.trailingAnchor constraintEqualToAnchor:language_.leadingAnchor
                                         constant:-14],
    [dots_.centerYAnchor constraintEqualToAnchor:orientation_.centerYAnchor],
    [pager_.topAnchor constraintEqualToAnchor:orientation_.bottomAnchor constant:16],
    [pager_.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
    [pager_.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
    [pager_.bottomAnchor constraintEqualToAnchor:divider.topAnchor],
    [divider.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
    [divider.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
    [divider.heightAnchor constraintEqualToConstant:1],
    [divider.bottomAnchor constraintEqualToAnchor:bottom.topAnchor constant:-6],
    [bottom.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:20],
    [bottom.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-20],
    [bottom.bottomAnchor constraintLessThanOrEqualToAnchor:safe.bottomAnchor],
    lift,
  ]];

  [self showStep:0 direction:0];
}

- (void)viewDidLayoutSubviews {
  [super viewDidLayoutSubviews];
  [self syncOrientation];
}

- (void)viewDidDisappear:(BOOL)animated {
  [super viewDidDisappear:animated];
  [jitTimer_ invalidate];
  jitTimer_ = nil;
}

// Android's toggle has selectionRequired. Unlocked, which only iOS can be, it
// shows the way the screen is actually turned.
- (void)syncOrientation {
  NSString* lock = [XenraSettings stringForKey:@"ui.orientation"
                                      fallback:@"auto"];
  const CGSize size = self.view.bounds.size;
  orientation_.selectedIndex = [lock isEqual:@"portrait"]    ? 0
                               : [lock isEqual:@"landscape"] ? 1
                               : size.width > size.height    ? 1
                                                             : 0;
}

- (void)chooseLanguage {
  __weak XenraLanguageButton* button = language_;
  XenraShowLanguagePicker(self.view, ^{
    [button refresh];
  });
}

- (void)orientationChanged:(NSInteger)index {
  [XenraSettings setString:index ? @"landscape" : @"portrait"
                    forKey:@"ui.orientation"];
  XenraApplyOrientation(self);
}

// --- Steps ------------------------------------------------------------------

- (void)goBack {
  if (moving_) return;
  if (step_ > 0) [self showStep:step_ - 1 direction:-1];
}

- (void)goOn {
  if (moving_) return;
  if (step_ < kSteps - 1) {
    [self showStep:step_ + 1 direction:1];
  } else {
    [self finish];
  }
}

- (void)updateChrome {
  [dots_.arrangedSubviews
      enumerateObjectsUsingBlock:^(UIView* dot, NSUInteger i, BOOL*) {
        dot.backgroundColor = (NSInteger)i < step_    ? XenraAccentContainer()
                              : (NSInteger)i == step_ ? XenraAccent()
                                                      : XenraOutlineVariant();
      }];
  back_.hidden = step_ == 0;
  continue_.title = step_ == kSteps - 1 ? XS(@"Finish") : XS(@"Continue");
}

// ZoomOutPageTransformer at position 1: scaled to 85%, half faded, 6% low, and a
// whole page along, less the margin the transformer takes back.
static CGAffineTransform AwayPage(CGSize size, NSInteger side) {
  const CGFloat scale = 0.85;
  const CGFloat horizontal = size.width * (1 - scale) / 2;
  const CGFloat vertical = size.height * (1 - scale) / 2;
  const CGFloat along = size.width - horizontal + vertical / 2;
  return CGAffineTransformConcat(
      CGAffineTransformMakeScale(scale, scale),
      CGAffineTransformMakeTranslation(side * along, size.height * 0.06));
}

- (void)showStep:(NSInteger)step direction:(NSInteger)direction {
  step_ = step;
  [jitTimer_ invalidate];
  jitTimer_ = nil;
  [self updateChrome];
  UIView* leaving = page_;
  UIView* arriving = [self buildPage];
  page_ = arriving;
  arriving.frame = pager_.bounds;
  arriving.autoresizingMask =
      UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  [pager_ addSubview:arriving];
  if (!leaving) return;
  const CGSize size = pager_.bounds.size;
  arriving.alpha = 0.5;
  arriving.transform = AwayPage(size, direction);
  moving_ = YES;
  XenraAnimate(0.3, 0, XenraCurveStandard,
               ^{
                 arriving.alpha = 1;
                 arriving.transform = CGAffineTransformIdentity;
                 leaving.alpha = 0.5;
                 leaving.transform = AwayPage(size, -direction);
               },
               ^{
                 [leaving removeFromSuperview];
                 self->moving_ = NO;
               });
}

- (UIView*)buildPage {
  [slots_ removeAllObjects];
  jitStatus_ = nil;
  UIStackView* stack = [[UIStackView alloc] init];
  stack.axis = UILayoutConstraintAxisVertical;
  stack.translatesAutoresizingMaskIntoConstraints = NO;
  switch (step_) {
    case 0:
      [self buildWelcome:stack];
      break;
    case 1:
      AddHeader(stack, kIconMemory, YES, XS(@"BIOS Files"),
                XS(@"Choose your Xbox BIOS, MCPX ROM, and hard disk image. Original "
                 "Xbox games need all three. Xbox 360 games need none of them, "
                 "so you can skip this if that is all you play."));
      Gap(stack, 12);
      [self addFile:@"mcpx"
              title:XS(@"MCPX Boot ROM")
               hint:XS(@"mcpx_1.0.bin · exactly 512 bytes")
             button:XS(@"Choose MCPX ROM")
               icon:kIconUploadFile
                 to:stack];
      Gap(stack, 8);
      [self addFile:@"flash"
              title:XS(@"Flash ROM (BIOS)")
               hint:XS(@"BIOS image · 256 KB, 512 KB or 1 MB")
             button:XS(@"Choose Flash ROM")
               icon:kIconMemory
                 to:stack];
      Gap(stack, 8);
      [self addFile:@"hdd"
              title:XS(@"Hard Disk")
               hint:XS(@"xbox_hdd.qcow2 · or a raw image")
             button:XS(@"Choose Hard Disk")
               icon:kIconHardDrive
                 to:stack];
      break;
    case 2:
      AddHeader(stack, kIconFolderOpen, NO, XS(@"Original Xbox Games Folder"),
                XS(@"Pick the folder holding your original Xbox titles. Keep it "
                 "separate from the Xbox 360 folder: each console scans its "
                 "own."));
      Gap(stack, 20);
      [self addFolder:@"games.og"
               button:XS(@"Choose Original Xbox Folder")
                 note:XS(@"Games in Xenra / Games OG are found as well.")
                   to:stack];
      break;
    case 3:
      AddHeader(stack, kIconFolderOpen, NO, XS(@"Xbox 360 Games Folder"),
                XS(@"Pick the folder holding your Xbox 360 titles. Games copied to "
                 "Xenra / Games in the Files app are found whether you do this "
                 "or not."));
      Gap(stack, 20);
      [self addFolder:@"games.360"
               button:XS(@"Choose Xbox 360 Folder")
                 note:XS(@"Optional. You can set it later.")
                   to:stack];
      break;
    default:
      [self buildJit:stack];
      break;
  }

  // fillViewport: a short step sits in the middle of the page. BIOS starts at
  // the top, so that a warning line appearing moves only the cards under it.
  const BOOL top = step_ == 1;
  const CGFloat air = top ? 16 : 24;
  UIScrollView* scroll = [[XenraScrollView alloc] init];
  UIView* holder = [[UIView alloc] init];
  holder.translatesAutoresizingMaskIntoConstraints = NO;
  [scroll addSubview:holder];
  [holder addSubview:stack];
  UILayoutGuide* content = scroll.contentLayoutGuide;
  UILayoutGuide* frame = scroll.frameLayoutGuide;
  NSLayoutConstraint* column = [stack.widthAnchor constraintEqualToConstant:kColumn];
  column.priority = UILayoutPriorityRequired - 1;
  NSLayoutConstraint* fit = [holder.heightAnchor
      constraintEqualToAnchor:frame.heightAnchor];
  fit.priority = UILayoutPriorityDefaultLow;
  [NSLayoutConstraint activateConstraints:@[
    [holder.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
    [holder.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
    [holder.topAnchor constraintEqualToAnchor:content.topAnchor],
    [holder.bottomAnchor constraintEqualToAnchor:content.bottomAnchor],
    [holder.widthAnchor constraintEqualToAnchor:frame.widthAnchor],
    [holder.heightAnchor constraintGreaterThanOrEqualToAnchor:frame.heightAnchor],
    fit,
    column,
    [stack.widthAnchor constraintLessThanOrEqualToAnchor:holder.widthAnchor
                                                constant:-48],
    [stack.centerXAnchor constraintEqualToAnchor:holder.centerXAnchor],
    [stack.topAnchor constraintGreaterThanOrEqualToAnchor:holder.topAnchor
                                                 constant:air],
    [stack.bottomAnchor constraintLessThanOrEqualToAnchor:holder.bottomAnchor
                                                 constant:-air],
    top ? [stack.topAnchor constraintEqualToAnchor:holder.topAnchor constant:air]
        : [stack.centerYAnchor constraintEqualToAnchor:holder.centerYAnchor],
  ]];
  return scroll;
}

- (void)buildWelcome:(UIStackView*)stack {
  // The artwork has a wide empty margin. Android blows it up 1.65 times inside
  // a 112 dp box and lets the box crop it.
  UIView* box = [[UIView alloc] init];
  box.clipsToBounds = YES;
  box.translatesAutoresizingMaskIntoConstraints = NO;
  UIImageView* logo =
      [[UIImageView alloc] initWithImage:XenraBundleImage(@"setup_logo_x.png")];
  logo.contentMode = UIViewContentModeScaleAspectFit;
  logo.frame = CGRectMake(0, 0, 112, 112);
  logo.transform = CGAffineTransformMakeScale(1.65, 1.65);
  [box addSubview:logo];
  [box.widthAnchor constraintEqualToConstant:112].active = YES;
  [box.heightAnchor constraintEqualToConstant:112].active = YES;
  [stack addArrangedSubview:Centred(box)];
  Gap(stack, 6);

  UILabel* title = XenraMakeLabel(nil, 28, UIFontWeightBold, XenraText());
  title.attributedText = [[NSAttributedString alloc]
      initWithString:XS(@"Welcome to Xenra")
          attributes:@{
            NSFontAttributeName : [UIFont systemFontOfSize:28
                                                    weight:UIFontWeightBold],
            NSForegroundColorAttributeName : XenraText(),
            NSKernAttributeName : @(XenraKern(28 * 0.06)),
          }];
  title.textAlignment = NSTextAlignmentCenter;
  [stack addArrangedSubview:title];
  Gap(stack, 8);

  XenraCardView* about = Card(22, 1.5, 18, 6, XenraSurfaceVariant());
  UILabel* text = XenraMakeLabel(nil, 14, UIFontWeightRegular, XenraTextSecondary());
  Wraps(text);
  text.attributedText = XenraBodyText(
      XS(@"Xenra is an emulator frontend for running Xbox software on iOS.\n\nXenra "
       "is an open-source project and is not affiliated with or endorsed by "
       "Microsoft in any way. This project is intended for educational and "
       "research purposes as we continue developing and porting the emulator "
       "to iOS."),
      14, XenraTextSecondary());
  [about.body addArrangedSubview:text];
  [stack addArrangedSubview:about];
  Gap(stack, 6);

  XenraCardView* legal = Card(12, 1, 12, 2, XenraSurface());
  [legal.body addArrangedSubview:XenraMakeLabel(XS(@"⚠ Legal Notice"), 12,
                                                UIFontWeightMedium, Notice())];
  Gap(legal.body, 4);
  [legal.body
      addArrangedSubview:
          Paragraph(XS(@"We do not condone piracy. BIOS files and game backups "
                     "must be legally owned. While emulator software itself is "
                     "legal, downloading or distributing copyrighted BIOS files "
                     "or games without ownership is illegal. Please be "
                     "responsible and cautious online."),
                    12, XenraTextMuted(), 1.3, NSTextAlignmentNatural)];
  [stack addArrangedSubview:legal];
  Gap(stack, 4);

  __weak XenraSetupController* weak = self;
  XenraPillButton* privacy =
      [[XenraPillButton alloc] initWithTitle:XS(@"Privacy policy")
                                       style:XenraPillText
                                      action:^{
                                        XenraShowPrivacyPolicy(weak.view);
                                      }];
  privacy.contentColor = Notice();
  [stack addArrangedSubview:Centred(privacy)];
}

// A BiosCard.
- (void)addFile:(NSString*)key
          title:(NSString*)title
           hint:(NSString*)hint
         button:(NSString*)button
           icon:(NSString*)icon
             to:(UIStackView*)stack {
  XenraSetupSlot* slot = [[XenraSetupSlot alloc] init];
  XenraCardView* card = Card(14, 1, 12, 3, XenraSurfaceVariant());
  UIStackView* body = card.body;

  UILabel* heading = XenraMakeLabel(title, 14, UIFontWeightMedium, XenraText());
  [heading setContentHuggingPriority:UILayoutPriorityDefaultLow
                             forAxis:UILayoutConstraintAxisHorizontal];
  [heading
      setContentCompressionResistancePriority:UILayoutPriorityDefaultLow
                                      forAxis:UILayoutConstraintAxisHorizontal];
  slot.status = XenraMakeLabel(nil, 11, UIFontWeightMedium, XenraTextMuted());
  slot.statusPill = StatusPill(slot.status);
  UIStackView* top = [[UIStackView alloc] initWithArrangedSubviews:@[
    Icon(icon, 20, XenraAccent()), heading, slot.statusPill
  ]];
  top.spacing = 8;
  top.alignment = UIStackViewAlignmentCenter;
  [body addArrangedSubview:top];

  [body addArrangedSubview:Indented(XenraMakeLabel(hint, 12, UIFontWeightRegular,
                                                   XenraTextMuted()),
                                    28)];
  Gap(body, 8);

  [body addArrangedSubview:[self pickButton:button icon:icon key:key]];
  Gap(body, 6);

  slot.path = XenraMakeLabel(nil, 12, UIFontWeightRegular, XenraTextMuted());
  slot.path.lineBreakMode = NSLineBreakByTruncatingMiddle;
  [slot.path.heightAnchor constraintGreaterThanOrEqualToConstant:18].active = YES;
  [body addArrangedSubview:PathPill(slot.path, 12, 3, 4)];
  Gap(body, 6);

  slot.warning = XenraMakeLabel(nil, 12, UIFontWeightRegular, XenraWarning());
  Wraps(slot.warning);
  UIStackView* warning = [[UIStackView alloc]
      initWithArrangedSubviews:@[ Icon(kIconWarning, 16, XenraWarning()), slot.warning ]];
  warning.spacing = 6;
  warning.alignment = UIStackViewAlignmentCenter;
  slot.warningRow = warning;
  [body addArrangedSubview:warning];

  [stack addArrangedSubview:card];
  slots_[key] = slot;
  [self paintSlot:key];
}

// The folder steps' card: the path, the button, then the status under them.
- (void)addFolder:(NSString*)key
           button:(NSString*)button
             note:(NSString*)note
               to:(UIStackView*)stack {
  XenraSetupSlot* slot = [[XenraSetupSlot alloc] init];
  XenraCardView* card = Card(18, 1.5, 16, 6, XenraSurfaceVariant());
  UIStackView* body = card.body;

  slot.path = XenraMakeLabel(nil, 12, UIFontWeightRegular, XenraTextMuted());
  slot.path.numberOfLines = 2;
  slot.path.lineBreakMode = NSLineBreakByTruncatingMiddle;
  [body addArrangedSubview:PathPill(slot.path, 16, 13, 14)];
  Gap(body, 12);

  [body addArrangedSubview:[self pickButton:button icon:kIconFolderOpen key:key]];
  Gap(body, 8);

  slot.status = XenraMakeLabel(nil, 12, UIFontWeightMedium, XenraTextMuted());
  slot.statusPill = StatusPill(slot.status);
  [body addArrangedSubview:Centred(slot.statusPill)];
  Gap(body, 10);

  UILabel* detail = XenraMakeLabel(note, 11, UIFontWeightMedium, XenraTextMuted());
  Wraps(detail);
  detail.textAlignment = NSTextAlignmentCenter;
  [body addArrangedSubview:detail];

  [stack addArrangedSubview:card];
  slots_[key] = slot;
  [self paintSlot:key];
}

- (XenraPillButton*)pickButton:(NSString*)title
                          icon:(NSString*)icon
                           key:(NSString*)key {
  __weak XenraSetupController* weak = self;
  XenraPillButton* button = [[XenraPillButton alloc] initWithTitle:title
                                                             style:XenraPillOutlined
                                                            action:^{
                                                              [weak pick:key];
                                                            }];
  button.icon = XenraMaterialIcon(icon, 22);
  return button;
}

// Everything that depends on what has been picked. A pick calls this and nothing
// else, so the page keeps its scroll position and the other slots stay as they are.
- (void)paintSlot:(NSString*)key {
  XenraSetupSlot* slot = slots_[key];
  NSURL* picked = [XenraSettings urlForBookmark:key];
  NSString* warning = nil;
  if (picked && ![key hasPrefix:@"games"]) {
    [picked startAccessingSecurityScopedResource];
    warning = FileWarning(key, picked);
    [picked stopAccessingSecurityScopedResource];
  }
  UIColor* color = !picked   ? XenraTextMuted()
                   : warning ? XenraWarning()
                             : XenraAccent();
  slot.status.text = !picked ? XS(@"Tap to choose") : warning ? XS(@"Check this") : XS(@"Ready");
  slot.status.textColor = color;
  slot.statusPill.backgroundColor = [color colorWithAlphaComponent:0.14];
  slot.path.text = picked.lastPathComponent ?: XS(@"Not set");
  slot.warning.text = warning;
  slot.warningRow.hidden = warning == nil;
}

- (void)buildJit:(UIStackView*)stack {
  AddHeader(stack, kIconSyncAlt, NO, @"JIT", nil);
  Gap(stack, 14);

  XenraCardView* about = Card(16, 1.5, 16, 6, XenraSurfaceVariant());
  [about.body
      addArrangedSubview:
          Paragraph(XS(@"Games need JIT, which iOS only allows while a debugger "
                     "tool has attached to Xenra. That takes two things: an "
                     "install signed with a development certificate, and JIT "
                     "enabled for Xenra in StikDebug."),
                    14, XenraTextMuted(), 1.4, NSTextAlignmentNatural)];
  [stack addArrangedSubview:about];
  Gap(stack, 8);

  XenraCardView* status = Card(18, 1.5, 16, 6, XenraSurfaceVariant());
  jitStatus_ = XenraMakeLabel(nil, 12, UIFontWeightRegular, XenraTextMuted());
  Wraps(jitStatus_);
  [status.body addArrangedSubview:PathPill(jitStatus_, 16, 13, 14)];
  Gap(status.body, 12);
  XenraPillButton* enable =
      [[XenraPillButton alloc] initWithTitle:XS(@"Enable JIT")
                                       style:XenraPillOutlined
                                      action:^{
                                        XenraOpenJitEnabler();
                                      }];
  enable.icon = XenraMaterialIcon(kIconSyncAlt, 22);
  [status.body addArrangedSubview:enable];
  [stack addArrangedSubview:status];
  Gap(stack, 12);

  [stack addArrangedSubview:Paragraph(XS(@"Enable it once per launch. Tapping a game "
                                       "does this for you."),
                                      12, XenraTextMuted(), 1.15,
                                      NSTextAlignmentCenter)];

  [self updateJit];
  __weak XenraSetupController* weak = self;
  jitTimer_ = [NSTimer scheduledTimerWithTimeInterval:1
                                              repeats:YES
                                                block:^(NSTimer*) {
                                                  [weak updateJit];
                                                }];
}

- (void)updateJit {
  [self showJit:JitStatus() active:XenraJitActive()];
}

- (void)showJit:(NSString*)text active:(BOOL)active {
  jitStatus_.text = text;
  jitStatus_.textColor = active ? XenraAccent() : XenraWarning();
}

// --- Picking ----------------------------------------------------------------

- (void)pick:(NSString*)key {
  pickingKey_ = key;
  UTType* type = [key hasPrefix:@"games"] ? UTTypeFolder : UTTypeData;
  UIDocumentPickerViewController* picker =
      [[UIDocumentPickerViewController alloc]
          initForOpeningContentTypes:@[ type ]];
  picker.delegate = self;
  [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController*)controller
    didPickDocumentsAtURLs:(NSArray<NSURL*>*)urls {
  NSURL* url = urls.firstObject;
  if (!url) return;
  // In place, not copied: a hard disk or a games folder is far too big to
  // duplicate, and a bookmark is how iOS lets the app come back to it.
  [url startAccessingSecurityScopedResource];
  [XenraSettings storeBookmark:url key:pickingKey_];
  [url stopAccessingSecurityScopedResource];
  [XenraSettings holdPickedFiles];
  [self paintSlot:pickingKey_];
}

#ifdef XENRA_UITEST
// The system picker cannot be driven from the tour, so it answers for it.
- (void)tourPick:(NSString*)key url:(NSURL*)url {
  pickingKey_ = key;
  [self documentPicker:(id)self didPickDocumentsAtURLs:@[ url ]];
}

- (UIScrollView*)tourPage {
  return (UIScrollView*)page_;
}

// The simulator's stub always reports JIT on.
- (void)tourShowJitWaiting {
  [jitTimer_ invalidate];
  jitTimer_ = nil;
  [self showJit:XS(@"Waiting for JIT. Enable it for Xenra in StikDebug, then come back.")
         active:NO];
}
#endif

// --- Finish -----------------------------------------------------------------

// SetupHandoffTransition: the content leaves, the backdrop stays, and the
// dashboard assembles itself out of it. Saved first: setup that has been
// completed stays completed whether or not the pretty part gets to finish.
- (void)finish {
  [XenraSettings setSetupComplete:YES];
  UIView* root = self.view;
  root.userInteractionEnabled = NO;
  UIWindow* window = root.window;
  XenraAnimate(0.3, 0, XenraCurveEaseInOut,
               ^{
                 for (UIView* view in root.subviews) {
                   if ([view isKindOfClass:[XenraDashboardBackground class]]) {
                     continue;
                   }
                   view.alpha = 0;
                   view.transform = CGAffineTransformMakeTranslation(0, 16);
                 }
               },
               ^{
                 XenraCrossfade(window, 0.34, ^{
                   window.rootViewController =
                       XenraMakeRoot(XenraDashboardEntryArriving);
                   [window layoutIfNeeded];
                 });
               });
}

@end

void XenraRestartSetup(UIWindow* window) {
  XenraCrossfade(window, 0.25, ^{
    [XenraSettings setSetupComplete:NO];
    window.rootViewController = XenraMakeRoot(XenraDashboardEntryPlain);
    [window layoutIfNeeded];
  });
}

void XenraShowPrivacyPolicy(UIView* host) {
  [XenraBladeSheet showIn:host
                    title:XS(@"Privacy Policy")
                  message:XS(@"Xenra processes BIOS, HDD, game images, controller "
                          "input, preferences, and diagnostic logs on your "
                          "device. User-selected game and firmware files are "
                          "not uploaded by the app.\n\nLogs remain in the "
                          "app's own folder unless you share them yourself "
                          "with Share Logs.\n\nLocal data remains until you "
                          "clear it or delete the app.")
                    items:@[]];
}
