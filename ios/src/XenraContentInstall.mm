/**
 ******************************************************************************
 * Xenra : iOS shell - installing content (implementation)                     *
 ******************************************************************************
 */

#import "XenraContentInstall.h"
#import "XenraStrings.h"

#import "XenraGameScanner.h"
#import "XenraScreens.h"

#include <stdlib.h>

#ifdef XENRA_UITEST
// The simulator build has no core.
static int xenra_content_install(const char*, const char*) { return -1; }
static float xenra_content_progress(void) { return -1; }
static int xenra_content_list_disc(const char*, char**, int) { return 0; }
static int xenra_content_install_disc(const char*, const char*, const char*,
                                      const char*) {
  return -1;
}
#else
extern "C" {
int xenra_content_install(const char* source, const char* content_root);
float xenra_content_progress(void);
int xenra_content_list_disc(const char* disc, char** out, int capacity);
int xenra_content_install_disc(const char* disc, const char* inner_path,
                               const char* content_root, const char* scratch);
}
#endif

namespace {

constexpr int kMaxDiscPackages = 256;

typedef void (^Progress)(NSString*, float);

NSString* Documents(void) {
  return NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                             NSUserDomainMask, YES)
      .firstObject;
}

// ios_emu.mm's storage root, and the content tree under it.
NSString* ContentRoot(void) {
  NSString* root = [Documents() stringByAppendingPathComponent:@"content"];
  [NSFileManager.defaultManager createDirectoryAtPath:root
                          withIntermediateDirectories:YES
                                           attributes:nil
                                                error:nil];
  return root;
}

// Xbox360ContentInstall.reasonFor, with X_STATUS as this core gives it: anything
// the installer refuses to open is a bad package.
NSString* Reason(int status) {
  if (status == (int)0xC000000D) {  // X_STATUS_INVALID_PARAMETER
    return XS(@"Not a content package. Content packages start with CON, LIVE or "
            "PIRS.");
  }
  if (status == -1) return XS(@"The installer could not run.");
  return [NSString stringWithFormat:XS(@"The installer reported error %08X."),
                                    (unsigned)status];
}

