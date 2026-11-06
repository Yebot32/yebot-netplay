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
#import "XenraGameScanner.h"
#import "XenraLanguage.h"
#import "XenraMotion.h"
#import "XenraScreens.h"
#import "XenraSettings.h"
#import "XenraStrings.h"
#import "XenraTheme.h"
#import "XenraPadNav.h"
#import "XenraUI.h"
#import "XenraUiSounds.h"
#include "ios_emu.h"

#include <unistd.h>

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

@interface XenraSettingsController (Tour)
- (void)tourScrollPaneToEnd;
@end

typedef void (^TourStep)(void);

static UIWindow* g_window;
static NSMutableArray* g_steps;
static NSUInteger g_next;
static int g_shot;
// Past every entrance, so the picture shows the settled screen. The language runs
// repeat screens the main tour has already timed, and there are several of them.
static int g_stepMs = 1400;

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
    // The page fits on an iPad, so give it somewhere to have scrolled to.
    page.contentInset = UIEdgeInsetsMake(0, 0, 300, 0);
    const CGFloat bottom = 200;
    [page setContentOffset:CGPointMake(0, bottom) animated:NO];
    [SetupScreen() tourPick:@"mcpx" url:TourFile(@"mcpx_1.0.bin", 512)];
    [page layoutIfNeeded];
    XenraLog([NSString
        stringWithFormat:@"tour: setup pick same page=%d offset %.0f then %.0f",
                         page == [SetupScreen() tourPage], bottom,
                         page.contentOffset.y]);
    page.contentInset = UIEdgeInsetsZero;
    [page setContentOffset:CGPointZero animated:NO];
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

// A page on its way in, a moment after Continue: it should start a screen away.
static void SetupTransition(void) {
  Step(^{
    [Need(@"Continue") sendActionsForControlEvents:UIControlEventTouchUpInside];
    UIView* page = [SetupScreen() tourPage];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 40 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
                     XenraLog([NSString
                         stringWithFormat:@"tour: setup page at x=%.0f of %.0f",
                                          page.layer.presentationLayer.frame.origin.x,
                                          page.superview.bounds.size.width]);
                   });
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
  UISwitch* toggleRow = [[UISwitch alloc] init];
  toggleRow.onTintColor = XenraAccent();
  [second insertArrangedSubview:toggleRow atIndex:4];

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
    Step(^{
      [(XenraSettingsController*)Nav().topViewController tourScrollPaneToEnd];
    });
    Shot([NSString stringWithFormat:@"land-%@-settings-%@-end", console, tab.title]);
  }
  // A list setting: the sheet, then a pick, which must leave the pane where it was.
  const BOOL x360 = [console isEqual:@"360"];
  Tap(@"System");
  Pause();
  Tap(x360 ? @"User language" : @"AV pack");
  Both([NSString stringWithFormat:@"%@-settings-choice", console]);
  Tap(x360 ? @"German" : @"VGA");
  Pause();
  Shot([NSString stringWithFormat:@"land-%@-settings-picked", console]);
  Tap(x360 ? @"User language" : @"AV pack");
  Pause();
  Tap(x360 ? @"English" : @"HDTV");
  Pause();

  Tap(@"Maintenance");
  Step(^{
    [(XenraSettingsController*)Nav().topViewController tourScrollPaneToEnd];
  });
  Tap(@"About Xenra");
  Both([NSString stringWithFormat:@"%@-settings-about", console]);
  Tap(@"Back");  // the sheet's
  Pause();
  Tap(@"Clear shader cache");
  Shot([NSString stringWithFormat:@"land-%@-settings-clear", console]);
  Tap(@"Cancel");
  Pause();

  // Per-game settings: Use Global fields, and the anchored dropdown.
  Step(^{
    XenraSettingsController* perGame = [[XenraSettingsController alloc] init];
    perGame.game = @"Crash Bandicoot - The Wrath of Cortex";
    perGame.gameFile = @"Crash Bandicoot - The Wrath of Cortex (USA).iso";
    [Nav() pushViewController:perGame animated:YES];
  });
  Pause();
  Both([NSString stringWithFormat:@"%@-pergame", console]);
  Tap(x360 ? @"Internal resolution" : @"Internal Resolution Scale");
  Shot([NSString stringWithFormat:@"land-%@-pergame-dropdown", console]);
  Tap(x360 ? @"2x" : @"2x (960p)");
  Pause();
  Shot([NSString stringWithFormat:@"land-%@-pergame-picked", console]);
  Tap(@"Clear Overrides");
  Pause();
  Pop();
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

