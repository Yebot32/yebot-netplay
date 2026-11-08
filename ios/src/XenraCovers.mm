/**
 ******************************************************************************
 * Xenra : iOS shell - cover art (implementation)                              *
 ******************************************************************************
 */

#import "XenraCovers.h"

#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#import "XenraCoverMatch.hpp"
#import "XenraGameScanner.h"
#import "XenraScreens.h"

#include <memory>
#include <string>

namespace match = xenra::covers;

// One place a cover can come from: the file it is kept in once downloaded, and
// the addresses to try for it, in order. Immutable once made.
@interface XenraArtSource : NSObject
@property(nonatomic, copy) NSString* key;  // names it in downloads_ and misses_
@property(nonatomic, copy) NSString* kept;
@property(nonatomic, copy) NSArray<NSURL*>* urls;
@end

@implementation XenraArtSource
@end

namespace {

// GameLibraryActivity.coverRepoBaseUrl.
NSString* const kRepository =
    @"https://raw.githubusercontent.com/izzy2lost/X1_Covers/main/";

// Xbox 360 box art by title id: xenia-manager/x360db, as XeniOS and Xenia Edge
// use it. Its GitHub Pages site first, then the raw file at the commit
// X360_Titles.txt was made from, which holds every id listed there.
NSString* const kX360Pages = @"https://xenia-manager.github.io/x360db/";
NSString* const kX360Pinned =
    @"https://raw.githubusercontent.com/xenia-manager/x360db/"
    @"3a673638ca22bd78a4768f3d7730dceb40e9ec32/";

// Original Xbox covers by title id: xemu-project/xdb, at the commit
// XboxOG_Titles.txt was made from (XeniOS pins the same one).
NSString* const kXdbPinned =
    @"https://raw.githubusercontent.com/xemu-project/xdb/"
    @"d83d221eb2eea51a6d1d8b60cccff70f1056e6a4/";

// Bounds the decoded images: about 220 full-size tiles.
constexpr NSUInteger kMemoryLimit = 96 * 1024 * 1024;
constexpr NSTimeInterval kRetryAfter = 60;
constexpr CGFloat kPixelStep = 64;

std::string Native(NSString* text) {
  return text.length ? std::string(text.UTF8String) : std::string();
}

NSString* FromNative(const std::string& text) {
  return [NSString stringWithUTF8String:text.c_str()];
}

NSString* SupportFolder(NSString* name) {
  NSString* support = NSSearchPathForDirectoriesInDomains(
                          NSApplicationSupportDirectory, NSUserDomainMask, YES)
                          .firstObject;
  NSString* folder = [[support stringByAppendingPathComponent:@"Covers"]
      stringByAppendingPathComponent:name];
  [NSFileManager.defaultManager createDirectoryAtPath:folder
                          withIntermediateDirectories:YES
                                           attributes:nil
                                                error:nil];
  return folder;
}

// collapseCoverKey keeps letters and digits only, which is a safe file name. A
// title in another script collapses to nothing, so it gets its bytes instead.
NSString* FileKey(NSString* title) {
  const std::string collapsed = match::CollapseKey(Native(title));
  if (!collapsed.empty()) return FromNative(collapsed);
  NSMutableString* hex = [NSMutableString string];
  const std::string bytes = Native(title);
  for (const char c : bytes) [hex appendFormat:@"%02x", (uint8_t)c];
  return hex;
}

NSString* CustomFile(XenraGameEntry* game) {
  return [SupportFolder(@"custom") stringByAppendingPathComponent:
                                       [FileKey(game.name)
                                           stringByAppendingPathExtension:@"png"]];
}

NSString* DownloadedFile(NSString* title) {
  return [SupportFolder(@"boxart") stringByAppendingPathComponent:
                                       [FileKey(title)
                                           stringByAppendingPathExtension:@"png"]];
}

// Documents/Covers, which the Files app can reach. Any thread.
NSString* HandPlacedFile(XenraGameEntry* game) {
  NSString* docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                       NSUserDomainMask, YES)
                       .firstObject;
  NSString* folder = [docs stringByAppendingPathComponent:@"Covers"];
  NSFileManager* files = NSFileManager.defaultManager;
  for (NSString* stem in @[ game.name, game.fileTitle ]) {
    for (NSString* extension in @[ @"png", @"jpg", @"jpeg" ]) {
      NSString* path = [[folder stringByAppendingPathComponent:stem]
          stringByAppendingPathExtension:extension];
      if ([files fileExistsAtPath:path]) return path;
    }
  }
  return nil;
}

