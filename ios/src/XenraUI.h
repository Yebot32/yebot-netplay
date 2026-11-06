/**
 ******************************************************************************
 * Xenra : iOS shell - shared widgets                                         *
 ******************************************************************************
 *
 * The pieces every screen is made of, each one the iOS twin of an Android
 * widget. One pt is one dp. Read a colour as late as you can: every widget here
 * takes its palette when it is built, so a theme change rebuilds the screen.
 *
 * Which widget, by the Android style it replaces:
 *
 *   Widget.Xaniteog.Blade                XenraBladeButton           64 pt, 17 pt
 *   Widget.Xaniteog.Blade.Compact        XenraBladeButton.compact   48 pt, 14 pt
 *   Widget.Xaniteog.Button               XenraPillButton Filled     52 pt, 44 drawn
 *   Widget.Xaniteog.Button.Outlined.Pill XenraPillButton Outlined
 *   Material3 TextButton                 XenraPillButton Text
 *   Widget.Xaniteog.Button.Secondary     XenraChromeButton          44 pt, 32 drawn
 *   Widget.Xaniteog.OrientationButton    XenraIconToggleGroup       44 x 44 cells
 *   Widget.Xaniteog.Segment              XenraSegmentView           44 pt
 *   Widget.Xaniteog.SectionCard          XenraCardView              12 radius
 *   section_header_background, 11-12 sp  XenraSectionHeader
 *   SeekBar row with a read-out          XenraSliderRow
 *   dialog_blade_menu                    XenraBladeSheet showIn:
 *   dialog_dashboard_back                XenraBladeSheet showConfirmIn:
 *   ChamferedPanelView                   XenraPanelView
 *   B / A hint row                       XenraHintBar, XenraHintButton
 *   Toast                                XenraToast
 *
 * Pills and chrome buttons reserve the same insets Material does, so a 52 pt pill
 * has 4 pt of air above and below its shape. Lay them out by Android's margins
 * and the gaps come out the same; do not compensate.
 */

#import <UIKit/UIKit.h>

// Any screen's scroller. Scrolls from anywhere, a drag that starts on a control
// included, and a tap on a control still answers on release. Sliders keep their
// drags. Controls inside draw no pressed state until XenraPressDelay has passed,
// so a drag that turns into a scroll does not flash the row under the finger.
@interface XenraScrollView : UIScrollView
@end

// How long a control in a scroller waits before it lights up: Android's tap
// timeout, near enough. Use this for anything that draws its own press state in
// a collection view.
extern const NSTimeInterval XenraPressDelay;

// The base of every tappable widget here. Subclass it for a new one.
//
// `pressed` is what to draw. It is not `highlighted`: inside a scroller it runs
// XenraPressDelay behind the finger, and a quick tap still gets a short flash of
// it. Subclasses repaint in pressedChanged. `action` runs on touch up inside.
// `title` is also what ios/uitest taps by, and what is logged on a tap.
@interface XenraPressControl : UIControl
@property(nonatomic, copy) NSString* title;
@property(nonatomic, copy) void (^action)(void);
@property(nonatomic, readonly) BOOL pressed;
- (void)pressedChanged;
@end

// A framed panel with cut corners, Android's ChamferedPanelView. Chamfer 20, panel
// fill, accent66 stroke by default. `rounded` is the per-game settings card:
// radius 24 with a solid 2 pt accent outline.
@interface XenraPanelView : UIView
@property(nonatomic, assign) BOOL rounded;
@property(nonatomic, assign) CGFloat chamfer;
- (void)setFill:(UIColor*)fill;
- (void)setStroke:(UIColor*)stroke width:(CGFloat)width;
@end

// A setting with a choice of values: an outlined field, its name in the border.
@interface XenraFieldButton : XenraPressControl
@property(nonatomic, copy) NSString* value;
@property(nonatomic, copy) NSString* detail;
- (instancetype)initWithTitle:(NSString*)title action:(void (^)(void))action;
// What the caption's gap in the outline is filled with. Must be the opaque colour
// the field sits on, or the outline shows through. Defaults to the panel fill.
- (void)setCaptionFill:(UIColor*)fill;
@end

// One tappable blade, Android's Widget.Xaniteog.Blade. Set `compact` for any row
// of a menu; only the dashboard uses the full size. A compact blade on the light
// console is a raised white row, as Android builds it.
@interface XenraBladeButton : XenraPressControl
@property(nonatomic, copy) NSString* subtitle;
@property(nonatomic, assign) BOOL destructive;
@property(nonatomic, assign) BOOL dimmed;   // shown, but says it is unavailable
@property(nonatomic, assign) BOOL chosen;   // the current settings tab
@property(nonatomic, assign) BOOL primary;  // the default action, filled
@property(nonatomic, assign) BOOL compact;  // 48 pt, 14 pt text
@property(nonatomic, assign) BOOL padFocused;  // the controller cursor is on it
- (instancetype)initWithTitle:(NSString*)title action:(void (^)(void))action;
@end

