/**
 ******************************************************************************
 * Xenra : iOS shell - Xbox OG Live (Insignia) onboarding                     *
 ******************************************************************************
 *
 * InsigniaSetupActivity and activity_insignia_setup.xml, step for step: the
 * same three steps, the same done-detection, the same wording. Android's screen
 * is the reference; keep the two in step.
 *
 * The one deliberate difference is step 2. Android boots the disc image the
 * user picked, wherever it lives. iOS has to copy it into the app's own games
 * folder first: a security-scoped URL from the document picker does not survive
 * the StikDebug relaunch that starts the core, and the copy is what the library
 * lists anyway.
 */

#import "XenraScreens.h"
#import "XenraStrings.h"

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#import "XenraBladeView.h"
#import "XenraContentInstall.h"
#import "XenraInsignia.h"
#import "XenraTheme.h"
#import "XenraUI.h"
#import "XenraXemu.h"

static UIStackView* VerticalStack(void) {
  UIStackView* stack = [[UIStackView alloc] init];
  stack.axis = UILayoutConstraintAxisVertical;
  stack.translatesAutoresizingMaskIntoConstraints = NO;
  return stack;
}

static UILabel* TextLabel(NSString* text, CGFloat size, UIFontWeight weight,
                          UIColor* color) {
  UILabel* label = XenraMakeLabel(text, size, weight, color);
  label.numberOfLines = 0;
  return label;
}

static UILabel* Body(NSString* text, CGFloat size, UIColor* color) {
  UILabel* label = TextLabel(nil, size, UIFontWeightRegular, color);
  label.attributedText = XenraBodyText(text, size, color);
  return label;
}

static UIView* Hairline(void) {
  UIView* line = [[UIView alloc] init];
  line.translatesAutoresizingMaskIntoConstraints = NO;
  line.backgroundColor = XenraAccentAlpha(0x33);
  [line.heightAnchor constraintEqualToConstant:1].active = YES;
  return line;
}

@interface XenraInsigniaController () <UIDocumentPickerDelegate>
@end

@implementation XenraInsigniaController {
  NSLayoutYAxisAnchor* headerBottom_;
  UIView* donePanel_;
  UIStackView* setupPanel_;
  UIStackView* steps_;
  UILabel* statusLine_;
  BOOL importing_;
}

- (void)viewDidLoad {
  [super viewDidLoad];

  XenraDashboardBackground* background =
      [[XenraDashboardBackground alloc]
          initForDashboardWithFrame:self.view.bounds];
  background.autoresizingMask =
      UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  [self.view addSubview:background];
  UIView* scrim = [[UIView alloc] initWithFrame:self.view.bounds];
  scrim.backgroundColor = XenraPick(0x55000000, 0x14000000, 0x55000000);
  scrim.autoresizingMask = background.autoresizingMask;
  [self.view addSubview:scrim];

  [self buildHeader];
  [self buildContent];
  [self render];
}

// --- Header -----------------------------------------------------------------

