#import "CommandDockViewController.h"
#import "OOBPopoverViewController.h"
#import "../utils/ConfigLoader.h"

@interface CommandDockViewController () <NSSearchFieldDelegate, NSTableViewDelegate, NSTableViewDataSource>
@property (nonatomic, strong) NSPopUpButton *linkGroupPopUp;
@property (nonatomic, strong) NSSearchField *ispfCommandField;
@property (nonatomic, strong) NSSearchField *oobCommandField;
@property (nonatomic, strong) NSPopover *oobPopover; // <--- Ripristinata qui

@property (nonatomic, strong) NSArray<NSDictionary *> *availableCommands;
@property (nonatomic, assign) BOOL isAutocompleting;

// Properties of the Autocompletion Popover
@property (nonatomic, strong) NSPopover *completionPopover;
@property (nonatomic, strong) NSTableView *completionTableView;
@property (nonatomic, strong) NSArray<NSDictionary *> *currentMatches;
@property (nonatomic, weak) NSTextField *activeSearchField;
@property (nonatomic, strong) NSButton *timeMachineBtn;
@end

@implementation CommandDockViewController

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)loadView {
    // 1. Sfondo nativo edge-to-edge scuro
    NSVisualEffectView *bgView = [[NSVisualEffectView alloc] initWithFrame:NSMakeRect(0, 0, 900, 120)];
    bgView.material = NSVisualEffectMaterialHeaderView; // Materiale più coerente per le barre degli strumenti
    bgView.appearance = [NSAppearance appearanceNamed:NSAppearanceNameVibrantDark]; // FORZA IL TEMA SCURO
    bgView.blendingMode = NSVisualEffectBlendingModeWithinWindow;
    bgView.translatesAutoresizingMaskIntoConstraints = NO;
    [bgView.heightAnchor constraintEqualToConstant:120].active = YES;

    // Bordo superiore netto (separatore dal terminale nero)
    NSBox *topBorder = [[NSBox alloc] init];
    topBorder.boxType = NSBoxCustom;
    topBorder.fillColor = [NSColor separatorColor]; // Usa il colore semantico nativo di macOS
    topBorder.borderWidth = 0.0; // Elimina il bordo per usare solo il riempimento del box da 1px
    topBorder.translatesAutoresizingMaskIntoConstraints = NO;
    [bgView addSubview:topBorder];
    
    // 2. SCROLLVIEW: Trasparente e a tutto schermo
    NSScrollView *scrollView = [[NSScrollView alloc] init];
    scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    scrollView.hasVerticalScroller = YES;
    scrollView.hasHorizontalScroller = YES;
    scrollView.autohidesScrollers = YES;
    scrollView.drawsBackground = NO;
    scrollView.borderType = NSNoBorder;
    [bgView addSubview:scrollView];
    
    // Vincoli per far aderire lo scrollview al contenitore e sotto il bordo
    [NSLayoutConstraint activateConstraints:@[
        [topBorder.topAnchor constraintEqualToAnchor:bgView.topAnchor],
        [topBorder.leadingAnchor constraintEqualToAnchor:bgView.leadingAnchor],
        [topBorder.trailingAnchor constraintEqualToAnchor:bgView.trailingAnchor],
        [topBorder.heightAnchor constraintEqualToConstant:1],
        
        [scrollView.topAnchor constraintEqualToAnchor:topBorder.bottomAnchor],
        [scrollView.bottomAnchor constraintEqualToAnchor:bgView.bottomAnchor],
        [scrollView.leadingAnchor constraintEqualToAnchor:bgView.leadingAnchor],
        [scrollView.trailingAnchor constraintEqualToAnchor:bgView.trailingAnchor]
    ]];
    
    // 3. STACK VERTICALE: Il contenitore delle righe
    NSStackView *mainVerticalStack = [[NSStackView alloc] initWithFrame:NSZeroRect];
    mainVerticalStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    mainVerticalStack.alignment = NSLayoutAttributeLeading;
    mainVerticalStack.edgeInsets = NSEdgeInsetsMake(12, 16, 12, 16);
    mainVerticalStack.spacing = 10;
    mainVerticalStack.translatesAutoresizingMaskIntoConstraints = NO;
    scrollView.documentView = mainVerticalStack;
    
    [NSLayoutConstraint activateConstraints:@[
        [mainVerticalStack.topAnchor constraintEqualToAnchor:scrollView.contentView.topAnchor],
        [mainVerticalStack.leadingAnchor constraintEqualToAnchor:scrollView.contentView.leadingAnchor],
        [mainVerticalStack.widthAnchor constraintGreaterThanOrEqualToAnchor:scrollView.contentView.widthAnchor]
    ]];
    
    // ==========================================
    // RIGA 1: Controlli di sistema e navigazione
    // ==========================================
    NSStackView *row1 = [[NSStackView alloc] init];
    row1.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    row1.spacing = 12;
    
    self.linkGroupPopUp = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.linkGroupPopUp.controlSize = NSControlSizeSmall;
    [self.linkGroupPopUp addItemsWithTitles:@[@"  Only This", @"  Group A", @"  Group B"]];
    self.linkGroupPopUp.target = self;
    self.linkGroupPopUp.action = @selector(linkGroupChanged:);
    [row1 addArrangedSubview:self.linkGroupPopUp];
    
    NSArray *navTitles = @[@"  Prev", @"Next  ", @"List  ", @"New +"];
    NSArray *navCommands = @[@"SWAP PREV", @"SWAP NEXT", @"SWAP LIST", @"START"];
    for (NSUInteger i = 0; i < navTitles.count; i++) {
        NSButton *btn = [NSButton buttonWithTitle:navTitles[i] target:self action:@selector(ispfButtonClicked:)];
        btn.bezelStyle = NSBezelStyleInline;
        btn.controlSize = NSControlSizeSmall;
        btn.identifier = navCommands[i];
        [row1 addArrangedSubview:btn];
    }
    [mainVerticalStack addArrangedSubview:row1];
    
    // SEPARATORE 1
    NSBox *hSep1 = [[NSBox alloc] init];
    hSep1.boxType = NSBoxSeparator;
    [mainVerticalStack addArrangedSubview:hSep1];
    [hSep1.widthAnchor constraintEqualToAnchor:mainVerticalStack.widthAnchor constant:-32].active = YES;
    
// ==========================================
    // RIGA 2: Azioni Rapide (Caricate dinamicamente)
    // ==========================================
    NSStackView *row2 = [[NSStackView alloc] init];
    row2.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    row2.spacing = 8;
    
    NSArray *pathsToLoad = self.fastPaths;
    
    // Se non ci sono bottoni passati o se l'array è vuoto, 
    // usiamo SEMPRE i default. Così non avrai mai una dock vuota.
    if (!pathsToLoad || pathsToLoad.count == 0) {
        pathsToLoad = @[
            @{@"title": @"=3.4",  @"cmd": @"=3.4"},
            @{@"title": @"=3.2",  @"cmd": @"=3.2"},
            @{@"title": @"SDSF",  @"cmd": @"=S;ST"},
            @{@"title": @"LOG",   @"cmd": @"=S;LOG"},
            @{@"title": @"TIME",  @"cmd": @"/D T"}
        ];
    }
    
    for (NSDictionary *path in pathsToLoad) {
        NSButton *btn = [NSButton buttonWithTitle:path[@"title"] target:self action:@selector(ispfButtonClicked:)];
        btn.bezelStyle = NSBezelStyleInline;
        btn.controlSize = NSControlSizeSmall;
        btn.identifier = path[@"cmd"];
        [row2 addArrangedSubview:btn];
    }
    [mainVerticalStack addArrangedSubview:row2];
    
    // SEPARATORE 2
    NSBox *hSep2 = [[NSBox alloc] init];
    hSep2.boxType = NSBoxSeparator;
    [mainVerticalStack addArrangedSubview:hSep2];
    [hSep2.widthAnchor constraintEqualToAnchor:mainVerticalStack.widthAnchor constant:-32].active = YES;
    
    // ==========================================
    // RIGA 3: Comandi, Strumenti e OOB
    // ==========================================
    NSStackView *row3 = [[NSStackView alloc] init];
    row3.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    row3.spacing = 16;
    
    self.ispfCommandField = [[NSSearchField alloc] init];
    self.ispfCommandField.placeholderString = @"ISPF Cmd...";
    self.ispfCommandField.delegate = self;
    self.ispfCommandField.controlSize = NSControlSizeSmall;
    [self.ispfCommandField.widthAnchor constraintEqualToConstant:130].active = YES; // Allargato
    [row3 addArrangedSubview:self.ispfCommandField];
    
    NSButton *rulerBtn = [NSButton buttonWithTitle:@"  Ruler" target:self action:@selector(rulerButtonClicked:)];
    rulerBtn.bezelStyle = NSBezelStyleInline;
    rulerBtn.controlSize = NSControlSizeSmall;
    [row3 addArrangedSubview:rulerBtn];
    
    self.timeMachineBtn = [NSButton buttonWithTitle:@"  Time-Machine" target:self action:@selector(timeMachineButtonClicked:)];
    self.timeMachineBtn.bezelStyle = NSBezelStyleInline;
    self.timeMachineBtn.controlSize = NSControlSizeSmall;
    [self updateTimeMachineButtonVisibility];
    [row3 addArrangedSubview:self.timeMachineBtn];
    
    NSTextField *oobLabel = [NSTextField labelWithString:@"SSH/OOB:"];
    oobLabel.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    oobLabel.textColor = [NSColor secondaryLabelColor];
    [row3 addArrangedSubview:oobLabel];
    
    self.oobCommandField = [[NSSearchField alloc] init];
    self.oobCommandField.placeholderString = @"TSO / System...";
    self.oobCommandField.delegate = self;
    self.oobCommandField.controlSize = NSControlSizeSmall;
    [self.oobCommandField.widthAnchor constraintEqualToConstant:220].active = YES; // Allargato
    [row3 addArrangedSubview:self.oobCommandField];
    
    [mainVerticalStack addArrangedSubview:row3];
    
    self.view = bgView;
    
    self.availableCommands = [ConfigLoader loadMergedJSONNamed:@"commands.json"];
    if (![self.availableCommands isKindOfClass:[NSArray class]]) {
        self.availableCommands = @[];
    }
}

