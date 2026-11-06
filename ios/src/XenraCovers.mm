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

namespace {

// GameLibraryActivity.coverRepoBaseUrl.
NSString* const kRepository =
    @"https://raw.githubusercontent.com/izzy2lost/X1_Covers/main/";

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
NSString* RepositoryFile(XenraGameEntry* game) {
  const match::Index& index = CoverIndex();
  std::string file = index.Lookup(Native(game.fileTitle));
  if (file.empty()) file = index.Lookup(Native(game.name));
  return file.empty() ? nil : FromNative(file);
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
  // Downloads running, by repository file, and who wants each.
  NSMutableDictionary<NSString*, NSMutableArray<dispatch_block_t>*>* downloads_;
  // Repository files that failed, until when.
  NSMutableDictionary<NSString*, NSDate*>* retry_;
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
    retry_ = [NSMutableDictionary dictionary];
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

// The cover chain in the header. Runs on the decode queue.
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
    NSString* remote = nil;
    if (!image && game.console == XenraConsole360) {
      NSData* icon = [game embeddedIconData];
      if (icon) image = DecodeData(icon, maxPixels, scale);
    } else if (!image) {
      NSString* kept = DownloadedFile(game.fileTitle);
      if (NonEmptyFile(kept)) {
        image = DecodeFile(kept, maxPixels, scale);
      } else {
        remote = RepositoryFile(game);
      }
    }
    dispatch_async(dispatch_get_main_queue(), ^{
      [self->operations_ removeObjectForKey:key];
      if (!self->waiting_[key]) return;  // everyone left
      if (remote) {
        [self fetch:remote
               game:game
                key:key
          maxPixels:maxPixels];
        return;
      }
      [self finish:key image:image];
    });
  }];
  operations_[key] = operation;
  [decoder_ addOperation:operation];
}

- (void)fetch:(NSString*)file
         game:(XenraGameEntry*)game
          key:(NSString*)key
    maxPixels:(CGFloat)maxPixels {
  NSDate* until = retry_[file];
  if (until && until.timeIntervalSinceNow > 0) {
    [self finish:key image:nil];
    return;
  }
  [retry_ removeObjectForKey:file];

  __weak XenraCovers* weak = self;
  dispatch_block_t again = ^{
    XenraCovers* covers = weak;
    if (!covers) return;
    if (covers->retry_[file]) {
      [covers finish:key image:nil];
    } else if (covers->waiting_[key]) {
      [covers startDecode:game key:key maxPixels:maxPixels];
    }
  };
  NSMutableArray<dispatch_block_t>* running = downloads_[file];
  if (running) {
    [running addObject:[again copy]];
    return;
  }
  downloads_[file] = [NSMutableArray arrayWithObject:[again copy]];

  NSString* target = DownloadedFile(game.fileTitle);
  NSURLSessionDownloadTask* task = [session_
      downloadTaskWithURL:RepositoryURL(file)
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
            [files removeItemAtPath:target error:nil];
            ok = [files moveItemAtPath:location.path toPath:target error:nil];
          }
          if (!ok) {
            XenraLog([NSString stringWithFormat:@"covers: no %@ (%ld, %@)", file,
                                                (long)status,
                                                error.localizedDescription]);
          }
          dispatch_async(dispatch_get_main_queue(), ^{
            XenraCovers* covers = weak;
            if (!covers) return;
            if (!ok) {
              covers->retry_[file] =
                  [NSDate dateWithTimeIntervalSinceNow:kRetryAfter];
            }
            NSArray<dispatch_block_t>* waiters = covers->downloads_[file];
            [covers->downloads_ removeObjectForKey:file];
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

void XenraCoversSelfTest(void (^check)(NSString* name, BOOL ok)) {
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