// Reports the core's byte counter until told to stop.
dispatch_source_t WatchProgress(NSString* message, Progress progress) {
  dispatch_source_t timer = dispatch_source_create(
      DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
  dispatch_source_set_timer(timer, DISPATCH_TIME_NOW, NSEC_PER_SEC / 5,
                            NSEC_PER_SEC / 20);
  dispatch_source_set_event_handler(timer, ^{
    progress(message, xenra_content_progress());
  });
  dispatch_resume(timer);
  return timer;
}

XenraInstallOutcome CopyGame(NSString* path, XenraGameEntry* game,
                             XenraConsole console, Progress progress,
                             NSString** message) {
  NSFileManager* files = NSFileManager.defaultManager;
  NSString* folder = [Documents()
      stringByAppendingPathComponent:console == XenraConsole360 ? @"Games"
                                                                : @"Games OG"];
  [files createDirectoryAtPath:folder
      withIntermediateDirectories:YES
                       attributes:nil
                            error:nil];
  NSString* target =
      [folder stringByAppendingPathComponent:path.lastPathComponent];
  if ([files fileExistsAtPath:target]) {
    *message = [NSString
        stringWithFormat:XS(@"“%@” is already in your games folder."), game.name];
    return XenraInstallFailed;
  }
  dispatch_async(dispatch_get_main_queue(), ^{
    progress([NSString stringWithFormat:XS(@"Copying %@…"), game.name], -1);
  });
  // Under another name until it is whole: a kill halfway must not leave a broken
  // game in the library that also blocks a retry.
  NSString* partial = [target stringByAppendingPathExtension:@"part"];
  [files removeItemAtPath:partial error:nil];
  NSError* error = nil;
  if (![files copyItemAtPath:path toPath:partial error:&error] ||
      ![files moveItemAtPath:partial toPath:target error:&error]) {
    [files removeItemAtPath:partial error:nil];
    *message = error.code == NSFileWriteOutOfSpaceError
                   ? XS(@"There is not enough free space.")
                   : XS(@"The file could not be copied.");
    return XenraInstallFailed;
  }
  *message = [NSString
      stringWithFormat:XS(@"“%@” is in your games folder now."), game.name];
  return XenraInstallGame;
}

XenraInstallOutcome InstallDisc(NSString* path, XenraGameEntry* game,
                                XenraConsole console, Progress progress,
                                NSString** message) {
  dispatch_async(dispatch_get_main_queue(), ^{
    progress(XS(@"Reading the package…"), -1);
  });
  char* inner[kMaxDiscPackages];
  const int count = xenra_content_list_disc(path.fileSystemRepresentation, inner,
                                            kMaxDiscPackages);
  if (count == 0) return CopyGame(path, game, console, progress, message);

  NSString* scratch = [NSTemporaryDirectory()
      stringByAppendingPathComponent:@"disc-install"];
  [NSFileManager.defaultManager createDirectoryAtPath:scratch
                          withIntermediateDirectories:YES
                                           attributes:nil
                                                error:nil];
  int installed = 0;
  int status = 0;
  for (int i = 0; i < count; ++i) {
    if (status == 0) {
      NSString* step =
          [NSString stringWithFormat:XS(@"Installing %d of %d…"), i + 1, count];
      __block dispatch_source_t watch = nil;
      dispatch_sync(dispatch_get_main_queue(), ^{
        watch = WatchProgress(step, progress);
      });
      status = xenra_content_install_disc(path.fileSystemRepresentation, inner[i],
                                          ContentRoot().fileSystemRepresentation,
                                          scratch.fileSystemRepresentation);
      dispatch_source_cancel(watch);
      if (status == 0) ++installed;
    }
    free(inner[i]);
  }
  [NSFileManager.defaultManager removeItemAtPath:scratch error:nil];
  if (status != 0) {
    *message = [NSString stringWithFormat:XS(@"Installed %d of %d. %@"), installed,
                                          count, Reason(status)];
    return XenraInstallFailed;
  }
  *message = [NSString stringWithFormat:XS(@"Installed %d package(s) from the disc. "
                                         "Boot the play disc to use them."),
                                        installed];
  return XenraInstallContent;
}

XenraInstallOutcome Install(NSString* path, XenraConsole console,
                            Progress progress, NSString** message) {
  XenraGameEntry* game = [XenraGameScanner entryForFileAtPath:path console:console];
  if (console == XenraConsoleOG) {
    if (game) return CopyGame(path, game, console, progress, message);
    *message = XS(@"This is not an original Xbox game. Use .iso, .xiso, .cci or "
                ".cso.");
    return XenraInstallFailed;
  }
  if (game) {
    switch (game.format) {
      case XenraGameFormatDiscImage:
        return InstallDisc(path, game, console, progress, message);
      case XenraGameFormatGOD:
        *message = [NSString
            stringWithFormat:XS(@"“%@” is a game with a data folder beside it. Use "
                              "Set game folder on the folder that holds it."),
                             game.name];
        return XenraInstallFailed;
      default:
        return CopyGame(path, game, console, progress, message);
    }
  }

  __block dispatch_source_t watch = nil;
  dispatch_sync(dispatch_get_main_queue(), ^{
    watch = WatchProgress(XS(@"Installing…"), progress);
  });
  const int status = xenra_content_install(path.fileSystemRepresentation,
                                           ContentRoot().fileSystemRepresentation);
  dispatch_source_cancel(watch);
  if (status != 0) {
    *message = Reason(status);
    return XenraInstallFailed;
  }
  *message = [NSString stringWithFormat:XS(@"Installed “%@”."),
                                        path.lastPathComponent];
  return XenraInstallContent;
}

}  // namespace

void XenraInstallFromURL(NSURL* url, XenraConsole console,
                         void (^progress)(NSString*, float),
                         void (^done)(XenraInstallOutcome, NSString*)) {
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    const BOOL scoped = [url startAccessingSecurityScopedResource];
    NSString* message = nil;
    const XenraInstallOutcome outcome =
        Install(url.path, console, progress, &message);
    if (scoped) [url stopAccessingSecurityScopedResource];
    XenraLog([NSString stringWithFormat:@"install: %@: %@",
                                        url.lastPathComponent, message]);
    dispatch_async(dispatch_get_main_queue(), ^{
      done(outcome, message);
    });
  });
}
