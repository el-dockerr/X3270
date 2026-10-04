#import "PreferencesWindowController.h"
#import "TerminalView.h"
#import "../utils/TimeMachineManager.h"

@implementation PreferencesWindowController {
    NSButton *_use3270FontCheckbox;
    NSButton *_herculesBracketsCheckbox;
    NSButton *_crosshairRulerCheckbox;
    NSButton *_timeMachineCheckbox;
}

+ (instancetype)sharedController {
    static PreferencesWindowController *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // Finestra ridotta a 400px di altezza, siccome abbiamo tolto la tabella
        NSWindow *win = [[NSWindow alloc]
                         initWithContentRect:NSMakeRect(0, 0, 420, 400)
                                   styleMask:NSWindowStyleMaskTitled
                                            |NSWindowStyleMaskClosable
                                     backing:NSBackingStoreBuffered
                                       defer:NO];
        win.title = @"DX3270 - Preferences";
        win.releasedWhenClosed = NO;
        [win center];
        shared = [[PreferencesWindowController alloc] initWithWindow:win];
        [shared buildUI];
    });
    return shared;
}

#pragma mark - UI Setup
- (void)buildUI {
    NSView *cv = self.window.contentView;
    CGFloat margin = 20;

    // ==========================================
    // Section: Terminal Font
    // ==========================================
    NSTextField *fontHeader = [NSTextField labelWithString:@"Terminal Font"];
    fontHeader.font = [NSFont boldSystemFontOfSize:13];
    fontHeader.frame = NSMakeRect(margin, 350, 380, 20);
    [cv addSubview:fontHeader];

    NSBox *sep1 = [[NSBox alloc] initWithFrame:NSMakeRect(margin, 344, 380, 1)];
    sep1.boxType = NSBoxSeparator;
    [cv addSubview:sep1];

    _use3270FontCheckbox = [NSButton checkboxWithTitle:@"Use IBM 3270 font (by Ricardo Bánffy)"
                                                target:self
                                                action:@selector(fontCheckboxChanged:)];
    _use3270FontCheckbox.frame = NSMakeRect(margin, 316, 380, 22);
    BOOL currentValue = [[NSUserDefaults standardUserDefaults] boolForKey:kPref3270FontEnabled];
    _use3270FontCheckbox.state = currentValue ? NSControlStateValueOn : NSControlStateValueOff;
    [cv addSubview:_use3270FontCheckbox];

    NSTextField *note = [NSTextField wrappingLabelWithString:
        @"Replaces the default Menlo font with the authentic IBM 3270 monospace font. "
         "The font is bundled with this app and designed to match the look of original "
         "IBM 3270 terminals."];
    note.textColor = [NSColor secondaryLabelColor];
    note.font = [NSFont systemFontOfSize:11];
    note.frame = NSMakeRect(margin + 18, 266, 362, 44);
    [cv addSubview:note];

    NSMutableAttributedString *linkTitle = [[NSMutableAttributedString alloc]
        initWithString:@"3270font on GitHub (github.com/rbanffy/3270font)"
            attributes:@{
                NSFontAttributeName:            [NSFont systemFontOfSize:11],
                NSForegroundColorAttributeName: [NSColor linkColor],
            }];
    NSButton *linkBtn = [[NSButton alloc] initWithFrame:NSMakeRect(margin + 18, 248, 362, 18)];
    [linkBtn setAttributedTitle:linkTitle];
    linkBtn.buttonType = NSButtonTypeMomentaryLight;
    linkBtn.bordered = NO;
    linkBtn.target = self;
    linkBtn.action = @selector(open3270FontLink:);
    linkBtn.alignment = NSTextAlignmentLeft;
    [cv addSubview:linkBtn];

    // ==========================================
    // Section: Compatibility & Features
    // ==========================================
    NSTextField *compatHeader = [NSTextField labelWithString:@"Compatibility & Features"];
    compatHeader.font = [NSFont boldSystemFontOfSize:13];
    compatHeader.frame = NSMakeRect(margin, 200, 380, 20);
    [cv addSubview:compatHeader];

    NSBox *sep2 = [[NSBox alloc] initWithFrame:NSMakeRect(margin, 194, 380, 1)];
    sep2.boxType = NSBoxSeparator;
    [cv addSubview:sep2];

    _herculesBracketsCheckbox = [NSButton checkboxWithTitle:@"Display Hercules-style EBCDIC brackets as [ ]"
                                                     target:self
                                                     action:@selector(herculesBracketsChanged:)];
    _herculesBracketsCheckbox.frame = NSMakeRect(margin, 166, 380, 22);
    BOOL bracketsValue = [[NSUserDefaults standardUserDefaults] boolForKey:kPrefHerculesBrackets];
    _herculesBracketsCheckbox.state = bracketsValue ? NSControlStateValueOn : NSControlStateValueOff;
    [cv addSubview:_herculesBracketsCheckbox];

    NSTextField *compatNote = [NSTextField wrappingLabelWithString:
        @"For Hercules-hosted MVS (e.g. TK5) where the host code page is CP1047. "
         "Renders inbound 0xAD/0xBD (and 0x4A/0x5A) as [ and ], and sends typed "
         "brackets as 0xAD/0xBD so the host stores them natively."];
    compatNote.textColor = [NSColor secondaryLabelColor];
    compatNote.font = [NSFont systemFontOfSize:11];
    compatNote.frame = NSMakeRect(margin + 18, 118, 362, 44);
    [cv addSubview:compatNote];

    _crosshairRulerCheckbox = [NSButton checkboxWithTitle:@"Show Crosshair Ruler (Cursor Guide) by default"
                                                   target:self
                                                   action:@selector(crosshairRulerChanged:)];
    _crosshairRulerCheckbox.frame = NSMakeRect(margin, 88, 380, 22);
    BOOL rulerValue = [[NSUserDefaults standardUserDefaults] boolForKey:kPrefCrosshairRuler];
    _crosshairRulerCheckbox.state = rulerValue ? NSControlStateValueOn : NSControlStateValueOff;
    [cv addSubview:_crosshairRulerCheckbox];

    _timeMachineCheckbox = [NSButton checkboxWithTitle:@"Record screen history (Time-Machine & Diff)"
                                                target:self
                                                action:@selector(timeMachineChanged:)];
    _timeMachineCheckbox.frame = NSMakeRect(margin, 62, 380, 22);
    BOOL tmEnabled = [[NSUserDefaults standardUserDefaults] objectForKey:@"DX3270_EnableTimeMachine"]
                      ? [[NSUserDefaults standardUserDefaults] boolForKey:@"DX3270_EnableTimeMachine"]
                      : YES;
    _timeMachineCheckbox.state = tmEnabled ? NSControlStateValueOn : NSControlStateValueOff;
    [cv addSubview:_timeMachineCheckbox];

    // ==========================================
    // Footer
    // ==========================================
    NSBox *sep3 = [[NSBox alloc] initWithFrame:NSMakeRect(margin, 46, 380, 1)];
    sep3.boxType = NSBoxSeparator;
    [cv addSubview:sep3];

    NSTextField *futureLbl = [NSTextField wrappingLabelWithString:
        @"More options coming: colour scheme, code page defaults, keyboard mapping."];
    futureLbl.textColor = [NSColor tertiaryLabelColor];
    futureLbl.font = [NSFont systemFontOfSize:10];
    futureLbl.frame = NSMakeRect(margin, 22, 380, 18);
    [cv addSubview:futureLbl];
}

#pragma mark - Actions
- (void)fontCheckboxChanged:(NSButton *)sender {
    BOOL enabled = (sender.state == NSControlStateValueOn);
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:kPref3270FontEnabled];
}

- (void)herculesBracketsChanged:(NSButton *)sender {
    BOOL enabled = (sender.state == NSControlStateValueOn);
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:kPrefHerculesBrackets];
}

- (void)open3270FontLink:(id)sender {
    [[NSWorkspace sharedWorkspace]
        openURL:[NSURL URLWithString:@"https://github.com/rbanffy/3270font"]];
}

- (void)crosshairRulerChanged:(NSButton *)sender {
    BOOL enabled = (sender.state == NSControlStateValueOn);
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:kPrefCrosshairRuler];
}

- (void)timeMachineChanged:(NSButton *)sender {
    BOOL enabled = (sender.state == NSControlStateValueOn);
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:@"DX3270_EnableTimeMachine"];
}
@end