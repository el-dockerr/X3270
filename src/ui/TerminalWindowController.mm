#import "TerminalWindowController.h"
#import "TerminalView.h"
#import "DebugWindowController.h"
#include "ITerminalSession.h"
#include "TN3270Session.h"
#include "TN5250Session.h"
#include "DataStreamParser.h"
#include "DataStream5250Parser.h"
#include "KeyboardState.h"
#include "KeyboardState5250.h"
#include "ScreenBuffer.h"
#include "GraphicsBuffer.h"
#include "EbcdicCodec.h"
#include "TerminalProtocol.h"
#include <memory>
#include <thread>
#include <string>

@interface TerminalWindowController () <NSWindowDelegate>
@end

@implementation TerminalWindowController {
    TerminalView*   _termView;
    DebugWindowController *_debugWC;

    // Core engine objects
    std::unique_ptr<x3270::ScreenBuffer>          _screen;
    std::unique_ptr<x3270::GraphicsBuffer>        _graphics;  // 3270 only
    std::unique_ptr<x3270::EbcdicCodec>           _codec;
    std::unique_ptr<x3270::DataStreamParser>      _parser3270;  // 3270 only
    std::unique_ptr<x3270::DataStream5250Parser>  _parser5250;  // 5250 only
    std::unique_ptr<x3270::KeyboardState>         _kbd3270;     // 3270 only
    std::unique_ptr<x3270::KeyboardState5250>     _kbd5250;     // 5250 only
    std::unique_ptr<x3270::ITerminalSession>      _session;     // either

    std::thread _networkThread;
    BOOL        _userClosed;

    NSString  *_host;
    uint16_t   _port;
    BOOL       _useSSL;
    NSString  *_caBundle;
    x3270::CodePage       _codePage;
    x3270::TerminalModel  _model;
    x3270::TerminalProtocol _protocol;
}

