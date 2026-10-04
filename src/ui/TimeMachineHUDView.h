#import <AppKit/AppKit.h>
#import "../utils/TimeMachineManager.h"

@protocol TimeMachineHUDDelegate <NSObject>
- (void)timeMachineDidSelectSnapshotAtIndex:(NSInteger)index;
- (void)timeMachineDidToggleDiffMode:(BOOL)diffEnabled;
- (void)timeMachineDidReturnToLive;
- (void)timeMachineDidRequestSearch:(NSString *)query searchBackward:(BOOL)backward;
- (void)timeMachineDidTogglePin;
- (void)timeMachineDidRequestJumpToNextPin:(BOOL)forward;
- (void)timeMachineDidRequestExport;
- (void)timeMachineDidRequestImport;
@end

@interface TimeMachineHUDView : NSVisualEffectView
@property (nonatomic, weak) id<TimeMachineHUDDelegate> delegate;

- (void)updateWithSnapshotsCount:(NSInteger)count currentIndex:(NSInteger)index timestamp:(NSTimeInterval)timestamp;
- (void)showInParentView:(NSView *)parentView;
- (void)hide;
@end