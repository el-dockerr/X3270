#pragma once
#import <AppKit/AppKit.h>
#import "CommandDockViewController.h"
#include "TerminalModel.h"
#include "TerminalProtocol.h"
#include "EbcdicCodec.h"

NS_ASSUME_NONNULL_BEGIN

/// Reusable View Controller hosting a complete 3270/5250 session.
/// Can be embedded in a standalone window or as a tab in a Workspace.
@interface TerminalViewController : NSViewController <CommandDockDelegate>

// Session parameters
@property (nonatomic, copy, readonly) NSString *host;
@property (nonatomic, assign, readonly) uint16_t port;

// Lifecycle Callbacks
@property (nonatomic, copy, nullable) void(^onConnected)(void);
@property (nonatomic, copy, nullable) void(^onConnectError)(NSString*);
@property (nonatomic, copy, nullable) void(^onClosed)(void);

// Exposed for broadcast/OOB routing
@property (nonatomic, strong) CommandDockViewController *commandDock;

/// Array of fast path configurations for quick access within the terminal session.
@property (nonatomic, strong, nullable) NSArray<NSDictionary *> *fastPaths;

// Initializer
- (instancetype)initWithHost:(NSString*)host
                        port:(uint16_t)port
                      useSSL:(BOOL)useSSL
                  verifyCert:(BOOL)verifyCert
                    caBundle:(NSString*)caBundle
                    codePage:(x3270::CodePage)codePage
                       model:(x3270::TerminalModel)model
                    protocol:(x3270::TerminalProtocol)protocol
                    fastPaths:(nullable NSArray<NSDictionary *> *)fastPaths;

/// Safely disconnects the session and stops network threads.
- (void)disconnectSession;
/// Safely reconnects the session, re-establishing network threads if needed.
- (void)reconnectSession;

// Native Actions
- (IBAction)saveScreenshot:(id)sender;
- (IBAction)exportText:(id)sender;
- (IBAction)toggleVideoRecording:(id)sender;
- (IBAction)toggleTimeMachine:(id)sender;
- (IBAction)openDebugWindow:(id)sender;
- (IBAction)toggleCommandDock:(id)sender;
@end

NS_ASSUME_NONNULL_END