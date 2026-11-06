/**
 ******************************************************************************
 * Xenra : UI-only simulator build                                            *
 ******************************************************************************
 *
 * The shell with the cores stubbed out, driven through every screen so CI can
 * photograph it. Steps tap real controls by their titles, so a control that
 * stopped working stops the tour too: look for NO SUCH CONTROL in the app log.
 *
 * Pictures are taken inside the app, of the window, and written to tour/. A
 * simulator with no window of its own stays a portrait device, so an app locked to
 * landscape is letterboxed and scaled on a picture of the home screen: its layout
 * is really 1180 x 820 but `simctl io screenshot` cannot show it. Each picture
 * here is the real window at full size, and the log has its bounds.
 *
 * Both() photographs a screen one way up, rotates with it open, and photographs
 * it the other way. So every sheet in here is also a rotation test.
 */

#import <UIKit/UIKit.h>

#import "XenraBladeView.h"
#import "XenraMotion.h"
#import "XenraScreens.h"
#import "XenraSettings.h"
#import "XenraTheme.h"
#import "XenraUI.h"
#include "ios_emu.h"

int xe_ios_initialize(const char*, const char*, const char*) { return 0; }
void xe_ios_set_game_view(UIView*) {}
int xe_ios_boot(const char*) { return 0; }
void xe_ios_pump(void) {}
void xe_ios_input_set(int, short, short, short, short, unsigned char,
                      unsigned char) {}
int xe_ios_status(void) { return 0; }
const char* xe_ios_status_detail(void) { return ""; }
void xe_ios_set_cvar(const char*, const char*) {}
void xe_ios_shutdown(void) {}
void xe_ios_flush_log(void) {}

typedef void (^TourStep)(void);

static UIWindow* g_window;
static NSMutableArray* g_steps;
static NSUInteger g_next;
static int g_shot;

static NSString* TourDir(void) {
  return [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                              NSUserDomainMask, YES)
              .firstObject stringByAppendingPathComponent:@"tour"];
}

static UINavigationController* Nav(void) {
  return (UINavigationController*)g_window.rootViewController;
}

static UIView* TopView(void) { return Nav().topViewController.view; }

static XenraPressControl* FindControl(UIView* root, NSString* title) {
  if (root.hidden || root.alpha == 0) return nil;
  for (UIView* view in root.subviews.reverseObjectEnumerator) {
    if (XenraPressControl* found = FindControl(view, title)) return found;
  }
  if ([root isKindOfClass:[XenraPressControl class]] &&
      [((XenraPressControl*)root).title isEqual:title]) {
    return (XenraPressControl*)root;
  }
  return nil;
}

static UIView* FindClass(UIView* root, Class type) {
  if ([root isKindOfClass:type]) return root;
  for (UIView* view in root.subviews) {
    if (UIView* found = FindClass(view, type)) return found;
  }
  return nil;
}

static XenraPressControl* Need(NSString* title) {
  XenraPressControl* control = FindControl(g_window, title);
  if (!control) {
    XenraLog([NSString stringWithFormat:@"tour: NO SUCH CONTROL %@", title]);
  }
  return control;
}

static void Advance(void);

static void Step(TourStep step) { [g_steps addObject:[step copy]]; }

static void Tap(NSString* title) {
  Step(^{
    [Need(title) sendActionsForControlEvents:UIControlEventTouchUpInside];
  });
}

static void Pause(void) {
  Step(^{
  });
}

static void Pop(void) {
  Step(^{
    [Nav() popViewControllerAnimated:YES];
  });
}

static void Shot(NSString* name) {
  Step(^{
    const int shot = ++g_shot;
    const CGRect bounds = g_window.bounds;
    UIGraphicsImageRendererFormat* format =
        [UIGraphicsImageRendererFormat preferredFormat];
    format.opaque = YES;
    UIGraphicsImageRenderer* renderer =
        [[UIGraphicsImageRenderer alloc] initWithSize:bounds.size format:format];
    NSData* png =
        [renderer PNGDataWithActions:^(UIGraphicsImageRendererContext*) {
          [g_window drawViewHierarchyInRect:bounds afterScreenUpdates:YES];
        }];
    [png writeToFile:[TourDir() stringByAppendingPathComponent:
                                    [NSString stringWithFormat:@"%03d-%@.png",
                                                               shot, name]]
          atomically:YES];
    XenraLog([NSString stringWithFormat:@"tour: shot %03d %@ %.0fx%.0f", shot,
                                        name, bounds.size.width,
                                        bounds.size.height]);
  });
}

