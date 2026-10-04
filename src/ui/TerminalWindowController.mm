#import "TerminalWindowController.h"
#import "TransferDockViewController.h"

@interface TerminalWindowController () <NSWindowDelegate>
@property (nonatomic, strong) NSSplitViewController *splitViewController;
@property (nonatomic, strong) TransferDockViewController *transferDockVC;
@property (nonatomic, strong) NSSplitViewItem *sidebarSplitItem;
@end

@implementation TerminalWindowController

- (instancetype)initWithHost:(NSString*)host
                        port:(uint16_t)port
                      useSSL:(BOOL)useSSL
                  verifyCert:(BOOL)verifyCert
                    caBundle:(NSString*)caBundle
                    codePage:(x3270::CodePage)codePage
                       model:(x3270::TerminalModel)model
                    protocol:(x3270::TerminalProtocol)protocol {
         
    // Create the Window Shell
    NSWindow *win = [[NSWindow alloc]
                     initWithContentRect:NSMakeRect(0, 0, 640, 420)
                               styleMask:NSWindowStyleMaskTitled
                                        |NSWindowStyleMaskClosable
                                        |NSWindowStyleMaskMiniaturizable
                                        |NSWindowStyleMaskResizable
                                 backing:NSBackingStoreBuffered
                                   defer:NO];
         
    if (self = [super initWithWindow:win]) {
        self.window.delegate = self;
        self.window.releasedWhenClosed = NO;
        self.window.minSize = NSMakeSize(800, 500);
        
        [self.window center];
        
        // 1. Inizializza il terminale puro
        _terminalVC = [[TerminalViewController alloc] initWithHost:host port:port useSSL:useSSL verifyCert:verifyCert caBundle:caBundle codePage:codePage model:model protocol:protocol fastPaths:nil];
        
        // 2. Inizializza la Transfer Dock dedicata a questa finestra
        _transferDockVC = [[TransferDockViewController alloc] init];
        _transferDockVC.currentHost = host;
        
        // 3. Crea lo Split Controller per affiancarli
        _splitViewController = [[NSSplitViewController alloc] init];
        
        NSSplitViewItem *mainItem = [NSSplitViewItem splitViewItemWithViewController:_terminalVC];
        mainItem.holdingPriority = 200;
        
        _sidebarSplitItem = [NSSplitViewItem splitViewItemWithViewController:_transferDockVC];
        _sidebarSplitItem.holdingPriority = 260;
        _sidebarSplitItem.canCollapse = YES;
        _sidebarSplitItem.collapsed = YES;
        _sidebarSplitItem.minimumThickness = 280;
        _sidebarSplitItem.maximumThickness = 350;
        
        [_splitViewController addSplitViewItem:mainItem];
        [_splitViewController addSplitViewItem:_sidebarSplitItem];
        
        // 4. Bind del titolo e settaggio del content
        [self.window bind:@"title" toObject:_terminalVC withKeyPath:@"title" options:nil];
        self.window.contentViewController = _splitViewController;
    }
    return self;
}

// Forward the connection callbacks
- (void)setOnConnected:(void (^)(void))onConnected {
    _onConnected = onConnected;
    _terminalVC.onConnected = onConnected;
}

- (void)setOnConnectError:(void (^)(NSString *))onConnectError {
    _onConnectError = onConnectError;
    __weak typeof(self) weakSelf = self;
    _terminalVC.onConnectError = ^(NSString *err) {
        if (onConnectError) onConnectError(err);
        [weakSelf close];
    };
}

- (void)setOnClosed:(void (^)(void))onClosed {
    _onClosed = onClosed;
    _terminalVC.onClosed = onClosed;
}

- (void)windowWillClose:(NSNotification *)notification {
    [_terminalVC disconnectSession];
}

// Actions
- (IBAction)saveScreenshot:(id)sender { [_terminalVC saveScreenshot:sender]; }
- (IBAction)exportText:(id)sender { [_terminalVC exportText:sender]; }
- (IBAction)toggleVideoRecording:(id)sender { [_terminalVC toggleVideoRecording:sender]; }
- (void)toggleTimeMachine:(id)sender { [_terminalVC toggleTimeMachine:sender]; }
- (IBAction)reconnectActiveSession:(id)sender {[_terminalVC reconnectSession];}

// LA GESTIONE DELLA DOCK ORA È LOCALE:
- (void)toggleTransferSidebar:(id)sender {
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = 0.25;
        self.sidebarSplitItem.animator.collapsed = !self.sidebarSplitItem.isCollapsed;
    } completionHandler:nil];
}

- (IBAction)openDebugWindow:(id)sender {
    [_terminalVC openDebugWindow:sender];
}

- (void)toggleCommandDock:(id)sender {
    [_terminalVC toggleCommandDock:sender];
}

@end