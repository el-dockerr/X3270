#import <Security/Security.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "TerminalViewController.h"
#import "TransferDockViewController.h"
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
#include <atomic>

static NSString * const kDX3270BroadcastISPFNotification = @"DX3270BroadcastISPFNotification";
static NSString * const kDX3270BroadcastOOBNotification  = @"DX3270BroadcastOOBNotification";

@interface TerminalViewController ()
- (NSString *)getPasswordForUser:(NSString *)user host:(NSString *)host;
- (void)savePasswordToKeychain:(NSString *)password forUser:(NSString *)user host:(NSString *)host;
- (NSString *)promptForPasswordForUser:(NSString *)user host:(NSString *)host;
@end

@implementation TerminalViewController {
    TerminalView* _termView;
    DebugWindowController *_debugWC;
    
    // C++ Engine
    std::shared_ptr<x3270::ScreenBuffer>          _screen;
    std::shared_ptr<x3270::GraphicsBuffer>        _graphics;
    std::shared_ptr<x3270::EbcdicCodec>           _codec;
    std::shared_ptr<x3270::DataStreamParser>      _parser3270;
    std::shared_ptr<x3270::DataStream5250Parser>  _parser5250;
    std::shared_ptr<x3270::KeyboardState>         _kbd3270;
    std::shared_ptr<x3270::KeyboardState5250>     _kbd5250;
    
    std::shared_ptr<x3270::ITerminalSession>      _session;
    
    std::thread _networkThread;
    
    std::atomic<bool> _isClosing;
    BOOL _isConnecting;
    
    // Generation counter to protect us from "Ghost Callbacks"
    int _connectionId;
    
    // Config
    BOOL       _useSSL;
    BOOL       _verifyCert;
    NSString  *_caBundle;
    x3270::CodePage       _codePage;
    x3270::TerminalModel  _model;
    x3270::TerminalProtocol _protocol;
}

- (instancetype)initWithHost:(NSString*)host
                        port:(uint16_t)port
                      useSSL:(BOOL)useSSL
                  verifyCert:(BOOL)verifyCert
                    caBundle:(NSString*)caBundle
                    codePage:(x3270::CodePage)codePage
                       model:(x3270::TerminalModel)model
                    protocol:(x3270::TerminalProtocol)protocol 
                    fastPaths:(nullable NSArray<NSDictionary *> *)fastPaths{
         
    if (self = [super initWithNibName:nil bundle:nil]) {
        _host = [host copy];
        _port = port;
        _useSSL = useSSL;
        _verifyCert = verifyCert;
        _caBundle = [caBundle copy];
        _codePage = codePage;
        _model = model;
        _protocol = protocol;
        _fastPaths = fastPaths;
        _isClosing = false;
        _connectionId = 0;
        
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(userDefaultsDidChange:) name:NSUserDefaultsDidChangeNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleBroadcastISPFCommand:) name:kDX3270BroadcastISPFNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleBroadcastOOBCommand:) name:kDX3270BroadcastOOBNotification object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self disconnectSession];
}

- (void)disconnectSession {
    if (_isClosing.exchange(true)) return;
    
    if (_session) {
        _session->disconnect();
    }
    
    if (_termView) {
        [_termView setScreenBuffer:nullptr keyboardState:nullptr];
        [_termView setScreenBuffer:nullptr keyboardState5250:nullptr];
        [_termView setGraphicsBuffer:nullptr];
    }
    
    if (_networkThread.joinable()) {
        _networkThread.join();
    }
    
    if (self.onClosed) self.onClosed();
}

- (void)reconnectSession {
    // If the tab/window is closing permanently, ignore the command
    if (_isClosing) return;
    
    // 1. Unhook and stop the current network session
    if (_session) {
        _session->disconnect();
    }
    
    // 2. Unhook the view from the old C++ buffers before destroying them
    if (_termView) {
        [_termView setScreenBuffer:nullptr keyboardState:nullptr];
        [_termView setScreenBuffer:nullptr keyboardState5250:nullptr];
        [_termView setGraphicsBuffer:nullptr];
    }
    
    // 3. DETACH the old thread instead of using "join".
    // Ghost callbacks will be discarded thanks to the _connectionId increment.
    if (_networkThread.joinable()) {
        _networkThread.detach();
    }
    
    _isConnecting = NO;
    
    // 4. Rebuild a clean new C++ engine
    [self buildEngineObjects];
    
    // 5. Reconnect the new buffers to the view
    if (_kbd3270) {
        [_termView setScreenBuffer:_screen.get() keyboardState:_kbd3270.get()];
        [_termView setGraphicsBuffer:_graphics.get()];
    } else {
        [_termView setScreenBuffer:_screen.get() keyboardState5250:_kbd5250.get()];
    }
    
    // 6. Force a visual update and restart!
    [_termView setNeedsDisplay:YES];
    [self startNetworkConnection];
}