// The controller. A simulator has none, so these stand in for what GCController
// reads and leave the rest of XenraPadNav as it is on a device, the display link
// and its timing included. Every line is in the log as "tour: pad".
static void PadLog(NSString* what) {
  XenraLog([NSString
      stringWithFormat:@"tour: pad %@ focus=%@ blips=%d polling=%d top=%@", what,
                       XenraPadNavTestFocus() ?: @"-", XenraUiSoundsTestCount(),
                       XenraPadNavTestPolling(), Nav().topViewController.class]);
}

static void PadNeutral(void) {
  XenraPadTestState state = {};
  XenraPadNavTestSet(&state);
}

static void PadHoldKey(NSString* key) {
  XenraPadTestState state = {};
  if ([key isEqual:@"U"]) state.dy = -1;
  if ([key isEqual:@"D"]) state.dy = 1;
  if ([key isEqual:@"L"]) state.dx = -1;
  if ([key isEqual:@"R"]) state.dx = 1;
  state.a = [key isEqual:@"A"];
  state.b = [key isEqual:@"B"];
  state.lb = [key isEqual:@"LB"];
  state.rb = [key isEqual:@"RB"];
  XenraPadNavTestSet(&state);
}

static void After(int ms, void (^block)(void)) {
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, ms * NSEC_PER_MSEC),
                 dispatch_get_main_queue(), block);
}

// Up to six keys, 200 ms apart, which is past the step throttle.
static void Pad(NSString* keys) {
  Step(^{
    NSArray<NSString*>* list = [keys componentsSeparatedByString:@" "];
    for (NSUInteger i = 0; i < list.count; i++) {
      After(int(i) * 200, ^{
        PadHoldKey(list[i]);
      });
      After(int(i) * 200 + 70, ^{
        PadNeutral();
      });
    }
    After(int(list.count) * 200 + 20, ^{
      PadLog(keys);
    });
  });
}

static void PadSeekStep(NSString* name, NSString* key, int left) {
  if ([XenraPadNavTestFocus() isEqual:name] || left == 0) {
    PadLog([NSString stringWithFormat:@"seek %@", name]);
    return;
  }
  PadHoldKey(key);
  After(70, ^{
    PadNeutral();
  });
  After(190, ^{
    PadSeekStep(name, key, left - 1);
  });
}

// Walks until the cursor is on `name`, a title or a class.
static void PadSeek(NSString* name, NSString* key) {
  Step(^{
    PadSeekStep(name, key, 6);
  });
}

// Held 1.3 s: a step at once, at 450 ms, then every 250 ms. So five.
static void PadHoldTest(NSString* key) {
  Step(^{
    const int before = XenraUiSoundsTestCount();
    PadHoldKey(key);
    After(1300, ^{
      PadNeutral();
      PadLog([NSString stringWithFormat:@"hold steps=%d want 5",
                                        XenraUiSoundsTestCount() - before]);
    });
  });
}

static void PadStick(float x, float y) {
  XenraPadTestState state = {};
  state.sx = x;
  state.sy = y;
  XenraPadNavTestSet(&state);
}

// ControllerNavigator's numbers. Under 0.5 is nothing, a diagonal is nothing, a
// push off true is still that direction, and 0.35 holds a direction that 0.5 took.
static void PadStickTest(void) {
  Step(^{
    const int before = XenraUiSoundsTestCount();
    PadStick(0, 0.45);
    After(100, ^{
      PadStick(0.6, 0.6);
    });
    After(200, ^{
      PadNeutral();
      PadLog([NSString stringWithFormat:@"stick weak and diagonal steps=%d want 0",
                                        XenraUiSoundsTestCount() - before]);
    });
  });
  Step(^{
    const int before = XenraUiSoundsTestCount();
    PadStick(0.2, 0.6);
    After(100, ^{
      PadStick(0, 0.35);
    });
    After(250, ^{
      PadStick(0, 0.1);
    });
    After(350, ^{
      PadStick(0, 0.6);
    });
    After(450, ^{
      PadNeutral();
      PadLog([NSString stringWithFormat:@"stick hysteresis steps=%d want 2",
                                        XenraUiSoundsTestCount() - before]);
    });
  });
}

