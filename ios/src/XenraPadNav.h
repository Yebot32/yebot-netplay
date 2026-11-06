/**
 ******************************************************************************
 * Xenra : iOS shell - controller navigation in the menus                     *
 ******************************************************************************
 *
 * Android's ControllerNavigator and BaseActivity's key handling. UIKit's focus
 * engine takes no game controller input on an iPad, so this is a cursor of its
 * own. It knows no screen: on each input it walks the visible, enabled controls
 * of the open sheet, or else of the top screen, and moves by Android's
 * FocusFinder rules. A new widget is reachable by being a XenraPressControl.
 *
 * What it walks: XenraPressControl, any other UIControl, and the cells of a
 * UICollectionView, including ones not on screen yet. It skips padSkipped
 * controls. A view that is not a press control but answers setPadFocused: draws
 * its own focus; anything else gets the white ring.
 *
 *   D-pad, left stick  move, 450 ms to repeat and 250 ms between repeats
 *   A                  press what the cursor is on, acting on release
 *   B                  close the sheet, else what the hint bar's Back does
 *   LB, RB             the settings tab either side of the chosen blade
 *
 * The first direction or A on a screen only places the cursor. B needs no cursor.
 * A touch takes it away and the next input puts it back where it was. It stands
 * down completely while a game is on top: the game owns the controller.
 */

#import <UIKit/UIKit.h>

typedef NS_ENUM(NSInteger, XenraPadButton) {
  XenraPadButtonA,
  XenraPadButtonB,
  XenraPadButtonX,
  XenraPadButtonY,
  XenraPadButtonLB,
  XenraPadButtonRB,
  XenraPadButtonUp,
  XenraPadButtonDown,
  XenraPadButtonLeft,
  XenraPadButtonRight,
};

// For a screen with buttons of its own, as Android's library has Y. Adopted by the
// top view controller, it sees each press before the cursor does, and each repeat
// of a held direction, unless a sheet is open. Answer YES to keep the press.
@protocol XenraPadScreen <NSObject>
- (BOOL)xenraPadButton:(XenraPadButton)button;
@end

// Starting twice is harmless. XenraNavigationController does it.
void XenraPadNavStart(void);

// The stack changed. A game going away has to wake the poll up again.
void XenraPadNavScreenChanged(void);

// Takes the cursor away. A touch anywhere in the window calls this.
void XenraPadNavTouched(void);

// The white outline, 2 pt at radius 8 in xenraFocus, Android's buildFocusRing. It
// lives on the view's own layer so it scrolls and clips with it.
void XenraPadRing(UIView* view, BOOL on);

#ifdef XENRA_UITEST
// The simulator has no controller. This stands in for what GCController reads:
// the same tick then runs on the same display link. NULL hands it back.
typedef struct {
  int dx, dy;    // D-pad, -1 to 1, down is positive
  float sx, sy;  // left stick, down is positive
  BOOL a, b, x, y, lb, rb;
} XenraPadTestState;
void XenraPadNavTestSet(const XenraPadTestState* state);
// What the cursor is on, or nil.
NSString* XenraPadNavTestFocus(void);
BOOL XenraPadNavTestPolling(void);
#endif