- (void)loadView {
    self.view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 640, 420)];
    
    NSString *protoLabel = (_protocol == x3270::TerminalProtocol::TN5250) ? @" [5250]" : @"";
    self.title = [NSString stringWithFormat:@"%@:%d%@ - DX3270", _host, _port, protoLabel];
    
    [self buildEngineObjects];
    
    _termView = [[TerminalView alloc] initWithFrame:NSZeroRect];
    [_termView setCodePage:_codePage];
    
    if (_kbd3270) {
        [_termView setScreenBuffer:_screen.get() keyboardState:_kbd3270.get()];
        [_termView setGraphicsBuffer:_graphics.get()];
    } else {
        [_termView setScreenBuffer:_screen.get() keyboardState5250:_kbd5250.get()];
    }
    
    self.commandDock = [[CommandDockViewController alloc] init];
    self.commandDock.delegate = self;
    self.commandDock.fastPaths = self.fastPaths;
    
    NSStackView *terminalStack = [[NSStackView alloc] init];
    terminalStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    terminalStack.spacing = 0;
    
    [_termView setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationVertical];
    [terminalStack addArrangedSubview:_termView];
    
    NSView *dockView = self.commandDock.view;
    [dockView setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationVertical];
    [terminalStack addArrangedSubview:dockView];
    
    [dockView.widthAnchor constraintEqualToAnchor:terminalStack.widthAnchor].active = YES;

    terminalStack.frame = self.view.bounds;
    terminalStack.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [self.view addSubview:terminalStack];
}

- (void)viewDidAppear {
    [super viewDidAppear];
    if (!_session || (!_session->isConnected() && !_isConnecting && !_isClosing)) {
        [self startNetworkConnection];
    }
}

- (void)userDefaultsDidChange:(NSNotification *)note {
    BOOL brackets = [[NSUserDefaults standardUserDefaults] boolForKey:kPrefHerculesBrackets];
    if (_codec) _codec->setHerculesBrackets(brackets);
    if (_debugWC) [_debugWC configureCodePage:(int)_codePage herculesBrackets:brackets];
}

