#import "WorkspaceViewController.h"

@interface WorkspaceViewController ()
@property (nonatomic, strong) NSViewController *paneContainerVC;
@property (nonatomic, strong) NSMutableArray<TerminalPaneViewController *> *allPanes;
@property (nonatomic, weak) TerminalPaneViewController *activePane;
@property (nonatomic, strong) NSTextField *emptyStateLabel;

// The Transfer Dock and its column manager
@property (nonatomic, strong) TransferDockViewController *transferDockVC;
@property (nonatomic, strong) NSSplitViewItem *transferSidebarItem;
@end

@implementation WorkspaceViewController

- (instancetype)initWithWorkspace:(DXWorkspace *)workspace {
    if (self = [super initWithNibName:nil bundle:nil]) {
        _workspace = workspace;
        _allPanes = [NSMutableArray array];
    }
    return self;
}

- (void)loadView {
    self.view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 1024, 768)];
    self.view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    
    // --- PANES CONTAINER (Center) ---
    self.paneContainerVC = [[NSViewController alloc] init];
    self.paneContainerVC.view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 800, 768)];
    self.paneContainerVC.view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.paneContainerVC.view.wantsLayer = YES;
    self.paneContainerVC.view.layer.backgroundColor = [NSColor colorWithWhite:0.1 alpha:1.0].CGColor;
    
    // --- EMPTY STATE LABEL ---
    _emptyStateLabel = [NSTextField labelWithString:@"No active sessions\nDouble-click a system in the sidebar to connect"];
    _emptyStateLabel.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
    _emptyStateLabel.textColor = [NSColor tertiaryLabelColor];
    _emptyStateLabel.alignment = NSTextAlignmentCenter;
    _emptyStateLabel.frame = NSMakeRect(200, 350, 400, 40);
    _emptyStateLabel.autoresizingMask = NSViewMinXMargin | NSViewMaxXMargin | NSViewMinYMargin | NSViewMaxYMargin;
    [self.paneContainerVC.view addSubview:_emptyStateLabel];
    
    // --- SIDEBAR (Left) ---
    WorkspaceSidebarViewController *sidebarVC = [[WorkspaceSidebarViewController alloc] initWithWorkspace:_workspace];
    sidebarVC.delegate = self;
    
    // --- GLOBAL TRANSFER DOCK (Right) ---
    self.transferDockVC = [[TransferDockViewController alloc] init];
    
    // --- MAIN SPLIT ---
    _mainSplitController = [[NSSplitViewController alloc] init];
    
    NSSplitViewItem *sidebarItem = [NSSplitViewItem sidebarWithViewController:sidebarVC];
    sidebarItem.canCollapse = YES;
    
    NSSplitViewItem *contentItem = [NSSplitViewItem splitViewItemWithViewController:self.paneContainerVC];
    
    self.transferSidebarItem = [NSSplitViewItem splitViewItemWithViewController:self.transferDockVC];
    self.transferSidebarItem.holdingPriority = 260;
    self.transferSidebarItem.canCollapse = YES;
    self.transferSidebarItem.collapsed = YES; // Hidden by default
    self.transferSidebarItem.minimumThickness = 280;
    self.transferSidebarItem.maximumThickness = 350;
    
    [_mainSplitController addSplitViewItem:sidebarItem];
    [_mainSplitController addSplitViewItem:contentItem];
    [_mainSplitController addSplitViewItem:self.transferSidebarItem];
    
    [self addChildViewController:_mainSplitController];
    _mainSplitController.view.frame = self.view.bounds;
    _mainSplitController.view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [self.view addSubview:_mainSplitController.view];
}

#pragma mark - Pane Tree Management

- (TerminalViewController *)activeTerminal {
    return self.activePane.terminalVC;
}

- (void)setActivePane:(TerminalPaneViewController *)pane {
    // Remove focus from all other panes
    for (TerminalPaneViewController *p in self.allPanes) {
        p.isActive = NO;
    }
    _activePane = pane;
    if (_activePane) {
        _activePane.isActive = YES;
        // Pass the host to the global Transfer Dock
        self.transferDockVC.currentHost = _activePane.terminalVC.host;
        
        if (self.view.window && _activePane.terminalVC.title) {
            self.view.window.title = [NSString stringWithFormat:@"%@ — %@", self.workspace.name, _activePane.terminalVC.title];
        }
    } else if (self.view.window) {
        self.view.window.title = self.workspace.name;
    }
}

