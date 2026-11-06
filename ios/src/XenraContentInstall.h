/**
 ******************************************************************************
 * Xenra : iOS shell - installing content                                      *
 ******************************************************************************
 *
 * Xbox360ContentInstall.kt, with what a picked file turns out to be deciding the
 * rest:
 *
 *   Add-on content (DLC, a title update, a profile)
 *       Goes through the core's installer: the header entries it writes beside
 *       the package are what the core looks for, so a plain copy does not work.
 *   A 360 disc image carrying packages under \content\
 *       Each package is staged out and installed: a mandatory-install title.
 *   A game (original Xbox image, 360 disc, GOD, STFS, XEX, ZAR)
 *       Copied into this console's own games folder. Android tells the user to do
 *       that by hand; on iOS the app's own folder is the natural place.
 *   Anything else
 *       Refused, saying why.
 *
 * A GOD game is a header file and a "<name>.data" folder, and a document picker
 * hands over one item. So it is refused too, pointing at Set game folder.
 */

#import <Foundation/Foundation.h>

#import "XenraSettings.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, XenraInstallOutcome) {
  XenraInstallFailed,
  XenraInstallContent,  // in the content tree
  XenraInstallGame,     // in the games folder: the list needs a refresh
};

// Runs in the background; both blocks run on the main thread. fraction is 0..1,
// or negative while the step has no measure. url may be security scoped.
void XenraInstallFromURL(NSURL* url, XenraConsole console,
                         void (^progress)(NSString* message, float fraction),
                         void (^done)(XenraInstallOutcome outcome,
                                      NSString* message));

NS_ASSUME_NONNULL_END