static void PadTour(NSString* console) {
  NSString* (^name)(NSString*) = ^NSString*(NSString* what) {
    return [NSString stringWithFormat:@"land-%@-pad-%@", console, what];
  };
  Step(^{
    PadNeutral();
    XenraLog([NSString stringWithFormat:@"tour: pad sound %@",
                                        XenraUiSoundsTestReport()]);
  });

  // The dashboard: nothing until a press, and the first press only places it.
  Shot(name(@"dash-none"));
  Pad(@"D");
  Shot(name(@"dash-placed"));
  PadSeek(@"Settings", @"D");
  Shot(name(@"dash-settings"));
  Step(^{
    XenraPadNavTouched();
    PadLog(@"touch");
  });
  Shot(name(@"dash-touched"));
  Pad(@"D");  // back where it was

  // B with a cursor or without opens the back choice, and closes it.
  Pad(@"B");
  Pad(@"D R");
  Shot(name(@"back-sheet"));
  Pad(@"B");
  Shot(name(@"back-closed"));

  // Into settings on A.
  Pad(@"A");
  Pause();
  Shot(name(@"settings-none"));
  Pad(@"D");
  Both([NSString stringWithFormat:@"%@-pad-settings-tab", console]);
  Pad(@"RB");
  Shot(name(@"settings-rb"));
  Pad(@"LB");
  Pad(@"R");
  Shot(name(@"settings-pane"));
  Pad(@"RB");  // the cursor stays in the pane
  Pause();
  Step(^{
    PadLog(@"after RB in the pane, want a pane control");
  });
  Shot(name(@"settings-rb-pane"));
  Pad(@"LB");
  Pad(@"U U U U U U");
  Pad(@"D D D D D D");
  Shot(name(@"settings-scrolled"));
  Pad(@"B");
  Pause();
  Shot(name(@"settings-left"));

  // Every kind of widget.
  Step(^{
    [Nav() pushViewController:[[TourGallery alloc] init] animated:YES];
  });
  Pause();
  Pad(@"D");
  Shot(name(@"widget-first"));
  // It starts on the row marked chosen, as it would on a tab.
  PadSeek(@"UISlider", @"U");
  PadSeek(@"UISlider", @"U");
  Pad(@"R R");
  Step(^{
    PadLog([NSString
        stringWithFormat:@"slider value=%.0f want 80",
                         ((XenraSliderRow*)FindClass(TopView(),
                                                     [XenraSliderRow class]))
                             .value]);
  });
  Shot(name(@"widget-slider"));
  PadSeek(@"Frame limit", @"D");
  Shot(name(@"widget-field"));
  Pad(@"D");  // the middle of the row under a wide field
  PadSeek(@"Continue", @"L");
  Shot(name(@"widget-pill"));
  Pad(@"D");
  PadSeek(@"UISwitch", @"R");
  Pad(@"A");
  Step(^{
    PadLog([NSString
        stringWithFormat:@"switch on=%d want 1",
                         ((UISwitch*)FindClass(TopView(), [UISwitch class])).on]);
  });
  Shot(name(@"widget-switch"));
  PadSeek(@"Chosen row", @"D");
  Shot(name(@"widget-chosen"));
  PadSeek(@"Dashboard blade", @"D");
  Shot(name(@"widget-blade"));
  Pop();
  Pause();

  // A long sheet: the cursor is held in it and it follows the cursor.
  Step(^{
    NSMutableArray* rows = [NSMutableArray array];
    for (int i = 1; i <= 16; i++) {
      [rows addObject:[XenraBladeItem
                          title:[NSString stringWithFormat:@"Choice number %d", i]
                         action:nil]];
    }
    [XenraBladeSheet showIn:TopView() title:@"Pad test" message:nil items:rows];
  });
  Pause();
  Pad(@"D");
  PadHoldTest(@"D");
  Shot(name(@"sheet-held"));
  PadStickTest();
  PadHoldTest(@"D");
  Shot(name(@"sheet-scrolled"));
  Pad(@"B");
  Pause();

  // The library, cell by cell.
  Tap(@"Game Library");
  Pause();
  Pad(@"D");
  Shot(name(@"library-placed"));
  Pad(@"R D");
  Shot(name(@"library-moved"));
  Tap(@"Covers");
  Pause();
  Pad(@"D R D");
  Shot(name(@"library-covers"));
  Tap(@"List");
  Pause();
  Pad(@"B");
  Pause();
  Step(^{
    PadLog(@"tour ended");
    XenraPadNavTestSet(nullptr);
  });
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
  Step(^{
    [Nav().topViewController performSelector:@selector(tourTapItem:)
                                  withObject:@1];
  });
  Both([NSString stringWithFormat:@"%@-library-selected", console]);
  Tap(@"Actions");
  Shot([NSString stringWithFormat:@"%@-library-actions", console]);
  Step(^{
    [[XenraBladeSheet topSheetIn:TopView()] dismiss];
  });
  Tap(@"Back");
  Tap(@"More");
  Shot([NSString stringWithFormat:@"%@-library-more", console]);
  Tap(@"More");
  Tap(@"Covers");
  Both([NSString stringWithFormat:@"%@-library-grid", console]);
  Tap(@"List");
  Step(^{
    [Nav().topViewController performSelector:@selector(tourEmpty:) withObject:@YES];
  });
  Both([NSString stringWithFormat:@"%@-library-empty", console]);
  Step(^{
    [Nav().topViewController performSelector:@selector(tourEmpty:) withObject:@NO];
  });
  Pop();
  SettingsTour(console);
  PadTour(console);
}

