#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@protocol CommandDockDelegate <NSObject>
- (void)commandDockDidRequestISPFCommand:(NSString *)command targetGroup:(nullable NSString *)group;
- (void)commandDockDidRequestOutOdBandCommand:(NSString *)command targetGroup:(nullable NSString *)group;
- (void)commandDockDidToggleRuler;
- (void)commandDockDidToggleTimeMachine;
@end

@interface CommandDockViewController : NSViewController

@property (nonatomic, weak) id<CommandDockDelegate> delegate;
@property (nonatomic, copy, nullable) NSString *linkGroup;
@property (nonatomic, strong) NSArray<NSDictionary *> *fastPaths;

// Declaration required for TerminalWindowController to present the OOB Popover
- (void)showOOBPopoverWithTitle:(NSString *)title content:(NSString *)content;

@end

NS_ASSUME_NONNULL_END