static void Rotate(NSString* lock) {
  Step(^{
    [XenraSettings setString:lock forKey:@"ui.orientation"];
    XenraApplyOrientation(Nav());
  });
  Pause();  // The scene takes longer to turn than a screen does to settle.
}

// Starts and ends in landscape.
static void Both(NSString* name) {
  Shot([@"land-" stringByAppendingString:name]);
  Rotate(@"portrait");
  Shot([@"port-" stringByAppendingString:name]);
  Rotate(@"landscape");
}

// Lights a control without a touch ending, so the press state can be photographed.
static void Pressed(NSString* title, NSString* name) {
  Step(^{
    Need(title).highlighted = YES;
  });
  Shot(name);
  Step(^{
    Need(title).highlighted = NO;
  });
}

@interface XenraSetupController (Tour)
- (void)tourPick:(NSString*)key url:(NSURL*)url;
- (UIScrollView*)tourPage;
- (void)tourShowJitWaiting;
@end

static XenraSetupController* SetupScreen(void) {
  return (XenraSetupController*)Nav().topViewController;
}

static NSURL* TourFile(NSString* name, NSUInteger bytes) {
  NSString* path = [NSTemporaryDirectory() stringByAppendingPathComponent:name];
  [[NSMutableData dataWithLength:bytes] writeToFile:path atomically:NO];
  return [NSURL fileURLWithPath:path];
}

// A29: a pick repaints its own card and leaves the page and its scroll alone. Two
// wrong files for the warning line, then a good one from the bottom of the page.
static void SetupPicks(void) {
  Step(^{
    [SetupScreen() tourPick:@"flash" url:TourFile(@"wrong-flash.bin", 1000)];
    [SetupScreen() tourPick:@"hdd" url:TourFile(@"a-disk-image.img", 2000)];
  });
  Step(^{
    UIScrollView* page = [SetupScreen() tourPage];
    const CGFloat bottom =
        MAX(0, page.contentSize.height - page.bounds.size.height);
    [page setContentOffset:CGPointMake(0, bottom) animated:NO];
    [SetupScreen() tourPick:@"mcpx" url:TourFile(@"mcpx_1.0.bin", 512)];
    [page layoutIfNeeded];
    XenraLog([NSString
        stringWithFormat:@"tour: setup pick same page=%d offset %.0f then %.0f",
                         page == [SetupScreen() tourPage], bottom,
                         page.contentOffset.y]);
  });
  Both(@"setup-2-picked");
  // The game screens further on are meant to find no BIOS.
  Step(^{
    for (NSString* key in @[ @"mcpx", @"flash", @"hdd" ]) {
      [NSUserDefaults.standardUserDefaults
          removeObjectForKey:[@"bookmark." stringByAppendingString:key]];
    }
    [XenraSettings holdPickedFiles];
  });
}

// A10: a control in a scroller must not light up the moment it is touched, or a
// drag flashes it. It must light up a moment later, and go out again on a cancel.
static void PressTiming(NSString* title) {
  Step(^{
    XenraPressControl* control = Need(title);
    control.highlighted = YES;
    const BOOL at_once = control.pressed;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
                     XenraLog([NSString
                         stringWithFormat:
                             @"tour: press in scroller at once=%d after 300ms=%d",
                             at_once, control.pressed]);
                     control.highlighted = NO;
                     XenraLog([NSString
                         stringWithFormat:@"tour: press cancelled pressed=%d",
                                          control.pressed]);
                   });
  });
  // A drag that wins inside the delay never shows it at all.
  Step(^{
    XenraPressControl* control = Need(title);
    control.highlighted = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
                     control.highlighted = NO;
                   });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
                     XenraLog([NSString
                         stringWithFormat:@"tour: early cancel pressed=%d",
                                          control.pressed]);
                   });
  });
}

// Every widget on one screen, since most are not on a real one yet.
@interface TourGallery : UIViewController
@end

@implementation TourGallery

