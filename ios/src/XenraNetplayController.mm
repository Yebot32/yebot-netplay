/**
 ******************************************************************************
 * Xenra : iOS shell - Xbox 360 netplay onboarding                           *
 ******************************************************************************
 *
 * XboxLive360Activity and activity_xbox_live_360.xml, in the order they are
 * built there: header, welcome, two steps, then the online-state card that is
 * always visible. Android's screen is the reference; keep the two in step.
 *
 * The profile half is the part that matters to games today - a 360 title with
 * nobody signed in stops at its title screen. The profile itself is created on
 * the first game launch, so this screen stores the name to use and reports the
 * profile once it exists.
 */

#import "XenraScreens.h"
#import "XenraStrings.h"

#import "XenraBladeView.h"
#import "XenraNetplay.h"
#import "XenraTheme.h"
#import "XenraUI.h"

static NSString* const kGamertagKey = @"xenra.gamertag";
static NSString* const kDefaultGamertag = @"Xenra";

// The 360 core accepts 1-15 characters, starting with a letter.
static NSString* StoredGamertag(void) {
  NSString* stored = [NSUserDefaults.standardUserDefaults stringForKey:kGamertagKey];
  return XenraNetplayGamertagValid(stored) ? stored : kDefaultGamertag;
}

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

@implementation XenraNetplayController {
  NSString* content_;
  NSLayoutYAxisAnchor* headerBottom_;
  UIView* donePanel_;
  UILabel* gamertagLine_;
  UIStackView* setupPanel_;
  UIStackView* steps_;
  XenraPillButton* netcheckButton_;
  UILabel* netcheckResult_;
  BOOL checking_;
}

