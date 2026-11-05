/**
 ******************************************************************************
 * Xenra : UI-only simulator build                                            *
 ******************************************************************************
 *
 * The shell with the cores stubbed out, driven through every screen so CI can
 * photograph it. The app writes tour/shot-N-name and waits; the host takes the
 * screenshot and writes tour/ack-N. Steps tap real controls by their titles, so
 * a control that stopped working stops the tour too.
 */

#import <UIKit/UIKit.h>

#import "XenraScreens.h"
#import "XenraSettings.h"
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

static UIControl* FindControl(UIView* root, NSString* title) {
  for (UIView* view in root.subviews.reverseObjectEnumerator) {
    if (UIControl* found = FindControl(view, title)) return found;
  }
  if ([root isKindOfClass:[XenraBladeButton class]] &&
      [((XenraBladeButton*)root).title isEqual:title]) {
    return (UIControl*)root;
  }
  return nil;
}

static void Tap(NSString* title) {
  UIControl* control = FindControl(g_window, title);
  if (!control) {
    XenraLog([NSString stringWithFormat:@"tour: NO SUCH CONTROL %@", title]);
    return;
  }
  [control sendActionsForControlEvents:UIControlEventTouchUpInside];
}

static void Step(TourStep step) { [g_steps addObject:[step copy]]; }

static void Shot(NSString* name) {
  Step(^{
    const int shot = ++g_shot;
    [@"" writeToFile:[TourDir()
                         stringByAppendingPathComponent:
                             [NSString stringWithFormat:@"shot-%03d-%@", shot,
                                                        name]]
          atomically:YES
            encoding:NSUTF8StringEncoding
               error:nil];
    NSString* ack = [TourDir() stringByAppendingPathComponent:
                                   [NSString stringWithFormat:@"ack-%03d", shot]];
    // The run loop keeps turning while the host photographs the screen.
    NSDate* limit = [NSDate dateWithTimeIntervalSinceNow:30];
    while (![NSFileManager.defaultManager fileExistsAtPath:ack] &&
           limit.timeIntervalSinceNow > 0) {
      [NSRunLoop.mainRunLoop
          runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    }
  });
}

static void Rotate(NSString* lock) {
  Step(^{
    [XenraSettings setString:lock forKey:@"ui.orientation"];
    XenraApplyOrientation(g_window.rootViewController);
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

static void SeedGames(void) {
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
}

static void SettingsTour(NSString* prefix) {
  Step(^{
    Tap(@"Settings");
  });
  Shot([prefix stringByAppendingString:@"-settings"]);
  for (XenraSettingTab* tab in [XenraSettings tabs]) {
    Step(^{
      Tap(tab.title);
    });
    Shot([NSString stringWithFormat:@"%@-settings-%@", prefix, tab.title]);
  }
  Step(^{
    [(UINavigationController*)g_window.rootViewController
        popViewControllerAnimated:YES];
  });
}

void XenraTourStart(UIWindow* window) {
  g_window = window;
  g_steps = [NSMutableArray array];
  [NSFileManager.defaultManager createDirectoryAtPath:TourDir()
                          withIntermediateDirectories:YES
                                           attributes:nil
                                                error:nil];
  SeedGames();

  // Setup, as a new user sees it.
  for (int page = 1; page <= 4; page++) {
    Shot([NSString stringWithFormat:@"setup-%d", page]);
    Step(^{
      Tap(@"Continue");
    });
  }
  Shot(@"setup-5");
  Step(^{
    Tap(@"Finish");
  });
  Step(^{
  });

  // Both consoles, landscape then portrait.
  Shot(@"dashboard-360");
  Step(^{
    Tap(@"Game Library");
  });
  Shot(@"library-360");
  Step(^{
    [(UINavigationController*)g_window.rootViewController
        popViewControllerAnimated:YES];
  });
  SettingsTour(@"360");
  Step(^{
    Tap(@"Console — Xbox 360");
  });
  Step(^{
  });
  Shot(@"dashboard-og");
  Step(^{
    Tap(@"Game Library");
  });
  Shot(@"library-og");
  Step(^{
    [(UINavigationController*)g_window.rootViewController
        popViewControllerAnimated:YES];
  });
  SettingsTour(@"og");
  Rotate(@"portrait");
  Shot(@"portrait-dashboard");
  Step(^{
    Tap(@"Game Library");
  });
  Shot(@"portrait-library");
  Step(^{
    [(UINavigationController*)g_window.rootViewController
        popViewControllerAnimated:YES];
  });
  SettingsTour(@"portrait");
  Rotate(@"landscape");
  Step(^{
    Tap(@"Game Library");
  });
  Step(^{
    [(UINavigationController*)g_window.rootViewController
        pushViewController:[[XenraGameController alloc]
                               initWithPath:@"/none.iso"
                                       name:@"Smashing Drive"]
                  animated:YES];
  });
  Shot(@"game-pad");
  Step(^{
    UIViewController* top =
        ((UINavigationController*)g_window.rootViewController).topViewController;
    [top performSelector:@selector(showMenu)];
  });
  Shot(@"game-menu");

  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                 dispatch_get_main_queue(), ^{
                   Advance();
                 });
}