- (instancetype)initWithHost:(NSString*)host
                        port:(uint16_t)port
                      useSSL:(BOOL)useSSL
                    caBundle:(NSString*)caBundle
                    codePage:(x3270::CodePage)codePage
                       model:(x3270::TerminalModel)model
                    protocol:(x3270::TerminalProtocol)protocol {
    NSString *protoLabel = (protocol == x3270::TerminalProtocol::TN5250) ? @" [5250]" : @"";
    NSWindow *win = [[NSWindow alloc]
                     initWithContentRect:NSMakeRect(0, 0, 640, 420)
                               styleMask:NSWindowStyleMaskTitled
                                        |NSWindowStyleMaskClosable
                                        |NSWindowStyleMaskMiniaturizable
                                        |NSWindowStyleMaskResizable
                               backing:NSBackingStoreBuffered
                                  defer:NO];
    win.title = [NSString stringWithFormat:@"%@:%d%@ — DX3270", host, port, protoLabel];
    win.releasedWhenClosed = NO;
    [win center];

    if ((self = [super initWithWindow:win])) {
        win.delegate = self;
        _host     = [host copy];
        _port     = port;
        _useSSL   = useSSL;
        _caBundle = [caBundle copy];
        _codePage = codePage;
        _model    = model;
        _protocol = protocol;

        [self buildEngineObjects];
        [self buildUI];
        [self startNetworkConnection];

        [[NSNotificationCenter defaultCenter]
            addObserver:self
               selector:@selector(userDefaultsDidChange:)
                   name:NSUserDefaultsDidChangeNotification
                 object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    if (_session) _session->disconnect();
    if (_networkThread.joinable()) _networkThread.detach();
    _debugWC = nil;
}

- (void)userDefaultsDidChange:(NSNotification *)note {
    BOOL hb = [[NSUserDefaults standardUserDefaults] boolForKey:kPrefHerculesBrackets];
    if (_codec) {
        _codec->setHerculesBrackets(hb);
    }
    [_debugWC configureCodePage:(int)_codePage herculesBrackets:hb];
}

// ── Engine ────────────────────────────────────────────────────────────────────
- (void)buildEngineObjects {
    _screen = std::make_unique<x3270::ScreenBuffer>(_model);
    _codec  = std::make_unique<x3270::EbcdicCodec>(_codePage);
    _codec->setHerculesBrackets([[NSUserDefaults standardUserDefaults] boolForKey:kPrefHerculesBrackets]);
    _debugWC = [[DebugWindowController alloc] init];
    [_debugWC configureCodePage:(int)_codePage
               herculesBrackets:[[NSUserDefaults standardUserDefaults] boolForKey:kPrefHerculesBrackets]];

    __weak TerminalWindowController *weakSelf = self;

    if (_protocol == x3270::TerminalProtocol::TN5250) {
        // ── 5250 engine ───────────────────────────────────────────────────────
        auto* session5250 = new x3270::TN5250Session();
        session5250->setModel(_model);
        _session.reset(session5250);

        _parser5250 = std::make_unique<x3270::DataStream5250Parser>(*_screen);
        _kbd5250    = std::make_unique<x3270::KeyboardState5250>(*_screen, *_codec);

        _parser5250->setUnlockCallback([weakSelf]() {
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong auto s = weakSelf;
                if (s) s->_kbd5250->unlock();
            });
        });
        _parser5250->setAlarmCallback([]() {
            dispatch_async(dispatch_get_main_queue(), ^{ NSBeep(); });
        });
        // Query reply and other parser-initiated responses (e.g. CMD_WRITE_STRUCTURED_FIELD)
        _parser5250->setSendCallback([weakSelf](const std::vector<uint8_t>& payload) {
            __strong auto s = weakSelf;
            if (s) s->_session->sendRecord(payload);
        });
        // Query reply uses GDS opcode NO_OP (0x00), not PUT_GET (0x03)
        _parser5250->setQueryReplyCallback([weakSelf, session5250](const std::vector<uint8_t>& payload) {
            __strong auto s = weakSelf;
            if (s) session5250->sendGdsRecord(payload, x3270::GDS_OP_NO_OP);
        });

        _kbd5250->setSendCallback([weakSelf](const std::vector<uint8_t>& record) -> bool {
            __strong auto s = weakSelf;
            return s ? s->_session->sendRecord(record) : false;
        });

        _session->setDataCallback([weakSelf](const std::vector<uint8_t>& record) {
            __strong auto s = weakSelf;
            if (!s) return;

            // Log the GDS record header for debugging
            if (!record.empty()) {
                uint8_t b0 = record.size()>0 ? record[0] : 0;
                uint8_t b1 = record.size()>1 ? record[1] : 0;
                uint8_t b2 = record.size()>2 ? record[2] : 0;
                uint8_t b3 = record.size()>3 ? record[3] : 0;
                uint8_t b4 = record.size()>4 ? record[4] : 0;
                uint8_t b5 = record.size()>5 ? record[5] : 0;
                NSLog(@"[5250] record %zu bytes  GDS hdr: %02X %02X %02X %02X  opcode=%02X flags=%02X",
                      record.size(), b0, b1, b2, b3, b4, b5);
            }

            // Per the reference (session.c tn5250_session_handle_receive):
            // PUT_GET (0x03) and INVITE (0x01) opcodes immediately unlock the keyboard
            // (set invited=1 and clear X_CLOCK indicator) BEFORE processing stream content.
            if (record.size() >= 10) {
                uint8_t opcode = record[9];
                if (opcode == 0x01 || opcode == 0x03) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        __strong auto s2 = weakSelf;
                        if (s2) s2->_kbd5250->unlock();
                    });
                }
            }

            s->_parser5250->processRecord(record);
            NSLog(@"[5250] after processRecord: bufPtr=%d", s->_screen->bufferPointer());
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong auto s2 = weakSelf;
                if (s2) [s2->_termView screenDidUpdate];
            });
        });

    } else {
        // ── 3270 engine ───────────────────────────────────────────────────────
        _graphics = std::make_unique<x3270::GraphicsBuffer>();
        auto* session3270 = new x3270::TN3270Session();
        session3270->setModel(_model);
        _session.reset(session3270);

        _parser3270 = std::make_unique<x3270::DataStreamParser>(*_screen, *_codec);
        _parser3270->setGraphicsBuffer(*_graphics);
        _kbd3270    = std::make_unique<x3270::KeyboardState>(*_screen, *_codec);

        _parser3270->setGraphicsUpdateCallback([weakSelf]() {
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong auto s = weakSelf;
                if (s) [s->_termView graphicsDidUpdate];
            });
        });
        _parser3270->setUnlockCallback([weakSelf]() {
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong auto s = weakSelf;
                if (s) s->_kbd3270->unlock();
            });
        });
        _parser3270->setAlarmCallback([]() {
            dispatch_async(dispatch_get_main_queue(), ^{ NSBeep(); });
        });
        _parser3270->setSendCallback([weakSelf](const std::vector<uint8_t>& data) {
            __strong auto s = weakSelf;
            if (s) s->_session->sendRecord(data);
        });

        _kbd3270->setSendCallback([weakSelf](const std::vector<uint8_t>& record) -> bool {
            __strong auto s = weakSelf;
            return s ? s->_session->sendRecord(record) : false;
        });

        _session->setDataCallback([weakSelf](const std::vector<uint8_t>& record) {
            __strong auto s = weakSelf;
            if (!s) return;
            // TN3270E mode: strip 5-byte header and ignore non-3270-data records
            auto* s3270 = static_cast<x3270::TN3270Session*>(s->_session.get());
            const std::vector<uint8_t>* payload = &record;
            std::vector<uint8_t> stripped;
            if (s3270->tn3270eActive() && record.size() >= 5) {
                if (record[0] != 0x00) return;
                stripped.assign(record.begin() + 5, record.end());
                payload = &stripped;
            }
            s->_parser3270->processRecord(*payload);
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong auto s2 = weakSelf;
                if (s2) [s2->_termView screenDidUpdate];
            });
        });
    }

    // ── Common callbacks ──────────────────────────────────────────────────────
    _session->setConnectedCallback([weakSelf]() {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong auto s = weakSelf;
            if (s) {
                // 3270: unlock immediately (server sends data right away)
                // 5250: transition from Connecting → System; keyboard stays locked until
                //       the server's first WTD+WCC2 fires the unlockCb_ in the parser.
                if (s->_kbd3270) s->_kbd3270->unlock();
                if (s->_kbd5250)
                    s->_kbd5250->lock(x3270::KeyboardState5250::LockReason::System);
                [s->_termView screenDidUpdate];
                if (s.onConnected) s.onConnected();
            }
        });
    });

    _session->setErrorCallback([weakSelf](const std::string& msg) {
        NSString *nsMsg = [NSString stringWithUTF8String:msg.c_str()];
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong auto s = weakSelf;
            if (!s) return;
            // If the user closed the window we already tore everything down,
            // and the readLoop's parting "Connection closed" must not surface
            // back to the connection screen.
            if (s->_userClosed) return;
            if (s.onConnectError) s.onConnectError(nsMsg);
            [s close];
        });
    });

    _session->setTrafficCallback([weakSelf](bool tx, const std::vector<uint8_t>& data) {
        __strong auto s = weakSelf;
        if (s) {
            [s->_debugWC appendBytes:data.data()
                              length:data.size()
                          isOutgoing:tx ? YES : NO];
        }
    });
}