- (void)setRootPane:(NSViewController *)newVC {
    for (NSViewController *child in [self.paneContainerVC.childViewControllers copy]) {
        [child.view removeFromSuperview];
        [child removeFromParentViewController];
    }
    
    [self.paneContainerVC addChildViewController:newVC];
    NSView *newView = newVC.view;
    newView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.paneContainerVC.view addSubview:newView];
    
    // Safe Auto Layout constraints
    [NSLayoutConstraint activateConstraints:@[
        [newView.topAnchor constraintEqualToAnchor:self.paneContainerVC.view.topAnchor],
        [newView.bottomAnchor constraintEqualToAnchor:self.paneContainerVC.view.bottomAnchor],
        [newView.leadingAnchor constraintEqualToAnchor:self.paneContainerVC.view.leadingAnchor],
        [newView.trailingAnchor constraintEqualToAnchor:self.paneContainerVC.view.trailingAnchor]
    ]];
    
    self.emptyStateLabel.hidden = YES;
}

- (void)replaceViewController:(NSViewController *)oldVC withViewController:(NSViewController *)newVC {
    NSViewController *parent = oldVC.parentViewController;
    
    if ([parent isKindOfClass:[NSSplitViewController class]]) {
        NSSplitViewController *split = (NSSplitViewController *)parent;
        NSInteger idx = -1;
        for (NSUInteger i = 0; i < split.splitViewItems.count; i++) {
            if (split.splitViewItems[i].viewController == oldVC) {
                idx = i; break;
            }
        }
        if (idx >= 0) {
            NSSplitViewItem *newItem = [NSSplitViewItem splitViewItemWithViewController:newVC];
            [split insertSplitViewItem:newItem atIndex:idx];
            [split removeSplitViewItem:split.splitViewItems[idx + 1]];
        }
    } else if (parent == self.paneContainerVC) {
        [self setRootPane:newVC];
    }
}

- (DXSessionConfig *)findSessionConfigForTerminal:(TerminalViewController *)term {
    for (DXWorkspaceGroup *group in self.workspace.groups) {
        for (DXSessionConfig *cfg in group.sessions) {
            if ([cfg.host isEqualToString:term.host] && cfg.port == term.port) {
                return cfg;
            }
        }
    }
    return nil;
}

#pragma mark - WorkspaceSidebarDelegate

- (void)sidebarDidRequestConnectionToSession:(DXSessionConfig *)sessionConfig {
    
    // Fail-safe: peschiamo sempre la configurazione più fresca dal manager centrale (come fa lo split)
    DXSessionConfig *freshConfig = sessionConfig;
    for (DXWorkspaceGroup *g in self.workspace.groups) {
        for (DXSessionConfig *s in g.sessions) {
            if ([s.host isEqualToString:sessionConfig.host] && s.port == sessionConfig.port) {
                freshConfig = s;
                break;
            }
        }
    }
    
    TerminalViewController *termVC = [[TerminalViewController alloc]
                                      initWithHost:freshConfig.host
                                      port:freshConfig.port
                                      useSSL:freshConfig.useSSL
                                      verifyCert:freshConfig.verifyCert
                                      caBundle:freshConfig.caBundle
                                      codePage:(x3270::CodePage)freshConfig.codePage
                                      model:(x3270::TerminalModel)freshConfig.model
                                      protocol:(x3270::TerminalProtocol)freshConfig.protocol
                                      fastPaths:freshConfig.customFastPaths]; 
    
    NSString *tabTitle = freshConfig.name.length > 0 ? freshConfig.name : [NSString stringWithFormat:@"%@:%d", freshConfig.host, freshConfig.port];
    termVC.title = tabTitle;
    
    TerminalPaneViewController *newPane = [[TerminalPaneViewController alloc] initWithTerminal:termVC];
    newPane.delegate = self;
    [self.allPanes addObject:newPane];
    
    if (self.allPanes.count == 1) {
        [self setRootPane:newPane];
        [self setActivePane:newPane];
    } else if (self.activePane) {
        [self replaceViewController:self.activePane withViewController:newPane];
        [self.allPanes removeObject:self.activePane];
        [self.activePane.terminalVC disconnectSession];
        [self setActivePane:newPane];
    }
}