typedef NS_ENUM(NSInteger, XenraPillStyle) {
  XenraPillFilled,    // Widget.Xaniteog.Button
  XenraPillOutlined,  // Widget.Xaniteog.Button.Outlined.Pill
  XenraPillText,      // Material3 text button, no outline and no spring
};

// Android's pill buttons, with button_press_spring. Sizes to its label with 24 pt
// of padding and is 52 pt tall; give it a width constraint to fill a column.
// `enabled` is the standard UIControl property and repaints it as Android's
// disabled state. `destructive` fills or outlines it in the error colour.
@interface XenraPillButton : XenraPressControl
@property(nonatomic, assign) XenraPillStyle style;
@property(nonatomic, assign) BOOL destructive;
@property(nonatomic, strong) UIImage* icon;  // template image, 22 pt
- (instancetype)initWithTitle:(NSString*)title
                        style:(XenraPillStyle)style
                       action:(void (^)(void))action;
@end

// Widget.Xaniteog.Button.Secondary as the dashboard uses it: a small floating
// button, icon and tracked label, surface fill, accent99 hairline, 12 pt shadow.
@interface XenraChromeButton : XenraPressControl
@property(nonatomic, strong) UIImage* icon;  // template image, 24 pt
- (instancetype)initWithTitle:(NSString*)title
                         icon:(UIImage*)icon
                       action:(void (^)(void))action;
@end

// A row of 44 x 44 icon cells, one of them selected: the setup wizard's
// orientation toggle. `titles` name the cells for tests and VoiceOver.
// onChange runs on a tap that changes the selection, not on setting it from code.
@interface XenraIconToggleGroup : UIView
@property(nonatomic, assign) NSInteger selectedIndex;  // -1 for none
@property(nonatomic, copy) void (^onChange)(NSInteger index);
- (instancetype)initWithIcons:(NSArray<UIImage*>*)icons
                       titles:(NSArray<NSString*>*)titles;
@end

// Widget.Xaniteog.Segment: two to four text choices side by side, for a setting
// too small to deserve a sheet. Fills its width, 44 pt tall.
@interface XenraSegmentView : UIView
@property(nonatomic, assign) NSInteger selectedIndex;
@property(nonatomic, copy) void (^onChange)(NSInteger index);
- (instancetype)initWithTitles:(NSArray<NSString*>*)titles;
@end

// Widget.Xaniteog.SectionCard with its CardBody: radius 12, 1 pt accent33 stroke,
// xenraSettingsCardFill, 16 pt padding. Add rows to `body`. Leave 12 pt under it.
@interface XenraCardView : UIView
@property(nonatomic, readonly) UIStackView* body;
@end

typedef NS_ENUM(NSInteger, XenraSectionStyle) {
  XenraSectionLabel,  // 12 pt bold tracked capitals in the accent
  XenraSectionPill,   // section_header_background, per-game settings
};

// A heading over a group of rows. Hugs its text; put 10 to 12 pt under it.
@interface XenraSectionHeader : UIView
- (instancetype)initWithTitle:(NSString*)title style:(XenraSectionStyle)style;
@end

// A setting with a continuous value: a title, an optional hint, then the slider
// with its live read-out beside it (accent, 13 bold). Goes in a card row.
@interface XenraSliderRow : UIView
@property(nonatomic, assign) float value;
// Turns the value into the read-out. Without it the value is printed as a whole
// number.
@property(nonatomic, copy) NSString* (^format)(float value);
@property(nonatomic, copy) void (^onChange)(float value);  // while dragging
@property(nonatomic, copy) void (^onCommit)(float value);  // on release
- (instancetype)initWithTitle:(NSString*)title
                       detail:(NSString*)detail
                      minimum:(float)minimum
                      maximum:(float)maximum
                         step:(float)step;  // 0 for continuous
@end

// A row of a blade dialog.
@interface XenraBladeItem : NSObject
@property(nonatomic, copy) NSString* title;
@property(nonatomic, copy) NSString* subtitle;
@property(nonatomic, assign) BOOL destructive;
@property(nonatomic, assign) BOOL dimmed;
@property(nonatomic, assign) BOOL primary;  // Resume in the game menu
@property(nonatomic, copy) void (^action)(void);
+ (instancetype)title:(NSString*)title action:(void (^)(void))action;
@end

