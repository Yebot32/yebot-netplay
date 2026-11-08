/**
 ******************************************************************************
 * Xenra : iOS shell - cover art                                               *
 ******************************************************************************
 *
 * Where a cover comes from, first hit wins (GameLibraryActivity.bindCoverArt):
 *
 *   1. The custom cover the user set.
 *   2. Documents/Covers/<title or file stem>.png, .jpg or .jpeg. iOS only: the
 *      folder the Files app can reach.
 *   3. Box art downloaded before, kept in Application Support, so a cover once
 *      seen still shows offline.
 *   4. Box art downloaded now, from the first source that has it:
 *        Xbox 360       xenia-manager/x360db, by the title id the scanner read
 *                       (GOD, STFS, ISO, XEX), mapped through X360_Titles.txt
 *                       so a region or reissue id finds its game; by name when
 *                       there is no id (ZAR, an unreadable file).
 *        Original Xbox  xemu-project/xdb by the XBE certificate title id
 *                       (XboxOG_Titles.txt), then the public X1_Covers
 *                       repository by Android's title match, then xdb by name.
 *      Android has only X1_Covers, and nothing for the 360. A source whose every
 *      address says 404 is not asked again this run; any other failure, such
 *      as being offline, waits a minute, and the next source is tried.
 *   5. Xbox 360: the icon in the GOD or STFS header, when no box art comes.
 *
 * Decoding is ImageIO, downsampled to the size asked for, on a background queue.
 * Decoded images live in a memory cache bounded by bytes, which empties on a
 * memory warning. Files are kept in Application Support, not Caches: Maintenance
 * clears Caches, and covers must survive that.
 *
 * Tiles: original Xbox art is 2:3, a 360 icon is square. A custom cover keeps the
 * console's tile shape, as bindCoverAspect does.
 *
 * IN A CELL
 *
 *   cell.cover.image = [covers cachedCoverForGame:game pointSize:size];
 *   if (!cell.cover.image) {
 *     __weak Cell* weak = cell;
 *     cell.coverRequest = [covers loadCoverForGame:game
 *                                        pointSize:size
 *                                       completion:^(UIImage* image) {
 *                                         weak.cover.image = image;
 *                                       }];
 *   }
 *   // prepareForReuse: [coverRequest cancel];
 */

#import <UIKit/UIKit.h>

@class XenraGameEntry;

NS_ASSUME_NONNULL_BEGIN

@interface XenraCoverRequest : NSObject
// After this the completion never runs. Main thread. Safe to call twice. A
// download already under way still finishes, so the art is there next time.
- (void)cancel;
@end

// Everything here is main thread only. Completions run on the main thread.
@interface XenraCovers : NSObject

+ (instancetype)shared;

// The memory cache only, so it is cheap enough for cellForItem. pointSize is the
// view's size; the screen scale is applied here. Sizes are rounded up in steps
// of 64 pixels, so a tile that moves a little does not miss.
- (nullable UIImage*)cachedCoverForGame:(XenraGameEntry*)game
                              pointSize:(CGSize)pointSize;

// completion runs once, with the image, or with nil when the game has no cover
// (a placeholder should stay). It never runs synchronously, and never after
// -cancel. Two requests for the same cover share one decode.
- (XenraCoverRequest*)loadCoverForGame:(XenraGameEntry*)game
                             pointSize:(CGSize)pointSize
                            completion:(void (^)(UIImage* _Nullable image))completion;

// Custom covers are keyed by title, as on Android, so a game's two discs share
// one. Reloading the tile is up to the caller, in completion.
- (BOOL)hasCustomCoverForGame:(XenraGameEntry*)game;

// Copies the picture at url, which may be security scoped, as the document
// picker gives it. A file ImageIO cannot read is refused with ok = NO, and any
// cover already set stays.
- (void)setCustomCoverFromURL:(NSURL*)url
                      forGame:(XenraGameEntry*)game
                   completion:(nullable void (^)(BOOL ok))completion;

// ok = NO when there was none to remove, or the delete failed.
- (void)removeCustomCoverForGame:(XenraGameEntry*)game
                      completion:(nullable void (^)(BOOL ok))completion;

// Drops decoded images. Files on disk stay.
- (void)clearMemoryCache;

@end

#ifdef XENRA_UITEST
// The checks behind XenraScannerSelfTest. check is called once per result.
void XenraCoversSelfTest(void (^check)(NSString* name, BOOL ok));
// Every address the cover chain would try for game, best first.
NSArray<NSString*>* XenraCoverURLsForGame(XenraGameEntry* game);
#endif

NS_ASSUME_NONNULL_END