#pragma mark - TerminalPaneDelegate

- (void)paneDidGainFocus:(TerminalPaneViewController *)pane {
    [self setActivePane:pane];
}

- (void)paneDidRequestSplitRight:(TerminalPaneViewController *)pane {
    [self splitPane:pane isVertical:YES];
}

- (void)paneDidRequestSplitDown:(TerminalPaneViewController *)pane {
    [self splitPane:pane isVertical:NO];
}

- (void)splitPane:(TerminalPaneViewController *)pane isVertical:(BOOL)isVertical {
    DXSessionConfig *cfg = [self findSessionConfigForTerminal:pane.terminalVC];
    if (!cfg) {
        NSBeep();
        return; 
    }
    
    TerminalViewController *newTerm = [[TerminalViewController alloc]
                                      initWithHost:cfg.host
                                      port:cfg.port
                                      useSSL:cfg.useSSL
                                      verifyCert:cfg.verifyCert
                                      caBundle:cfg.caBundle
                                      codePage:(x3270::CodePage)cfg.codePage
                                      model:(x3270::TerminalModel)cfg.model
                                      protocol:(x3270::TerminalProtocol)cfg.protocol
                                      fastPaths:cfg.customFastPaths];
    newTerm.title = pane.terminalVC.title;
    
    TerminalPaneViewController *newPane = [[TerminalPaneViewController alloc] initWithTerminal:newTerm];
    newPane.delegate = self;
    [self.allPanes addObject:newPane];
    
    NSSplitViewController *splitVC = [[NSSplitViewController alloc] init];
    splitVC.splitView.vertical = isVertical;
    splitVC.splitView.dividerStyle = NSSplitViewDividerStyleThin;
    
    [self replaceViewController:pane withViewController:splitVC];
    
    [splitVC addSplitViewItem:[NSSplitViewItem splitViewItemWithViewController:pane]];
    [splitVC addSplitViewItem:[NSSplitViewItem splitViewItemWithViewController:newPane]];
    
    [self setActivePane:newPane];
}

- (void)paneDidRequestClose:(TerminalPaneViewController *)pane {
    [pane.terminalVC disconnectSession];
    [self.allPanes removeObject:pane];
    
    NSViewController *parent = pane.parentViewController;
    
    if ([parent isKindOfClass:[NSSplitViewController class]]) {
        NSSplitViewController *splitVC = (NSSplitViewController *)parent;
        
        NSSplitViewItem *itemToRemove = nil;
        for (NSSplitViewItem *item in splitVC.splitViewItems) {
            if (item.viewController == pane) {
                itemToRemove = item;
                break;
            }
        }
        if (itemToRemove) {
            [splitVC removeSplitViewItem:itemToRemove];
        }
        
        // Auto-cleanup post-removal with safe unlinking
        if (splitVC.splitViewItems.count == 1) {
            NSSplitViewItem *remainingItem = splitVC.splitViewItems.firstObject;
            NSViewController *remainingChild = remainingItem.viewController;
            
            [splitVC removeSplitViewItem:remainingItem];
            [remainingChild.view removeFromSuperview];
            [remainingChild removeFromParentViewController];
            
            [self replaceViewController:splitVC withViewController:remainingChild];
        }
    } else if (parent == self.paneContainerVC) {
        // Closed the last root pane
        [pane.view removeFromSuperview];
        [pane removeFromParentViewController];
        self.emptyStateLabel.hidden = NO;
        if (self.view.window) {
            self.view.window.title = self.workspace.name;
        }
    }
    
    if (self.activePane == pane) {
        if (self.allPanes.count > 0) {
            [self setActivePane:self.allPanes.lastObject];
        } else {
            [self setActivePane:nil];
        }
    }
}

#pragma mark - Global Actions

- (void)closeActiveTab {
    if (self.activePane) {
        [self paneDidRequestClose:self.activePane];
    }
}

- (void)disconnectAllSessions {
    for (TerminalPaneViewController *pane in self.allPanes) {
        [pane.terminalVC disconnectSession];
    }
    [self.allPanes removeAllObjects];
}

- (void)toggleTransferSidebar:(id)sender {
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = 0.25;
        self.transferSidebarItem.animator.collapsed = !self.transferSidebarItem.isCollapsed;
    } completionHandler:nil];
}

@end