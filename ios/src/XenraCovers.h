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
 *   3. Xbox 360: the icon in the GOD or STFS header. An ISO, ZAR or XEX has none
 *      we can read here, so it stays on the placeholder. The box art repository
 *      is original Xbox only; Android skips it for the 360 too.
 *   4. Original Xbox: box art from the public X1_Covers repository, found by the
 *      same title match as Android (XenraCoverMatch.hpp), downloaded once and
 *      kept. Offline or on any error the cover is simply nil, nothing is shown,
 *      and the same file is not asked for again for a minute.
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
#endif

NS_ASSUME_NONNULL_END
