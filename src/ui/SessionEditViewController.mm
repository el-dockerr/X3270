#import "SessionEditViewController.h"
#include "TerminalModel.h"
#include "TerminalProtocol.h"
#include "EbcdicCodec.h"

@interface SessionEditViewController () <NSTableViewDataSource, NSTableViewDelegate>
@property (nonatomic, strong) NSTableView *fastPathsTable;
@property (nonatomic, strong) NSMutableArray<NSMutableDictionary *> *localFastPaths;
@end

@implementation SessionEditViewController {
    DXSessionConfig *_session;
    BOOL _isNew;
    
    NSTextField *_nameField;
    NSTextField *_hostField;
    NSTextField *_portField;
    NSButton *_sslCheckbox;
    NSButton *_verifyCertCheckbox;
    NSTextField *_caField;
    
    NSPopUpButton *_protocolPopup;
    NSPopUpButton *_modelPopup;
    NSPopUpButton *_codepagePopup;
}

- (NSArray *)defaultFastPaths {
    return @[
        [@{@"title": @"=3.4",  @"cmd": @"=3.4"} mutableCopy],
        [@{@"title": @"=3.2",  @"cmd": @"=3.2"} mutableCopy],
        [@{@"title": @"SDSF",  @"cmd": @"=S;ST"} mutableCopy],
        [@{@"title": @"LOG",   @"cmd": @"=S;LOG"} mutableCopy],
        [@{@"title": @"TIME",  @"cmd": @"/D T"} mutableCopy]
    ];
}

- (instancetype)initWithSession:(DXSessionConfig *)session {
    if (self = [super initWithNibName:nil bundle:nil]) {
        if (session) {
            _session = session;
            _isNew = NO;
            _localFastPaths = [NSMutableArray array];
            
            // Se la sessione ha dei percorsi custom e non sono vuoti, li carichiamo
            if (session.customFastPaths && session.customFastPaths.count > 0) {
                for (NSDictionary *d in session.customFastPaths) {
                    [_localFastPaths addObject:[d mutableCopy]];
                }
            } else {
                // Se è vuota o mai configurata, PRE-CARICHIAMO I DEFAULT nella tabella
                [_localFastPaths addObjectsFromArray:[self defaultFastPaths]];
            }
        } else {
            _session = [[DXSessionConfig alloc] init];
            _isNew = YES;
            // Nuova connessione? PRE-CARICHIAMO I DEFAULT nella tabella
            _localFastPaths = [NSMutableArray arrayWithArray:[self defaultFastPaths]];
        }
    }
    return self;
}

#pragma mark - Enum Helpers
- (x3270::CodePage)selectedCodePage {
    switch (_codepagePopup.indexOfSelectedItem) {
        case 1:  return x3270::CodePage::CP500;
        case 2:  return x3270::CodePage::CP1047;
        case 3:  return x3270::CodePage::CP280;
        case 4:  return x3270::CodePage::CP273;
        case 5:  return x3270::CodePage::CP284;
        case 6:  return x3270::CodePage::CP285;
        default: return x3270::CodePage::CP037;
    }
}

- (NSInteger)indexForCodePage:(x3270::CodePage)cp {
    switch (cp) {
        case x3270::CodePage::CP500:  return 1;
        case x3270::CodePage::CP1047: return 2;
        case x3270::CodePage::CP280:  return 3;
        case x3270::CodePage::CP273:  return 4;
        case x3270::CodePage::CP284:  return 5;
        case x3270::CodePage::CP285:  return 6;
        default:                      return 0;
    }
}

- (x3270::TerminalModel)selectedModel {
    BOOL is5250 = (_protocolPopup.indexOfSelectedItem == 1);
    if (is5250) {
        return (_modelPopup.indexOfSelectedItem == 1) ? x3270::TerminalModel::Model5 : x3270::TerminalModel::Model2;
    }
    switch (_modelPopup.indexOfSelectedItem) {
        case 1:  return x3270::TerminalModel::Model3;
        case 2:  return x3270::TerminalModel::Model4;
        case 3:  return x3270::TerminalModel::Model5;
        case 4:  return x3270::TerminalModel::LargeCustom;
        default: return x3270::TerminalModel::Model2;
    }
}

- (NSInteger)indexForModel:(x3270::TerminalModel)model is5250:(BOOL)is5250 {
    if (is5250) return (model == x3270::TerminalModel::Model5) ? 1 : 0;
    switch (model) {
        case x3270::TerminalModel::Model3:      return 1;
        case x3270::TerminalModel::Model4:      return 2;
        case x3270::TerminalModel::Model5:      return 3;
        case x3270::TerminalModel::LargeCustom: return 4;
        default:                                 return 0;
    }
}

