#pragma once
#import <AppKit/AppKit.h>
#import "../utils/WorkspaceManager.h"

NS_ASSUME_NONNULL_BEGIN

@protocol SessionEditDelegate <NSObject>
- (void)sessionEditorDidSave:(DXSessionConfig *)session isNew:(BOOL)isNew;
- (void)sessionEditorDidCancel;
@end

@interface SessionEditViewController : NSViewController
@property (nonatomic, weak) id<SessionEditDelegate> delegate;

// If you pass nil, it creates a new session. If you pass a config, it edits it.
- (instancetype)initWithSession:(nullable DXSessionConfig *)session;
@end

NS_ASSUME_NONNULL_END