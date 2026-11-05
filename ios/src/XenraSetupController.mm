#import "XenraScreens.h"

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#import "XenraBladeView.h"
#import "XenraMotion.h"
#import "XenraSettings.h"
#import "XenraTheme.h"
#import "XenraUI.h"

// Android's five steps. The last was the Vulkan driver, which iOS has no use
// for; what stands between an iOS install and a running game is JIT, so that
// step is the one that changed.
static const NSInteger kSteps = 5;

// BiosFileCheck: advice, not a gate. The file is kept whatever this says.
static NSString* FileWarning(NSString* key, NSURL* url) {
  NSNumber* size = nil;
  [url getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
  if (!size) {
    return @"That file could not be read. It may have been moved, or the app "
            "may not have been granted access to it.";
  }
  const unsigned long long bytes = size.unsignedLongLongValue;
  NSString* shown = [NSByteCountFormatter
      stringFromByteCount:(long long)bytes
               countStyle:NSByteCountFormatterCountStyleBinary];
  if ([key isEqual:@"mcpx"] && bytes != 512) {
    return [NSString stringWithFormat:@"The MCPX boot ROM is exactly 512 bytes. "
                                       "This file is %@, so it is probably not "
                                       "the boot ROM.",
                                      shown];
  }
  if ([key isEqual:@"flash"] && bytes != 256 * 1024 && bytes != 512 * 1024 &&
      bytes != 1024 * 1024) {
    return [NSString stringWithFormat:@"An Xbox BIOS image is 256 KB, 512 KB or "
                                       "1 MB. This file is %@, so it is "
                                       "probably not a BIOS image.",
                                      shown];
  }
  if ([key isEqual:@"hdd"] && bytes < 1024ull * 1024 * 1024 &&
      ![url.pathExtension.lowercaseString isEqual:@"qcow2"]) {
    return [NSString stringWithFormat:@"An Xbox hard-disk image is a .qcow2 "
                                       "file, or a raw image of at least 1 GB. "
                                       "This file is %@ and is not a qcow2.",
                                      shown];
  }
  return nil;
}

@interface XenraSetupController () <UIDocumentPickerDelegate>
@end

@implementation XenraSetupController {
  NSInteger step_;
  XenraPanelView* panel_;
  UIView* page_;
  UIStackView* dots_;
  XenraBladeButton* back_;
  XenraBladeButton* continue_;
  UISegmentedControl* orientation_;
  NSString* pickingKey_;
  UILabel* jitStatus_;
  NSTimer* jitTimer_;
}

- (void)viewDidLoad {
  [super viewDidLoad];
  XenraDashboardBackground* background =
      [[XenraDashboardBackground alloc] initWithFrame:self.view.bounds];
  background.autoresizingMask =
      UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  [self.view addSubview:background];

  dots_ = [[UIStackView alloc] init];
  dots_.spacing = 8;
  dots_.distribution = UIStackViewDistributionFillEqually;
  dots_.translatesAutoresizingMaskIntoConstraints = NO;
  for (NSInteger i = 0; i < kSteps; i++) {
    UIView* dot = [[UIView alloc] init];
    dot.layer.cornerRadius = 3;
    [dot.heightAnchor constraintEqualToConstant:6].active = YES;
    [dots_ addArrangedSubview:dot];
  }
  [self.view addSubview:dots_];

  panel_ = [[XenraPanelView alloc] initWithFrame:CGRectZero];
  panel_.rounded = YES;
  panel_.layer.cornerRadius = 24;
  panel_.clipsToBounds = YES;
  panel_.translatesAutoresizingMaskIntoConstraints = NO;
  [self.view addSubview:panel_];

  __weak XenraSetupController* weak = self;
  back_ = [[XenraBladeButton alloc] initWithTitle:@"Back"
                                           action:^{
                                             [weak goBack];
                                           }];
  continue_ = [[XenraBladeButton alloc] initWithTitle:@"Continue"
                                               action:^{
                                                 [weak goOn];
                                               }];
  continue_.primary = YES;
  XenraAddSpring(continue_);
  orientation_ = [[UISegmentedControl alloc]
      initWithItems:@[ @"Vertical", @"Horizontal" ]];
  orientation_.selectedSegmentTintColor = XenraAccent();
  [orientation_ setTitleTextAttributes:@{
    NSForegroundColorAttributeName : XenraTextMuted()
  }
                              forState:UIControlStateNormal];
  [orientation_ setTitleTextAttributes:@{
    NSForegroundColorAttributeName : XenraOnAccent()
  }
                              forState:UIControlStateSelected];
  [orientation_ addTarget:self
                   action:@selector(orientationChanged)
         forControlEvents:UIControlEventValueChanged];
  UIView* spacer = [[UIView alloc] init];
  UIStackView* bottom = [[UIStackView alloc]
      initWithArrangedSubviews:@[ back_, spacer, orientation_, continue_ ]];
  bottom.spacing = 12;
  bottom.alignment = UIStackViewAlignmentCenter;
  bottom.translatesAutoresizingMaskIntoConstraints = NO;
  [self.view addSubview:bottom];

  NSLayoutConstraint* wide = [panel_.widthAnchor constraintEqualToConstant:680];
  wide.priority = UILayoutPriorityDefaultHigh;
  UILayoutGuide* safe = self.view.safeAreaLayoutGuide;
  [NSLayoutConstraint activateConstraints:@[
    [dots_.topAnchor constraintEqualToAnchor:safe.topAnchor constant:20],
    [dots_.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
    [dots_.widthAnchor constraintEqualToAnchor:panel_.widthAnchor multiplier:0.6],
    wide,
    [panel_.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
    [panel_.leadingAnchor constraintGreaterThanOrEqualToAnchor:safe.leadingAnchor
                                                      constant:16],
    [panel_.trailingAnchor constraintLessThanOrEqualToAnchor:safe.trailingAnchor
                                                    constant:-16],
    [panel_.topAnchor constraintEqualToAnchor:dots_.bottomAnchor constant:20],
    [panel_.bottomAnchor constraintEqualToAnchor:bottom.topAnchor constant:-16],
    [bottom.leadingAnchor constraintEqualToAnchor:panel_.leadingAnchor],
    [bottom.trailingAnchor constraintEqualToAnchor:panel_.trailingAnchor],
    [bottom.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-16],
    [back_.widthAnchor constraintEqualToConstant:130],
    [continue_.widthAnchor constraintEqualToConstant:160],
  ]];

  [self syncOrientation];
  [self showStep:0 direction:0];
}

- (void)viewDidDisappear:(BOOL)animated {
  [super viewDidDisappear:animated];
  [jitTimer_ invalidate];
  jitTimer_ = nil;
}

- (void)syncOrientation {
  NSString* lock = [XenraSettings stringForKey:@"ui.orientation"
                                      fallback:@"auto"];
  orientation_.selectedSegmentIndex =
      [lock isEqual:@"portrait"]    ? 0
      : [lock isEqual:@"landscape"] ? 1
                                    : UISegmentedControlNoSegment;
}

- (void)orientationChanged {
  [XenraSettings setString:orientation_.selectedSegmentIndex ? @"landscape"
                                                             : @"portrait"
                    forKey:@"ui.orientation"];
  XenraApplyOrientation(self);
}

// --- Steps ------------------------------------------------------------------

- (void)goBack {
  if (step_ > 0) [self showStep:step_ - 1 direction:-1];
}

- (void)goOn {
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
  continue_.title = step_ == kSteps - 1 ? @"Finish" : @"Continue";
}

// ZoomOutPageTransformer: pages leave and arrive at 85%, half faded, and a
// little low.
- (void)showStep:(NSInteger)step direction:(NSInteger)direction {
  step_ = step;
  [jitTimer_ invalidate];
  jitTimer_ = nil;
  [self updateChrome];
  UIView* leaving = page_;
  UIView* arriving = [self buildPage];
  page_ = arriving;
  arriving.frame = panel_.bounds;
  arriving.autoresizingMask =
      UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  [panel_ addSubview:arriving];
  if (!leaving) return;
  if (!direction) {
    [leaving removeFromSuperview];
    return;
  }
  const CGFloat width = panel_.bounds.size.width;
  const CGFloat height = panel_.bounds.size.height;
  const CGAffineTransform shrunk = CGAffineTransformMakeScale(0.85, 0.85);
  arriving.alpha = 0.5;
  arriving.transform = CGAffineTransformTranslate(
      shrunk, direction * width * 0.3, height * 0.06);
  XenraAnimate(0.3, 0, XenraCurveStandard,
               ^{
                 arriving.alpha = 1;
                 arriving.transform = CGAffineTransformIdentity;
                 leaving.alpha = 0;
                 leaving.transform = CGAffineTransformTranslate(
                     shrunk, -direction * width * 0.3, height * 0.06);
               },
               ^{
                 [leaving removeFromSuperview];
               });
}

- (void)refreshPage {
  [self showStep:step_ direction:0];
}

- (UIView*)buildPage {
  UIStackView* stack = [[UIStackView alloc] init];
  stack.axis = UILayoutConstraintAxisVertical;
  stack.spacing = 14;
  stack.translatesAutoresizingMaskIntoConstraints = NO;
  switch (step_) {
    case 0:
      [self buildWelcome:stack];
      break;
    case 1:
      [self addTitle:@"BIOS Files"
                body:@"Choose your Xbox BIOS, MCPX ROM, and hard disk image. "
                      "Original Xbox games need all three. Xbox 360 games "
                      "need none of them, so you can skip this if that is all "
                      "you play."
                  to:stack];
      [self addSlot:@"mcpx"
              title:@"MCPX Boot ROM"
               hint:@"mcpx_1.0.bin · exactly 512 bytes"
             button:@"Choose MCPX ROM"
                 to:stack];
      [self addSlot:@"flash"
              title:@"Flash ROM (BIOS)"
               hint:@"BIOS image · 256 KB, 512 KB or 1 MB"
             button:@"Choose Flash ROM"
                 to:stack];
      [self addSlot:@"hdd"
              title:@"Hard Disk"
               hint:@"xbox_hdd.qcow2 · or a raw image"
             button:@"Choose Hard Disk"
                 to:stack];
      break;
    case 2:
      [self addTitle:@"Original Xbox Games Folder"
                body:@"Pick the folder holding your original Xbox titles. Keep "
                      "it separate from the Xbox 360 folder: each console "
                      "scans its own."
                  to:stack];
      [self addSlot:@"games.og"
              title:@"Original Xbox Games"
               hint:@"Games in Xenra / Games OG are found as well."
             button:@"Choose Original Xbox Folder"
                 to:stack];
      break;
    case 3:
      [self addTitle:@"Xbox 360 Games Folder"
                body:@"Pick the folder holding your Xbox 360 titles. Games "
                      "copied to Xenra / Games in the Files app are found "
                      "whether you do this or not."
                  to:stack];
      [self addSlot:@"games.360"
              title:@"Xbox 360 Games"
               hint:@"Optional. You can set it later."
             button:@"Choose Xbox 360 Folder"
                 to:stack];
      break;
    default:
      [self buildJit:stack];
      break;
  }

  UIScrollView* scroll = [[XenraScrollView alloc] init];
  [scroll addSubview:stack];
  [NSLayoutConstraint activateConstraints:@[
    [stack.leadingAnchor constraintEqualToAnchor:scroll.leadingAnchor constant:24],
    [stack.trailingAnchor constraintEqualToAnchor:scroll.trailingAnchor
                                         constant:-24],
    [stack.topAnchor constraintEqualToAnchor:scroll.topAnchor constant:24],
    [stack.bottomAnchor constraintEqualToAnchor:scroll.bottomAnchor constant:-24],
    [stack.widthAnchor constraintEqualToAnchor:scroll.widthAnchor constant:-48],
  ]];
  return scroll;
}

- (void)addTitle:(NSString*)title
            body:(NSString*)body
              to:(UIStackView*)stack {
  UILabel* heading = XenraMakeLabel(title, 24, UIFontWeightBold, XenraText());
  heading.numberOfLines = 0;
  [stack addArrangedSubview:heading];
  UILabel* text = XenraMakeLabel(body, 14, UIFontWeightRegular, XenraTextMuted());
  text.numberOfLines = 0;
  [stack addArrangedSubview:text];
}

- (void)buildWelcome:(UIStackView*)stack {
  UIImageView* logo =
      [[UIImageView alloc] initWithImage:XenraBundleImage(@"setup_logo_x.png")];
  logo.contentMode = UIViewContentModeScaleAspectFit;
  [logo.heightAnchor constraintEqualToConstant:120].active = YES;
  [stack addArrangedSubview:logo];
  [self addTitle:@"Welcome to Xenra"
            body:@"Xenra is an emulator frontend for running Xbox software on "
                  "iOS.\n\nXenra is an open-source project and is not "
                  "affiliated with or endorsed by Microsoft in any way. This "
                  "project is intended for educational and research purposes "
                  "as we continue developing and porting the emulator to iOS."
              to:stack];
  UILabel* legal = XenraMakeLabel(@"⚠ Legal Notice", 15, UIFontWeightBold,
                                  XenraWarning());
  [stack addArrangedSubview:legal];
  UILabel* notice = XenraMakeLabel(
      @"We do not condone piracy. BIOS files and game backups must be legally "
       "owned. While emulator software itself is legal, downloading or "
       "distributing copyrighted BIOS files or games without ownership is "
       "illegal. Please be responsible and cautious online.",
      14, UIFontWeightRegular, XenraTextMuted());
  notice.numberOfLines = 0;
  [stack addArrangedSubview:notice];
  __weak XenraSetupController* weak = self;
  [stack addArrangedSubview:[[XenraBladeButton alloc]
                                initWithTitle:@"Privacy policy"
                                       action:^{
                                         XenraShowPrivacyPolicy(weak.view);
                                       }]];
}

- (void)addSlot:(NSString*)key
          title:(NSString*)title
           hint:(NSString*)hint
         button:(NSString*)button
             to:(UIStackView*)stack {
  UILabel* heading = XenraMakeLabel(title, 15, UIFontWeightBold, XenraText());
  UILabel* requirement =
      XenraMakeLabel(hint, 12, UIFontWeightRegular, XenraTextMuted());
  NSURL* picked = [XenraSettings urlForBookmark:key];
  NSString* warning = nil;
  if (picked && ![key hasPrefix:@"games"]) {
    [picked startAccessingSecurityScopedResource];
    warning = FileWarning(key, picked);
    [picked stopAccessingSecurityScopedResource];
  }
  UILabel* status = XenraMakeLabel(
      !picked ? @"Tap to choose" : warning ? @"Check this" : @"Ready", 13,
      UIFontWeightBold,
      !picked ? XenraTextMuted() : warning ? XenraWarning() : XenraAccent());
  UILabel* path = XenraMakeLabel(picked.lastPathComponent ?: @"Not set", 13,
                                 UIFontWeightRegular, XenraTextMuted());
  path.lineBreakMode = NSLineBreakByTruncatingMiddle;
  UIView* spacer = [[UIView alloc] init];
  UIStackView* top =
      [[UIStackView alloc] initWithArrangedSubviews:@[ heading, spacer, status ]];
  [stack addArrangedSubview:top];
  [stack addArrangedSubview:requirement];
  [stack addArrangedSubview:path];
  if (warning) {
    UILabel* reason =
        XenraMakeLabel(warning, 12, UIFontWeightRegular, XenraWarning());
    reason.numberOfLines = 0;
    [stack addArrangedSubview:reason];
  }
  __weak XenraSetupController* weak = self;
  [stack addArrangedSubview:[[XenraBladeButton alloc]
                                initWithTitle:button
                                       action:^{
                                         [weak pick:key];
                                       }]];
}

- (void)buildJit:(UIStackView*)stack {
  [self addTitle:@"JIT"
            body:@"Xbox 360 games need JIT, which iOS only allows while a "
                  "debugger tool has attached to Xenra. That takes two things: "
                  "an install signed with a development certificate, and "
                  "StikDebug with universal.js assigned to Xenra.\n\nEnable it "
                  "once per launch. Tapping a game does this for you."
              to:stack];
  jitStatus_ = XenraMakeLabel(nil, 14, UIFontWeightBold, XenraText());
  jitStatus_.numberOfLines = 0;
  [stack addArrangedSubview:jitStatus_];
  [stack addArrangedSubview:[[XenraBladeButton alloc]
                                initWithTitle:@"Enable JIT"
                                       action:^{
                                         XenraOpenJitEnabler();
                                       }]];
  [self updateJit];
  __weak XenraSetupController* weak = self;
  jitTimer_ = [NSTimer scheduledTimerWithTimeInterval:1
                                              repeats:YES
                                                block:^(NSTimer*) {
                                                  [weak updateJit];
                                                }];
}

- (void)updateJit {
  jitStatus_.text = XenraJitStatusText();
  jitStatus_.textColor = XenraJitActive() ? XenraAccent() : XenraWarning();
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
  [self refreshPage];
}

// --- Finish -----------------------------------------------------------------

// SetupHandoffTransition: the content leaves, the backdrop stays, and the
// dashboard assembles itself out of it. Saved first: setup that has been
// completed stays completed whether or not the pretty part gets to finish.
- (void)finish {
  [XenraSettings setSetupComplete:YES];
  continue_.enabled = NO;
  UIView* root = self.view;
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
                    title:@"Privacy Policy"
                  message:@"Xenra processes BIOS, HDD, game images, controller "
                          "input, preferences, and diagnostic logs on your "
                          "device. User-selected game and firmware files are "
                          "not uploaded by the app.\n\nLogs remain in the "
                          "app's own folder unless you share them yourself "
                          "with Share Logs.\n\nLocal data remains until you "
                          "clear it or delete the app."
                    items:@[]];
}
