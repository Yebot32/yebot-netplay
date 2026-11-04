/**
 ******************************************************************************
 * Xenra : iOS shell - logs                                                   *
 ******************************************************************************
 *
 * Everything a bug report needs, kept across the crash that caused it, and
 * sent from inside the app as one text file.
 */

#import <UIKit/UIKit.h>

// First thing at launch, before the core: shelves the last runs' logs and
// installs the crash handlers. The core's fault handler chains to these, so
// they have to be in place before it is.
void XenraLogsBegin(void);

// Where the core writes this run's log. The default is beside the executable,
// which is the read-only app bundle on iOS.
NSString* XenraLogsCorePath(void);

// A game session is open from boot until a clean quit. Still open at the next
// launch means the process died in a way no handler sees: a SIGKILL for
// running unsigned code, or jetsam.
void XenraLogsBeginSession(void);
void XenraLogsEndSession(void);

// Non-nil once per launch when the last run crashed or never closed its
// session: a sentence for the screens.
NSString* XenraLogsTakeUncleanExitNotice(void);

// Builds the report and opens the share sheet over controller. done runs when
// the sheet closes, and may be nil.
void XenraShareLogs(UIViewController* controller, void (^done)(void));
