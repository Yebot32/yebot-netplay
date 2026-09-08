/**
 ******************************************************************************
 * Xenra : iOS shell - blade row                                              *
 ******************************************************************************
 *
 * The Android game-library row (GameBladeView): an octagonally chamfered
 * panel with a title, a muted subtitle and an optional cover thumbnail.
 * The blade painting lives in XenraBladeView (shared with the status panel);
 * colours come from XenraTheme.h, which mirrors the Android palette byte for
 * byte.
 */

#import "XenraBladeCell.h"

#import "XenraBladeView.h"
#import "XenraTheme.h"

@interface XenraBladeCell : UITableViewCell
- (void)bindTitle:(NSString*)title
         subtitle:(NSString*)subtitle
            cover:(UIImage*)cover;
@end

@implementation XenraBladeCell {
  XenraBladeView* blade_;
  UIImageView* coverView_;
  UILabel* titleLabel_;
  UILabel* subtitleLabel_;
  NSLayoutConstraint* titleLeadingCover_;
  NSLayoutConstraint* titleLeadingBlade_;
  NSLayoutConstraint* subtitleLeadingCover_;
  NSLayoutConstraint* subtitleLeadingBlade_;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style
              reuseIdentifier:(NSString*)reuseIdentifier {
  self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
  if (self) {
    self.backgroundColor = UIColor.clearColor;
    self.selectionStyle = UITableViewCellSelectionStyleNone;
    self.contentView.backgroundColor = UIColor.clearColor;

    blade_ = [[XenraBladeView alloc] initWithFrame:CGRectZero];
    blade_.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:blade_];
    [blade_ release];

    coverView_ = [[UIImageView alloc] initWithFrame:CGRectZero];
    coverView_.contentMode = UIViewContentModeScaleAspectFill;
    coverView_.clipsToBounds = YES;
    coverView_.layer.cornerRadius = 4.0;
    coverView_.layer.borderWidth = 1.0;
    coverView_.layer.borderColor = XenraAccent22().CGColor;
    coverView_.translatesAutoresizingMaskIntoConstraints = NO;
    coverView_.hidden = YES;
    [blade_ addSubview:coverView_];
    [coverView_ release];

    titleLabel_ = [[UILabel alloc] initWithFrame:CGRectZero];
    titleLabel_.textColor = XenraText();
    titleLabel_.font =
        [UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold];
    titleLabel_.translatesAutoresizingMaskIntoConstraints = NO;
    [blade_ addSubview:titleLabel_];
    [titleLabel_ release];

    subtitleLabel_ = [[UILabel alloc] initWithFrame:CGRectZero];
    subtitleLabel_.textColor = XenraTextMuted();
    subtitleLabel_.font = [UIFont systemFontOfSize:12.0];
    subtitleLabel_.translatesAutoresizingMaskIntoConstraints = NO;
    [blade_ addSubview:subtitleLabel_];
    [subtitleLabel_ release];

    [NSLayoutConstraint activateConstraints:@[
      [blade_.leadingAnchor
          constraintEqualToAnchor:self.contentView.leadingAnchor constant:10.0],
      [blade_.trailingAnchor
          constraintEqualToAnchor:self.contentView.trailingAnchor
                         constant:-10.0],
      [blade_.topAnchor constraintEqualToAnchor:self.contentView.topAnchor
                                       constant:3.0],
      [blade_.bottomAnchor
          constraintEqualToAnchor:self.contentView.bottomAnchor constant:-3.0],

      [coverView_.leadingAnchor
          constraintEqualToAnchor:blade_.leadingAnchor constant:12.0],
      [coverView_.centerYAnchor constraintEqualToAnchor:blade_.centerYAnchor],
      [coverView_.widthAnchor constraintEqualToConstant:72.0],
      [coverView_.heightAnchor constraintEqualToConstant:54.0],

      [titleLabel_.topAnchor constraintEqualToAnchor:blade_.topAnchor
                                            constant:12.0],
      [titleLabel_.trailingAnchor
          constraintEqualToAnchor:blade_.trailingAnchor constant:-12.0],
      [subtitleLabel_.topAnchor
          constraintEqualToAnchor:titleLabel_.bottomAnchor constant:2.0],
      [subtitleLabel_.bottomAnchor
          constraintLessThanOrEqualToAnchor:blade_.bottomAnchor constant:-12.0],
      [subtitleLabel_.trailingAnchor
          constraintEqualToAnchor:blade_.trailingAnchor constant:-12.0],
    ]];
    // The text block's leading edge tracks whether a cover is present.
    titleLeadingCover_ = [titleLabel_.leadingAnchor
        constraintEqualToAnchor:coverView_.trailingAnchor constant:12.0];
    titleLeadingBlade_ = [titleLabel_.leadingAnchor
        constraintEqualToAnchor:blade_.leadingAnchor constant:14.0];
    subtitleLeadingCover_ = [subtitleLabel_.leadingAnchor
        constraintEqualToAnchor:coverView_.trailingAnchor constant:12.0];
    subtitleLeadingBlade_ = [subtitleLabel_.leadingAnchor
        constraintEqualToAnchor:blade_.leadingAnchor constant:14.0];
    titleLeadingCover_.active = NO;
    subtitleLeadingCover_.active = NO;
    titleLeadingBlade_.active = YES;
    subtitleLeadingBlade_.active = YES;
  }
  return self;
}

- (void)bindTitle:(NSString*)title
         subtitle:(NSString*)subtitle
            cover:(UIImage*)cover {
  titleLabel_.text = title;
  subtitleLabel_.text = subtitle;
  coverView_.image = cover;
  coverView_.hidden = (cover == nil);
  titleLeadingCover_.active = (cover != nil);
  titleLeadingBlade_.active = (cover == nil);
  subtitleLeadingCover_.active = (cover != nil);
  subtitleLeadingBlade_.active = (cover == nil);
}

- (void)dealloc {
  [blade_ release];
  [coverView_ release];
  [titleLabel_ release];
  [subtitleLabel_ release];
  [titleLeadingCover_ release];
  [titleLeadingBlade_ release];
  [subtitleLeadingCover_ release];
  [subtitleLeadingBlade_ release];
  [super dealloc];
}

@end
