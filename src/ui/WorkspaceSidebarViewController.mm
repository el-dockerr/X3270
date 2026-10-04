#import "WorkspaceSidebarViewController.h"

@implementation WorkspaceSidebarViewController {
    NSScrollView *_scrollView;
    NSOutlineView *_outlineView;
}

- (instancetype)initWithWorkspace:(DXWorkspace *)workspace {
    if (self = [super initWithNibName:nil bundle:nil]) {
        _workspace = workspace;
    }
    return self;
}

- (void)loadView {
    self.view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 250, 600)];
    
    // Leave 28 pixels at the bottom for the toolbar
    _scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 28, 250, 572)];
    _scrollView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _scrollView.hasVerticalScroller = YES;
    _scrollView.borderType = NSNoBorder;
    _scrollView.drawsBackground = NO;
    
    _outlineView = [[NSOutlineView alloc] initWithFrame:_scrollView.bounds];
    _outlineView.dataSource = self;
    _outlineView.delegate = self;
    _outlineView.headerView = nil;
    _outlineView.style = NSTableViewStyleSourceList;
    
    NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:@"MainColumn"];
    col.width = 240;
    col.resizingMask = NSTableColumnAutoresizingMask;
    [_outlineView addTableColumn:col];
    _outlineView.outlineTableColumn = col;
    _outlineView.autoresizesOutlineColumn = YES;
    
    _scrollView.documentView = _outlineView;
    [self.view addSubview:_scrollView];
    
    _outlineView.target = self;
    _outlineView.doubleAction = @selector(onDoubleClick:);
    
    // --- BOTTOM BAR ---
    NSVisualEffectView *bottomBar = [[NSVisualEffectView alloc] initWithFrame:NSMakeRect(0, 0, 250, 28)];
    bottomBar.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
    bottomBar.material = NSVisualEffectMaterialWindowBackground;
    
    // Segmented control in native macOS style (+, -, ⚙️)
    NSSegmentedControl *segCtrl = [NSSegmentedControl segmentedControlWithImages:@[
        [NSImage imageWithSystemSymbolName:@"plus" accessibilityDescription:@"Add"],
        [NSImage imageWithSystemSymbolName:@"minus" accessibilityDescription:@"Remove"],
        [NSImage imageWithSystemSymbolName:@"gearshape" accessibilityDescription:@"Edit"]
    ] trackingMode:NSSegmentSwitchTrackingMomentary target:self action:@selector(bottomBarClicked:)];
    
    segCtrl.segmentStyle = NSSegmentStyleSmallSquare;
    segCtrl.frame = NSMakeRect(10, 3, 90, 22);
    [bottomBar addSubview:segCtrl];
    
    [self.view addSubview:bottomBar];
    
    [_outlineView expandItem:nil expandChildren:YES];
}

- (void)reloadSidebar {
    [_outlineView reloadData];
    [_outlineView expandItem:nil expandChildren:YES];
}

#pragma mark - NSOutlineView DataSource

- (NSInteger)outlineView:(NSOutlineView *)outlineView numberOfChildrenOfItem:(id)item {
    if (item == nil) {
        return _workspace.groups.count; // Root: show groups
    } else if ([item isKindOfClass:[DXWorkspaceGroup class]]) {
        DXWorkspaceGroup *group = (DXWorkspaceGroup *)item;
        return group.sessions.count; // Node: show the group's sessions
    }
    return 0; // Leaf: sessions have no children
}

- (id)outlineView:(NSOutlineView *)outlineView child:(NSInteger)index ofItem:(id)item {
    if (item == nil) {
        return _workspace.groups[index];
    } else if ([item isKindOfClass:[DXWorkspaceGroup class]]) {
        DXWorkspaceGroup *group = (DXWorkspaceGroup *)item;
        return group.sessions[index];
    }
    return nil;
}

- (BOOL)outlineView:(NSOutlineView *)outlineView isItemExpandable:(id)item {
    return [item isKindOfClass:[DXWorkspaceGroup class]];
}

#pragma mark - NSOutlineView Delegate

