/**
 ******************************************************************************
 * Xenra : iOS shell - game list model (implementation)                        *
 ******************************************************************************
 */

#import "XenraGameScanner.h"

#import "XenraSettings.h"

#import <UIKit/UIKit.h>

static NSArray<NSString*>* XenraGameExtensions() {
  static NSArray<NSString*>* ext = nil;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    // Copy of an autoreleased literal: the static holds the single +1.
    ext = [@[
      @"iso", @"xex", @"zar", @"god", @"con", @"live", @"pirs", @"xbe"
    ] copy];
  });
  return ext;
}

static NSString* XenraCoversDir() {
  NSString* docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                       NSUserDomainMask, YES)
                       .firstObject;
  return [docs stringByAppendingPathComponent:@"Covers"];
}

@implementation XenraGameEntry

- (instancetype)init {
  self = [super init];
  if (self) {
    _path = [[NSString alloc] init];
    _name = [[NSString alloc] init];
    _subtitle = [[NSString alloc] init];
  }
  return self;
}

- (void)dealloc {
  [_path release];
  [_name release];
  [_subtitle release];
  [super dealloc];
}

@end

@implementation XenraGameScanner {
  NSCache* coverCache_;
  NSMutableArray* coverOrder_;  // LRU keys, names
}

- (instancetype)init {
  self = [super init];
  if (self) {
    _games = [[NSArray alloc] init];
    coverCache_ = [[NSCache alloc] init];
    coverCache_.countLimit = 96;
    coverOrder_ = [[NSMutableArray alloc] init];
  }
  return self;
}

- (void)dealloc {
  [_games release];
  [coverCache_ release];
  [coverOrder_ release];
  [super dealloc];
}

- (void)scanWithCompletion:(void (^)(NSArray<XenraGameEntry*>* games))completion {
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{

    NSFileManager* fm = [NSFileManager defaultManager];
    NSMutableArray<NSURL*>* contents = [NSMutableArray array];
    for (NSString* dir in [XenraSettings gameFolders]) {
      NSArray<NSURL*>* found = [fm contentsOfDirectoryAtURL:
          [NSURL fileURLWithPath:dir]
          includingPropertiesForKeys:@[ NSURLIsRegularFileKey,
                                        NSURLFileSizeKey ]
                              options:0
                                error:nil];
      if (found) [contents addObjectsFromArray:found];
    }

    NSArray<NSString*>* extensions = XenraGameExtensions();
    NSMutableArray<XenraGameEntry*>* entries = [NSMutableArray array];
    for (NSURL* url in contents) {
      NSString* ext = url.pathExtension.lowercaseString;
      if (![extensions containsObject:ext]) {
        continue;
      }
      NSDictionary* attrs = [fm attributesOfItemAtPath:url.path error:nil];
      unsigned long long size = attrs.fileSize;

      XenraGameEntry* entry = [[XenraGameEntry alloc] init];
      entry.path = [url.path copy];
      entry.name = [url.path.lastPathComponent.stringByDeletingPathExtension copy];
      entry.fileSize = size;
      if (size >= 1024ull * 1024ull * 1024ull) {
        entry.subtitle = [NSString stringWithFormat:@"%.1f GB · %@",
                                                    size / (1024.0 * 1024.0 * 1024.0),
                                                    ext.uppercaseString];
      } else {
        entry.subtitle = [NSString stringWithFormat:@"%llu MB · %@",
                                                    size / (1024ull * 1024ull),
                                                    ext.uppercaseString];
      }
      [entries addObject:entry];
      [entry release];
    }
    [entries sortUsingComparator:^NSComparisonResult(XenraGameEntry* a,
                                                     XenraGameEntry* b) {
      return [a.name compare:b.name options:NSCaseInsensitiveSearch |
                                          NSNumericSearch];
    }];

    dispatch_async(dispatch_get_main_queue(), ^{
      // MRC: copy is +1 (ours); the retain setter takes its own +1 and
      // releases the previous value, so only our +1 is dropped here.
      NSArray<XenraGameEntry*>* fresh = [entries copy];
      self.games = fresh;
      [fresh release];
      if (completion) {
        completion(self.games);
      }
    });
  });
}

// Cover lookup mirrors Android: Documents/Covers/<name>.png then .jpg then
// .jpeg. Case-insensitive over the directory listing, cached per scan batch.
- (UIImage*)coverForEntryNamed:(NSString*)name {
  if (name.length == 0) {
    return nil;
  }
  UIImage* cached = [coverCache_ objectForKey:name];
  if (cached) {
    return cached;
  }

  NSString* covers = XenraCoversDir();
  for (NSString* ext in @[ @"png", @"jpg", @"jpeg" ]) {
    NSString* candidate = [[covers stringByAppendingPathComponent:name]
        stringByAppendingPathExtension:ext];
    if ([[NSFileManager defaultManager] fileExistsAtPath:candidate]) {
      // Small cover files decode instantly; anything large is capped so a
      // stray multi-megabyte image cannot stall row binding (the Android
      // library's startup-picker thumbnail lesson, E10).
      NSDictionary* attrs =
          [[NSFileManager defaultManager] attributesOfItemAtPath:candidate
                                                           error:nil];
      if (attrs.fileSize > 4ull * 1024ull * 1024ull) {
        return nil;
      }
      UIImage* img = [UIImage imageWithContentsOfFile:candidate];
      if (img) {
        [coverCache_ setObject:img forKey:name];
        [coverOrder_ removeObject:name];
        [coverOrder_ addObject:name];
        while (coverOrder_.count > 96) {
          NSString* victim = coverOrder_.firstObject;
          [coverCache_ removeObjectForKey:victim];
          [coverOrder_ removeObjectAtIndex:0];
        }
        return img;
      }
    }
  }
  return nil;
}

- (void)clearCovers {
  [coverCache_ removeAllObjects];
  [coverOrder_ removeAllObjects];
}

@end
