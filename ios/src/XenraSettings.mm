#import "XenraSettings.h"

#include "ios_emu.h"

@implementation XenraSettingRow
@end
@implementation XenraSettingSection
@end
@implementation XenraSettingTab
@end

static XenraSettingRow* Toggle(NSString* key, NSString* title, NSString* detail,
                               BOOL on) {
  XenraSettingRow* row = [[XenraSettingRow alloc] init];
  row.key = key;
  row.title = title;
  row.detail = detail;
  row.kind = XenraRowToggle;
  row.defaultValue = on ? @"true" : @"false";
  return row;
}

static XenraSettingRow* Choice(NSString* key, NSString* title, NSString* detail,
                               NSArray* titles, NSArray* values,
                               NSString* fallback) {
  XenraSettingRow* row = [[XenraSettingRow alloc] init];
  row.key = key;
  row.title = title;
  row.detail = detail;
  row.kind = XenraRowChoice;
  row.choiceTitles = titles;
  row.choiceValues = values;
  row.defaultValue = fallback;
  return row;
}

static XenraSettingRow* Action(NSString* key, NSString* title,
                               NSString* detail) {
  XenraSettingRow* row = [[XenraSettingRow alloc] init];
  row.key = key;
  row.title = title;
  row.detail = detail;
  row.kind = XenraRowAction;
  return row;
}

static XenraSettingSection* Section(NSString* title, NSArray* rows) {
  XenraSettingSection* section = [[XenraSettingSection alloc] init];
  section.title = title;
  section.rows = rows;
  return section;
}

static XenraSettingTab* Tab(NSString* title, NSArray* sections) {
  XenraSettingTab* tab = [[XenraSettingTab alloc] init];
  tab.title = title;
  tab.sections = sections;
  return tab;
}

static XenraSettingRow* ResolutionRow() {
  XenraSettingRow* row = Choice(
      @"x360.resolution", @"Internal resolution",
      @"Rendering above 1x costs GPU time on every frame.",
      @[ @"1x", @"2x", @"3x" ], @[ @"1", @"2", @"3" ], @"1");
  row.cvars = @[ @"draw_resolution_scale_x", @"draw_resolution_scale_y" ];
  row.perGame = YES;
  return row;
}

static XenraSettingRow* FrameLimitRow() {
  XenraSettingRow* row = Choice(
      @"x360.framerate_limit", @"Frame rate limit",
      @"The only setting measured to lower heat on the 360 core.",
      @[ @"30 FPS", @"60 FPS", @"Unlimited" ], @[ @"30", @"60", @"0" ], @"60");
  row.cvars = @[ @"framerate_limit" ];
  row.perGame = YES;
  return row;
}

static XenraSettingRow* CoreRow() {
  XenraSettingRow* row = Choice(
      @"og.core", @"Core",
      @"Performance is not on iOS yet. See docs/IOS-PORT-PLAN.md.",
      @[ @"Performance (hakuX)", @"Compatibility (xemu)" ],
      @[ @"hakux", @"xemu" ], @"hakux");
  row.perGame = YES;
  return row;
}

@implementation XenraSettings

+ (NSArray<XenraSettingTab*>*)tabs {
  static NSArray* tabs;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    tabs = @[
      Tab(@"Video",
          @[ Section(@"Display", @[
            ResolutionRow(), FrameLimitRow(),
          ]) ]),
      Tab(@"Input",
          @[ Section(@"Touch controls", @[
            Toggle(@"pad.visible", @"Show touch controls", nil, YES),
            Choice(@"pad.scale", @"Controls size", nil,
                   @[ @"Small", @"Normal", @"Large" ],
                   @[ @"0.8", @"1.0", @"1.25" ], @"1.0"),
            Toggle(@"pad.haptics", @"Vibration", nil, YES),
          ]) ]),
      Tab(@"System",
          @[
            Section(@"Console", @[ CoreRow() ]),
            Section(@"JIT", @[
              Action(@"jit.enable", @"Enable JIT",
                     @"Opens StikDebug. Needed once per launch."),
            ]),
          ]),
      Tab(@"Maintenance",
          @[ Section(@"Maintenance", @[
            Action(@"log.share", @"Share logs",
                   @"Core log, crash reports and device details, as one file."),
            Action(@"cache.clear", @"Clear shader cache",
                   @"Games compile their shaders again on next launch."),
          ]) ]),
    ];
  });
  return tabs;
}

+ (NSArray<XenraSettingRow*>*)perGameRows {
  static NSArray* rows;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    rows = @[ ResolutionRow(), FrameLimitRow() ];
  });
  return rows;
}

+ (XenraConsole)console {
  return (XenraConsole)[NSUserDefaults.standardUserDefaults
      integerForKey:@"xenra.console"];
}

+ (void)setConsole:(XenraConsole)console {
  [NSUserDefaults.standardUserDefaults setInteger:console
                                           forKey:@"xenra.console"];
}

+ (NSString*)gameKey:(NSString*)game row:(NSString*)key {
  return [NSString stringWithFormat:@"game.%@.%@", game, key];
}

+ (NSString*)stringForKey:(NSString*)key fallback:(NSString*)fallback {
  return [NSUserDefaults.standardUserDefaults stringForKey:key] ?: fallback;
}

+ (void)setString:(NSString*)value forKey:(NSString*)key {
  [NSUserDefaults.standardUserDefaults setObject:value forKey:key];
}

+ (NSString*)valueForRow:(XenraSettingRow*)row game:(NSString*)game {
  if (game) {
    NSString* own = [NSUserDefaults.standardUserDefaults
        stringForKey:[self gameKey:game row:row.key]];
    if (own) return own;
  }
  return [self stringForKey:row.key fallback:row.defaultValue];
}

+ (void)setValue:(NSString*)value row:(XenraSettingRow*)row game:(NSString*)game {
  [self setString:value forKey:game ? [self gameKey:game row:row.key] : row.key];
}

+ (void)clearOverridesForGame:(NSString*)game {
  for (XenraSettingRow* row in [self perGameRows]) {
    [NSUserDefaults.standardUserDefaults
        removeObjectForKey:[self gameKey:game row:row.key]];
  }
}

+ (void)applyForGame:(NSString*)game {
  for (XenraSettingTab* tab in [self tabs]) {
    for (XenraSettingSection* section in tab.sections) {
      for (XenraSettingRow* row in section.rows) {
        for (NSString* cvar in row.cvars) {
          xe_ios_set_cvar(cvar.UTF8String,
                          [self valueForRow:row game:game].UTF8String);
        }
      }
    }
  }
}

@end