// ── UI ────────────────────────────────────────────────────────────────────────
- (void)buildUI {
    _termView = [[TerminalView alloc] initWithFrame:self.window.contentView.bounds];
    _termView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [_termView setCodePage:_codePage];

    // Wire the appropriate keyboard state to the terminal view
    if (_kbd3270) {
        [_termView setScreenBuffer:_screen.get() keyboardState:_kbd3270.get()];
        [_termView setGraphicsBuffer:_graphics.get()];
    } else {
        [_termView setScreenBuffer:_screen.get() keyboardState5250:_kbd5250.get()];
    }

    [self.window.contentView addSubview:_termView];
    [self.window makeFirstResponder:_termView];

    // Resize window to fit preferred terminal size
    NSSize preferred = [_termView preferredSize];
    NSRect frame = self.window.frame;
    NSRect contentFrame = [self.window contentRectForFrameRect:frame];
    CGFloat widthDiff  = frame.size.width  - contentFrame.size.width;
    CGFloat heightDiff = frame.size.height - contentFrame.size.height;
    [self.window setContentSize:preferred];
    (void)widthDiff; (void)heightDiff;
}

// ── Networking ────────────────────────────────────────────────────────────────
- (void)startNetworkConnection {
    std::string host      = [_host UTF8String];
    uint16_t    port      = _port;
    bool        useSSL    = _useSSL == YES;
    std::string caBundle  = _caBundle ? [_caBundle UTF8String] : "";

    // Capture self strongly so the controller stays alive while the network
    // thread is running, but hand the final release back to the main thread
    // so dealloc (and the AppKit teardown it triggers) never runs on a
    // background thread.
    _networkThread = std::thread([self, host, port, useSSL, caBundle]() {
        @autoreleasepool {
            bool ok = _session->connect(host, port, useSSL, caBundle);
            if (ok) {
                _session->readLoop(); // blocks until disconnected
            }
        }
        __block TerminalWindowController *retained = self;
        dispatch_async(dispatch_get_main_queue(), ^{ retained = nil; });
    });
    _networkThread.detach();
}

