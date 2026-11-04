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

@interface XenraDashboardController : UIViewController
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

// Appends to Documents/xenra-jit-log.txt, which Files can see.
void XenraLog(NSString* line);
NSString* XenraLogPath(void);

// Whether generated code can run in this process right now.
BOOL XenraJitActive(void);
// A line for the screens: what state JIT is in and what to do about it.
NSString* XenraJitStatusText(void);
void XenraOpenJitEnabler(void);
