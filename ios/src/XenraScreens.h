/**
 ******************************************************************************
 * Xenra : iOS shell - screens                                                *
 ******************************************************************************
 *
 * One view controller per Android activity: dashboard, library, settings,
 * per-game settings, game. A UINavigationController with its bar hidden stands
 * in for the activity stack.
 */

#import <UIKit/UIKit.h>

@class XenraGameEntry;

typedef NS_ENUM(NSInteger, XenraDashboardEntry) {
  XenraDashboardEntryPlain,      // the blades cascade in
  XenraDashboardEntryCrossfade,  // a console switch: the dissolve is the entrance
  XenraDashboardEntryArriving,   // from setup: SetupHandoffTransition
};

@interface XenraDashboardController : UIViewController
@property(nonatomic, assign) XenraDashboardEntry entry;
@end

// SetupWizardActivity.
@interface XenraSetupController : UIViewController
@end

@interface XenraLibraryController : UIViewController
@end

@interface XenraSettingsController : UIViewController
// Non-nil: Android's PerGameSettingsActivity for that game.
@property(nonatomic, copy) NSString* game;
@end

@interface XenraGameController : UIViewController
- (instancetype)initWithPath:(NSString*)path name:(NSString*)name;
@end

// Appends a timestamped line to Documents/xenra-jit-log.txt, which Files can see.
void XenraLog(NSString* line);
NSString* XenraLogPath(void);

// Whether generated code can run in this process right now.
BOOL XenraJitActive(void);
// A line for the screens: what state JIT is in and what to do about it.
NSString* XenraJitStatusText(void);
void XenraOpenJitEnabler(void);

// The window's root: the wizard until setup is finished, then the dashboard.
// Applies the theme first, since screens read it as they are built.
UIViewController* XenraMakeRoot(XenraDashboardEntry entry);
void XenraRestartSetup(UIWindow* window);
void XenraApplyOrientation(UIViewController* controller);
void XenraShowPrivacyPolicy(UIView* host);
// dialog_blade_about: the version, who made it, and the community links.
void XenraShowAbout(UIView* host);
