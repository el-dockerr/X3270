#import "PreferencesWindowController.h"
#import "TerminalView.h"

@implementation PreferencesWindowController {
    NSButton *_use3270FontCheckbox;
    NSButton *_herculesBracketsCheckbox;
}

+ (instancetype)sharedController {
    static PreferencesWindowController *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSWindow *win = [[NSWindow alloc]
                         initWithContentRect:NSMakeRect(0, 0, 420, 320)
                                   styleMask:NSWindowStyleMaskTitled
                                            |NSWindowStyleMaskClosable
                                   backing:NSBackingStoreBuffered
                                      defer:NO];
        win.title = @"DX3270 — Preferences";
        win.releasedWhenClosed = NO;
        [win center];
        shared = [[PreferencesWindowController alloc] initWithWindow:win];
        [shared buildUI];
    });
    return shared;
}

- (void)buildUI {
    NSView *cv = self.window.contentView;
    CGFloat margin = 20;

    // ── Section: Font ─────────────────────────────────────────────────────────
    NSTextField *fontHeader = [NSTextField labelWithString:@"Terminal Font"];
    fontHeader.font = [NSFont boldSystemFontOfSize:13];
    fontHeader.frame = NSMakeRect(margin, 280, 380, 20);
    [cv addSubview:fontHeader];

    NSBox *sep1 = [[NSBox alloc] initWithFrame:NSMakeRect(margin, 274, 380, 1)];
    sep1.boxType = NSBoxSeparator;
    [cv addSubview:sep1];

    // Checkbox: use IBM 3270 font
    _use3270FontCheckbox = [NSButton checkboxWithTitle:@"Use IBM 3270 font (by Ricardo Bánffy)"
                                                target:self
                                                action:@selector(fontCheckboxChanged:)];
    _use3270FontCheckbox.frame = NSMakeRect(margin, 246, 380, 22);
    BOOL currentValue = [[NSUserDefaults standardUserDefaults] boolForKey:kPref3270FontEnabled];
    _use3270FontCheckbox.state = currentValue ? NSControlStateValueOn : NSControlStateValueOff;
    [cv addSubview:_use3270FontCheckbox];

    // Descriptive note
    NSTextField *note = [NSTextField wrappingLabelWithString:
        @"Replaces the default Menlo font with the authentic IBM 3270 monospace font. "
         "The font is bundled with this app and designed to match the look of original "
         "IBM 3270 terminals."];
    note.textColor = [NSColor secondaryLabelColor];
    note.font = [NSFont systemFontOfSize:11];
    note.frame = NSMakeRect(margin + 18, 196, 362, 44);
    [cv addSubview:note];

    // Attribution link
    NSMutableAttributedString *linkTitle = [[NSMutableAttributedString alloc]
        initWithString:@"3270font on GitHub (github.com/rbanffy/3270font)"
            attributes:@{
                NSFontAttributeName:            [NSFont systemFontOfSize:11],
                NSForegroundColorAttributeName: [NSColor linkColor],
            }];
    NSButton *linkBtn = [[NSButton alloc] initWithFrame:NSMakeRect(margin + 18, 178, 362, 18)];
    [linkBtn setAttributedTitle:linkTitle];
    linkBtn.buttonType = NSButtonTypeMomentaryLight;
    linkBtn.bordered = NO;
    linkBtn.target = self;
    linkBtn.action = @selector(open3270FontLink:);
    linkBtn.alignment = NSTextAlignmentLeft;
    [cv addSubview:linkBtn];

    // ── Section: Compatibility ────────────────────────────────────────────────
    NSTextField *compatHeader = [NSTextField labelWithString:@"Compatibility"];
    compatHeader.font = [NSFont boldSystemFontOfSize:13];
    compatHeader.frame = NSMakeRect(margin, 144, 380, 20);
    [cv addSubview:compatHeader];

    NSBox *sep2 = [[NSBox alloc] initWithFrame:NSMakeRect(margin, 138, 380, 1)];
    sep2.boxType = NSBoxSeparator;
    [cv addSubview:sep2];

    _herculesBracketsCheckbox = [NSButton checkboxWithTitle:@"Display EBCDIC 0xAD/0xBD as [ ] (Hercules MVS-TK5)"
                                                     target:self
                                                     action:@selector(herculesBracketsChanged:)];
    _herculesBracketsCheckbox.frame = NSMakeRect(margin, 110, 380, 22);
    BOOL bracketsValue = [[NSUserDefaults standardUserDefaults] boolForKey:kPrefHerculesBrackets];
    _herculesBracketsCheckbox.state = bracketsValue ? NSControlStateValueOn : NSControlStateValueOff;
    [cv addSubview:_herculesBracketsCheckbox];

    NSTextField *compatNote = [NSTextField wrappingLabelWithString:
        @"Some Hercules-hosted MVS systems (e.g. TK5) store the CP1047 bracket bytes "
         "(0xAD, 0xBD) inside an otherwise CP037 stream, which would otherwise display "
         "as ¡ and ¨. Enable this to render — and transmit — them as [ and ]."];
    compatNote.textColor = [NSColor secondaryLabelColor];
    compatNote.font = [NSFont systemFontOfSize:11];
    compatNote.frame = NSMakeRect(margin + 18, 50, 362, 56);
    [cv addSubview:compatNote];

    // ── Footer ────────────────────────────────────────────────────────────────
    NSBox *sep3 = [[NSBox alloc] initWithFrame:NSMakeRect(margin, 36, 380, 1)];
    sep3.boxType = NSBoxSeparator;
    [cv addSubview:sep3];

    NSTextField *futureLbl = [NSTextField wrappingLabelWithString:
        @"More options coming: colour scheme, code page defaults, keyboard mapping."];
    futureLbl.textColor = [NSColor tertiaryLabelColor];
    futureLbl.font = [NSFont systemFontOfSize:10];
    futureLbl.frame = NSMakeRect(margin, 12, 380, 18);
    [cv addSubview:futureLbl];
}

// ── Actions ───────────────────────────────────────────────────────────────────

- (void)fontCheckboxChanged:(NSButton *)sender {
    BOOL enabled = (sender.state == NSControlStateValueOn);
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:kPref3270FontEnabled];
    // NSUserDefaultsDidChangeNotification is posted automatically; TerminalView observes it.
}

- (void)herculesBracketsChanged:(NSButton *)sender {
    BOOL enabled = (sender.state == NSControlStateValueOn);
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:kPrefHerculesBrackets];
}

- (void)open3270FontLink:(id)sender {
    [[NSWorkspace sharedWorkspace]
        openURL:[NSURL URLWithString:@"https://github.com/rbanffy/3270font"]];
}

@end
