/**
 ******************************************************************************
 * Xenra : iOS shell - game list model                                        *
 ******************************************************************************
 *
 * Finds what the Android library finds, for the console in use, off the main
 * thread, and remembers it.
 *
 * The folder decides the console, as on Android (Xbox360Library.resolveLaunchPath):
 * a .iso means either console, so [XenraSettings gameFolders] is the whole test.
 *
 *   Original Xbox  .iso .xiso .cci .cso, in any subfolder.
 *   Xbox 360       .iso .zar, a loose .xex, a folder holding default.xex (the
 *                  folder is the game, nothing under it is scanned), and
 *                  containers recognised by their CON/LIVE/PIRS magic: files
 *                  with no extension, or .god .con .live .pirs. Only launchable
 *                  content types count, so DLC, updates, saves and profiles
 *                  never appear. "<name>.data" payload folders are skipped.
 *   Both           Hidden files and folders are skipped. Depth stops at 12, and
 *                  a symlink loop ends at the first repeat.
 *
 * The list is sorted as Android sorts it: by lowercased title, by UTF-16 code
 * unit, so "Zoo" comes before "ÉA". Path breaks ties.
 *
 * HOW THE LIBRARY SCREEN USES THIS (gap audit A11)
 *
 *   viewDidLoad:     games_ = [XenraGameScanner shared].cachedGames;
 *                    Show it at once: no spinner, no empty state, unless the
 *                    list is empty and scanning.
 *   viewWillAppear:  [[XenraGameScanner shared] refreshWithCompletion:
 *                        ^(NSArray* games, BOOL changed) {
 *                      if (changed) { games_ = games; [collection_ reloadData]; }
 *                    }];
 *
 * A return to the library with nothing changed does no header reads and no
 * reload. The cached list is on disk too, so it survives a relaunch. Only the
 * first read per console touches the disk, and it is one small plist.
 */

#import <UIKit/UIKit.h>

#import "XenraSettings.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, XenraGameFormat) {
  XenraGameFormatDiscImage,   // .iso .xiso, either console
  XenraGameFormatCompressed,  // .cci .cso: nothing inside is readable
  XenraGameFormatZAR,
  XenraGameFormatGOD,
  XenraGameFormatSTFS,
  XenraGameFormatXEXFolder,  // path is the default.xex inside the folder
  XenraGameFormatXEXFile,
};

// Android's DiscImageFormat. Redump is an original Xbox image still carrying
// its video partition; Android offers to convert those, and badges them.
typedef NS_ENUM(NSInteger, XenraDiscLayout) {
  XenraDiscLayoutNotApplicable,  // not an original Xbox .iso or .xiso
  XenraDiscLayoutXISO,
  XenraDiscLayoutRedump,
  XenraDiscLayoutUnknown,  // no XDVDFS volume found, or the file is empty
};

// Immutable. Safe to hold and to read from any thread.
@interface XenraGameEntry : NSObject

// What the core boots. For a XEX folder this is the default.xex inside it.
@property(nonatomic, readonly, copy) NSString* path;

// The title to show.
//   Original Xbox: the file name without extension and without trailing (...)
//   and [...] groups, as Android shows it. If the file has no such group it was
//   named by hand, and the XBE certificate title replaces it. A tagged name
//   stays, because the certificate field is 40 characters and publishers
//   abbreviate: Crash's reads "Crash Bandicoot: tWoC".
//   Xbox 360: the title in the container header, else the display name. ISO,
//   ZAR and XEX have only the file or folder name: the real name is in an
//   encrypted resource, which needs the core.
// Per-game settings are keyed by this, so it no longer equals the file stem.
@property(nonatomic, readonly, copy) NSString* name;

// For the muted column, as Android words it: "Size: 7.3 GB". A XEX folder has no
// size worth walking for, so it says "XEX".
@property(nonatomic, readonly, copy) NSString* subtitle;