BOOL NonEmptyFile(NSString* path) {
  return [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil]
             .fileSize > 0;
}

// One decode at the size wanted, on the calling thread: a 1000 pt tall cover is
// never held at full size, and the first draw has nothing left to do.
UIImage* Downsample(CGImageSourceRef source, CGFloat max_pixels, CGFloat scale) {
  if (!source || CGImageSourceGetCount(source) == 0) return nil;
  NSDictionary* options = @{
    (__bridge NSString*)kCGImageSourceCreateThumbnailFromImageAlways : @YES,
    (__bridge NSString*)kCGImageSourceCreateThumbnailWithTransform : @YES,
    (__bridge NSString*)kCGImageSourceShouldCacheImmediately : @YES,
    (__bridge NSString*)kCGImageSourceThumbnailMaxPixelSize : @(max_pixels),
  };
  CGImageRef image = CGImageSourceCreateThumbnailAtIndex(
      source, 0, (__bridge CFDictionaryRef)options);
  if (!image) return nil;
  UIImage* result = [UIImage imageWithCGImage:image
                                        scale:scale
                                  orientation:UIImageOrientationUp];
  CGImageRelease(image);
  return result;
}

UIImage* DecodeFile(NSString* path, CGFloat max_pixels, CGFloat scale) {
  NSDictionary* options =
      @{(__bridge NSString*)kCGImageSourceShouldCache : @NO};
  CGImageSourceRef source = CGImageSourceCreateWithURL(
      (__bridge CFURLRef)[NSURL fileURLWithPath:path],
      (__bridge CFDictionaryRef)options);
  UIImage* image = Downsample(source, max_pixels, scale);
  if (source) CFRelease(source);
  return image;
}

UIImage* DecodeData(NSData* data, CGFloat max_pixels, CGFloat scale) {
  NSDictionary* options =
      @{(__bridge NSString*)kCGImageSourceShouldCache : @NO};
  CGImageSourceRef source = CGImageSourceCreateWithData(
      (__bridge CFDataRef)data, (__bridge CFDictionaryRef)options);
  UIImage* image = Downsample(source, max_pixels, scale);
  if (source) CFRelease(source);
  return image;
}

BOOL IsImageFile(NSString* path) {
  CGImageSourceRef source = CGImageSourceCreateWithURL(
      (__bridge CFURLRef)[NSURL fileURLWithPath:path], nullptr);
  if (!source) return NO;
  const BOOL ok = CGImageSourceGetCount(source) > 0 &&
                  CGImageSourceGetType(source) != nullptr;
  CFRelease(source);
  return ok;
}

// Parsed once, on first need, off the main thread. Lookups are const.
const match::Index& CoverIndex() {
  static const match::Index* index = [] {
    NSString* path = [NSBundle.mainBundle pathForResource:@"X1_Covers"
                                                   ofType:@"txt"];
    NSString* text = path ? [NSString stringWithContentsOfFile:path
                                                      encoding:NSUTF8StringEncoding
                                                         error:nil]
                          : nil;
    if (!text) XenraLog(@"covers: X1_Covers.txt is missing from the bundle");
    return new match::Index(Native(text));
  }();
  return *index;
}

// The repository's file for this game, or nil. The title Android would look up
// first, then the one the header gave.
NSString* RepositoryFile(XenraGameEntry* game, bool closest) {
  const match::Index& index = CoverIndex();
  std::string file = index.Lookup(Native(game.fileTitle), closest);
  if (file.empty()) file = index.Lookup(Native(game.name), closest);
  return file.empty() ? nil : FromNative(file);
}

