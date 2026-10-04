#import "AppDelegate.h"
#import "ConnectionWindowController.h"
#import "PreferencesWindowController.h"
#import "ShortcutsWindowController.h"
#import "../utils/WorkspaceManager.h"

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    _workspaceWindows = [NSMutableSet set];
    
    [self buildMenuBar];
    
    [[WorkspaceManager sharedManager] loadWorkspaces];
    
    // Se non ci sono workspace (es. primo avvio), ne crea uno di default
    if ([WorkspaceManager sharedManager].workspaces.count == 0) {
        DXWorkspace *defaultWs = [[DXWorkspace alloc] init];
        defaultWs.name = @"Main Systems";
        [[WorkspaceManager sharedManager].workspaces addObject:defaultWs];
        [[WorkspaceManager sharedManager] saveWorkspaces];
    }
    
    // Apre il primo workspace all'avvio
    DXWorkspace *defaultWorkspace = [WorkspaceManager sharedManager].workspaces.firstObject;
    [self openWindowForWorkspace:defaultWorkspace];
    
    _connectionWindowController = [[ConnectionWindowController alloc] init];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    return NO; // L'app rimane aperta senza finestre
}

- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender hasVisibleWindows:(BOOL)flag {
    if (!flag) {
        if (_workspaceWindows.count > 0) {
            [[_workspaceWindows anyObject].window makeKeyAndOrderFront:nil];
        } else if ([WorkspaceManager sharedManager].workspaces.count > 0) {
            [self openWindowForWorkspace:[WorkspaceManager sharedManager].workspaces.firstObject];
        }
    }
    return YES;
}

#pragma mark - Gestione Finestre Multiple

- (void)openWindowForWorkspace:(DXWorkspace *)ws {
    // Controlla se è già aperto in un'altra finestra. Se sì, la porta in primo piano
    for (WorkspaceWindowController *wc in _workspaceWindows) {
        if (wc.workspaceVC.workspace == ws) {
            [wc.window makeKeyAndOrderFront:nil];
            return;
        }
    }
    
    // Apre una nuova finestra per questo Workspace
    WorkspaceWindowController *wc = [[WorkspaceWindowController alloc] initWithWorkspace:ws];
    [_workspaceWindows addObject:wc];
    [wc showWindow:nil];
    
    // Registra un observer per pulire il Set quando la finestra viene chiusa
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(workspaceWindowWillClose:)
                                                 name:NSWindowWillCloseNotification
                                               object:wc.window];
}

- (void)workspaceWindowWillClose:(NSNotification *)note {
    NSWindow *win = note.object;
    WorkspaceWindowController *toRemove = nil;
    
    for (WorkspaceWindowController *wc in _workspaceWindows) {
        if (wc.window == win) {
            toRemove = wc;
            break;
        }
    }
    
    if (toRemove) {
        [_workspaceWindows removeObject:toRemove];
        [[NSNotificationCenter defaultCenter] removeObserver:self
                                                        name:NSWindowWillCloseNotification
                                                      object:win];
    }
}

#pragma mark - Menu Bar

