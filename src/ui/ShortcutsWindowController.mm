#import "ShortcutsWindowController.h"

// ── Row model ─────────────────────────────────────────────────────────────────
@interface SCRow : NSObject
@property (nonatomic) BOOL      isSection;
@property (nonatomic, copy) NSString *key;   // shortcut string
@property (nonatomic, copy) NSString *desc;  // description, or section title
+ (instancetype)section:(NSString *)title;
+ (instancetype)key:(NSString *)key desc:(NSString *)desc;
@end

@implementation SCRow
+ (instancetype)section:(NSString *)title {
    SCRow *r = [SCRow new];
    r.isSection = YES;
    r.desc = title;
    return r;
}
+ (instancetype)key:(NSString *)key desc:(NSString *)desc {
    SCRow *r = [SCRow new];
    r.isSection = NO;
    r.key  = key;
    r.desc = desc;
    return r;
}
@end

// ── Custom row view for section headers ───────────────────────────────────────
@interface SCHeaderRowView : NSTableRowView
@end
@implementation SCHeaderRowView
- (void)drawBackgroundInRect:(NSRect)dirtyRect {
    if (@available(macOS 10.14, *)) {
        [NSColor.windowBackgroundColor setFill];
    } else {
        [[NSColor colorWithWhite:0.93 alpha:1.0] setFill];
    }
    NSRectFill(dirtyRect);
}
- (void)drawSelectionInRect:(NSRect)dirtyRect {}   // never selectable
@end

// ── Main controller ───────────────────────────────────────────────────────────
@interface ShortcutsWindowController () <NSTableViewDataSource, NSTableViewDelegate>
@end

@implementation ShortcutsWindowController {
    NSTableView        *_table;
    NSArray<SCRow *>   *_rows;
}

+ (instancetype)sharedController {
    static ShortcutsWindowController *shared = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSWindow *win = [[NSWindow alloc]
            initWithContentRect:NSMakeRect(0, 0, 560, 500)
                      styleMask:  NSWindowStyleMaskTitled
                                | NSWindowStyleMaskClosable
                        backing:NSBackingStoreBuffered
                          defer:NO];
        win.title              = @"Keyboard Shortcuts";
        win.releasedWhenClosed = NO;
        win.minSize            = NSMakeSize(400, 320);
        [win center];
        shared = [[ShortcutsWindowController alloc] initWithWindow:win];
        [shared buildUI];
    });
    return shared;
}

// ── Build shortcut data ───────────────────────────────────────────────────────
- (void)buildRows {
    NSMutableArray *rows = [NSMutableArray new];

#define SECTION(t)    [rows addObject:[SCRow section:(t)]]
#define ROW(k, d)     [rows addObject:[SCRow key:(k) desc:(d)]]

    SECTION(@"Function Keys");
    ROW(@"F1 – F12",           @"PF1 – PF12");
    ROW(@"Shift + F1 – F12",   @"PF13 – PF24");
    ROW(@"Option + 1",         @"PA1");
    ROW(@"Option + 2",         @"PA2");
    ROW(@"Option + 3",         @"PA3");

    SECTION(@"Session Control");
    ROW(@"Return",             @"Enter — send AID to host");
    ROW(@"Escape",             @"Reset — unlock keyboard after host error");
    ROW(@"Option + Escape",    @"Clear — send Clear AID (clears host screen)");
    ROW(@"Option + E",         @"Erase Input — clear all unprotected fields");

    SECTION(@"Navigation & Editing");
    ROW(@"Tab",                @"Move cursor to next input field");
    ROW(@"Alt + Tab",          @"Move cursor to previous input field");
    ROW(@"↑  ↓  ←  →",        @"Move cursor within the current field or screen");
    ROW(@"Insert",             @"Toggle insert mode (characters shift right)");
    ROW(@"Option + Delete",    @"Erase to End of Field — clears from cursor to end");

    SECTION(@"Application");
    ROW(@"⌘ N",                @"New Connection — open a new Connect dialog");
    ROW(@"⌘ ,",                @"Preferences — font and display settings");
    ROW(@"⌘ ⇧ P",             @"Save Screenshot — capture screen as PNG");
    ROW(@"⌘ ⇧ T",             @"Export as Text — save screen content to UTF-8 file");
    ROW(@"⌘ ⇧ D",             @"Traffic Monitor — inspect raw Telnet / TN3270 bytes");
    ROW(@"⌘ /",               @"Keyboard Shortcuts — show this window");
    ROW(@"⌘ Q",               @"Quit DX3270");

#undef SECTION
#undef ROW

    _rows = [rows copy];
}

