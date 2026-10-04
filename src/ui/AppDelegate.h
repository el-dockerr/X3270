#pragma once
#import <AppKit/AppKit.h>
#import "WorkspaceWindowController.h"

@class ConnectionWindowController;

@interface AppDelegate : NSObject <NSApplicationDelegate>

@property (nonatomic, strong) ConnectionWindowController *connectionWindowController;
@property (nonatomic, strong) NSMutableSet<WorkspaceWindowController *> *workspaceWindows;

@end