// Parsed once, on first need, off the main thread.
const match::TitleDb& LoadTitleDb(NSString* resource) {
  NSString* path = [NSBundle.mainBundle pathForResource:resource ofType:@"txt"];
  NSString* text = path ? [NSString stringWithContentsOfFile:path
                                                    encoding:NSUTF8StringEncoding
                                                       error:nil]
                        : nil;
  if (!text) {
    XenraLog([NSString
        stringWithFormat:@"covers: %@.txt is missing from the bundle", resource]);
  }
  return *new match::TitleDb(Native(text));
}

const match::TitleDb& X360Titles() {
  static const match::TitleDb& db = LoadTitleDb(@"X360_Titles");
  return db;
}

const match::TitleDb& OgTitles() {
  static const match::TitleDb& db = LoadTitleDb(@"XboxOG_Titles");
  return db;
}

uint32_t TitleIdOf(XenraGameEntry* game) {
  return match::ParseHexId(Native(game.titleId));
}

// By id, else by the shown title, else by the file's.
uint32_t ArtIdFor(const match::TitleDb& db, XenraGameEntry* game, bool by_id) {
  uint32_t art = by_id ? db.ArtId(TitleIdOf(game)) : 0;
  if (!art) art = db.ArtIdForName(Native(game.name));
  if (!art && ![game.fileTitle isEqualToString:game.name]) {
    art = db.ArtIdForName(Native(game.fileTitle));
  }
  return art;
}

NSURL* RepositoryURL(NSString* file) {
  NSMutableCharacterSet* allowed =
      [NSMutableCharacterSet alphanumericCharacterSet];
  [allowed addCharactersInString:@"-._~"];
  return [NSURL
      URLWithString:[kRepository
                        stringByAppendingString:
                            [file stringByAddingPercentEncodingWithAllowedCharacters:
                                      allowed]]];
}

NSString* BoxartFile(NSString* name) {
  return [SupportFolder(@"boxart") stringByAppendingPathComponent:name];
}

XenraArtSource* Source(NSString* key, NSString* kept, NSArray<NSURL*>* urls) {
  XenraArtSource* source = [[XenraArtSource alloc] init];
  source.key = key;
  source.kept = kept;
  source.urls = urls;
  return source;
}

NSURL* Under(NSString* base, const std::string& path) {
  return [NSURL URLWithString:[base stringByAppendingString:FromNative(path)]];
}

// Where this game's cover can come from, best first. Any thread.
//   Xbox 360: x360db, by title id, else by name.
//   Original Xbox: xdb by title id; X1_Covers by name, exact or collapsed;
//   xdb by name; then X1_Covers by Android's fuzzy match, which is the least
//   sure of the four.
NSArray<XenraArtSource*>* ResolveSources(XenraGameEntry* game) {
  NSMutableArray<XenraArtSource*>* sources = [NSMutableArray array];
  if (game.console == XenraConsole360) {
    const uint32_t art = ArtIdFor(X360Titles(), game, true);
    if (art) {
      const std::string path = match::X360ArtPath(art);
      NSString* hex = FromNative(match::HexId(art));
      [sources addObject:Source([@"x360:" stringByAppendingString:hex],
                                BoxartFile([NSString stringWithFormat:@"x360-%@.jpg", hex]),
                                @[ Under(kX360Pages, path), Under(kX360Pinned, path) ])];
    }
    return sources;
  }

  const match::TitleDb& og = OgTitles();
  const auto add_xdb = [&](uint32_t art) {
    const std::string path = match::OgArtPath(art);
    if (!art || path.empty()) return;
    NSString* hex = FromNative(match::HexId(art));
    NSString* key = [@"xdb:" stringByAppendingString:hex];
    for (XenraArtSource* source in sources) {
      if ([source.key isEqualToString:key]) return;
    }
    [sources addObject:Source(key,
                              BoxartFile([NSString stringWithFormat:@"og-%@.jpg", hex]),
                              @[ Under(kXdbPinned, path) ])];
  };
  const auto add_x1 = [&](NSString* file) {
    if (!file) return;
    [sources addObject:Source([@"x1:" stringByAppendingString:file],
                              DownloadedFile(game.fileTitle),
                              @[ RepositoryURL(file) ])];
  };
  add_xdb(og.ArtId(TitleIdOf(game)));
  NSString* x1 = RepositoryFile(game, false);
  add_x1(x1);
  add_xdb(ArtIdFor(og, game, false));
  if (!x1) add_x1(RepositoryFile(game, true));
  return sources;
}