- (void)userDefaultsDidChange:(NSNotification *)note {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self updateTimeMachineButtonVisibility];
    });
}

- (void)updateTimeMachineButtonVisibility {
    BOOL tmEnabled = [[NSUserDefaults standardUserDefaults] objectForKey:@"DX3270_EnableTimeMachine"] 
                     ? [[NSUserDefaults standardUserDefaults] boolForKey:@"DX3270_EnableTimeMachine"] 
                     : YES;
                     
    self.timeMachineBtn.hidden = !tmEnabled;
}

#pragma mark - Group Selection & Actions

- (void)linkGroupChanged:(NSPopUpButton *)sender {
    NSInteger index = sender.indexOfSelectedItem;
    if (index == 1) {
        self.linkGroup = @"GroupA";
    } else if (index == 2) {
        self.linkGroup = @"GroupB";
    } else {
        self.linkGroup = nil; // Standalone / Solo window
    }
}

- (void)ispfButtonClicked:(NSButton *)sender {
    if (self.delegate && sender.identifier) {
        [self.delegate commandDockDidRequestISPFCommand:sender.identifier targetGroup:self.linkGroup];
    }
}

- (void)controlTextDidEndEditing:(NSNotification *)obj {
    NSTextField *textField = obj.object;
    NSInteger movement = [[[obj userInfo] objectForKey:@"NSTextMovement"] integerValue];

    if (movement == NSReturnTextMovement && textField.stringValue.length > 0) {
        if (textField == self.ispfCommandField) {
            if (self.delegate) {
                [self.delegate commandDockDidRequestISPFCommand:textField.stringValue targetGroup:self.linkGroup];
            }
        } else if (textField == self.oobCommandField) {
            if (self.delegate) {
                NSString *rawInput = [textField.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                NSString *resolvedCmd = rawInput; // Fallback se il comando non è nel JSON

                // Data-Driven Engine to translate the OOB template
                NSArray *parts = [rawInput componentsSeparatedByString:@" "];
                if (parts.count > 0) {
                    NSString *baseCmd = [parts.firstObject uppercaseString];
                    NSString *arg = (parts.count > 1) ? [[parts subarrayWithRange:NSMakeRange(1, parts.count - 1)] componentsJoinedByString:@" "] : @"";

                    for (NSDictionary *cmdDict in self.availableCommands) {
                        NSString *target = cmdDict[@"target"] ?: @"all";
                        if ([target isEqualToString:@"oob"] || [target isEqualToString:@"all"]) {
                            if ([[cmdDict[@"cmd"] uppercaseString] isEqualToString:baseCmd]) {
                                NSString *execTemplate = cmdDict[@"exec"];
                                if (execTemplate && execTemplate.length > 0) {
                                    resolvedCmd = [execTemplate stringByReplacingOccurrencesOfString:@"{arg}" withString:arg];
                                }
                                break;
                            }
                        }
                    }
                }
                
                [self.delegate commandDockDidRequestOutOdBandCommand:resolvedCmd targetGroup:self.linkGroup];
            }
        }
        textField.stringValue = @"";
    }
}

- (void)controlTextDidChange:(NSNotification *)obj {
    NSTextField *textField = obj.object;
    if (textField != self.ispfCommandField && textField != self.oobCommandField) return;

    // Determine the type of text field in use
    NSString *currentFieldTarget = (textField == self.ispfCommandField) ? @"ispf" : @"oob";

    // Do not trigger autocomplete on Backspace / Delete keys
    NSEvent *event = [NSApp currentEvent];
    if (event.type == NSEventTypeKeyDown && (event.keyCode == 51 || event.keyCode == 117)) {
        [self.completionPopover close];
        return;
    }

    NSString *text = textField.stringValue;
    if (text.length == 0) {
        [self.completionPopover close];
        return;
    }

    // Filter commands by prefix and target (destination)
    NSMutableArray<NSDictionary *> *matches = [NSMutableArray array];
    for (NSDictionary *cmdDict in self.availableCommands) {
        NSString *cmdTarget = cmdDict[@"target"] ?: @"all";
        
        // Check if the command belongs to the active category or 'all'
        if ([cmdTarget isEqualToString:@"all"] || [cmdTarget isEqualToString:currentFieldTarget]) {
            NSString *cmd = cmdDict[@"cmd"];
            if ([cmd.uppercaseString hasPrefix:text.uppercaseString]) {
                [matches addObject:cmdDict];
            }
        }
    }

    if (matches.count > 0) {
        self.currentMatches = matches;
        self.activeSearchField = textField;
        
        [self setupCompletionPopover];
        [self.completionTableView reloadData];

        CGFloat rowHeight = 42.0;
        CGFloat totalHeight = MIN(matches.count * rowHeight + 8, 160.0);
        self.completionPopover.contentSize = NSMakeSize(480, totalHeight);

        if (!self.completionPopover.isShown) {
            [self.completionPopover showRelativeToRect:textField.bounds
                                                 ofView:textField
                                          preferredEdge:NSRectEdgeMaxY];
        }
    } else {
        [self.completionPopover close];
    }
}

#pragma mark - Native Autocomplete Delegate

- (NSArray<NSString *> *)control:(NSControl *)control
                        textView:(NSTextView *)textView
                     completions:(NSArray<NSString *> *)words
             forPartialWordRange:(NSRange)charRange
             indexOfSelectedItem:(NSInteger *)index {
    
    // Get the substring the user has typed so far
    NSString *partialString = [[textView string] substringWithRange:charRange];
    if (partialString.length == 0) {
        return @[];
    }
    
    NSMutableArray<NSString *> *matches = [NSMutableArray array];
    
    // Filter the loaded JSON commands
    for (NSDictionary *cmdDict in self.availableCommands) {
        NSString *command = cmdDict[@"cmd"];
        
        // Match the beginning of the command, case-insensitive
        if ([command.uppercaseString hasPrefix:partialString.uppercaseString]) {
            [matches addObject:command];
        }
    }
    
    // You can set *index to a specific row if you want to pre-select one,
    // otherwise leaving it untouched defaults to 0 or no selection.
    
    return matches;
}

#pragma mark - OOB Popover Presentation

- (void)showOOBPopoverWithTitle:(NSString *)title content:(NSString *)content {
    if (!self.oobPopover) {
        self.oobPopover = [[NSPopover alloc] init];
        self.oobPopover.behavior = NSPopoverBehaviorTransient;
        self.oobPopover.appearance = [NSAppearance appearanceNamed:NSAppearanceNameVibrantDark];
    }
    
    OOBPopoverViewController *popoverVC = [[OOBPopoverViewController alloc] initWithTitle:title content:content];
    self.oobPopover.contentViewController = popoverVC;
    
    [self.oobPopover showRelativeToRect:self.oobCommandField.bounds
                                 ofView:self.oobCommandField
                          preferredEdge:NSRectEdgeMinY];
}


#pragma mark - Completion Popover Setup

- (void)setupCompletionPopover {
    if (self.completionPopover) return;

    NSViewController *vc = [[NSViewController alloc] init];
    NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 480, 200)];
    scrollView.hasVerticalScroller = YES;

    NSTableView *tableView = [[NSTableView alloc] initWithFrame:scrollView.bounds];
    NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:@"cmdCol"];
    col.width = 460; 
    [tableView addTableColumn:col];
    tableView.headerView = nil;
    tableView.delegate = self;
    tableView.dataSource = self;
    tableView.rowHeight = 42.0; 

    scrollView.documentView = tableView;
    vc.view = scrollView;

    self.completionTableView = tableView;
    self.completionPopover = [[NSPopover alloc] init];
    self.completionPopover.contentViewController = vc;
    self.completionPopover.behavior = NSPopoverBehaviorTransient;
}