- (void)buildEngineObjects {
    // Increment the generation ID to invalidate old asynchronous callbacks
    _connectionId++;
    int currentId = _connectionId;
    
    _screen = std::make_shared<x3270::ScreenBuffer>(_model);
    _codec = std::make_shared<x3270::EbcdicCodec>(_codePage);
    BOOL brackets = [[NSUserDefaults standardUserDefaults] boolForKey:kPrefHerculesBrackets];
    _codec->setHerculesBrackets(brackets);
    
    if (!_debugWC) {
        _debugWC = [[DebugWindowController alloc] init];
    }
    [_debugWC configureCodePage:(int)_codePage herculesBrackets:brackets];
    
    __weak TerminalViewController *weakSelf = self;
    
    if (_protocol == x3270::TerminalProtocol::TN5250) {
        auto session5250 = std::make_shared<x3270::TN5250Session>();
        session5250->setModel(_model);
        _session = session5250;
        
        _parser5250 = std::make_shared<x3270::DataStream5250Parser>(*_screen);
        _kbd5250 = std::make_shared<x3270::KeyboardState5250>(*_screen, *_codec);
        
        auto parser = _parser5250;
        auto kbd = _kbd5250;
        auto session = _session;
        
        parser->setUnlockCallback([kbd]() {
            dispatch_async(dispatch_get_main_queue(), ^{ kbd->unlock(); });
        });
        parser->setAlarmCallback([]() {
            dispatch_async(dispatch_get_main_queue(), ^{ NSBeep(); });
        });
        parser->setSendCallback([session](const std::vector<uint8_t> &payload) {
            session->sendRecord(payload);
        });
        parser->setQueryReplyCallback([session5250](const std::vector<uint8_t> &payload) {
            session5250->sendGdsRecord(payload, x3270::GDS_OP_NO_OP);
        });
        kbd->setSendCallback([session](const std::vector<uint8_t> &record) -> bool {
            return session->sendRecord(record);
        });
        
        _session->setDataCallback([weakSelf, currentId, parser, kbd](const std::vector<uint8_t> &record) {
            std::vector<uint8_t> recCopy = record;
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong auto s = weakSelf; 
                if (!s || s->_isClosing || s->_connectionId != currentId) return; // Ghost filter
                if (recCopy.size() >= 10 && (recCopy[9] == 0x01 || recCopy[9] == 0x03)) kbd->unlock();
                parser->processRecord(recCopy);
                [s->_termView screenDidUpdate];
            });
        });
    } else {
        _graphics = std::make_shared<x3270::GraphicsBuffer>();
        auto session3270 = std::make_shared<x3270::TN3270Session>();
        session3270->setModel(_model);
        _session = session3270;
        
        _parser3270 = std::make_shared<x3270::DataStreamParser>(*_screen, *_codec);
        _parser3270->setGraphicsBuffer(*_graphics);
        _kbd3270 = std::make_shared<x3270::KeyboardState>(*_screen, *_codec);
        
        auto parser = _parser3270;
        auto kbd = _kbd3270;
        auto session = _session;
        
        parser->setGraphicsUpdateCallback([weakSelf, currentId]() {
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong auto s = weakSelf; 
                if (!s || s->_isClosing || s->_connectionId != currentId) return;
                [s->_termView graphicsDidUpdate];
            });
        });
        parser->setUnlockCallback([kbd]() {
            dispatch_async(dispatch_get_main_queue(), ^{ kbd->unlock(); });
        });
        parser->setAlarmCallback([]() {
            dispatch_async(dispatch_get_main_queue(), ^{ NSBeep(); });
        });
        parser->setSendCallback([session](const std::vector<uint8_t> &data) {
            session->sendRecord(data);
        });
        kbd->setSendCallback([session](const std::vector<uint8_t> &record) -> bool {
            return session->sendRecord(record);
        });
        
        _session->setDataCallback([weakSelf, currentId, parser, session](const std::vector<uint8_t> &record) {
            std::vector<uint8_t> recCopy = record;
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong auto s = weakSelf; 
                if (!s || s->_isClosing || s->_connectionId != currentId) return; // Ghost filter
                auto *sess = static_cast<x3270::TN3270Session *>(session.get());
                const std::vector<uint8_t> *payload = &recCopy;
                std::vector<uint8_t> stripped;
                if (sess->tn3270eActive() && recCopy.size() >= 5) {
                    if (recCopy[0] != 0x00) return;
                    stripped.assign(recCopy.begin() + 5, recCopy.end());
                    payload = &stripped;
                }
                parser->processRecord(*payload);
                [s->_termView screenDidUpdate];
            });
        });
    }
    
    auto kbd3270 = _kbd3270;
    auto kbd5250 = _kbd5250;
    
    _session->setConnectedCallback([weakSelf, currentId, kbd3270, kbd5250]() {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong auto s = weakSelf; 
            if (!s || s->_isClosing || s->_connectionId != currentId) return;
            if (kbd3270) kbd3270->unlock();
            if (kbd5250) kbd5250->lock(x3270::KeyboardState5250::LockReason::System);
            [s->_termView screenDidUpdate];
            if (s.onConnected) s.onConnected();
        });
    });
    
    _session->setErrorCallback([weakSelf, currentId](const std::string &message) {
        NSString *error = [NSString stringWithUTF8String:message.c_str()];
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong auto s = weakSelf; 
            if (!s || s->_isClosing || s->_connectionId != currentId) return; // Vital ghost filter
            if (s.onConnectError) s.onConnectError(error);
            [s disconnectSession];
        });
    });
    
    _session->setTrafficCallback([weakSelf, currentId](bool outgoing, const std::vector<uint8_t> &data) {
        std::vector<uint8_t> dataCopy = data;
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong auto s = weakSelf;
            if (!s || s->_isClosing || s->_connectionId != currentId) return;
            [s->_debugWC appendBytes:dataCopy.data() length:dataCopy.size() isOutgoing:outgoing ? YES : NO];
        });
    });
}