#pragma mark - UI Setup
- (void)loadView {
    self.view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 420, 420)];
    
    NSTextField *titleLabel = [NSTextField labelWithString:_isNew ? @"Add New Session" : @"Edit Session"];
    titleLabel.font = [NSFont boldSystemFontOfSize:14];
    titleLabel.frame = NSMakeRect(20, 380, 260, 20);
    [self.view addSubview:titleLabel];
    
    // --- TABS CONTROLLER ---
    NSTabView *tabView = [[NSTabView alloc] initWithFrame:NSMakeRect(14, 50, 392, 310)];
    [self.view addSubview:tabView];
    
    // ==========================================
    // TAB 1: General (Connection Settings)
    // ==========================================
    NSTabViewItem *tabGeneral = [[NSTabViewItem alloc] initWithIdentifier:@"general"];
    tabGeneral.label = @"General";
    NSView *v1 = [[NSView alloc] initWithFrame:tabView.contentRect];
    tabGeneral.view = v1;
    [tabView addTabViewItem:tabGeneral];
    
    [v1 addSubview:[self label:@"Name:" y:220]];
    _nameField = [NSTextField textFieldWithString:_session.name ?: @""];
    _nameField.frame = NSMakeRect(110, 216, 250, 22);
    [v1 addSubview:_nameField];
    
    [v1 addSubview:[self label:@"Host:" y:190]];
    _hostField = [NSTextField textFieldWithString:_session.host ?: @""];
    _hostField.placeholderString = @"e.g. 10.134.49.215";
    _hostField.frame = NSMakeRect(110, 186, 250, 22);
    [v1 addSubview:_hostField];
    
    [v1 addSubview:[self label:@"Port:" y:160]];
    _portField = [NSTextField textFieldWithString:[NSString stringWithFormat:@"%d", _session.port > 0 ? _session.port : 23]];
    _portField.frame = NSMakeRect(110, 156, 50, 22);
    [v1 addSubview:_portField];
    
    _sslCheckbox = [NSButton checkboxWithTitle:@"Use SSL" target:self action:@selector(sslToggled:)];
    _sslCheckbox.state = _session.useSSL ? NSControlStateValueOn : NSControlStateValueOff;
    _sslCheckbox.frame = NSMakeRect(170, 156, 80, 22);
    [v1 addSubview:_sslCheckbox];
    
    _verifyCertCheckbox = [NSButton checkboxWithTitle:@"Verify Cert" target:nil action:nil];
    _verifyCertCheckbox.state = _session.verifyCert ? NSControlStateValueOn : NSControlStateValueOff;
    _verifyCertCheckbox.enabled = _session.useSSL;
    _verifyCertCheckbox.frame = NSMakeRect(255, 156, 100, 22);
    [v1 addSubview:_verifyCertCheckbox];
    
    [v1 addSubview:[self label:@"CA Bundle:" y:130]];
    _caField = [NSTextField textFieldWithString:_session.caBundle ?: @""];
    _caField.placeholderString = @"(optional) path to .pem";
    _caField.frame = NSMakeRect(110, 126, 250, 22);
    _caField.enabled = _session.useSSL;
    [v1 addSubview:_caField];
    
    [v1 addSubview:[self label:@"Protocol:" y:100]];
    _protocolPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(108, 96, 254, 22) pullsDown:NO];
    [_protocolPopup addItemsWithTitles:@[@"TN3270     Mainframe (z/OS)", @"TN5250     Midrange (IBM i / AS400)"]];
    [_protocolPopup selectItemAtIndex:_session.protocol];
    [_protocolPopup setTarget:self];
    [_protocolPopup setAction:@selector(protocolChanged:)];
    [v1 addSubview:_protocolPopup];
    
    [v1 addSubview:[self label:@"Screen Model:" y:70]];
    _modelPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(108, 66, 254, 22) pullsDown:NO];
    [self updateModelItemsForProtocol:_session.protocol];
    [_modelPopup selectItemAtIndex:[self indexForModel:(x3270::TerminalModel)_session.model is5250:(_session.protocol == 1)]];
    [v1 addSubview:_modelPopup];
    
    [v1 addSubview:[self label:@"Code Page:" y:40]];
    _codepagePopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(108, 36, 254, 22) pullsDown:NO];
    [_codepagePopup addItemsWithTitles:@[
        @"CP037 (US/Canada)", @"CP500 (International)", @"CP1047 (Open Systems)",
        @"CP280 (Italy)", @"CP273 (Germany)", @"CP284 (Spain)", @"CP285 (United Kingdom)"
    ]];
    [_codepagePopup selectItemAtIndex:[self indexForCodePage:(x3270::CodePage)_session.codePage]];
    [v1 addSubview:_codepagePopup];
    
    // ==========================================
    // TAB 2: Fast Paths (Command Dock Customization)
    // ==========================================
    NSTabViewItem *tabPaths = [[NSTabViewItem alloc] initWithIdentifier:@"paths"];
    tabPaths.label = @"Fast Paths";
    NSView *v2 = [[NSView alloc] initWithFrame:tabView.contentRect];
    tabPaths.view = v2;
    [tabView addTabViewItem:tabPaths];
    
    NSTextField *desc = [NSTextField wrappingLabelWithString:@"Configure custom Command Dock buttons for this specific connection. Leave the table empty to use the system default buttons."];
    desc.frame = NSMakeRect(10, 215, 340, 30);
    desc.font = [NSFont systemFontOfSize:11];
    desc.textColor = [NSColor secondaryLabelColor];
    [v2 addSubview:desc];
    
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(10, 45, 340, 160)];
    scroll.hasVerticalScroller = YES;
    scroll.borderType = NSBezelBorder;
    scroll.autohidesScrollers = YES;
    
    self.fastPathsTable = [[NSTableView alloc] init];
    self.fastPathsTable.dataSource = self;
    self.fastPathsTable.delegate = self;
    self.fastPathsTable.rowHeight = 20;
    
    NSTableColumn *colTitle = [[NSTableColumn alloc] initWithIdentifier:@"title"];
    colTitle.title = @"Button Label";
    colTitle.width = 110;
    [self.fastPathsTable addTableColumn:colTitle];
    
    NSTableColumn *colCmd = [[NSTableColumn alloc] initWithIdentifier:@"cmd"];
    colCmd.title = @"ISPF Command";
    colCmd.width = 200;
    [self.fastPathsTable addTableColumn:colCmd];
    
    scroll.documentView = self.fastPathsTable;
    [v2 addSubview:scroll];
    
    NSButton *addBtn = [NSButton buttonWithTitle:@"+" target:self action:@selector(addFastPath:)];
    addBtn.frame = NSMakeRect(10, 10, 32, 24);
    addBtn.bezelStyle = NSBezelStyleSmallSquare;
    [v2 addSubview:addBtn];
    
    NSButton *remBtn = [NSButton buttonWithTitle:@"-" target:self action:@selector(removeFastPath:)];
    remBtn.frame = NSMakeRect(45, 10, 32, 24);
    remBtn.bezelStyle = NSBezelStyleSmallSquare;
    [v2 addSubview:remBtn];
    
    NSButton *upBtn = [NSButton buttonWithTitle:@"^" target:self action:@selector(moveFastPathUp:)];
    upBtn.frame = NSMakeRect(80, 10, 32, 24);
    upBtn.bezelStyle = NSBezelStyleSmallSquare;
    [v2 addSubview:upBtn];
    
    NSButton *dnBtn = [NSButton buttonWithTitle:@"v" target:self action:@selector(moveFastPathDown:)];
    dnBtn.frame = NSMakeRect(115, 10, 32, 24);
    dnBtn.bezelStyle = NSBezelStyleSmallSquare;
    [v2 addSubview:dnBtn];
    
    // --- Bottom Buttons (Sempre visibili fuori dai tab) ---
    NSButton *cancelBtn = [NSButton buttonWithTitle:@"Cancel" target:self action:@selector(cancelClicked:)];
    cancelBtn.frame = NSMakeRect(230, 14, 80, 24);
    [self.view addSubview:cancelBtn];
    
    NSButton *saveBtn = [NSButton buttonWithTitle:@"Save" target:self action:@selector(saveClicked:)];
    saveBtn.frame = NSMakeRect(310, 14, 80, 24);
    saveBtn.keyEquivalent = @"\r";
    [self.view addSubview:saveBtn];
}

