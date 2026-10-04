#pragma once
#import <AppKit/AppKit.h>
#import "TerminalViewController.h"
#import "TerminalPaneViewController.h"
#import "WorkspaceSidebarViewController.h"
#import "../utils/WorkspaceManager.h"
#import "TransferDockViewController.h"

NS_ASSUME_NONNULL_BEGIN

@interface WorkspaceViewController : NSViewController <WorkspaceSidebarDelegate, TerminalPaneDelegate>

@property (nonatomic, strong) DXWorkspace *workspace;
@property (nonatomic, strong) NSSplitViewController *mainSplitController;

// Reference to the terminal that currently has focus.
// Exposed publicly so that the top menu (Save Screenshot, etc)
// knows which machine to send the command to!
@property (nonatomic, weak, readonly, nullable) TerminalViewController *activeTerminal;

- (instancetype)initWithWorkspace:(DXWorkspace *)workspace;
- (void)disconnectAllSessions;
- (void)closeActiveTab; // Maintains this name for menu compatibility (will close the active pane)
- (void)toggleTransferSidebar:(id)sender;
@end

NS_ASSUME_NONNULL_END