- (void)viewDidLoad {
  [super viewDidLoad];
  XenraDashboardBackground* background =
      [[XenraDashboardBackground alloc] initWithFrame:self.view.bounds];
  background.autoresizingMask =
      UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  [self.view addSubview:background];

  XenraScrollView* scroll = [[XenraScrollView alloc] init];
  scroll.alwaysBounceVertical = YES;
  scroll.translatesAutoresizingMaskIntoConstraints = NO;
  [self.view addSubview:scroll];
  UIStackView* column = [[UIStackView alloc] init];
  column.axis = UILayoutConstraintAxisVertical;
  column.spacing = 12;
  column.translatesAutoresizingMaskIntoConstraints = NO;
  [scroll addSubview:column];

  XenraCardView* card = [[XenraCardView alloc] initWithFrame:CGRectZero];
  [column addArrangedSubview:card];
  UIStackView* body = card.body;
  XenraSectionHeader* label =
      [[XenraSectionHeader alloc] initWithTitle:@"Display" style:XenraSectionLabel];
  [body addArrangedSubview:label];
  [body setCustomSpacing:10 afterView:label];
  XenraSegmentView* segment =
      [[XenraSegmentView alloc] initWithTitles:@[ @"Off", @"Fast", @"Strict" ]];
  segment.selectedIndex = 1;
  [body addArrangedSubview:segment];
  [body setCustomSpacing:14 afterView:segment];
  XenraSliderRow* slider = [[XenraSliderRow alloc]
      initWithTitle:@"Menu music volume"
             detail:@"Plays on every screen except a running game."
            minimum:0
            maximum:100
               step:5];
  slider.value = 70;
  slider.format = ^NSString*(float value) {
    return [NSString stringWithFormat:@"%d%%", (int)value];
  };
  [body addArrangedSubview:slider];
  [body setCustomSpacing:14 afterView:slider];
  XenraSectionHeader* pill =
      [[XenraSectionHeader alloc] initWithTitle:@"Performance"
                                          style:XenraSectionPill];
  [body addArrangedSubview:pill];
  [body setCustomSpacing:12 afterView:pill];
  XenraFieldButton* field = [[XenraFieldButton alloc] initWithTitle:@"Frame limit"
                                                             action:nil];
  field.value = @"Use Global";
  field.detail = @"Global default: 60";
  [field setCaptionFill:XenraCardFill()];
  [body addArrangedSubview:field];

  XenraCardView* buttons = [[XenraCardView alloc] initWithFrame:CGRectZero];
  [column addArrangedSubview:buttons];
  UIStackView* row = [[UIStackView alloc] initWithArrangedSubviews:@[
    [[XenraPillButton alloc] initWithTitle:@"Continue"
                                     style:XenraPillFilled
                                    action:nil],
    [[XenraPillButton alloc] initWithTitle:@"Back"
                                     style:XenraPillOutlined
                                    action:nil],
    [[XenraPillButton alloc] initWithTitle:@"Privacy Policy"
                                     style:XenraPillText
                                    action:nil],
  ]];
  row.spacing = 12;
  row.alignment = UIStackViewAlignmentCenter;
  [row addArrangedSubview:[[UIView alloc] init]];
  [buttons.body addArrangedSubview:row];
  XenraPillButton* disabled = [[XenraPillButton alloc] initWithTitle:@"Disabled"
                                                               style:XenraPillFilled
                                                              action:nil];
  disabled.enabled = NO;
  XenraPillButton* off = [[XenraPillButton alloc] initWithTitle:@"Off"
                                                          style:XenraPillOutlined
                                                         action:nil];
  off.enabled = NO;
  XenraPillButton* danger = [[XenraPillButton alloc] initWithTitle:@"Delete"
                                                             style:XenraPillFilled
                                                            action:nil];
  danger.destructive = YES;
  XenraIconToggleGroup* toggle = [[XenraIconToggleGroup alloc]
      initWithIcons:@[
        XenraOrientationIcon(@"portrait", 22),
        XenraOrientationIcon(@"landscape", 22)
      ]
             titles:@[ @"Vertical", @"Horizontal" ]];
  toggle.selectedIndex = 1;
  UIStackView* second = [[UIStackView alloc]
      initWithArrangedSubviews:@[ disabled, off, danger, toggle, [[UIView alloc] init] ]];
  second.spacing = 12;
  second.alignment = UIStackViewAlignmentCenter;
  [buttons.body addArrangedSubview:second];

  XenraCardView* blades = [[XenraCardView alloc] initWithFrame:CGRectZero];
  blades.body.spacing = 8;
  [column addArrangedSubview:blades];
  NSArray* rows = @[
    @"Plain row", @"Primary row", @"Destructive row", @"Dimmed row", @"Chosen row"
  ];
  for (NSUInteger i = 0; i < rows.count; i++) {
    XenraBladeButton* blade = [[XenraBladeButton alloc] initWithTitle:rows[i]
                                                               action:nil];
    blade.compact = YES;
    blade.primary = i == 1;
    blade.destructive = i == 2;
    blade.dimmed = i == 3;
    blade.chosen = i == 4;
    [blades.body addArrangedSubview:blade];
  }
  XenraBladeButton* subtitled =
      [[XenraBladeButton alloc] initWithTitle:@"Row with a subtitle" action:nil];
  subtitled.compact = YES;
  subtitled.subtitle = @"A line under the title, as the game menu has";
  [blades.body addArrangedSubview:subtitled];
  [blades.body addArrangedSubview:[[XenraBladeButton alloc]
                                      initWithTitle:@"Dashboard blade"
                                             action:nil]];

  XenraHintBar* hints = [[XenraHintBar alloc] initWithFrame:CGRectZero];
  hints.panelStyle = YES;
  hints.selectTitle = @"Open";
  hints.onSelect = ^{
  };
  hints.onBack = ^{
  };
  [self.view addSubview:hints];

  UILayoutGuide* safe = self.view.safeAreaLayoutGuide;
  [NSLayoutConstraint activateConstraints:@[
    [scroll.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:24],
    [scroll.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-24],
    [scroll.topAnchor constraintEqualToAnchor:safe.topAnchor constant:24],
    [scroll.bottomAnchor constraintEqualToAnchor:hints.topAnchor],
    [column.leadingAnchor constraintEqualToAnchor:scroll.leadingAnchor],
    [column.trailingAnchor constraintEqualToAnchor:scroll.trailingAnchor],
    [column.topAnchor constraintEqualToAnchor:scroll.topAnchor],
    [column.bottomAnchor constraintEqualToAnchor:scroll.bottomAnchor],
    [column.widthAnchor constraintEqualToAnchor:scroll.widthAnchor],
    [hints.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
    [hints.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
    [hints.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor],
  ]];
  XenraToast(self.view, @"Custom cover saved");
}

@end

static void GalleryTour(NSString* console) {
  Step(^{
    [Nav() pushViewController:[[TourGallery alloc] init] animated:YES];
  });
  Both([NSString stringWithFormat:@"%@-widgets", console]);
  Pressed(@"Continue", [NSString stringWithFormat:@"land-%@-pressed-pill", console]);
  PressTiming(@"Plain row");
  Pause();
  Pop();
}

// A long title and too many rows: nothing may be cut off or wrap badly.
static void LongSheetTour(NSString* console) {
  Step(^{
    NSMutableArray* rows = [NSMutableArray array];
    for (int i = 1; i <= 16; i++) {
      [rows addObject:[XenraBladeItem
                          title:[NSString stringWithFormat:@"Choice number %d", i]
                         action:nil]];
    }
    ((XenraBladeItem*)rows[2]).subtitle = @"A subtitle on one of the rows";
    ((XenraBladeItem*)rows[3]).destructive = YES;
    ((XenraBladeItem*)rows[0]).primary = YES;
    [XenraBladeSheet showIn:TopView()
                      title:@"Crash Bandicoot - The Wrath of Cortex and a very "
                             "long title indeed for a sheet"
                    message:@"A message over the rows, long enough that it has "
                             "to go onto a second line in the panel."
                      items:rows];
  });
  Both([NSString stringWithFormat:@"%@-sheet-long", console]);
  Tap(@"Close");
  Pause();
}

static void SettingsTour(NSString* console) {
  Tap(@"Settings");
  Pause();
  for (XenraSettingTab* tab in [XenraSettings tabs]) {
    Tap(tab.title);
    Both([NSString stringWithFormat:@"%@-settings-%@", console, tab.title]);
  }
  Step(^{
    XenraFieldButton* field =
        (XenraFieldButton*)FindClass(TopView(), [XenraFieldButton class]);
    [field sendActionsForControlEvents:UIControlEventTouchUpInside];
  });
  Both([NSString stringWithFormat:@"%@-settings-choice", console]);
  Tap(@"Back");  // the sheet's
  Pause();

  // The edge swipe's transition, stopped half way, abandoned, then done.
  Step(^{
    [(XenraNavigationController*)Nav() tourDragBegin];
  });
  Step(^{
    [(XenraNavigationController*)Nav() tourDragTo:0.45];
  });
  Shot([NSString stringWithFormat:@"land-%@-swipe-half", console]);
  Step(^{
    [(XenraNavigationController*)Nav() tourDragEnd:NO];
  });
  Shot([NSString stringWithFormat:@"land-%@-swipe-cancelled", console]);
  Step(^{
    [(XenraNavigationController*)Nav() tourDragBegin];
  });
  Step(^{
    [(XenraNavigationController*)Nav() tourDragTo:0.6];
  });
  Step(^{
    [(XenraNavigationController*)Nav() tourDragEnd:YES];
  });
  Shot([NSString stringWithFormat:@"land-%@-swipe-done", console]);
}

static void ConsoleTour(NSString* console, NSString* online) {
  Both([NSString stringWithFormat:@"%@-dashboard", console]);
  Pressed(@"Settings", [NSString stringWithFormat:@"land-%@-pressed-blade", console]);

  Tap(@"Back");
  Both([NSString stringWithFormat:@"%@-back-dialog", console]);
  Pressed(@"Close App", [NSString stringWithFormat:@"land-%@-pressed-dialog", console]);
  Tap(@"Back");
  Pause();

  Tap(online);
  Both([NSString stringWithFormat:@"%@-online", console]);
  Tap(@"OK");
  Pause();

  LongSheetTour(console);
  GalleryTour(console);

  Tap(@"Game Library");
  Both([NSString stringWithFormat:@"%@-library", console]);
  Pop();
  SettingsTour(console);
}

void XenraTourStart(UIWindow* window) {
  g_window = window;
  g_steps = [NSMutableArray array];
  [NSFileManager.defaultManager createDirectoryAtPath:TourDir()
                          withIntermediateDirectories:YES
                                           attributes:nil
                                                error:nil];
  NSString* docs = TourDir().stringByDeletingLastPathComponent;
  NSDictionary* folders = @{
    @"Games OG" : @[
      @"Crash Bandicoot - The Wrath of Cortex (USA).iso",
      @"Halo - Combat Evolved (USA).iso", @"Jet Set Radio Future (USA).iso",
      @"Smashing Drive (USA).iso", @"Forza Motorsport (USA).iso",
      @"Voodoo Vince (USA).iso", @"Project Gotham Racing 2 (USA).iso"
    ],
    @"Games" : @[ @"Halo 3.iso", @"Forza Horizon 2.iso", @"DiRT 3.iso" ],
  };
  for (NSString* folder in folders) {
    NSString* dir = [docs stringByAppendingPathComponent:folder];
    [NSFileManager.defaultManager createDirectoryAtPath:dir
                            withIntermediateDirectories:YES
                                             attributes:nil
                                                  error:nil];
    for (NSString* name in folders[folder]) {
      [NSData.data writeToFile:[dir stringByAppendingPathComponent:name]
                    atomically:NO];
    }
  }

  // Setup, as a new user sees it.
  Rotate(@"landscape");
  for (int page = 1; page <= 4; page++) {
    Both([NSString stringWithFormat:@"setup-%d", page]);
    if (page == 2) SetupPicks();
    Tap(@"Continue");
  }
  Both(@"setup-5");
  Step(^{
    [SetupScreen() tourShowJitWaiting];
  });
  Both(@"setup-5-waiting");
  Tap(@"Finish");
  Pause();
  Pause();

  ConsoleTour(@"360", @"Netplay");
  Tap(@"Console — Xbox 360");
  Pause();
  ConsoleTour(@"og", @"Xbox Live");

  Tap(@"Game Library");
  Step(^{
    [Nav() pushViewController:[[XenraGameController alloc]
                                  initWithPath:@"/none.iso"
                                          name:@"Smashing Drive"]
                     animated:YES];
  });
  Pause();
  Both(@"game-pad");
  Step(^{
    [Nav().topViewController performSelector:@selector(showMenu)];
  });
  Both(@"game-menu");

  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                 dispatch_get_main_queue(), ^{
                   Advance();
                 });
}

static void Advance(void) {
  if (g_next >= g_steps.count) {
    [@"" writeToFile:[TourDir() stringByAppendingPathComponent:@"done"]
          atomically:YES
            encoding:NSUTF8StringEncoding
               error:nil];
    return;
  }
  TourStep step = g_steps[g_next++];
  step();
  // Past every entrance, so the picture shows the settled screen.
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1400 * NSEC_PER_MSEC),
                 dispatch_get_main_queue(), ^{
                   Advance();
                 });
}