// ResolveSources is a pure function of the entry, and the fuzzy match is not
// free, so each game resolves once per run.
NSArray<XenraArtSource*>* ArtSources(XenraGameEntry* game) {
  static NSMutableDictionary<NSString*, NSArray<XenraArtSource*>*>* known =
      [NSMutableDictionary dictionary];
  static NSLock* lock = [[NSLock alloc] init];
  NSString* key = [NSString stringWithFormat:@"%ld|%@|%@|%@", (long)game.console,
                                             game.path, game.titleId ?: @"",
                                             game.name];
  [lock lock];
  NSArray<XenraArtSource*>* found = known[key];
  [lock unlock];
  if (found) return found;
  found = ResolveSources(game);
  [lock lock];
  known[key] = found;
  [lock unlock];
  return found;
}

}  // namespace

@interface XenraCoverRequest ()
@property(nonatomic, copy) NSString* key;
@property(nonatomic, copy) void (^completion)(UIImage*);
@end

@interface XenraCovers ()
- (void)dropRequest:(XenraCoverRequest*)request;
@end

@implementation XenraCoverRequest

- (void)cancel {
  if (!_completion) return;
  _completion = nil;
  [XenraCovers.shared dropRequest:self];
}

@end

@implementation XenraCovers {
  NSCache<NSString*, UIImage*>* memory_;
  NSOperationQueue* decoder_;
  NSURLSession* session_;
  // By memory key. Each waits on the one decode in operations_.
  NSMutableDictionary<NSString*, NSMutableArray<XenraCoverRequest*>*>* waiting_;
  NSMutableDictionary<NSString*, NSOperation*>* operations_;
  // Games with nothing to show, until when, by memory key.
  NSMutableDictionary<NSString*, NSDate*>* empty_;
  // Downloads running, by source key, and who wants each.
  NSMutableDictionary<NSString*, NSMutableArray<dispatch_block_t>*>* downloads_;
  // Sources that failed, until when, by key: distantFuture when every address
  // said 404, so a miss is asked for once a run; a minute for anything else,
  // such as being offline. Read on the decode queue too, so under its lock.
  NSMutableDictionary<NSString*, NSDate*>* misses_;
  NSLock* missesLock_;
  // Bumped when a title's custom cover changes, so its old sizes stop matching.
  NSMutableDictionary<NSString*, NSNumber*>* generation_;
}

+ (instancetype)shared {
  static XenraCovers* covers;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    covers = [[XenraCovers alloc] init];
  });
  return covers;
}

- (instancetype)init {
  self = [super init];
  if (self) {
    memory_ = [[NSCache alloc] init];
    memory_.totalCostLimit = kMemoryLimit;
    decoder_ = [[NSOperationQueue alloc] init];
    decoder_.maxConcurrentOperationCount = 2;
    decoder_.qualityOfService = NSQualityOfServiceUserInitiated;
    NSURLSessionConfiguration* config =
        NSURLSessionConfiguration.ephemeralSessionConfiguration;
    config.timeoutIntervalForRequest = 20;
    config.HTTPMaximumConnectionsPerHost = 4;
    session_ = [NSURLSession sessionWithConfiguration:config];
    waiting_ = [NSMutableDictionary dictionary];
    operations_ = [NSMutableDictionary dictionary];
    empty_ = [NSMutableDictionary dictionary];
    downloads_ = [NSMutableDictionary dictionary];
    misses_ = [NSMutableDictionary dictionary];
    missesLock_ = [[NSLock alloc] init];
    generation_ = [NSMutableDictionary dictionary];
    [NSNotificationCenter.defaultCenter
        addObserver:self
           selector:@selector(clearMemoryCache)
               name:UIApplicationDidReceiveMemoryWarningNotification
             object:nil];
  }
  return self;
}

