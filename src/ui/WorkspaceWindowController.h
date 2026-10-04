#pragma once
#import <AppKit/AppKit.h>
#import "WorkspaceViewController.h"

NS_ASSUME_NONNULL_BEGIN

@interface WorkspaceWindowController : NSWindowController

@property (nonatomic, strong, readonly) WorkspaceViewController *workspaceVC;

- (instancetype)initWithWorkspace:(DXWorkspace *)workspace;

@end

NS_ASSUME_NONNULL_END