/**
 ******************************************************************************
 * Xenra : iOS shell - Xbox OG Live (Insignia)                                *
 ******************************************************************************
 *
 * XboxInsigniaHelper.kt and XboxEepromEditor.kt from Android, without the UI:
 * the Insignia DNS entry in the console EEPROM, the setup progress flags, and
 * the two boots the wizard offers (the setup assistant disc and the retail
 * dashboard with no disc in the drive).
 *
 * The DNS write is the same edit Android makes: four bytes at 0xAC of the
 * 256-byte EEPROM, then the user checksum at 0x60 over 0x64..0xBF has to be
 * recomputed or the console ignores the change.
 */

#import <Foundation/Foundation.h>

@class XenraGameController;

NS_ASSUME_NONNULL_BEGIN

extern NSString* const XenraInsigniaPrimaryDNS;    // 46.101.64.175
extern NSString* const XenraInsigniaSecondaryDNS;  // 8.8.8.8

NSString* XenraInsigniaSiteURL(void);
NSString* XenraInsigniaGuideURL(void);
NSString* XenraInsigniaSetupDownloadURL(void);

// The [net] enable row Android's wizard switches on before writing the DNS.
BOOL XenraInsigniaNetworkingOn(void);
void XenraInsigniaSetNetworkingOn(BOOL on);

// The EEPROM the core actually boots with: the user's picked file, else the one
// the core generated. nil when neither exists yet (it appears after one game
// launch, exactly as Android's does).
NSURL* _Nullable XenraInsigniaEepromURL(void);
BOOL XenraInsigniaDNSApplied(void);

// YES when the EEPROM changed, NO when the DNS was already right (or on error,
// which fills error). Reads and writes in place so a picked file's bookmark
// stays valid.
BOOL XenraInsigniaApplyDNS(NSError* _Nullable* _Nullable error);

// The setup assistant image, remembered by path after an import.
NSString* _Nullable XenraInsigniaSetupDiscPath(void);
void XenraInsigniaRememberSetupDisc(NSString* path);
void XenraInsigniaClearSetupDisc(void);

BOOL XenraInsigniaSignedUp(void);
void XenraInsigniaSetSignedUp(BOOL signedUp);

BOOL XenraInsigniaAllDone(void);
void XenraInsigniaClearProgress(void);

// The marker path XenraXemu's config writer reads as "no disc in the drive".
NSString* XenraInsigniaDashboardPath(void);

// The Settings folder the installer copies original Xbox images into.
NSString* XenraInsigniaGamesFolder(void);
// Where a picked file lands after XenraInstallFromURL: Games OG/<file name>.
NSString* XenraInsigniaInstalledDiscPath(NSString* sourcePath);

// The setup assistant boot, or the dashboard with an empty drive. nil (and a
// reason) when the core's system files are not all chosen.
NSString* _Nullable XenraInsigniaBootProblem(void);
XenraGameController* _Nullable XenraInsigniaMakeSetupDiscController(
    NSString* path);
XenraGameController* _Nullable XenraInsigniaMakeDashboardController(void);

NS_ASSUME_NONNULL_END