- (CGFloat)maxPixelsFor:(CGSize)size {
  const CGFloat pixels =
      MAX(size.width, size.height) * UIScreen.mainScreen.scale;
  return MAX(kPixelStep, ceil(pixels / kPixelStep) * kPixelStep);
}

- (NSString*)keyFor:(XenraGameEntry*)game size:(CGSize)size {
  return [NSString stringWithFormat:@"%@|%.0f|%@", game.path,
                                    [self maxPixelsFor:size],
                                    generation_[game.name] ?: @0];
}

- (UIImage*)cachedCoverForGame:(XenraGameEntry*)game pointSize:(CGSize)pointSize {
  return [memory_ objectForKey:[self keyFor:game size:pointSize]];
}

- (XenraCoverRequest*)loadCoverForGame:(XenraGameEntry*)game
                             pointSize:(CGSize)pointSize
                            completion:(void (^)(UIImage*))completion {
  NSString* key = [self keyFor:game size:pointSize];
  XenraCoverRequest* request = [[XenraCoverRequest alloc] init];
  request.key = key;
  request.completion = completion;

  UIImage* known = [memory_ objectForKey:key];
  NSDate* until = empty_[key];
  if (until && until.timeIntervalSinceNow <= 0) {
    [empty_ removeObjectForKey:key];
    until = nil;
  }
  if (known || until) {
    dispatch_async(dispatch_get_main_queue(), ^{
      void (^done)(UIImage*) = request.completion;
      request.completion = nil;
      if (done) done(known);
    });
    return request;
  }

  NSMutableArray<XenraCoverRequest*>* waiting = waiting_[key];
  if (waiting) {
    [waiting addObject:request];
    return request;
  }
  waiting_[key] = [NSMutableArray arrayWithObject:request];
  [self startDecode:game key:key maxPixels:[self maxPixelsFor:pointSize]];
  return request;
}

- (BOOL)isMissing:(NSString*)key {
  [missesLock_ lock];
  NSDate* until = misses_[key];
  const BOOL missing = until && until.timeIntervalSinceNow > 0;
  [missesLock_ unlock];
  return missing;
}

- (void)markMissing:(NSString*)key forSession:(BOOL)forSession {
  [missesLock_ lock];
  misses_[key] = forSession ? NSDate.distantFuture
                            : [NSDate dateWithTimeIntervalSinceNow:kRetryAfter];
  [missesLock_ unlock];
}

// The cover chain in the header. Runs on the decode queue. A kept download is
// used before anything is fetched, so a cover once seen works offline. With
// nothing kept, the first source not known to be missing is fetched, and this
// runs again when it lands. The 360 header icon is the last resort.
- (void)startDecode:(XenraGameEntry*)game
                key:(NSString*)key
          maxPixels:(CGFloat)maxPixels {
  const CGFloat scale = UIScreen.mainScreen.scale;
  NSBlockOperation* operation = [[NSBlockOperation alloc] init];
  __weak NSBlockOperation* weak = operation;
  [operation addExecutionBlock:^{
    if (weak.isCancelled) return;
    UIImage* image = nil;
    NSString* custom = CustomFile(game);
    NSString* hand = nil;
    if (NonEmptyFile(custom)) {
      image = DecodeFile(custom, maxPixels, scale);
    } else if ((hand = HandPlacedFile(game))) {
      image = DecodeFile(hand, maxPixels, scale);
    }
    XenraArtSource* remote = nil;
    if (!image) {
      NSArray<XenraArtSource*>* sources = ArtSources(game);
      for (XenraArtSource* source in sources) {
        if (NonEmptyFile(source.kept)) {
          image = DecodeFile(source.kept, maxPixels, scale);
          if (image) break;
        }
      }
      if (!image) {
        for (XenraArtSource* source in sources) {
          if (!NonEmptyFile(source.kept) && ![self isMissing:source.key]) {
            remote = source;
            break;
          }
        }
      }
    }
    if (!image && !remote && game.console == XenraConsole360) {
      NSData* icon = [game embeddedIconData];
      if (icon) image = DecodeData(icon, maxPixels, scale);
    }
    dispatch_async(dispatch_get_main_queue(), ^{
      [self->operations_ removeObjectForKey:key];
      if (!self->waiting_[key]) return;  // everyone left
      if (remote) {
        [self fetch:remote game:game key:key maxPixels:maxPixels];
        return;
      }
      [self finish:key image:image];
    });
  }];
  operations_[key] = operation;
  [decoder_ addOperation:operation];
}

