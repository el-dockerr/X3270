#pragma once
#import <AppKit/AppKit.h>
#import "TerminalViewController.h"

NS_ASSUME_NONNULL_BEGIN

/// A lightweight shell window that hosts a single TerminalViewController.
/// Used for backwards compatibility with the "Quick Connect" feature.
@interface TerminalWindowController : NSWindowController

// The embedded reusable view controller
@property (nonatomic, strong, readonly) TerminalViewController *terminalVC;

// Callbacks (Forwarded to the inner TerminalViewController)
@property (nonatomic, copy, nullable) void(^onConnected)(void);
@property (nonatomic, copy, nullable) void(^onConnectError)(NSString*);
@property (nonatomic, copy, nullable) void(^onClosed)(void);

- (instancetype)initWithHost:(NSString*)host
                        port:(uint16_t)port
                      useSSL:(BOOL)useSSL
                  verifyCert:(BOOL)verifyCert
                    caBundle:(NSString*)caBundle
                    codePage:(x3270::CodePage)codePage
                       model:(x3270::TerminalModel)model
                    protocol:(x3270::TerminalProtocol)protocol;

// Forwarded native commands
- (IBAction)saveScreenshot:(id)sender;
- (IBAction)exportText:(id)sender;
- (IBAction)toggleVideoRecording:(id)sender;
- (void)toggleTransferSidebar:(id)sender;

@end

NS_ASSUME_NONNULL_END