- (void)buildHeader {
  UIButton* back = [UIButton buttonWithType:UIButtonTypeSystem];
  UIImageConfiguration* glyph = [UIImageSymbolConfiguration
      configurationWithPointSize:18
                          weight:UIImageSymbolWeightSemibold];
  [back setImage:XenraDirectional([UIImage systemImageNamed:@"chevron.left"
                                           withConfiguration:glyph])
        forState:UIControlStateNormal];
  back.tintColor = XenraAccentText();
  back.accessibilityLabel = XS(@"Back");
  back.translatesAutoresizingMaskIntoConstraints = NO;
  [back addTarget:self
                action:@selector(leave)
      forControlEvents:UIControlEventTouchUpInside];

  UILabel* title = TextLabel(nil, 18, UIFontWeightBold, XenraAccentText());
  title.attributedText = XenraTrackedSpacing(XS(@"XBOX LIVE"), 18,
                                             XenraAccentText(), 0.08);
  UILabel* subtitle =
      TextLabel(XS(@"Powered by Insignia"), 11, UIFontWeightRegular,
                XenraTextSecondary());

  UIStackView* words =
      [[UIStackView alloc] initWithArrangedSubviews:@[ title, subtitle ]];
  words.axis = UILayoutConstraintAxisVertical;
  words.spacing = 2;
  words.translatesAutoresizingMaskIntoConstraints = NO;

  UIView* header = [[UIView alloc] init];
  header.translatesAutoresizingMaskIntoConstraints = NO;
  [header addSubview:back];
  [header addSubview:words];
  [self.view addSubview:header];

  UIView* rule = Hairline();
  [self.view addSubview:rule];

  UILayoutGuide* safe = self.view.safeAreaLayoutGuide;
  [NSLayoutConstraint activateConstraints:@[
    [header.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
    [header.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
    [header.topAnchor constraintEqualToAnchor:safe.topAnchor],
    [header.heightAnchor constraintEqualToConstant:56],
    [back.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
    [back.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
    [back.widthAnchor constraintEqualToConstant:40],
    [back.heightAnchor constraintEqualToConstant:40],
    [words.leadingAnchor constraintEqualToAnchor:back.trailingAnchor constant:8],
    [words.trailingAnchor constraintLessThanOrEqualToAnchor:safe.trailingAnchor
                                                   constant:-16],
    [words.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
    [rule.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
    [rule.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
    [rule.topAnchor constraintEqualToAnchor:header.bottomAnchor],
  ]];
  headerBottom_ = rule.bottomAnchor;
}

// --- Content ----------------------------------------------------------------

- (void)buildContent {
  XenraScrollView* scroll = [[XenraScrollView alloc] init];
  scroll.translatesAutoresizingMaskIntoConstraints = NO;
  scroll.alwaysBounceVertical = YES;
  scroll.showsVerticalScrollIndicator = YES;
  [self.view addSubview:scroll];

  UIStackView* content = VerticalStack();
  content.spacing = 20;
  [scroll addSubview:content];

  __weak XenraInsigniaController* weak = self;

  // Everything done: Android hides the checklist and shows this instead.
  XenraCardView* done = [[XenraCardView alloc] initWithFrame:CGRectZero];
  done.padding = 20;
  UILabel* doneHeading =
      TextLabel(XS(@"You're all set"), 20, UIFontWeightBold, XenraAccentText());
  UILabel* doneBody = Body(
      XS(@"This console is set up for Insignia. Launch a game that supports "
         "Xbox Live and sign in from its menu."),
      14, XenraText());
  XenraPillButton* redo = [[XenraPillButton alloc]
      initWithTitle:XS(@"Run setup again")
              style:XenraPillOutlined
             action:^{
               [weak clearProgress];
             }];
  XenraPillButton* guide = [[XenraPillButton alloc]
      initWithTitle:XS(@"Read the full guide")
              style:XenraPillText
             action:^{
               [weak openURL:XenraInsigniaGuideURL()];
             }];
  [done.body addArrangedSubview:doneHeading];
  [done.body addArrangedSubview:doneBody];
  [done.body addArrangedSubview:redo];
  [done.body addArrangedSubview:guide];
  [done.body setCustomSpacing:8 afterView:doneHeading];
  [done.body setCustomSpacing:16 afterView:doneBody];
  [done.body setCustomSpacing:6 afterView:redo];
  donePanel_ = done;

  setupPanel_ = VerticalStack();
  UILabel* welcome =
      TextLabel(XS(@"Play online again"), 22, UIFontWeightBold,
                XenraAccentText());
  UILabel* welcomeBody = Body(
      XS(@"Xbox Live for the original Xbox was shut down in 2010. Insignia is "
         "a free, fan-run service that brings it back — online matches, friends "
         "and leaderboards in the games that supported them.\n\nIt takes about "
         "five minutes to set up. You only have to do this once."),
      14, XenraText());
  steps_ = VerticalStack();
  steps_.spacing = 12;
  statusLine_ = Body(nil, 13, XenraTextSecondary());
  statusLine_.hidden = YES;

  XenraPillButton* guideButton = [[XenraPillButton alloc]
      initWithTitle:XS(@"Read the full guide")
              style:XenraPillOutlined
             action:^{
               [weak openURL:XenraInsigniaGuideURL()];
             }];
  XenraPillButton* clear = [[XenraPillButton alloc]
      initWithTitle:XS(@"Clear all steps")
              style:XenraPillText
             action:^{
               [weak confirmClear];
             }];
  clear.destructive = YES;

  [setupPanel_ addArrangedSubview:welcome];
  [setupPanel_ addArrangedSubview:welcomeBody];
  [setupPanel_ addArrangedSubview:steps_];
  [setupPanel_ addArrangedSubview:statusLine_];
  [setupPanel_ addArrangedSubview:guideButton];
  [setupPanel_ addArrangedSubview:clear];
  [setupPanel_ setCustomSpacing:8 afterView:welcome];
  [setupPanel_ setCustomSpacing:20 afterView:welcomeBody];
  [setupPanel_ setCustomSpacing:6 afterView:statusLine_];
  [setupPanel_ setCustomSpacing:6 afterView:guideButton];

  [content addArrangedSubview:done];
  [content addArrangedSubview:setupPanel_];

  UILayoutGuide* area = scroll.contentLayoutGuide;
  UILayoutGuide* safe = self.view.safeAreaLayoutGuide;
  [NSLayoutConstraint activateConstraints:@[
    [scroll.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
    [scroll.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
    [scroll.topAnchor constraintEqualToAnchor:headerBottom_],
    [scroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    [content.leadingAnchor constraintEqualToAnchor:area.leadingAnchor constant:20],
    [content.trailingAnchor constraintEqualToAnchor:area.trailingAnchor
                                            constant:-20],
    [content.topAnchor constraintEqualToAnchor:area.topAnchor constant:16],
    [content.bottomAnchor constraintEqualToAnchor:area.bottomAnchor constant:-24],
    [content.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor
                                        constant:-40],
  ]];
}

// --- State ------------------------------------------------------------------

- (void)viewWillAppear:(BOOL)animated {
  [super viewWillAppear:animated];
  // The EEPROM only appears after a game has been launched and the dashboard
  // and networking state can change in Settings, so re-check on every return.
  [self render];
}

- (void)render {
  const BOOL allDone = XenraInsigniaAllDone();
  donePanel_.hidden = !allDone;
  setupPanel_.hidden = allDone;
  if (allDone) return;

  while (steps_.arrangedSubviews.count) {
    UIView* view = steps_.arrangedSubviews.firstObject;
    [steps_ removeArrangedSubview:view];
    [view removeFromSuperview];
  }

  __weak XenraInsigniaController* weak = self;
  const BOOL ready = XenraInsigniaNetworkingOn() && XenraInsigniaDNSApplied();
  [self addStepWithTitle:XS(@"1. Get your console ready")
                    body:XS(@"Turns on networking and points your console at "
                            "Insignia's servers. Nothing to choose — just tap "
                            "it.\n\nYour console also needs the final Xbox "
                            "dashboard (version D:1.00.5960.01). On an older "
                            "dashboard the steps below all appear to work, but "
                            "signing in from a game will fail.")
                    done:ready
                 primary:ready ? nil : XS(@"Get ready")
            primaryAction:^{
              [weak prepareConsole];
            }
               secondary:nil
          secondaryAction:nil
                tertiary:nil
           tertiaryAction:nil];

  const BOOL registered = XenraInsigniaSetupDiscPath() != nil;
  [self addStepWithTitle:XS(@"2. Register your console")
                    body:XS(@"Download Insignia-Setup.iso from the Setup "
                            "Assistant download page. Import it below, boot it, "
                            "then press Register.")
                    done:registered
                 primary:(registered ? XS(@"Boot Setup Assistant")
                                     : XS(@"Open download page"))
            primaryAction:^{
              if (registered) {
                [weak bootSetupAssistant];
              } else {
                [weak openURL:XenraInsigniaSetupDownloadURL()];
              }
            }
               secondary:(registered ? XS(@"Import a different file")
                                     : XS(@"Import Insignia-Setup.iso"))
          secondaryAction:^{
            [weak importSetupAssistant];
          }
                tertiary:nil
           tertiaryAction:nil];

  [self addStepWithTitle:XS(@"3. Create your gamertag")
                    body:XS(@"Enter your email on insignia.live to get a code. "
                            "Then boot the dashboard, choose Xbox Live, and "
                            "sign up.\n\nWhen it asks for card details, use "
                            "4111 1111 1111 1111 — Insignia does not collect "
                            "them. Use the same email you requested the code "
                            "with.")
                    done:XenraInsigniaSignedUp()
                 primary:XS(@"Request a code")
            primaryAction:^{
              [weak openURL:XenraInsigniaSiteURL()];
            }
               secondary:XS(@"Boot to dashboard")
          secondaryAction:^{
            [weak bootDashboard];
          }
                tertiary:XS(@"I signed up")
           tertiaryAction:^{
             XenraInsigniaSetSignedUp(YES);
             [weak render];
           }];
}

- (void)addStepWithTitle:(NSString*)title
                    body:(NSString*)body
                    done:(BOOL)done
                 primary:(NSString*)primaryTitle
            primaryAction:(void (^)(void))primaryAction
               secondary:(NSString*)secondaryTitle
          secondaryAction:(void (^)(void))secondaryAction
                tertiary:(NSString*)tertiaryTitle
           tertiaryAction:(void (^)(void))tertiaryAction {
  XenraCardView* card = [[XenraCardView alloc] initWithFrame:CGRectZero];
  card.padding = 16;

  UILabel* heading = TextLabel(title, 15, UIFontWeightBold, XenraAccentText());
  [heading setContentCompressionResistancePriority:UILayoutPriorityRequired
                                           forAxis:UILayoutConstraintAxisHorizontal];
  UIView* spacer = [[UIView alloc] init];
  [spacer setContentHuggingPriority:1
                            forAxis:UILayoutConstraintAxisHorizontal];
  NSMutableArray<UIView*>* header =
      [NSMutableArray arrayWithObjects:heading, spacer, nil];
  if (done) {
    UILabel* mark = TextLabel([@"✓ " stringByAppendingString:XS(@"Done")], 13,
                              UIFontWeightBold, XenraSuccess());
    [mark setContentHuggingPriority:UILayoutPriorityRequired
                            forAxis:UILayoutConstraintAxisHorizontal];
    [header addObject:mark];
  }
  UIStackView* row = [[UIStackView alloc] initWithArrangedSubviews:header];
  row.axis = UILayoutConstraintAxisHorizontal;
  row.alignment = UIStackViewAlignmentCenter;
  row.spacing = 8;

  UILabel* bodyLabel = Body(body, 13, XenraText());
  [card.body addArrangedSubview:row];
  [card.body addArrangedSubview:bodyLabel];
  [card.body setCustomSpacing:6 afterView:row];

  NSArray<NSString*>* titles = @[
    primaryTitle ?: @"", secondaryTitle ?: @"", tertiaryTitle ?: @""
  ];
  NSArray<void (^)(void)>* actions = @[
    primaryAction ?: ^{}, secondaryAction ?: ^{}, tertiaryAction ?: ^{}
  ];
  UIView* previous = bodyLabel;
  BOOL first = YES;
  for (NSUInteger i = 0; i < titles.count; ++i) {
    if (!titles[i].length) continue;
    XenraPillButton* button = [[XenraPillButton alloc]
        initWithTitle:titles[i]
                style:i == 0 ? XenraPillOutlined : XenraPillText
               action:actions[i]];
    [card.body addArrangedSubview:button];
    [card.body setCustomSpacing:(first ? 10 : 6) afterView:previous];
    previous = button;
    first = NO;
  }
  [steps_ addArrangedSubview:card];
}

// --- Actions ----------------------------------------------------------------

// Step 1 in one tap, as on Android: networking and the DNS have no decision
// attached. The EEPROM only exists after a game has been launched, so say that
// plainly instead of failing silently.
- (void)prepareConsole {
  XenraInsigniaSetNetworkingOn(YES);
  if (!XenraInsigniaEepromURL()) {
    [self showStatus:XS(@"Networking is on, but the DNS still needs writing. "
                        "Launch any game once to create the EEPROM, then tap "
                        "again.")];
    [self render];
    return;
  }
  NSError* error = nil;
  const BOOL changed = XenraInsigniaApplyDNS(&error);
  if (error) {
    [self showStatus:error.localizedDescription];
  } else {
    [self showStatus:changed
                         ? XS(@"Insignia DNS written. Restart emulation for it "
                              "to take effect.")
                         : XS(@"Insignia DNS was already set.")];
  }
  [self render];
}

- (void)showStatus:(NSString*)text {
  statusLine_.attributedText = XenraBodyText(text, 13, XenraTextSecondary());
  statusLine_.hidden = text.length == 0;
}

- (void)importSetupAssistant {
  if (importing_) return;
  UIDocumentPickerViewController* picker = [[UIDocumentPickerViewController alloc]
      initForOpeningContentTypes:@[ UTTypeData ]];
  picker.delegate = self;
  picker.overrideUserInterfaceStyle = XenraInterfaceStyle();
  [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController*)controller {
}

- (void)documentPicker:(UIDocumentPickerViewController*)controller
    didPickDocumentsAtURLs:(NSArray<NSURL*>*)urls {
  NSURL* url = urls.firstObject;
  if (!url) return;

  NSString* target = XenraInsigniaInstalledDiscPath(url.path);
  if ([NSFileManager.defaultManager fileExistsAtPath:target]) {
    [self bootSetupAssistantAtPath:target];
    return;
  }

  importing_ = YES;
  [self showStatus:[NSString stringWithFormat:XS(@"Copying %@…"),
                                              url.lastPathComponent]];
  __weak XenraInsigniaController* weak = self;
  XenraInstallFromURL(
      url, XenraConsoleOG,
      ^(NSString* message, float fraction) {
        [weak showStatus:message];
      },
      ^(XenraInstallOutcome outcome, NSString* message) {
        XenraInsigniaController* strong = weak;
        if (!strong) return;
        strong->importing_ = NO;
        // A second import of the same file is refused as "already in your games
        // folder"; the copy is what gets booted either way.
        if ([NSFileManager.defaultManager fileExistsAtPath:target]) {
          [strong bootSetupAssistantAtPath:target];
          return;
        }
        [strong showStatus:message];
      });
}

- (void)bootSetupAssistant {
  NSString* path = XenraInsigniaSetupDiscPath();
  if (!path) {
    [self importSetupAssistant];
    return;
  }
  [self bootSetupAssistantAtPath:path];
}

- (void)bootSetupAssistantAtPath:(NSString*)path {
  XenraInsigniaRememberSetupDisc(path);
  XenraGameController* game = XenraInsigniaMakeSetupDiscController(path);
  if (!game) {
    [self showStatus:XS(@"Could not start the Setup Assistant.")];
    [self render];
    return;
  }
  [self.navigationController pushViewController:game animated:YES];
}

- (void)bootDashboard {
  NSString* problem = XenraInsigniaBootProblem();
  if (problem) {
    [XenraBladeSheet showIn:self.view
                      title:XS(@"Could not boot the dashboard.")
                    message:problem
                      items:@[]];
    return;
  }
  [self.navigationController
      pushViewController:XenraInsigniaMakeDashboardController()
                animated:YES];
}

- (void)confirmClear {
  __weak XenraInsigniaController* weak = self;
  [XenraBladeSheet
      showConfirmIn:self.view
              title:XS(@"Clear setup progress?")
            message:XS(@"This unchecks every step so you can start over. It "
                        "does not undo the DNS already written to your console, "
                        "and it will not delete your Insignia account.")
            leading:[XenraBladeItem title:XS(@"Cancel") action:nil]
           trailing:[XenraBladeItem title:XS(@"Clear")
                                   action:^{
                                     XenraInsigniaClearProgress();
                                     [weak showStatus:XS(@"Setup progress "
                                                         "cleared.")];
                                     [weak render];
                                   }]];
}

- (void)openURL:(NSString*)string {
  NSURL* url = [NSURL URLWithString:string];
  if (!url) return;
  [[UIApplication sharedApplication]
                openURL:url
                options:@{}
      completionHandler:^(BOOL success) {
        if (!success) {
          XenraToast(self.view, XS(@"No app available to open web links."));
        }
      }];
}

- (void)leave {
  [self.navigationController popViewControllerAnimated:YES];
}

@end
