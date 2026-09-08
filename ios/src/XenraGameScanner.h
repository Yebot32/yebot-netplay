/**
 ******************************************************************************
 * Xenra : iOS shell - game list model                                        *
 ******************************************************************************
 *
 * The Android library gathers its entries on a background lane (session-2
 * fix E1/E4/E5: never scan stat/disk metadata on the main thread). This is
 * the iOS counterpart: one background scan of Documents/Games producing
 * immutable entries, delivered back to the main thread as a batch.
 *
 * Cover art mirrors Android's Covers folder: Documents/Covers/<gamename>.png
 * (or .jpg) where <gamename> is the ROM filename without extension, with the
 * same "first match wins" looseness.
 */

#import <UIKit/UIKit.h>

@interface XenraGameEntry : NSObject
@property(nonatomic, copy) NSString* path;
@property(nonatomic, copy) NSString* name;      // display name, no extension
@property(nonatomic, copy) NSString* subtitle;  // size + extension, muted row
@property(nonatomic, assign) unsigned long long fileSize;
@end

@interface XenraGameScanner : NSObject

// Last scan result, main-thread only.
@property(nonatomic, retain) NSArray<XenraGameEntry*>* games;

// Kicks one scan on a background queue. completion runs on the MAIN thread
// with the fresh list. Safe to call repeatedly; each scan is independent.
- (void)scanWithCompletion:(void (^)(NSArray<XenraGameEntry*>* games))completion;

// Cached cover for a game (by display name), decoded off-main on first miss
// and kept in a small LRU. Main-thread only. Returns nil when no cover file
// exists - the row renders without a cover, like Android's library.
- (UIImage*)coverForEntryNamed:(NSString*)name;

// Drops the cover cache (Android's per-game "clear cover cache" analogue).
- (void)clearCovers;

@end