// The language picker and the note after a pick. English goes back to English, so
// the rest of the tour is not told about a language that is waiting for a relaunch.
static void PickerTour(void) {
  Tap(@"App Language");
  Both(@"setup-language");
  Tap(@"German");
  Both(@"setup-language-note");
  Tap(@"Nicht jetzt");
  Pause();
  Tap(@"App Language");
  Shot(@"land-setup-language-pending");
  Tap(@"English");
  Pause();
  Tap(@"Not Now");
  Pause();
  Step(^{
    [NSUserDefaults.standardUserDefaults removeObjectForKey:@"AppleLanguages"];
  });
}

// The main screens in the language the app was launched in, for what a longer word
// or another script does to them. Titles go through XS() here, as this is the one
// place the tour reads a screen that is not in English.
static void LanguageTour(NSString* code) {
  NSString* (^name)(NSString*) = ^NSString*(NSString* what) {
    return [NSString stringWithFormat:@"lang-%@-%@", code, what];
  };
  // Both() with the language in the name, which it puts land- or port- ahead of.
  void (^both)(NSString*) = ^(NSString* what) {
    Both(name(what));
  };
  void (^shot)(NSString*) = ^(NSString* what) {
    Shot([@"land-" stringByAppendingString:name(what)]);
  };
  Rotate(@"landscape");

  // Original Xbox, the dark theme.
  both(@"og-dashboard");
  Tap(XS(@"Back"));
  shot(@"og-back-dialog");
  Tap(XS(@"Back"));
  Pause();
  Tap(@"Xbox Live");
  shot(@"og-online");
  Tap(XS(@"OK"));
  Pause();

  Tap(XS(@"Game Library"));
  both(@"og-library");
  Step(^{
    [Nav().topViewController performSelector:@selector(tourTapItem:) withObject:@1];
  });
  shot(@"og-library-selected");
  Tap(XS(@"Actions"));
  shot(@"og-library-actions");
  Step(^{
    [[XenraBladeSheet topSheetIn:TopView()] dismiss];
  });
  Tap(XS(@"Back"));
  Tap(XS(@"More"));
  shot(@"og-library-more");
  Tap(XS(@"More"));
  Tap(XS(@"Covers"));
  shot(@"og-library-grid");
  Tap(XS(@"List"));
  Step(^{
    [Nav().topViewController performSelector:@selector(tourEmpty:) withObject:@YES];
  });
  shot(@"og-library-empty");
  Step(^{
    [Nav().topViewController performSelector:@selector(tourEmpty:) withObject:@NO];
    XenraToast(TopView(), XS(@"Failed to save custom cover"));
  });
  shot(@"og-toast");
  Pop();
  Pause();

  Tap(XS(@"Settings"));
  Pause();
  for (XenraSettingTab* tab in [XenraSettings tabsForConsole:XenraConsoleOG]) {
    Tap(tab.title);
    shot([NSString stringWithFormat:@"og-settings-%lu",
                                    (unsigned long)[[XenraSettings
                                        tabsForConsole:XenraConsoleOG] indexOfObject:tab]]);
  }
  Tap(XS(@"System"));
  Pause();
  both(@"og-settings-system");
  Tap(XS(@"App Language"));
  both(@"language-picker");
  Tap(XS(@"Close"));
  Pause();
  Tap(XS(@"AV pack"));
  shot(@"og-settings-choice");
  Tap(XS(@"Close"));
  Pause();
  Tap(XS(@"Maintenance"));
  Step(^{
    [(XenraSettingsController*)Nav().topViewController tourScrollPaneToEnd];
  });
  Tap(XS(@"About Xenra"));
  shot(@"og-settings-about");
  Tap(XS(@"Back"));
  Pause();
  Tap(XS(@"Clear shader cache"));
  shot(@"og-settings-clear");
  Tap(XS(@"Cancel"));
  Pause();
  Step(^{
    XenraSettingsController* perGame = [[XenraSettingsController alloc] init];
    perGame.game = @"Crash Bandicoot - The Wrath of Cortex";
    perGame.gameFile = @"Crash Bandicoot - The Wrath of Cortex (USA).iso";
    [Nav() pushViewController:perGame animated:YES];
  });
  Pause();
  both(@"og-pergame");
  Pop();
  Pause();
  Pop();
  Pause();

  // Xbox 360, the light theme.
  Tap([NSString stringWithFormat:XS(@"Console — %@"), @"Xbox Original"]);
  Pause();
  Pause();
  both(@"360-dashboard");
  Tap(XS(@"Netplay"));
  shot(@"360-online");
  Tap(XS(@"OK"));
  Pause();
  Tap(XS(@"Game Library"));
  shot(@"360-library");
  Pop();
  Pause();
  Tap(XS(@"Settings"));
  Pause();
  for (XenraSettingTab* tab in [XenraSettings tabsForConsole:XenraConsole360]) {
    Tap(tab.title);
    shot([NSString stringWithFormat:@"360-settings-%lu",
                                    (unsigned long)[[XenraSettings
                                        tabsForConsole:XenraConsole360] indexOfObject:tab]]);
  }
  Tap(XS(@"Rendering"));
  Pause();
  Step(^{
    [(XenraSettingsController*)Nav().topViewController tourScrollPaneToEnd];
  });
  shot(@"360-settings-rendering-end");
  Step(^{
    XenraSettingsController* perGame = [[XenraSettingsController alloc] init];
    perGame.game = @"Halo 3";
    perGame.gameFile = @"Halo 3.iso";
    [Nav() pushViewController:perGame animated:YES];
  });
  Pause();
  shot(@"360-pergame");
  Pop();
  Pause();
  Pop();
  Pause();

  // The game and its menu.
  Step(^{
    [Nav() pushViewController:[[XenraGameController alloc]
                                  initWithPath:@"/none.iso"
                                          name:@"Smashing Drive"]
                     animated:YES];
  });
  Pause();
  shot(@"game-failure");
  Step(^{
    [Nav().topViewController performSelector:@selector(showMenu)];
  });
  both(@"game-menu");
  Pop();
  Pause();

  // Setup, last, because it takes the app back to the start.
  Step(^{
    XenraRestartSetup(g_window);
  });
  Pause();
  Pause();
  for (int page = 1; page <= 5; page++) {
    NSString* picture = [NSString stringWithFormat:@"setup-%d", page];
    if (page <= 2) {
      both(picture);
    } else {
      shot(picture);
    }
    if (page == 1) {
      Tap(XS(@"App Language"));
      shot(@"setup-language");
      Tap(XS(@"Close"));
      Pause();
      Tap(XS(@"Privacy policy"));
      shot(@"setup-privacy");
      Tap(XS(@"OK"));
      Pause();
    }
    if (page < 5) Tap(XS(@"Continue"));
  }
  // As the next run expects to find it.
  Step(^{
    [XenraSettings setConsole:XenraConsoleOG];
    [XenraSettings setSetupComplete:YES];
    [NSUserDefaults.standardUserDefaults synchronize];
  });
}

