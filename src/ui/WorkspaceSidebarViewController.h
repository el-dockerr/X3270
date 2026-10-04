#pragma once
#import <AppKit/AppKit.h>
#import "../utils/WorkspaceManager.h"
#import "SessionEditViewController.h"

NS_ASSUME_NONNULL_BEGIN

@protocol WorkspaceSidebarDelegate <NSObject>
/// Recalled when the user double-clicks on a session in the Sidebar
- (void)sidebarDidRequestConnectionToSession:(DXSessionConfig *)session;
@end

@interface WorkspaceSidebarViewController : NSViewController <NSOutlineViewDataSource, NSOutlineViewDelegate, SessionEditDelegate>

@property (nonatomic, weak) id<WorkspaceSidebarDelegate> delegate;
@property (nonatomic, strong) DXWorkspace *workspace;

- (instancetype)initWithWorkspace:(DXWorkspace *)workspace;
- (void)reloadSidebar;

@end

NS_ASSUME_NONNULL_END