- (void)windowWillClose:(NSNotification*)notification {
    if (_userClosed) return;
    _userClosed = YES;
    if (_session) _session->disconnect();

    // Detach the view from the engine objects before the controller (and the
    // unique_ptrs it owns) can be deallocated.  AppKit may still issue one
    // final drawRect: as part of the window-close transaction, and without
    // this the view would dereference freed ScreenBuffer/Keyboard pointers.
    [_termView setScreenBuffer:(x3270::ScreenBuffer*)nullptr
                keyboardState:(x3270::KeyboardState*)nullptr];
    [_termView setGraphicsBuffer:nullptr];

    if (self.onClosed) self.onClosed();
}

/// Open the traffic monitor panel (⌘⇧D).
- (IBAction)openDebugWindow:(id)sender {
    [_debugWC showWindow:nil];
    [_debugWC.window makeKeyAndOrderFront:nil];
}

// ── Screenshot ────────────────────────────────────────────────────────────────

/// Save a PNG screenshot of the terminal view to a user-chosen file (⌘⇧P).
- (IBAction)saveScreenshot:(id)sender {
    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.allowedFileTypes = @[@"png"];
    panel.nameFieldStringValue = @"DX3270_screenshot.png";
    panel.message = @"Save a PNG image of the current terminal screen.";

    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
        if (result != NSModalResponseOK) return;

        NSRect bounds = self->_termView.bounds;
        NSBitmapImageRep *bitmap =
            [self->_termView bitmapImageRepForCachingDisplayInRect:bounds];
        if (!bitmap) return;
        [self->_termView cacheDisplayInRect:bounds toBitmapImageRep:bitmap];
        NSData *pngData = [bitmap representationUsingType:NSBitmapImageFileTypePNG
                                               properties:@{}];
        [pngData writeToURL:panel.URL atomically:YES];
    }];
}

// ── Text export ───────────────────────────────────────────────────────────────

/// Export the current terminal screen as UTF-8 plain text (⌘⇧T).
/// Each row is written as a fixed-width line; columns are preserved by position.
- (IBAction)exportText:(id)sender {
    if (!_screen || !_codec) return;

    int rows = _screen->rows();
    int cols = _screen->cols();
    NSMutableString *text = [NSMutableString stringWithCapacity:(cols + 1) * rows];

    for (int r = 0; r < rows; r++) {
        for (int c = 0; c < cols; c++) {
            const x3270::Cell &cell = _screen->at(r, c);
            // Field-attribute cells and NUL/space bytes → space character
            if (cell.isFA || cell.ch == 0x00 ||
                cell.ch == x3270::EbcdicCodec::EBCDIC_SPACE) {
                [text appendString:@" "];
                continue;
            }
            uint16_t uc = _codec->toUnicode(cell.ch);
            if (uc >= 0x20) {
                unichar ch = (unichar)uc;
                [text appendString:[NSString stringWithCharacters:&ch length:1]];
            } else {
                [text appendString:@" "];
            }
        }
        if (r < rows - 1) [text appendString:@"\n"];
    }

    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.allowedFileTypes = @[@"txt"];
    panel.nameFieldStringValue = @"DX3270_export.txt";
    panel.message = @"Export the current terminal screen as plain text.";

    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
        if (result != NSModalResponseOK) return;
        NSError *err = nil;
        [text writeToURL:panel.URL
              atomically:YES
                encoding:NSUTF8StringEncoding
                   error:&err];
    }];
}

// ── Menu validation ───────────────────────────────────────────────────────────

- (BOOL)validateMenuItem:(NSMenuItem *)item {
    SEL action = item.action;
    if (action == @selector(saveScreenshot:) ||
        action == @selector(exportText:)) {
        return _session != nullptr;
    }
    return YES;
}

@end
