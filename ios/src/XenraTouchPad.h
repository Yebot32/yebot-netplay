/**
 ******************************************************************************
 * Xenra : iOS shell - on-screen controller                                   *
 ******************************************************************************
 *
 * Android's OnScreenController.kt: same anchors, same proportions, same
 * mirrored 360 layout. Geometry is deliberately kept as the same arithmetic so
 * a change there can be carried over line by line.
 */

#import <UIKit/UIKit.h>

typedef void (^XenraPadChanged)(int buttons, short lx, short ly, short rx,
                                short ry, unsigned char lt, unsigned char rt);

@interface XenraTouchPad : UIView
// LB/RB and the stick clicks are mirrored on 360; see OnScreenController.
@property(nonatomic, assign) BOOL x360Layout;
@property(nonatomic, assign) CGFloat scaleFactor;  // 0.5 to 2.0
@property(nonatomic, assign) BOOL hapticsEnabled;
@property(nonatomic, copy) XenraPadChanged onChange;
@property(nonatomic, copy) void (^onMenu)(void);
@end
