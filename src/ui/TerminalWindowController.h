#pragma once
#import <AppKit/AppKit.h>
#include "EbcdicCodec.h"
#include "TerminalModel.h"
#include "TerminalProtocol.h"
#include <string>

/// Owns the TN3270 or TN5250 session and wires the core engine to the TerminalView.
@interface TerminalWindowController : NSWindowController

- (instancetype)initWithHost:(NSString*)host
                        port:(uint16_t)port
                      useSSL:(BOOL)useSSL
                    verifyCert:(BOOL)verifyCert
                    caBundle:(NSString*)caBundle
                    codePage:(x3270::CodePage)codePage
                       model:(x3270::TerminalModel)model
                    protocol:(x3270::TerminalProtocol)protocol;

/// Callbacks for ConnectionWindowController to observe results
@property (nonatomic, copy) void(^onConnected)(void);
@property (nonatomic, copy) void(^onConnectError)(NSString*);
/// Fired (on the main thread) when the terminal window has been closed by
/// the user, so the owner can drop its strong reference.
@property (nonatomic, copy) void(^onClosed)(void);

/// Save a PNG screenshot of the terminal window to disk.
- (IBAction)saveScreenshot:(id)sender;

/// Export the current screen content as a UTF-8 plain-text file.
- (IBAction)exportText:(id)sender;

@end
