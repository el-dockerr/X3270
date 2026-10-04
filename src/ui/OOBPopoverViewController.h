#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface OOBPopoverViewController : NSViewController
@property (nonatomic, strong) NSTextView *textView;
@property (nonatomic, strong) NSTextField *titleLabel;

- (instancetype)initWithTitle:(NSString *)title content:(NSString *)content;
- (void)updateContent:(NSString *)content;
@end

NS_ASSUME_NONNULL_END