- (void)fetch:(XenraArtSource*)source
         game:(XenraGameEntry*)game
          key:(NSString*)key
    maxPixels:(CGFloat)maxPixels {
  // Whatever happens, the chain runs again: it finds the download, or moves on
  // to the next source, or to the icon.
  __weak XenraCovers* weak = self;
  dispatch_block_t again = ^{
    XenraCovers* covers = weak;
    if (covers && covers->waiting_[key]) {
      [covers startDecode:game key:key maxPixels:maxPixels];
    }
  };
  NSMutableArray<dispatch_block_t>* running = downloads_[source.key];
  if (running) {
    [running addObject:[again copy]];
    return;
  }
  downloads_[source.key] = [NSMutableArray arrayWithObject:[again copy]];
  [self download:source index:0 allMissing:YES];
}

// Tries source.urls[index] and on, each once.
- (void)download:(XenraArtSource*)source
           index:(NSUInteger)index
      allMissing:(BOOL)allMissing {
  __weak XenraCovers* weak = self;
  if (index >= source.urls.count) {
    [self markMissing:source.key forSession:allMissing];
    XenraLog([NSString stringWithFormat:@"covers: no %@%@", source.key,
                                        allMissing ? @" (not listed)" : @""]);
    NSArray<dispatch_block_t>* waiters = downloads_[source.key];
    [downloads_ removeObjectForKey:source.key];
    for (dispatch_block_t waiter in waiters) waiter();
    return;
  }
  NSURL* url = source.urls[index];
  NSString* target = source.kept;
  NSURLSessionDownloadTask* task = [session_
      downloadTaskWithURL:url
        completionHandler:^(NSURL* location, NSURLResponse* response,
                            NSError* error) {
          // location goes when this returns, so the move happens here.
          BOOL ok = NO;
          const NSInteger status =
              [response isKindOfClass:NSHTTPURLResponse.class]
                  ? ((NSHTTPURLResponse*)response).statusCode
                  : 0;
          if (location && !error && status == 200 &&
              IsImageFile(location.path)) {
            NSFileManager* files = NSFileManager.defaultManager;
            NSString* staged = [target stringByAppendingString:@".new"];
            [files removeItemAtPath:staged error:nil];
            if ([files moveItemAtPath:location.path toPath:staged error:nil]) {
              [files removeItemAtPath:target error:nil];
              ok = [files moveItemAtPath:staged toPath:target error:nil];
            }
          }
          if (!ok) {
            XenraLog([NSString stringWithFormat:@"covers: %@ gave %ld%@%@",
                                                url.absoluteString, (long)status,
                                                error ? @", " : @"",
                                                error.localizedDescription ?: @""]);
          }
          dispatch_async(dispatch_get_main_queue(), ^{
            XenraCovers* covers = weak;
            if (!covers) return;
            if (!ok) {
              [covers download:source
                         index:index + 1
                    allMissing:allMissing && status == 404];
              return;
            }
            NSArray<dispatch_block_t>* waiters = covers->downloads_[source.key];
            [covers->downloads_ removeObjectForKey:source.key];
            for (dispatch_block_t waiter in waiters) waiter();
          });
        }];
  [task resume];
}

- (void)finish:(NSString*)key image:(UIImage*)image {
  if (image) {
    const CGSize size = image.size;
    const CGFloat scale = image.scale;
    [memory_ setObject:image
                forKey:key
                  cost:(NSUInteger)(size.width * size.height * scale * scale * 4)];
  } else {
    empty_[key] = [NSDate dateWithTimeIntervalSinceNow:kRetryAfter];
  }
  NSArray<XenraCoverRequest*>* waiting = waiting_[key];
  [waiting_ removeObjectForKey:key];
  for (XenraCoverRequest* request in waiting) {
    void (^done)(UIImage*) = request.completion;
    request.completion = nil;
    if (done) done(image);
  }
}