// Bytes. A GOD counts its .data payload. A XEX folder is 0: walking it to add
// it up is not worth it, and the subtitle leaves it out.
@property(nonatomic, readonly) unsigned long long fileSize;

@property(nonatomic, readonly) XenraConsole console;
@property(nonatomic, readonly) XenraGameFormat format;
@property(nonatomic, readonly) XenraDiscLayout discLayout;

// 8 uppercase hex digits, or nil when the file does not state one. Android
// treats 00000000 as none, and so does this.
@property(nonatomic, readonly, copy, nullable) NSString* titleId;
@property(nonatomic, readonly, copy, nullable) NSString* mediaId;

// 1-based. 0 when the header does not say.
@property(nonatomic, readonly) NSInteger discNumber;
@property(nonatomic, readonly) NSInteger discCount;

// The raw content type of a GOD or STFS container, else 0.
@property(nonatomic, readonly) uint32_t contentType;

// The file name, and the Android title derived from it. The cover lookup goes
// through fileTitle first, so a title finds the same box art as on Android.
@property(nonatomic, readonly, copy) NSString* fileName;
@property(nonatomic, readonly, copy) NSString* fileTitle;

// Every path that IS this game, launch target first: the folder of a XEX
// folder, and the header plus "<name>.data" of a GOD. Android's contentPaths.
@property(nonatomic, readonly) NSArray<NSString*>* contentPaths;

// The icon embedded in a GOD or STFS header, PNG bytes. Reads the file, so call
// it off the main thread. nil for anything else or when there is none.
- (nullable NSData*)embeddedIconData;

@end

@interface XenraGameScanner : NSObject

// One list per console, shared by every instance, so it outlives the library
// screen. Holding this or a plain alloc/init makes no difference.
+ (instancetype)shared;

// Everything below is main thread only, unless it says otherwise.

// The current console's list as last seen, from memory or the disk cache.
// Empty only before the first scan finishes, or after the folders changed.
@property(nonatomic, readonly) NSArray<XenraGameEntry*>* cachedGames;

// YES between a refresh and its completion.
@property(nonatomic, readonly, getter=isScanning) BOOL scanning;

// Folders the last scan could not open: a picked folder on a drive that has
// gone, or whose access has lapsed. They say why the list is short.
@property(nonatomic, readonly) NSArray<NSString*>* unreadableFolders;

// Scans in the background. A file whose size and date are unchanged is not
// opened again. changed says whether the list differs from cachedGames as it
// stood before this call.
//
// completion runs exactly once, on the main thread. A refresh while one runs
// restarts it, to catch whatever prompted the second call, and both completions
// run when it finishes. completion may be nil.
- (void)refreshWithCompletion:
    (nullable void (^)(NSArray<XenraGameEntry*>* games, BOOL changed))completion;

// Stops the running scan, if any. Pending completions run at once, with the
// cached list and changed = NO. The list is left as it was.
- (void)cancel;

// Deletes contentPaths off the main thread, then drops the game from the list.
// As on Android, nothing outside the configured folders is touched: the paths
// are resolved first, and one that lands outside fails the whole call. A missing
// .data folder is not a failure. completion runs on the main thread.
- (void)deleteGame:(XenraGameEntry*)game
        completion:(nullable void (^)(BOOL deleted))completion;

// Any thread, blocking. Reads one file as this console would, and gives its
// entry, or nil if it is not a game of that console. For sorting a picked file
// before installing it: a container whose contentType is not launchable also
// gives nil, which is Android's cue to hand it to the content installer.
+ (nullable XenraGameEntry*)entryForFileAtPath:(NSString*)path
                                       console:(XenraConsole)console;

@end

#ifdef XENRA_UITEST
// Builds a tree of fake games under tmp and checks what the scanner finds. Logs
// one PASS or FAIL line per check through XenraLog, then a summary. The checks
// on the file formats finish before this returns; the ones on the async refresh
// and on covers finish on the main queue afterwards, and log their own lines.
void XenraScannerSelfTest(void);
#endif

NS_ASSUME_NONNULL_END