- (NSView *)outlineView:(NSOutlineView *)outlineView viewForTableColumn:(NSTableColumn *)tableColumn item:(id)item {
    NSTableCellView *cell = [outlineView makeViewWithIdentifier:@"Cell" owner:self];
    if (!cell) {
        cell = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, 200, 24)];
        cell.identifier = @"Cell";
        
        NSTextField *textField = [NSTextField labelWithString:@""];
        textField.translatesAutoresizingMaskIntoConstraints = NO;
        textField.font = [NSFont systemFontOfSize:13];
        [cell addSubview:textField];
        cell.textField = textField;
        
        [NSLayoutConstraint activateConstraints:@[
            [textField.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
            [textField.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:4],
            [textField.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor]
        ]];
    }
    
    // Apply different styles for Groups and Sessions
    if ([item isKindOfClass:[DXWorkspaceGroup class]]) {
        DXWorkspaceGroup *group = (DXWorkspaceGroup *)item;
        cell.textField.stringValue = group.name.uppercaseString;
        cell.textField.textColor = [NSColor secondaryLabelColor];
        cell.textField.font = [NSFont boldSystemFontOfSize:11];
    } else if ([item isKindOfClass:[DXSessionConfig class]]) {
        DXSessionConfig *session = (DXSessionConfig *)item;
        cell.textField.stringValue = session.name;
        cell.textField.textColor = [NSColor labelColor];
        cell.textField.font = [NSFont systemFontOfSize:13];
    }
    
    return cell;
}

- (BOOL)outlineView:(NSOutlineView *)outlineView shouldSelectItem:(id)item {
    // Allow selection of sessions only, not group labels
    return [item isKindOfClass:[DXSessionConfig class]];
}

#pragma mark - Actions

- (void)onDoubleClick:(id)sender {
    NSInteger row = [_outlineView clickedRow];
    if (row < 0) return;
    
    id item = [_outlineView itemAtRow:row];
    if ([item isKindOfClass:[DXSessionConfig class]]) {
        DXSessionConfig *session = (DXSessionConfig *)item;
        if (self.delegate) {
            [self.delegate sidebarDidRequestConnectionToSession:session];
        }
    }
}

#pragma mark - Actions

- (void)bottomBarClicked:(NSSegmentedControl *)sender {
    NSInteger clickedSegment = sender.selectedSegment;
    
    if (clickedSegment == 0) { // [+] Aggiungi nuova sessione
        SessionEditViewController *editor = [[SessionEditViewController alloc] initWithSession:nil];
        editor.delegate = self;
        [self presentViewControllerAsSheet:editor];
        
    } else if (clickedSegment == 1) { // [-] Removes selected item
        NSInteger row = _outlineView.selectedRow;
        if (row >= 0) {
            id item = [_outlineView itemAtRow:row];
            if ([item isKindOfClass:[DXSessionConfig class]]) {
                id parent = [_outlineView parentForItem:item];
                if ([parent isKindOfClass:[DXWorkspaceGroup class]]) {
                    [((DXWorkspaceGroup *)parent).sessions removeObject:item];
                } else if (_workspace.groups.count > 0) {
                    [_workspace.groups.firstObject.sessions removeObject:item];
                }
            } else if ([item isKindOfClass:[DXWorkspaceGroup class]]) {
                [_workspace.groups removeObject:item];
            }
            [[WorkspaceManager sharedManager] saveWorkspaces];
            [self reloadSidebar];
        }
    } else if (clickedSegment == 2) { // [⚙️] Modifica sessione
        NSInteger row = _outlineView.selectedRow;
        if (row >= 0) {
            id item = [_outlineView itemAtRow:row];
            if ([item isKindOfClass:[DXSessionConfig class]]) {
                SessionEditViewController *editor = [[SessionEditViewController alloc] initWithSession:item];
                editor.delegate = self;
                [self presentViewControllerAsSheet:editor];
            }
        }
    }
}

#pragma mark - SessionEditDelegate

- (void)sessionEditorDidSave:(DXSessionConfig *)session isNew:(BOOL)isNew {
    [self dismissViewController:self.presentedViewControllers.firstObject];
    
    if (isNew) {
        // Adding it to the first available group
        DXWorkspaceGroup *group = _workspace.groups.firstObject;
        if (!group) {
            group = [[DXWorkspaceGroup alloc] init];
            group.name = @"Main Systems";
            [_workspace.groups addObject:group];
        }
        [group.sessions addObject:session];
    }
    
    // Save to JSON file and update the UI
    [[WorkspaceManager sharedManager] saveWorkspaces];
    [self reloadSidebar];
}

- (void)sessionEditorDidCancel {
    [self dismissViewController:self.presentedViewControllers.firstObject];
}

@end