#pragma mark - Table View DataSource & Delegate
- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return self.localFastPaths.count;
}

- (id)tableView:(NSTableView *)tableView objectValueForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    return self.localFastPaths[row][tableColumn.identifier];
}

- (void)tableView:(NSTableView *)tableView setObjectValue:(id)object forTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    self.localFastPaths[row][tableColumn.identifier] = object;
}

#pragma mark - Table Actions
- (void)addFastPath:(id)sender {
    [self.localFastPaths addObject:[@{@"title": @"New", @"cmd": @"=CMD"} mutableCopy]];
    [self.fastPathsTable reloadData];
}

- (void)removeFastPath:(id)sender {
    NSInteger row = self.fastPathsTable.selectedRow;
    if (row >= 0 && row < (NSInteger)self.localFastPaths.count) {
        [self.localFastPaths removeObjectAtIndex:row];
        [self.fastPathsTable reloadData];
    }
}

- (void)moveFastPathUp:(id)sender {
    NSInteger row = self.fastPathsTable.selectedRow;
    if (row > 0 && row < (NSInteger)self.localFastPaths.count) {
        [self.localFastPaths exchangeObjectAtIndex:row withObjectAtIndex:row - 1];
        [self.fastPathsTable reloadData];
        [self.fastPathsTable selectRowIndexes:[NSIndexSet indexSetWithIndex:row - 1] byExtendingSelection:NO];
    }
}