- (void)dropRequest:(XenraCoverRequest*)request {
  NSMutableArray<XenraCoverRequest*>* waiting = waiting_[request.key];
  if (!waiting) return;
  [waiting removeObjectIdenticalTo:request];
  if (waiting.count) return;
  // A tile that scrolled away before its turn costs nothing.
  [waiting_ removeObjectForKey:request.key];
  [operations_[request.key] cancel];
  [operations_ removeObjectForKey:request.key];
}

- (BOOL)hasCustomCoverForGame:(XenraGameEntry*)game {
  return NonEmptyFile(CustomFile(game));
}

- (void)customCoverChanged:(XenraGameEntry*)game {
  generation_[game.name] = @(generation_[game.name].integerValue + 1);
}

- (void)setCustomCoverFromURL:(NSURL*)url
                      forGame:(XenraGameEntry*)game
                   completion:(void (^)(BOOL))completion {
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    const BOOL scoped = [url startAccessingSecurityScopedResource];
    NSString* target = CustomFile(game);
    NSString* staged = [target stringByAppendingString:@".new"];
    NSFileManager* files = NSFileManager.defaultManager;
    [files removeItemAtPath:staged error:nil];
    BOOL ok = IsImageFile(url.path) &&
              [files copyItemAtPath:url.path toPath:staged error:nil];
    if (scoped) [url stopAccessingSecurityScopedResource];
    if (ok) {
      [files removeItemAtPath:target error:nil];
      ok = [files moveItemAtPath:staged toPath:target error:nil];
    }
    dispatch_async(dispatch_get_main_queue(), ^{
      if (ok) [self customCoverChanged:game];
      if (completion) completion(ok);
    });
  });
}

- (void)removeCustomCoverForGame:(XenraGameEntry*)game
                      completion:(void (^)(BOOL))completion {
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    const BOOL ok = [NSFileManager.defaultManager removeItemAtPath:CustomFile(game)
                                                             error:nil];
    dispatch_async(dispatch_get_main_queue(), ^{
      if (ok) [self customCoverChanged:game];
      if (completion) completion(ok);
    });
  });
}

- (void)clearMemoryCache {
  [memory_ removeAllObjects];
}

@end

#ifdef XENRA_UITEST

NSArray<NSString*>* XenraCoverURLsForGame(XenraGameEntry* game) {
  NSMutableArray<NSString*>* urls = [NSMutableArray array];
  for (XenraArtSource* source in ResolveSources(game)) {
    for (NSURL* url in source.urls) [urls addObject:url.absoluteString];
  }
  return urls;
}

