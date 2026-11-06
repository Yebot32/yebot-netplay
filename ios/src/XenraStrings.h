/**
 ******************************************************************************
 * Xenra : iOS shell - translated text                                        *
 ******************************************************************************
 *
 * XS(@"English text") is that text in the app's language. The English is the key,
 * so English needs no file of its own and a missing translation falls back to it.
 * ios/res/<lang>.lproj/Localizable.strings hold the rest; ios/tools/check_strings.pl
 * fails CI on a key one of them lacks, and on a format specifier that differs.
 *
 * Only what a person reads goes through this. A string that is also compared,
 * stored or used as a key must stay English; where a control's title has to be
 * found again, as the pad's Back does, compare it with XS() of the same text.
 */

#import <Foundation/Foundation.h>

// A format argument, so stringWithFormat:XS(...) is still checked by the compiler.
NS_FORMAT_ARGUMENT(1) static inline NSString* XenraLocalized(NSString* english) {
  return [NSBundle.mainBundle localizedStringForKey:english
                                              value:english
                                              table:nil];
}

#define XS(english) XenraLocalized(english)

// Marks text as translated without looking it up, for the check, where the lookup
// is not in the running language: see XenraLanguage.mm.
#define XSKey(english) english
