#pragma once
#import <AppKit/AppKit.h>
#import "TerminalViewController.h"

NS_ASSUME_NONNULL_BEGIN

@class TerminalPaneViewController;

@protocol TerminalPaneDelegate <NSObject>
// Request to split the pane in half (horizontally or vertically)
- (void)paneDidRequestSplitRight:(TerminalPaneViewController *)pane;
- (void)paneDidRequestSplitDown:(TerminalPaneViewController *)pane;
// Request to close the pane
- (void)paneDidRequestClose:(TerminalPaneViewController *)pane;
// Focus request: the user clicked in the pane (it should receive focus)
- (void)paneDidGainFocus:(TerminalPaneViewController *)pane;
@end

@interface TerminalPaneViewController : NSViewController

@property (nonatomic, strong, readonly) TerminalViewController *terminalVC;
@property (nonatomic, weak) id<TerminalPaneDelegate> delegate;
@property (nonatomic, assign) BOOL isActive; // If this is YES, the pane has keyboard focus

- (instancetype)initWithTerminal:(TerminalViewController *)terminalVC;

@end

NS_ASSUME_NONNULL_END