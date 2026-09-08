/**
 ******************************************************************************
 * Xenra : iOS shell - blade row (header)                                     *
 ******************************************************************************
 */

#import <UIKit/UIKit.h>

@interface XenraBladeCell : UITableViewCell
- (void)bindTitle:(NSString*)title
         subtitle:(NSString*)subtitle
            cover:(UIImage*)cover;
@end