- (void)startNetworkConnection {
    if (_isConnecting || _isClosing) return;
    _isConnecting = YES;
    
    std::string host = [_host UTF8String];
    uint16_t port = _port;
    bool useSSL = _useSSL == YES;
    bool verifyCert = _verifyCert == YES;
    std::string caBundle = _caBundle ? [_caBundle UTF8String] : "";
    
    std::shared_ptr<x3270::ITerminalSession> session = _session;
    __weak TerminalViewController *weakSelf = self;
    
    if (_networkThread.joinable()) {
        _networkThread.join();
    }
    
    _networkThread = std::thread([weakSelf, session, host, port, useSSL, verifyCert, caBundle]() {
        @autoreleasepool {
            bool success = false;
            if (session) {
                success = session->connect(host, port, useSSL, verifyCert, caBundle);
            }
            
            dispatch_async(dispatch_get_main_queue(), ^{
                TerminalViewController *s = weakSelf;
                if (s) s->_isConnecting = NO;
            });
            
            if (success) {
                session->readLoop();
            }
        }
    });
}

- (NSString *)getPasswordForUser:(NSString *)user host:(NSString *)host {
    if (user.length == 0 || host.length == 0) return nil;
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: [NSString stringWithFormat:@"DX3270_Mainframe_%@", host],
        (__bridge id)kSecAttrAccount: user,
        (__bridge id)kSecReturnData: @YES,
        (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitOne
    };
    CFTypeRef value = NULL;
    if (SecItemCopyMatching((__bridge CFDictionaryRef)query, &value) != errSecSuccess) return nil;
    NSData *data = (__bridge_transfer NSData *)value;
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

- (void)savePasswordToKeychain:(NSString *)password forUser:(NSString *)user host:(NSString *)host {
    if (password.length == 0 || user.length == 0 || host.length == 0) return;
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: [NSString stringWithFormat:@"DX3270_Mainframe_%@", host],
        (__bridge id)kSecAttrAccount: user
    };
    SecItemDelete((__bridge CFDictionaryRef)query);
    NSMutableDictionary *attributes = [query mutableCopy];
    attributes[(__bridge id)kSecValueData] = [password dataUsingEncoding:NSUTF8StringEncoding];
    SecItemAdd((__bridge CFDictionaryRef)attributes, NULL);
}

- (NSString *)promptForPasswordForUser:(NSString *)user host:(NSString *)host {
    __block NSString *password;
    dispatch_sync(dispatch_get_main_queue(), ^{
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = [NSString stringWithFormat:@"Autenticazione SSH OOB per %@", host];
        alert.informativeText = [NSString stringWithFormat:@"Inserisci la password SSH per l'utente '%@':", user];
        NSSecureTextField *input = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(0, 0, 260, 24)];
        alert.accessoryView = input;
        [alert addButtonWithTitle:@"OK"];
        [alert addButtonWithTitle:@"Annulla"];
        [alert.window makeFirstResponder:input];
        if ([alert runModal] == NSAlertFirstButtonReturn) password = input.stringValue;
    });
    if (password.length) [self savePasswordToKeychain:password forUser:user host:host];
    return password;
}

- (IBAction)saveScreenshot:(id)sender {
    NSSavePanel *panel = [NSSavePanel savePanel];
    if (@available(macOS 11.0, *)) panel.allowedContentTypes = @[UTTypePNG];
    else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        panel.allowedFileTypes = @[@"png"];
#pragma clang diagnostic pop
    }
    panel.nameFieldStringValue = @"DX3270_screenshot.png";
    [panel beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse result) {
        if (result != NSModalResponseOK) return;
        NSRect bounds = self->_termView.bounds;
        NSBitmapImageRep *bitmap = [self->_termView bitmapImageRepForCachingDisplayInRect:bounds];
        if (!bitmap) return;
        [self->_termView cacheDisplayInRect:bounds toBitmapImageRep:bitmap];
        NSData *png = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        [png writeToURL:panel.URL atomically:YES];
    }];
}