void XenraCoversSelfTest(void (^check)(NSString* name, BOOL ok)) {
  // The title databases, on synthetic text first.
  const match::TitleDb small(
      "# comment\n"
      "4D5309C9\tForza Horizon\t4D538A67 4d538a68\n"
      "4D530AA4\tForza Horizon 2\r\n"
      "545408A7\tGrand Theft Auto V\t\n"
      "nothex\tBroken Line\n"
      "41560001\t\t\n");
  check(@"titles: lines parse, comments and junk do not", small.size() == 4);
  check(@"titles: a listed id is its own art",
        small.ArtId(0x4D530AA4) == 0x4D530AA4);
  check(@"titles: another release id finds the game, either case",
        small.ArtId(0x4D538A67) == 0x4D5309C9 &&
            small.ArtId(0x4D538A68) == 0x4D5309C9);
  check(@"titles: unknown and zero ids find nothing",
        small.ArtId(0x12345678) == 0 && small.ArtId(0) == 0);
  check(@"titles: a tagged file name finds its game",
        small.ArtIdForName("Forza Horizon (USA) (En,Fr,De)") == 0x4D5309C9);
  check(@"titles: an unnumbered title is not its sequel",
        small.ArtIdForName("Forza Horizon") == 0x4D5309C9 &&
            small.ArtIdForName("Forza Horizon 2 (Europe)") == 0x4D530AA4);
  check(@"titles: a roman numeral is a number",
        small.ArtIdForName("Grand Theft Auto IV (USA)") == 0);
  check(@"titles: hex ids parse strictly",
        match::ParseHexId("4d5309c9") == 0x4D5309C9 &&
            match::ParseHexId("4D5309C") == 0 && match::ParseHexId("4D5309CZ") == 0);
  check(@"titles: 360 art path",
        match::X360ArtPath(0x545407F2) == "titles/545407F2/artwork/boxart.jpg");
  check(@"titles: OG art path is letters, then the number in decimal",
        match::OgArtPath(0x4D53006E) == "titles/MS/110/cover_front_thumbnail.jpg" &&
            match::OgArtPath(0x4E4D0001) == "titles/NM/001/cover_front_thumbnail.jpg" &&
            match::OgArtPath(0x00010001).empty());

  // The bundled ones.
  const match::TitleDb& x360 = X360Titles();
  const match::TitleDb& og = OgTitles();
  check(@"titles: both databases are in the bundle",
        x360.size() > 5000 && og.size() > 1000);
  check(@"titles: GTA IV and Forza Horizon have 360 art",
        x360.ArtId(0x545407F2) == 0x545407F2 &&
            x360.ArtId(0x4D5309C9) == 0x4D5309C9);
  check(@"titles: a Forza Horizon reissue id finds the game",
        x360.ArtId(0x4D538A67) == 0x4D5309C9);
  check(@"titles: Halo's other release finds the OG cover",
        og.ArtId(0x4D530057) == 0x4D530004);
  check(@"titles: an OG name in No-Intro style finds xdb",
        og.ArtIdForName("Simpsons, The - Hit & Run (USA)") == 0x56550015 &&
            og.ArtIdForName("Halo - Combat Evolved (USA)") == 0x4D530004);

  const match::Index& index = CoverIndex();
  check(@"covers: the index is in the bundle", index.size() > 500);
  const auto found = [&](const char* title, const char* file) {
    return index.Lookup(title) == file;
  };
  check(@"covers: a tagged name finds itself",
        found("Forza Motorsport (USA)", "Forza Motorsport (USA).png"));
  check(@"covers: the region is not needed",
        found("Crash Bandicoot - The Wrath of Cortex",
              "Crash Bandicoot - The Wrath of Cortex (USA).png"));
  check(@"covers: underscores and case do not matter",
        found("halo_-_combat_evolved", "Halo - Combat Evolved (USA).png"));
  check(@"covers: a sequel is not its first game",
        found("Halo 2", "Halo 2 (USA).png"));
  check(@"covers: nonsense finds nothing",
        index.Lookup("Zzqx Nothing Like This").empty());

  check(@"covers: the file key is a safe name",
        [FileKey(@"Crash: Twin/Sanity") isEqualToString:@"crashtwinsanity"]);
  check(@"covers: a title with no ASCII still has a key",
        FileKey(@"ファイナル").length > 0);
  check(@"covers: an odd name survives the URL",
        [RepositoryURL(@"Crash 'n' Burn (USA).png").absoluteString
            hasSuffix:@"Crash%20%27n%27%20Burn%20%28USA%29.png"]);

  // A big image comes back small, and at the screen's scale.
  UIGraphicsImageRendererFormat* format =
      [UIGraphicsImageRendererFormat preferredFormat];
  format.scale = 1;
  UIGraphicsImageRenderer* renderer =
      [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(1000, 1500)
                                             format:format];
  NSData* png = [renderer PNGDataWithActions:^(UIGraphicsImageRendererContext* c) {
    [UIColor.greenColor setFill];
    [c fillRect:CGRectMake(0, 0, 1000, 1500)];
  }];
  UIImage* small = DecodeData(png, 192, 2);
  check(@"covers: decoding downsamples to the long side",
        small && MAX(small.size.width, small.size.height) * small.scale <= 192 &&
            small.scale == 2);
  check(@"covers: junk data decodes to nothing",
        !DecodeData([@"not a picture" dataUsingEncoding:NSUTF8StringEncoding], 64,
                    1));
}

#endif  // XENRA_UITEST
