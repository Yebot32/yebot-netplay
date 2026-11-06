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
// Its file name, shown under the title.
@property(nonatomic, copy) NSString* gameFile;
@end

@interface XenraGameController : UIViewController
- (instancetype)initWithPath:(NSString*)path name:(NSString*)name;
// The game that sent the user to StikDebug, if this launch is the app coming back
// with JIT on. StikDebug relaunches Xenra, so the waiting screen does not survive.
+ (nullable instancetype)takePendingAfterJit;
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