- (IBAction)exportText:(id)sender {
    if (!_screen || !_codec) return;
    int rows = _screen->rows(), cols = _screen->cols();
    NSMutableString *text = [NSMutableString stringWithCapacity:(cols + 1) * rows];
    for (int row = 0; row < rows; row++) {
        for (int col = 0; col < cols; col++) {
            const x3270::Cell &cell = _screen->at(row, col);
            if (cell.isFA || cell.ch == 0x00 || cell.ch == x3270::EbcdicCodec::EBCDIC_SPACE) { [text appendString:@" "]; continue; }
            uint16_t unicode = _codec->toUnicode(cell.ch);
            if (unicode >= 0x20) { unichar character = (unichar)unicode; [text appendString:[NSString stringWithCharacters:&character length:1]]; }
            else [text appendString:@" "];
        }
        if (row + 1 < rows) [text appendString:@"\n"];
    }
    NSSavePanel *panel = [NSSavePanel savePanel];
    if (@available(macOS 11.0, *)) panel.allowedContentTypes = @[UTTypePlainText];
    else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        panel.allowedFileTypes = @[@"txt"];
#pragma clang diagnostic pop
    }
    panel.nameFieldStringValue = @"DX3270_export.txt";
    [panel beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse result) {
        if (result == NSModalResponseOK) [text writeToURL:panel.URL atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }];
}

- (IBAction)toggleVideoRecording:(id)sender {
    if ([_termView isVideoRecording]) {
        [_termView stopVideoRecording];
        self.title = [self.title stringByReplacingOccurrencesOfString:@" [RECORDING ●]" withString:@""];
        return;
    }
    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.title = @"Save Terminal Recording";
    panel.nameFieldStringValue = @"DX3270_Demo";
    if (@available(macOS 11.0, *)) panel.allowedContentTypes = @[UTTypeMPEG4Movie, UTTypeGIF];
    else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        panel.allowedFileTypes = @[@"mp4", @"gif"];
#pragma clang diagnostic pop
    }
    [panel beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse result) {
        if (result == NSModalResponseOK && panel.URL) {
            [self->_termView startVideoRecordingToURL:panel.URL];
            self.title = [self.title stringByAppendingString:@" [RECORDING ●]"];
        }
    }];
}

- (BOOL)validateMenuItem:(NSMenuItem *)item {
    SEL action = item.action;
    if (action == @selector(saveScreenshot:) || action == @selector(exportText:) || action == @selector(toggleVideoRecording:)) {
        if (action == @selector(toggleVideoRecording:)) item.title = [_termView isVideoRecording] ? @"Stop Video Recording" : @"Start Video Recording...";
        return _session != nullptr;
    }
    return YES;
}

- (void)commandDockDidRequestISPFCommand:(NSString *)command targetGroup:(NSString *)group {
    [self executeISPFCommandLocally:command];
    if (group.length) [[NSNotificationCenter defaultCenter] postNotificationName:kDX3270BroadcastISPFNotification object:nil userInfo:@{ @"command": command, @"group": group, @"sender": self }];
}

- (void)handleBroadcastISPFCommand:(NSNotification *)notification {
    if (notification.userInfo[@"sender"] == self) return;
    NSString *group = notification.userInfo[@"group"];
    if ([self.commandDock.linkGroup isEqualToString:group]) [self executeISPFCommandLocally:notification.userInfo[@"command"]];
}