- (void)moveFastPathDown:(id)sender {
    NSInteger row = self.fastPathsTable.selectedRow;
    if (row >= 0 && row < (NSInteger)self.localFastPaths.count - 1) {
        [self.localFastPaths exchangeObjectAtIndex:row withObjectAtIndex:row + 1];
        [self.fastPathsTable reloadData];
        [self.fastPathsTable selectRowIndexes:[NSIndexSet indexSetWithIndex:row + 1] byExtendingSelection:NO];
    }
}

- (void)sslToggled:(id)sender {
    BOOL sslOn = (_sslCheckbox.state == NSControlStateValueOn);
    _verifyCertCheckbox.enabled = sslOn;
    _caField.enabled = sslOn;
    
    if (sslOn && [_portField.stringValue isEqualToString:@"23"]) {
        _portField.stringValue = @"992";
    } else if (!sslOn && [_portField.stringValue isEqualToString:@"992"]) {
        _portField.stringValue = @"23";
    }
}

- (void)protocolChanged:(id)sender {
    BOOL is5250 = (_protocolPopup.indexOfSelectedItem == 1);
    [self updateModelItemsForProtocol:is5250 ? 1 : 0];
}

- (void)updateModelItemsForProtocol:(NSInteger)protocol {
    [_modelPopup removeAllItems];
    if (protocol == 1) {
        [_modelPopup addItemsWithTitles:@[
            @"Standard \u2014 24\u00d780",
            @"Wide \u2014 27\u00d7132"
        ]];
    } else {
        [_modelPopup addItemsWithTitles:@[
            @"Model 2 \u2014 24\u00d780 (default)",
            @"Model 3 \u2014 32\u00d780",
            @"Model 4 \u2014 43\u00d780",
            @"Model 5 \u2014 27\u00d7132 (wide)",
            @"Large \u2014 62\u00d7160 (non-standard)"
        ]];
    }
}

- (NSTextField *)label:(NSString *)text y:(CGFloat)y {
    NSTextField *lbl = [NSTextField labelWithString:text];
    lbl.alignment = NSTextAlignmentRight;
    lbl.frame = NSMakeRect(10, y, 90, 20);
    lbl.editable = NO;
    lbl.bordered = NO;
    lbl.backgroundColor = [NSColor clearColor];
    return lbl;
}

- (void)cancelClicked:(id)sender {
    if (self.delegate) [self.delegate sessionEditorDidCancel];
}

- (void)saveClicked:(id)sender {
    _session.name = _nameField.stringValue;
    _session.host = _hostField.stringValue;
    _session.port = _portField.intValue;
    _session.useSSL = (_sslCheckbox.state == NSControlStateValueOn);
    _session.verifyCert = (_verifyCertCheckbox.state == NSControlStateValueOn);
    _session.caBundle = _session.useSSL ? _caField.stringValue : @"";
    
    _session.protocol = (int)_protocolPopup.indexOfSelectedItem;
    _session.model = (int)[self selectedModel];
    _session.codePage = (int)[self selectedCodePage];
    
    // SALVA I DATI INIETTATI DALLA TABELLA!
    _session.customFastPaths = [self.localFastPaths copy];
    
    if (self.delegate) [self.delegate sessionEditorDidSave:_session isNew:_isNew];
}
@end