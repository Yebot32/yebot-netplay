/**
 ******************************************************************************
 * Xenra : iOS shell - the app's language                                     *
 ******************************************************************************
 *
 * LocaleHelper and dialog_language_picker. A language is chosen by writing
 * AppleLanguages, which iOS reads at launch, so a choice applies next time the app
 * opens: nothing here tries to swap the text of a running screen.
 */

#import <UIKit/UIKit.h>

#import "XenraUI.h"

// The language chosen: the one showing, or the one waiting for the next launch.
// The badge is the code on the wizard's button and on a picker row, the name the
// language's own.
NSString* XenraLanguageBadge(void);
NSString* XenraLanguageName(void);

// The picker, then the note that says when it applies. `changed` runs on a change.
void XenraShowLanguagePicker(UIView* host, void (^changed)(void));

// btn_setup_language: the globe and the badge, 44 pt tall. Its title is what the
// tour taps and VoiceOver reads; the badge is what shows.
@interface XenraLanguageButton : XenraPressControl
- (instancetype)initWithAction:(void (^)(void))action;
- (void)refresh;
@end