- (void)executeISPFCommandLocally:(NSString *)command {
    if (command.length == 0 || !_kbd3270 || !_screen || !_codec) return;
    NSString *finalCommand = [command stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    for (NSDictionary *path in [[NSUserDefaults standardUserDefaults] arrayForKey:@"DX3270_FastPaths"]) {
        NSString *shortcut = path[@"cmd"];
        if ([shortcut hasPrefix:@"="] && [finalCommand isEqualToString:[shortcut substringFromIndex:1]]) { finalCommand = shortcut; break; }
    }
    NSArray *tsoCommands = @[@"TIME", @"LISTALC", @"LISTDS", @"STATUS", @"ALLOC", @"FREE", @"SUBMIT"];
    NSString *upper = finalCommand.uppercaseString;
    for (NSString *tso in tsoCommands) if ([upper isEqualToString:tso] || [upper hasPrefix:[tso stringByAppendingString:@" "]]) { if (![upper hasPrefix:@"TSO "] && ![upper hasPrefix:@"="]) finalCommand = [NSString stringWithFormat:@"TSO %@", finalCommand]; break; }
    int position = -1, size = _screen->size();
    uint8_t equals = _codec->fromAscii('='), greater = _codec->fromAscii('>');
    for (int index = 0; index < size - 4; index++) if (_screen->at(index).ch == equals && _screen->at(index + 1).ch == equals && _screen->at(index + 2).ch == equals && _screen->at(index + 3).ch == greater) { position = index + 4; if (position < size && _screen->at(position).isFA) position++; break; }
    if (position >= 0) _screen->setCursor(position); else _kbd3270->handleHome();
    _kbd3270->handleEraseEOF();
    for (NSUInteger index = 0; index < finalCommand.length; index++) _kbd3270->handleChar((uint8_t)[finalCommand characterAtIndex:index]);
    if (!_kbd3270->handleEnter()) NSBeep(); else [_termView setNeedsDisplay:YES];
}

- (void)commandDockDidRequestOutOdBandCommand:(NSString *)command targetGroup:(NSString *)group {
    [self executeOutOdBandCommandLocally:command];
    if (group.length) [[NSNotificationCenter defaultCenter] postNotificationName:kDX3270BroadcastOOBNotification object:nil userInfo:@{ @"command": command, @"group": group, @"sender": self }];
}

- (void)handleBroadcastOOBCommand:(NSNotification *)notification {
    if (notification.userInfo[@"sender"] == self) return;
    if ([self.commandDock.linkGroup isEqualToString:notification.userInfo[@"group"]]) [self executeOutOdBandCommandLocally:notification.userInfo[@"command"]];
}

- (void)executeOutOdBandCommandLocally:(NSString *)command {
    if (command.length == 0) return;
    NSString *trimmed = [command stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *user = [[NSUserDefaults standardUserDefaults] stringForKey:@"DX3270_TransferUser"];
    if (user.length == 0) user = NSUserName();
    NSString *host = [_host copy];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        NSString *password = [self getPasswordForUser:user host:host];
        if (password.length == 0) password = [self promptForPasswordForUser:user host:host];
        if (password.length == 0) return;
        NSString *target = [NSString stringWithFormat:@"%@@%@", user, host];
        NSTask *task = [[NSTask alloc] init];
        NSPipe *pipe = [NSPipe pipe], *input = [NSPipe pipe];
        task.launchPath = @"/usr/bin/expect";
        task.standardOutput = pipe;
        task.standardError = pipe;
        task.standardInput = input;
        task.arguments = @[@"-"];
        NSMutableDictionary *environment = [[NSProcessInfo processInfo].environment mutableCopy];
        environment[@"SSH_PASS"] = password;
        task.environment = environment;
        NSString *script = [NSString stringWithFormat:@"set timeout 30\nspawn ssh %@ %@\nexpect {\n  \"*yes/no*\" { send \"yes\\r\"; exp_continue }\n  \"*assword:*\" { send \"$env(SSH_PASS)\\r\"; exp_continue }\n  eof\n}\n", target, trimmed];
        [input.fileHandleForWriting writeData:[script dataUsingEncoding:NSUTF8StringEncoding]];
        [input.fileHandleForWriting closeFile];
        NSError *error;
        if (![task launchAndReturnError:&error]) return;
        NSData *data = [pipe.fileHandleForReading readDataToEndOfFile];
        [task waitUntilExit];
        NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        NSRange passwordPrompt = [output rangeOfString:@"password:" options:NSCaseInsensitiveSearch];
        if (passwordPrompt.location != NSNotFound) output = [output substringFromIndex:passwordPrompt.location + passwordPrompt.length];
        output = [output stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        dispatch_async(dispatch_get_main_queue(), ^{
            NSString *title = [NSString stringWithFormat:@"OOB Result [%@]: %@", host, command];
            [self.commandDock showOOBPopoverWithTitle:title content:output.length ? output : @"(Command executed successfully with no output)"];
        });
    });
}

- (void)commandDockDidToggleRuler {
    [_termView toggleCrosshairRuler];
}

- (IBAction)toggleTimeMachine:(id)sender {
    [_termView toggleTimeMachine];
}

- (void)commandDockDidToggleTimeMachine {
    [self toggleTimeMachine:self];
}


- (IBAction)openDebugWindow:(id)sender {
    if (_debugWC) {
        [_debugWC showWindow:sender];
        [_debugWC.window makeKeyAndOrderFront:sender];
    }
}


- (IBAction)toggleCommandDock:(id)sender {
    if (!self.commandDock || !self.commandDock.view) return;
    
    NSView *dockView = self.commandDock.view;
    
    // NSStackView gestisce automaticamente il ridimensionamento del terminale 
    // quando una delle sue view viene nascosta. Lo facciamo in modo animato!
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = 0.25;
        context.allowsImplicitAnimation = YES;
        dockView.animator.hidden = !dockView.isHidden;
    } completionHandler:^{
        [self->_termView setNeedsDisplay:YES];
    }];
}
@end