#pragma mark - Completion TableView Delegate & DataSource

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return self.currentMatches.count;
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    NSTextField *cell = [tableView makeViewWithIdentifier:@"cmdCell" owner:self];
    if (!cell) {
        cell = [NSTextField labelWithString:@""];
        cell.identifier = @"cmdCell";
        cell.usesSingleLineMode = NO;
        cell.maximumNumberOfLines = 2;
        cell.lineBreakMode = NSLineBreakByWordWrapping;
    }

    NSDictionary *dict = self.currentMatches[row];
    NSString *cmd  = dict[@"cmd"] ?: @"";
    NSString *args = dict[@"args"] ?: @"";
    NSString *desc = dict[@"desc"] ?: @"";

    // First line: COMMAND in bold, ARGUMENTS in gray
    NSMutableAttributedString *titleAttr = [[NSMutableAttributedString alloc] initWithString:cmd attributes:@{
        NSFontAttributeName: [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightBold],
        NSForegroundColorAttributeName: [NSColor labelColor]
    }];

    if (args.length > 0) {
        NSAttributedString *argsAttr = [[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@" %@", args] attributes:@{
            NSFontAttributeName: [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular],
            NSForegroundColorAttributeName: [NSColor systemGrayColor]
        }];
        [titleAttr appendAttributedString:argsAttr];
    }

    // Second line: DESCRIPTION
    NSAttributedString *descAttr = [[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@"\n%@", desc] attributes:@{
        NSFontAttributeName: [NSFont systemFontOfSize:10 weight:NSFontWeightRegular],
        NSForegroundColorAttributeName: [NSColor secondaryLabelColor]
    }];
    [titleAttr appendAttributedString:descAttr];

    cell.attributedStringValue = titleAttr;
    return cell;
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    NSInteger row = self.completionTableView.selectedRow;
    if (row >= 0 && row < (NSInteger)self.currentMatches.count && self.activeSearchField) {
        NSDictionary *dict = self.currentMatches[row];
        NSString *cmd  = dict[@"cmd"] ?: @"";
        NSString *args = dict[@"args"] ?: @"";

        if (args.length > 0) {
            // Insert "COMMAND <arguments>"
            NSString *fullString = [NSString stringWithFormat:@"%@ %@", cmd, args];
            self.activeSearchField.stringValue = fullString;
            
            // AUTOMATIC HIGHLIGHTING: Select the arguments part so the user can overwrite it immediately!
            NSText *editor = [self.activeSearchField currentEditor];
            if (editor) {
                NSRange argRange = NSMakeRange(cmd.length + 1, args.length);
                [editor setSelectedRange:argRange];
            }
        } else {
            self.activeSearchField.stringValue = cmd;
        }

        [self.completionPopover close];
    }
}

- (void)rulerButtonClicked:(NSButton *)sender {
    if ([self.delegate respondsToSelector:@selector(commandDockDidToggleRuler)]) {
        [self.delegate commandDockDidToggleRuler];
    }
}


- (void)timeMachineButtonClicked:(NSButton *)sender {
    if ([self.delegate respondsToSelector:@selector(commandDockDidToggleTimeMachine)]) {
        [self.delegate commandDockDidToggleTimeMachine];
    }
}

@end