- (void)viewDidLoad {
  [super viewDidLoad];
  NSString* docs = NSSearchPathForDirectoriesInDomains(
                       NSDocumentDirectory, NSUserDomainMask, YES)
                       .firstObject;
  content_ = [docs stringByAppendingPathComponent:@"content"];

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
  [back setImage:[UIImage systemImageNamed:@"chevron.left"
                         withConfiguration:glyph]
        forState:UIControlStateNormal];
  back.tintColor = XenraAccentText();
  back.accessibilityLabel = XS(@"Back");
  back.translatesAutoresizingMaskIntoConstraints = NO;
  [back addTarget:self
                action:@selector(leave)
      forControlEvents:UIControlEventTouchUpInside];

  UILabel* title = TextLabel(nil, 18, UIFontWeightBold, XenraAccentText());
  title.attributedText = XenraTrackedSpacing(XS(@"NETPLAY"), 18,
                                             XenraAccentText(), 0.08);
  UILabel* subtitle = TextLabel(nil, 11, UIFontWeightRegular, XenraTextSecondary());
  subtitle.attributedText = [[NSAttributedString alloc]
      initWithString:XS(@"Xbox 360")
          attributes:@{
            NSFontAttributeName : [UIFont systemFontOfSize:11],
            NSForegroundColorAttributeName : XenraTextSecondary(),
            NSKernAttributeName : @(XenraKern(1.1)),
          }];

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
    [back.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:16],
    [back.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
    [back.widthAnchor constraintEqualToConstant:40],
    [back.heightAnchor constraintEqualToConstant:40],
    [words.leadingAnchor constraintEqualToAnchor:back.trailingAnchor constant:8],
    [words.trailingAnchor constraintLessThanOrEqualToAnchor:header.trailingAnchor
                                                   constant:-16],
    [words.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
    [rule.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
    [rule.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
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

  __weak XenraNetplayController* weak = self;

  // Profile ready: Android hides the whole checklist and shows this instead.
  XenraCardView* done = [[XenraCardView alloc] initWithFrame:CGRectZero];
  done.padding = 20;
  UILabel* doneHeading =
      TextLabel(XS(@"Profile ready"), 20, UIFontWeightBold, XenraAccentText());
  UILabel* doneBody = Body(
      XS(@"A gamer profile is set up and signed in, so games that demand one "
         "will start normally, and your saves and achievements have somewhere "
         "to go."),
      14, XenraText());
  gamertagLine_ =
      TextLabel(nil, 14, UIFontWeightBold, XenraAccentText());
  [done.body addArrangedSubview:doneHeading];
  [done.body addArrangedSubview:doneBody];
  [done.body addArrangedSubview:gamertagLine_];
  [done.body setCustomSpacing:8 afterView:doneHeading];
  [done.body setCustomSpacing:12 afterView:doneBody];
  donePanel_ = done;

  setupPanel_ = VerticalStack();
  UILabel* welcome =
      TextLabel(XS(@"Your profile and netplay"), 22, UIFontWeightBold,
                XenraAccentText());
  UILabel* welcomeBody = Body(
      XS(@"Xbox 360 games expect somebody to be signed in. Setting up a gamer "
         "profile is what unlocks saves, achievements and the menus most games "
         "hide behind a sign-in prompt — Angry Birds Trilogy will not go past "
         "its title screen without one.\n\nNetplay is a separate thing. System "
         "Link over your own Wi-Fi works today; its current state is at the "
         "bottom of this page."),
      14, XenraText());
  steps_ = VerticalStack();
  steps_.spacing = 12;
  [setupPanel_ addArrangedSubview:welcome];
  [setupPanel_ addArrangedSubview:welcomeBody];
  [setupPanel_ addArrangedSubview:steps_];
  [setupPanel_ setCustomSpacing:8 afterView:welcome];
  [setupPanel_ setCustomSpacing:20 afterView:welcomeBody];

  [content addArrangedSubview:done];
  [content addArrangedSubview:setupPanel_];
  [content addArrangedSubview:[self buildOnlineCard]];

  UILayoutGuide* area = scroll.contentLayoutGuide;
  [NSLayoutConstraint activateConstraints:@[
    [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
    [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
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

- (UIView*)buildOnlineCard {
  XenraCardView* card = [[XenraCardView alloc] initWithFrame:CGRectZero];
  card.padding = 16;
  UILabel* heading =
      TextLabel(XS(@"Netplay: where it has got to"), 15, UIFontWeightBold,
                XenraTextSecondary());
  UILabel* body = Body(
      XS(@"System Link over a local network is working. Put both consoles on "
         "the same Wi-Fi, then host or join from the game's own System Link "
         "menu — the connection stays on your network and never needs Xbox "
         "Live.\n\nStill being built: playing over the internet through a "
         "session server. The 360 core's session functions are stubs and its "
         "sign-in check reports disconnected, so that half is not ready yet."),
      13, XenraText());
  UIView* rule = Hairline();
  UILabel* limitsHeading =
      TextLabel(XS(@"What netplay will not be"), 15, UIFontWeightBold,
                XenraTextSecondary());
  UILabel* limits = Body(
      XS(@"Netplay is a community-run way for consoles to find each other. It "
         "is not Xbox Live, and it is worth knowing what it does not cover.\n\n"
         "Not Xbox Live. No friends list, no gamertag search, no messages, no "
         "marketplace, and no Xbox Live achievements. Microsoft's service is "
         "not involved at any point.\n\nOnly games that had system link. If a "
         "game only ever did multiplayer through Xbox Live, it stays offline. "
         "Titles that supported LAN or system-link play are the ones that can "
         "work, and that is a short list.\n\nWi-Fi only. Mobile data will not "
         "work for hosting. Carriers put you behind a shared address, so nobody "
         "can reach your console from outside.\n\nExpect rough edges. "
         "Disconnects, lag and games that simply refuse are all normal."),
      13, XenraText());
  UILabel* note = TextLabel(
      XS(@"System Link is LAN-only for now. This screen is where internet "
         "netplay will be set up once matches can connect."),
      12, UIFontWeightRegular, XenraTextTertiary());
  note.font = [UIFont italicSystemFontOfSize:12];

  __weak XenraNetplayController* weak = self;
  netcheckButton_ = [[XenraPillButton alloc]
      initWithTitle:XS(@"Check my network")
              style:XenraPillOutlined
             action:^{
               [weak runNetworkCheck];
             }];
  netcheckResult_ = Body(nil, 13, XenraText());
  netcheckResult_.hidden = YES;

  [card.body addArrangedSubview:heading];
  [card.body addArrangedSubview:body];
  [card.body addArrangedSubview:rule];
  [card.body addArrangedSubview:limitsHeading];
  [card.body addArrangedSubview:limits];
  [card.body addArrangedSubview:note];
  [card.body addArrangedSubview:netcheckButton_];
  [card.body addArrangedSubview:netcheckResult_];
  [card.body setCustomSpacing:8 afterView:heading];
  [card.body setCustomSpacing:16 afterView:body];
  [card.body setCustomSpacing:16 afterView:rule];
  [card.body setCustomSpacing:8 afterView:limitsHeading];
  [card.body setCustomSpacing:14 afterView:limits];
  [card.body setCustomSpacing:14 afterView:note];
  [card.body setCustomSpacing:10 afterView:netcheckButton_];
  return card;
}

// --- State ------------------------------------------------------------------

- (void)viewWillAppear:(BOOL)animated {
  [super viewWillAppear:animated];
  // The profile appears only after a game has been launched, so re-check on
  // every return rather than only when the screen is first built.
  [self render];
}

- (void)render {
  NSString* gamertag = XenraNetplayProfileSummary(content_);
  const BOOL ready = gamertag.length > 0;
  donePanel_.hidden = !ready;
  setupPanel_.hidden = ready;
  if (ready) {
    gamertagLine_.text = [NSString stringWithFormat:XS(@"Gamertag: %@"), gamertag];
    return;
  }

  while (steps_.arrangedSubviews.count) {
    UIView* view = steps_.arrangedSubviews.firstObject;
    [steps_ removeArrangedSubview:view];
    [view removeFromSuperview];
  }

  __weak XenraNetplayController* weak = self;
  [self addStepWithTitle:XS(@"1. Choose your gamertag")
                    body:XS(@"The name games will show for you. 1–15 "
                            "characters, starts with a letter, letters and "
                            "numbers only.\n\nPick it before you create the "
                            "profile — the 360 core can create a profile but "
                            "cannot rename one, so changing this later will "
                            "not touch a profile that already exists.")
                  detail:[NSString stringWithFormat:XS(@"Gamertag: %@"),
                                                    StoredGamertag()]
                    done:NO
             actionTitle:XS(@"Change gamertag")
                  action:^{
                    [weak promptGamertag];
                  }];
  [self addStepWithTitle:XS(@"2. Create your gamer profile")
                    body:XS(@"Xenra creates the profile and signs it into "
                            "slot 0 automatically the first time you launch a "
                            "360 game. There is nothing to fill in — just start "
                            "any game once and come back.")
                  detail:nil
                    done:NO
             actionTitle:XS(@"Open game library")
                  action:^{
                    [weak openLibrary];
                  }];
}

- (void)addStepWithTitle:(NSString*)title
                    body:(NSString*)body
                  detail:(NSString*)detail
                    done:(BOOL)done
             actionTitle:(NSString*)actionTitle
                  action:(void (^)(void))action {
  XenraCardView* card = [[XenraCardView alloc] initWithFrame:CGRectZero];
  card.padding = 16;

  UILabel* heading = TextLabel(title, 15, UIFontWeightBold, XenraAccentText());
  UIView* spacer = [[UIView alloc] init];
  [spacer setContentHuggingPriority:UILayoutPriorityDefaultLow
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

  UIView* beforeAction = bodyLabel;
  if (detail.length) {
    UILabel* detailLabel =
        TextLabel(detail, 13, UIFontWeightBold, XenraAccentText());
    [card.body addArrangedSubview:detailLabel];
    [card.body setCustomSpacing:8 afterView:bodyLabel];
    beforeAction = detailLabel;
  }
  if (actionTitle.length) {
    XenraPillButton* button = [[XenraPillButton alloc]
        initWithTitle:actionTitle
                style:XenraPillOutlined
               action:action];
    [card.body addArrangedSubview:button];
    [card.body setCustomSpacing:10 afterView:beforeAction];
  }
  [steps_ addArrangedSubview:card];
}

// --- Actions ----------------------------------------------------------------

- (void)promptGamertag {
  __weak XenraNetplayController* weak = self;
  UIAlertController* alert = [UIAlertController
      alertControllerWithTitle:XS(@"Choose your gamertag")
                       message:XS(@"1–15 characters. Must start with a "
                                 "letter, and can contain letters, numbers and "
                                 "single spaces.")
                preferredStyle:UIAlertControllerStyleAlert];
  [alert addTextFieldWithConfigurationHandler:^(UITextField* field) {
    field.text = StoredGamertag();
    field.autocapitalizationType = UITextAutocapitalizationTypeWords;
    field.clearButtonMode = UITextFieldViewModeWhileEditing;
  }];
  [alert addAction:[UIAlertAction actionWithTitle:XS(@"Cancel")
                                            style:UIAlertActionStyleCancel
                                          handler:nil]];
  [alert addAction:[UIAlertAction
                       actionWithTitle:XS(@"OK")
                                 style:UIAlertActionStyleDefault
                               handler:^(UIAlertAction* action) {
                                 NSString* name =
                                     [alert.textFields.firstObject.text
                                         stringByTrimmingCharactersInSet:
                                             NSCharacterSet
                                                 .whitespaceCharacterSet];
                                 XenraNetplayController* strong = weak;
                                 if (!strong) return;
                                 if (!XenraNetplayGamertagValid(name)) {
                                   XenraToast(strong.view,
                                              XS(@"That name will not be "
                                                 "accepted: 1–15 characters, "
                                                 "start with a letter, letters "
                                                 "and numbers with single "
                                                 "spaces."));
                                   return;
                                 }
                                 [NSUserDefaults.standardUserDefaults
                                     setObject:name forKey:kGamertagKey];
                                 XenraToast(strong.view,
                                            [NSString
                                                stringWithFormat:
                                                    XS(@"Gamertag set to %@"),
                                                    name]);
                                 [strong render];
                               }]];
  [self presentViewController:alert animated:YES completion:nil];
}

- (void)openLibrary {
  [self.navigationController pushViewController:[[XenraLibraryController alloc] init]
                                       animated:YES];
}

- (void)runNetworkCheck {
  if (checking_) return;
  checking_ = YES;
  netcheckButton_.enabled = NO;
  netcheckResult_.hidden = NO;
  netcheckResult_.text = XS(@"Checking…");
  __weak XenraNetplayController* weak = self;
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
    XenraNetplayUPnPDiscover(2000);
    NSString* status = XenraNetplayUPnPStatus();
    NSString* router;
    if ([status isEqualToString:@"ready"]) {
      if (XenraNetplayUPnPTestMapping(36000)) {
        NSString* external = XenraNetplayUPnPExternalAddress();
        router = [NSString
            stringWithFormat:XS(@"Your network can host. UPnP works and your "
                                "connection can be reached from outside "
                                "(%@). Nothing here is stopping netplay."),
                             external.length ? external : XS(@"Checking…")];
      } else {
        router = XS(@"A gateway answered, but it refused to open a port. UPnP "
                    "may be restricted in your router's settings.");
      }
    } else if ([status isEqualToString:@"not routable"]) {
      router = XS(@"Your router is fine, but your internet connection cannot "
                  "be reached from outside. That is your provider sharing one "
                  "address between many customers, not a setting you can "
                  "change. Hosting will not work on this connection; joining "
                  "someone else may.");
    } else {
      router = XS(@"No UPnP gateway answered. Either UPnP is switched off in "
                  "your router, or you are on mobile data. Hosting would need "
                  "UPnP turned on, or the port forwarded by hand.");
    }
    XenraNetplayCheckServer(^(BOOL reachable, NSInteger code) {
      XenraNetplayController* strong = weak;
      if (!strong) return;
      strong->checking_ = NO;
      strong->netcheckButton_.enabled = YES;
      NSString* server =
          reachable
              ? XS(@"The netplay session server is reachable from this device.")
              : XS(@"The netplay session server could not be reached. It may "
                   "be down, or your connection may be blocking it.");
      strong->netcheckResult_.text =
          [router stringByAppendingFormat:@"\n\n%@", server];
    });
  });
}

- (void)leave {
  [self.navigationController popViewControllerAnimated:YES];
}

@end