// ── Build UI ──────────────────────────────────────────────────────────────────
- (void)buildUI {
    [self buildRows];

    NSView *cv = self.window.contentView;
    CGFloat W  = cv.bounds.size.width;
    CGFloat H  = cv.bounds.size.height;

    // ── Top description label ─────────────────────────────────────────────────
    NSTextField *intro = [NSTextField wrappingLabelWithString:
        @"All keyboard shortcuts available in DX3270. "
         "Terminal keys are only active while a session is connected."];
    intro.font      = [NSFont systemFontOfSize:12];
    intro.textColor = [NSColor secondaryLabelColor];
    intro.frame     = NSMakeRect(16, H - 48, W - 32, 34);
    intro.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    [cv addSubview:intro];

    NSBox *topSep = [[NSBox alloc] initWithFrame:NSMakeRect(0, H - 54, W, 1)];
    topSep.boxType        = NSBoxSeparator;
    topSep.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    [cv addSubview:topSep];

    // ── Table ─────────────────────────────────────────────────────────────────
    _table = [[NSTableView alloc] init];
    _table.headerView               = nil;
    _table.rowHeight                = 24;
    _table.intercellSpacing         = NSMakeSize(0, 1);
    _table.gridStyleMask            = NSTableViewGridNone;
    _table.selectionHighlightStyle  = NSTableViewSelectionHighlightStyleNone;
    _table.usesAlternatingRowBackgroundColors = NO;
    _table.dataSource = self;
    _table.delegate   = self;

    // Key column — fixed 200 pt
    NSTableColumn *colKey  = [[NSTableColumn alloc] initWithIdentifier:@"key"];
    colKey.width    = 200;
    colKey.minWidth = 160;
    colKey.maxWidth = 260;
    [_table addTableColumn:colKey];

    // Description column — fills remaining width
    NSTableColumn *colDesc = [[NSTableColumn alloc] initWithIdentifier:@"desc"];
    colDesc.resizingMask = NSTableColumnAutoresizingMask;
    [_table addTableColumn:colDesc];

    NSScrollView *scroll = [[NSScrollView alloc]
        initWithFrame:NSMakeRect(0, 0, W, H - 55)];
    scroll.autoresizingMask  = NSViewWidthSizable | NSViewHeightSizable;
    scroll.hasVerticalScroller   = YES;
    scroll.hasHorizontalScroller = NO;
    scroll.borderType            = NSNoBorder;
    scroll.documentView          = _table;
    [cv addSubview:scroll];

    [_table sizeLastColumnToFit];
}

// ── NSTableViewDataSource ─────────────────────────────────────────────────────
- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return (NSInteger)_rows.count;
}

// ── NSTableViewDelegate ───────────────────────────────────────────────────────
- (CGFloat)tableView:(NSTableView *)tv heightOfRow:(NSInteger)row {
    return _rows[row].isSection ? 26 : 24;
}

- (BOOL)tableView:(NSTableView *)tv shouldSelectRow:(NSInteger)row {
    return NO;
}

- (NSTableRowView *)tableView:(NSTableView *)tv rowViewForRow:(NSInteger)row {
    if (_rows[row].isSection) return [SCHeaderRowView new];
    return nil;
}

- (NSView *)tableView:(NSTableView *)tv
   viewForTableColumn:(NSTableColumn *)col
                  row:(NSInteger)row
{
    SCRow *r       = _rows[row];
    BOOL  isKeyCol = [col.identifier isEqualToString:@"key"];

    // ── Section header ────────────────────────────────────────────────────────
    if (r.isSection) {
        if (!isKeyCol) {
            // Return an empty filler so the desc side shares the header background
            NSView *filler = [[NSView alloc] init];
            return filler;
        }
        NSTextField *lbl = [NSTextField labelWithString:r.desc.uppercaseString];
        lbl.font      = [NSFont boldSystemFontOfSize:10.5];
        lbl.textColor = [NSColor secondaryLabelColor];
        lbl.cell.backgroundStyle = NSBackgroundStyleNormal;
        return lbl;
    }

    // ── Shortcut row ──────────────────────────────────────────────────────────
    NSTextField *lbl;
    if (isKeyCol) {
        lbl = [NSTextField labelWithString:r.key ?: @""];
        lbl.font      = [NSFont monospacedSystemFontOfSize:12.0
                                                    weight:NSFontWeightMedium];
        lbl.textColor = [NSColor labelColor];
    } else {
        lbl = [NSTextField labelWithString:r.desc ?: @""];
        lbl.font      = [NSFont systemFontOfSize:13.0];
        lbl.textColor = [NSColor labelColor];
    }
    lbl.lineBreakMode = NSLineBreakByTruncatingTail;
    return lbl;
}

@end