void XenraTourStart(UIWindow* window) {
  g_window = window;
  g_steps = [NSMutableArray array];
  NSString* language =
      [NSUserDefaults.standardUserDefaults stringForKey:@"XenraTourLanguage"];
  if (language) {
    XenraLog([NSString
        stringWithFormat:@"tour: language %@ preferred=%@ in bundle=%@ Continue=%@ rtl=%d",
                         language, NSBundle.mainBundle.preferredLocalizations,
                         NSBundle.mainBundle.localizations, XS(@"Continue"),
                         UIApplication.sharedApplication.userInterfaceLayoutDirection ==
                             UIUserInterfaceLayoutDirectionRightToLeft]);
    g_stepMs = 800;
    if (![language isEqual:@"check"]) LanguageTour(language);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
                     Advance();
                   });
    return;
  }
  XenraScannerSelfTest();
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
      @"Voodoo Vince (USA).iso", @"Project Gotham Racing 2 (USA).iso",
      @"The Lord of the Rings - The Return of the King and a Title Far Longer "
      @"Than Any Row Has Room For On This Screen (USA).iso"
    ],
    @"Games" : @[
      @"Halo 3.iso", @"Forza Horizon 2.iso", @"DiRT 3.iso",
      @"Tom Clancy's Rainbow Six Vegas 2 Complete Collector Edition With a "
      @"Title Too Long For Any Tile To Show In Two Lines.iso"
    ],
  };
  for (NSString* folder in folders) {
    NSString* dir = [docs stringByAppendingPathComponent:folder];
    [NSFileManager.defaultManager createDirectoryAtPath:dir
                            withIntermediateDirectories:YES
                                             attributes:nil
                                                  error:nil];
    for (NSString* name in folders[folder]) {
      NSString* game = [dir stringByAppendingPathComponent:name];
      [NSData.data writeToFile:game atomically:NO];
      // Sparse, so the rows show a real size for nothing.
      truncate(game.fileSystemRepresentation, 3500000000LL + name.length * 40000000LL);
    }
  }

  // Setup, as a new user sees it.
  Rotate(@"landscape");
  for (int page = 1; page <= 4; page++) {
    Both([NSString stringWithFormat:@"setup-%d", page]);
    if (page == 1) PickerTour();
    if (page == 2) SetupPicks();
    if (page == 3) {
      SetupTransition();
      continue;
    }
    Tap(@"Continue");
  }
  Both(@"setup-5");
  // No hint bar here: B has to find the Back pill.
  Step(^{
    PadNeutral();
  });
  Pad(@"B");
  Shot(@"land-setup-pad-back");
  Pad(@"D");
  Shot(@"land-setup-pad-placed");
  Step(^{
    XenraPadNavTestSet(nullptr);
  });
  Tap(@"Continue");
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

  // The game owns the controller, with its menu open or not, until it is gone.
  Step(^{
    PadNeutral();
    PadLog(@"in game, want polling=0");
  });
  Pad(@"D A");
  Step(^{
    PadLog(@"in game after D A, want focus=-");
  });
  Pop();
  Pause();
  Step(^{
    PadLog(@"game gone, want polling=1");
    XenraPadNavTestSet(nullptr);
  });

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
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, g_stepMs * NSEC_PER_MSEC),
                 dispatch_get_main_queue(), ^{
                   Advance();
                 });
}