- (void)buildMenuBar {
    NSMenu *menuBar = [[NSMenu alloc] init];
    [NSApp setMainMenu:menuBar];
    
    // Application menu
    NSMenuItem *appMenuItem = [[NSMenuItem alloc] init];
    [menuBar addItem:appMenuItem];
    NSMenu *appMenu = [[NSMenu alloc] initWithTitle:@"DX3270"];
    appMenuItem.submenu = appMenu;
    [appMenu addItemWithTitle:@"About DX3270" action:@selector(showAbout:) keyEquivalent:@""];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:@"Preferences..." action:@selector(openPreferences:) keyEquivalent:@","];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:@"Keyboard Shortcuts" action:@selector(openShortcuts:) keyEquivalent:@"/"];
    [appMenu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *quitItem = [appMenu addItemWithTitle:@"Quit DX3270" action:@selector(terminate:) keyEquivalent:@"q"];
    quitItem.target = NSApp;
    
    // File menu
    NSMenuItem *fileMenuItem = [[NSMenuItem alloc] init];
    [menuBar addItem:fileMenuItem];
    NSMenu *fileMenu = [[NSMenu alloc] initWithTitle:@"File"];
    fileMenuItem.submenu = fileMenu;
    [fileMenu addItemWithTitle:@"New Connection..." action:@selector(newConnection:) keyEquivalent:@"n"];
    
    // --- WORKSPACE MENUS ---
    [fileMenu addItem:[NSMenuItem separatorItem]];
    
    NSMenuItem *newWsItem = [fileMenu addItemWithTitle:@"New Workspace..." action:@selector(newWorkspace:) keyEquivalent:@"N"];
    newWsItem.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
    
    NSMenuItem *openWsItem = [fileMenu addItemWithTitle:@"Open Workspace..." action:@selector(openWorkspace:) keyEquivalent:@"O"];
    openWsItem.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
    
    [fileMenu addItem:[NSMenuItem separatorItem]];
    // -----------------------
    
    NSMenuItem *closeTabItem = [fileMenu addItemWithTitle:@"Close Tab / Window" action:@selector(closeTab:) keyEquivalent:@"w"];
    closeTabItem.keyEquivalentModifierMask = NSEventModifierFlagCommand;

    NSMenuItem *reconnectItem = [fileMenu addItemWithTitle:@"Reconnect Session" action:@selector(reconnect:) keyEquivalent:@"r"];
    reconnectItem.keyEquivalentModifierMask = NSEventModifierFlagCommand;
    
    [fileMenu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *transferItem = [fileMenu addItemWithTitle:@"z/OS File Transfer Dock" action:@selector(openTransferDock:) keyEquivalent:@"U"];
    transferItem.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
    
    [fileMenu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *screenshotItem = [fileMenu addItemWithTitle:@"Save Screenshot..." action:@selector(saveScreenshot:) keyEquivalent:@"P"];
    screenshotItem.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
    NSMenuItem *exportItem = [fileMenu addItemWithTitle:@"Export as Text..." action:@selector(exportText:) keyEquivalent:@"T"];
    exportItem.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
    
    NSMenuItem *videoItem = [fileMenu addItemWithTitle:@"Start Video Recording..." action:@selector(toggleVideoRecording:) keyEquivalent:@"V"];
    videoItem.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
    
    // View menu
    NSMenuItem *viewMenuItem = [[NSMenuItem alloc] init];
    [menuBar addItem:viewMenuItem];
    NSMenu *viewMenu = [[NSMenu alloc] initWithTitle:@"View"];
    viewMenuItem.submenu = viewMenu;

    // -- Toggle Command Dock --
    NSMenuItem *toggleDockItem = [viewMenu addItemWithTitle:@"Toggle Command Dock" action:@selector(toggleCommandDock:) keyEquivalent:@"k"];
    toggleDockItem.keyEquivalentModifierMask = NSEventModifierFlagCommand;
    [viewMenu addItem:[NSMenuItem separatorItem]];

    // Toggle Sidebar (Ctrl+Cmd+S)
    NSMenuItem *toggleSidebarItem = [viewMenu addItemWithTitle:@"Toggle Sidebar" action:@selector(toggleSidebar:) keyEquivalent:@"s"];
    toggleSidebarItem.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagControl;
    [viewMenu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *timeMachineItem = [viewMenu addItemWithTitle:@"3270 Time-Machine" action:@selector(toggleTimeMachine:) keyEquivalent:@"t"];
    timeMachineItem.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagOption;
    
    // Edit menu
    NSMenuItem *editMenuItem = [[NSMenuItem alloc] init];
    [menuBar addItem:editMenuItem];
    NSMenu *editMenu = [[NSMenu alloc] initWithTitle:@"Edit"];
    editMenuItem.submenu = editMenu;
    [editMenu addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
    [editMenu addItemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@"v"];
    
    // Macro menu
    NSMenuItem *macroMenuItem = [[NSMenuItem alloc] init];
    [menuBar addItem:macroMenuItem];
    NSMenu *macroMenu = [[NSMenu alloc] initWithTitle:@"Macro"];
    macroMenuItem.submenu = macroMenu;
    NSMenuItem *recordItem = [macroMenu addItemWithTitle:@"Record Macro" action:@selector(startRecordingMacro:) keyEquivalent:@"r"];
    recordItem.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagControl;
    NSMenuItem *stopItem = [macroMenu addItemWithTitle:@"Stop & Save Macro..." action:@selector(stopRecordingMacro:) keyEquivalent:@"s"];
    stopItem.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagControl;
    [macroMenu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *playItem = [macroMenu addItemWithTitle:@"Play Macro..." action:@selector(playMacro:) keyEquivalent:@"p"];
    playItem.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagControl;
    
    // Debug menu
    NSMenuItem *debugMenuItem = [[NSMenuItem alloc] init];
    [menuBar addItem:debugMenuItem];
    NSMenu *debugMenu = [[NSMenu alloc] initWithTitle:@"Debug"];
    debugMenuItem.submenu = debugMenu;
    NSMenuItem *trafficItem = [debugMenu addItemWithTitle:@"Traffic Monitor" action:@selector(openDebugWindow:) keyEquivalent:@"D"];
    trafficItem.keyEquivalentModifierMask = NSEventModifierFlagCommand;
}

#pragma mark - Actions

- (void)newWorkspace:(id)sender {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"New Workspace";
    alert.informativeText = @"Enter a name for the new workspace:";
    [alert addButtonWithTitle:@"Create"];
    [alert addButtonWithTitle:@"Cancel"];
    
    NSTextField *input = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 200, 24)];
    input.placeholderString = @"Workspace Name";
    alert.accessoryView = input;
    [alert.window makeFirstResponder:input];
    
    if ([alert runModal] == NSAlertFirstButtonReturn) {
        NSString *name = [input.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (name.length > 0) {
            DXWorkspace *ws = [[DXWorkspace alloc] init];
            ws.name = name;
            [[WorkspaceManager sharedManager].workspaces addObject:ws];
            [[WorkspaceManager sharedManager] saveWorkspaces];
            [self openWindowForWorkspace:ws];
        }
    }
}

- (void)openWorkspace:(id)sender {
    NSArray *workspaces = [WorkspaceManager sharedManager].workspaces;
    if (workspaces.count == 0) return;
    
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Open Workspace";
    alert.informativeText = @"Select a workspace to open:";
    [alert addButtonWithTitle:@"Open"];
    [alert addButtonWithTitle:@"Cancel"];
    
    NSPopUpButton *popup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 250, 24) pullsDown:NO];
    for (DXWorkspace *ws in workspaces) {
        [popup addItemWithTitle:ws.name.length > 0 ? ws.name : @"Unnamed Workspace"];
    }
    alert.accessoryView = popup;
    
    if ([alert runModal] == NSAlertFirstButtonReturn) {
        NSInteger idx = popup.indexOfSelectedItem;
        if (idx >= 0 && idx < (NSInteger)workspaces.count) {
            [self openWindowForWorkspace:workspaces[idx]];
        }
    }
}

- (void)closeTab:(id)sender {
    NSWindowController *activeWC = NSApp.keyWindow.windowController;
    if ([activeWC respondsToSelector:@selector(closeTab:)]) {
        [activeWC performSelector:@selector(closeTab:) withObject:sender];
    } else {
        // Fallback per chiudere una finestra non-workspace (es. Preferences)
        [NSApp.keyWindow close];
    }
}

- (void)reconnect:(id)sender {
    NSWindowController *activeWC = NSApp.keyWindow.windowController;
    if ([activeWC respondsToSelector:@selector(reconnectActiveSession:)]) {
        [activeWC performSelector:@selector(reconnectActiveSession:) withObject:sender];
    }
}

- (void)toggleTimeMachine:(id)sender {
    NSWindowController *activeWC = NSApp.keyWindow.windowController;
    if ([activeWC respondsToSelector:@selector(toggleTimeMachine:)]) {
        [activeWC performSelector:@selector(toggleTimeMachine:) withObject:sender];
    }
}

- (void)toggleVideoRecording:(id)sender {
    NSWindowController *activeWC = NSApp.keyWindow.windowController;
    if ([activeWC respondsToSelector:@selector(toggleVideoRecording:)]) {
        [activeWC performSelector:@selector(toggleVideoRecording:) withObject:sender];
    }
}

- (void)newConnection:(id)sender {
    if (!_connectionWindowController) {
        _connectionWindowController = [[ConnectionWindowController alloc] init];
    }
    [_connectionWindowController showWindow:nil];
    [_connectionWindowController.window makeKeyAndOrderFront:nil];
}

- (void)showAbout:(id)sender {
    NSDictionary *info = [[NSBundle mainBundle] infoDictionary];
    NSString *version  = info[@"CFBundleShortVersionString"] ?: @"1.7.6";
    NSString *build    = info[@"CFBundleVersion"]            ?: @"1";
    NSString *credits = @"Free TN3270/TN3270E terminal emulator for macOS.\n\n"
                         "Native Cocoa — CoreText — OpenSSL\n"
                         "Supports ISPF, TSO and z/OS on IBM Mainframes.\n\n"
                         "Written by Swen Skalski\n"
                         "https://github.com/skalski/X3270";
    [NSApp orderFrontStandardAboutPanelWithOptions:@{
        @"ApplicationVersion": [NSString stringWithFormat:@"%@ (Build %@)", version, build],
        @"Credits": [[NSAttributedString alloc] initWithString:credits attributes:@{NSFontAttributeName: [NSFont systemFontOfSize:11]}],
        @"Copyright": @"Copyright © 2026 Swen Skalski",
    }];
}

- (void)openPreferences:(id)sender {
    [[PreferencesWindowController sharedController] showWindow:nil];
}

- (void)openShortcuts:(id)sender {
    [[ShortcutsWindowController sharedController] showWindow:nil];
}

- (void)openTransferDock:(id)sender {
    NSWindowController *activeWC = NSApp.keyWindow.windowController;
    if ([activeWC respondsToSelector:@selector(toggleTransferSidebar:)]) {
        [activeWC performSelector:@selector(toggleTransferSidebar:) withObject:sender];
    }
}

- (void)openDebugWindow:(id)sender {
    NSWindowController *activeWC = NSApp.keyWindow.windowController;
    if ([activeWC respondsToSelector:@selector(openDebugWindow:)]) {
        [activeWC performSelector:@selector(openDebugWindow:) withObject:sender];
    }
}

- (void)toggleCommandDock:(id)sender {
    NSWindowController *activeWC = NSApp.keyWindow.windowController;
    if ([activeWC respondsToSelector:@selector(toggleCommandDock:)]) {
        [activeWC performSelector:@selector(toggleCommandDock:) withObject:sender];
    }
}

@end