// Android's dialog_blade_menu: a dimmed screen, a chamfered panel, a title, a
// column of compact blades that cascade in, and a footer. Tapping outside, the
// close control or the B hint dismisses; tapping a blade dismisses and then acts.
// The title and footer stay put while the rows scroll, so the way out is always
// on screen. With no items the sheet is a notice and gets an OK pill of its own.
// It sits in `host`, follows its size through a rotation, and stays open.
@interface XenraBladeSheet : UIView <UIGestureRecognizerDelegate>
@property(nonatomic, copy) void (^onDismiss)(void);
+ (instancetype)showIn:(UIView*)host
                 title:(NSString*)title
               message:(NSString*)message
                 items:(NSArray<XenraBladeItem*>*)items;
// dialog_dashboard_back: a centred title and two pills side by side, which never
// stack. `leading` is outlined, the way back; `trailing` is filled, the way on.
+ (instancetype)showConfirmIn:(UIView*)host
                        title:(NSString*)title
                      message:(NSString*)message
                      leading:(XenraBladeItem*)leading
                     trailing:(XenraBladeItem*)trailing;
// The sheet on top in `host`, or nil. Back on a pad closes this first.
+ (instancetype)topSheetIn:(UIView*)host;
- (void)dismiss;
@end

// A badge and its label, Widget.Xaniteog.HintBadge and HintLabel. With an action
// it is a button, with none a legend and it lets touches through.
@interface XenraHintButton : XenraPressControl
- (instancetype)initWithLetter:(NSString*)letter
                         title:(NSString*)title
                        action:(void (^)(void))action;
@end

// The B BACK / A SELECT row along the bottom of a screen. As built it has Android's
// dashboard look: no background, 24 pt padding, 80 pt tall, and it wants the bottom
// of the view rather than of the safe area (see XenraHintBarInset). panelStyle is
// the library's bottom bar instead: panel fill, 16 pt sides, 48 pt tall.
@interface XenraHintBar : UIView
@property(nonatomic, copy) void (^onBack)(void);
// Makes A pressable too. Without it A is only a legend.
@property(nonatomic, copy) void (^onSelect)(void);
@property(nonatomic, copy) NSString* backTitle;    // "Back"
@property(nonatomic, copy) NSString* selectTitle;  // "Select"
@property(nonatomic, assign) BOOL showsSelect;     // YES
@property(nonatomic, assign) BOOL panelStyle;
@end

// How far above the bottom of the view a hint bar belongs. Its own padding already
// clears the home indicator on an iPad; a phone needs some of the safe area too.
CGFloat XenraHintBarInset(UIView* view);

// A short message over the bottom of `host` that goes away by itself.
void XenraToast(UIView* host, NSString* text);

// Bundled image by file name, wherever the bundle layout put it.
UIImage* XenraBundleImage(NSString* name);

UILabel* XenraMakeLabel(NSString* text, CGFloat size, UIFontWeight weight,
                        UIColor* color);

// Tracked capitals. Android varies the tracking: blade 0.12, screen title and
// hint 0.15, meta and section 0.1 to 0.12. XenraTracked is 0.1.
NSAttributedString* XenraTrackedSpacing(NSString* text, CGFloat size,
                                        UIColor* color, CGFloat spacing);
NSAttributedString* XenraTracked(NSString* text, CGFloat size, UIColor* color);

// TextAppearance.Xaniteog.ScreenTitle: 18 pt bold capitals, 0.15, in the accent.
NSAttributedString* XenraScreenTitle(NSString* text);

// TextAppearance.Xaniteog.Body and Hint: running text with Android's line height.
NSAttributedString* XenraBodyText(NSString* text, CGFloat size, UIColor* color);

// One <path> of a VectorDrawable, so an Android icon can be used as it stands.
// `data` is its pathData; M L H V C S Q A Z in either case are understood.
@interface XenraVectorPath : NSObject
+ (instancetype)fill:(NSString*)data;
+ (instancetype)stroke:(NSString*)data width:(CGFloat)width;
@end

// A template image `size` points square, tinted by whatever shows it. `viewport`
// is the drawable's viewportWidth.
UIImage* XenraVectorImage(NSArray<XenraVectorPath*>* paths, CGFloat viewport,
                          CGFloat size);

// ic_orientation_auto, _portrait and _landscape, by the ui.orientation setting.
UIImage* XenraOrientationIcon(NSString* orientation, CGFloat size);
