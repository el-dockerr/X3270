#import "ConnectionWindowController.h"
#import "TerminalWindowController.h"
#include "TerminalModel.h"
#include "TerminalProtocol.h"

@implementation ConnectionWindowController {
    NSComboBox     *_hostCombo;
    NSTextField    *_portField;
    NSButton       *_sslCheckbox;
    // Below existing variables like _sslCheckbox
    NSButton       *_verifyCertCheckbox;
    NSTextField    *_caField;
    NSPopUpButton  *_codePagePopup;
    NSPopUpButton  *_modelPopup;
    NSPopUpButton  *_protocolPopup;
    NSButton       *_connectButton;
    NSTextField    *_statusLabel;
    NSButton       *_donateBtn;

    NSMutableArray<TerminalWindowController*>  *_terminals;
    NSMutableArray<NSDictionary*>              *_connectionHistory;
}

- (instancetype)init {
    NSWindow *win = [[NSWindow alloc]
                     initWithContentRect:NSMakeRect(0, 0, 420, 444)
                               styleMask:NSWindowStyleMaskTitled
                                        |NSWindowStyleMaskClosable
                                        |NSWindowStyleMaskMiniaturizable
                               backing:NSBackingStoreBuffered
                                  defer:NO];
    win.title = @"DX3270 — Connect to Host";
    win.releasedWhenClosed = NO;
    [win center];

    if ((self = [super initWithWindow:win])) {
        _terminals = [NSMutableArray array];
        [self buildUI];
        [self restoreConnectionHistory];
        [self applyBirthdayEasterEggIfNeeded];
    }
    return self;
}

- (void)buildUI {
    NSView *cv = self.window.contentView;
    CGFloat margin = 20;
    CGFloat hdrW = 380;
    CGFloat labelW = 100, fieldW = 240, rowH = 24, gap = 10;
    __block CGFloat curY = 304;

    // ── Header: app name, version and author ──────────────────────────────────
    NSString *version = NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"] ?: @"1.7.5";

    NSTextField *appName = [NSTextField labelWithString:@"DX3270"];
    appName.font = [NSFont boldSystemFontOfSize:16];
    appName.alignment = NSTextAlignmentCenter;
    appName.frame = NSMakeRect(margin, 408, hdrW, 24);
    [cv addSubview:appName];

    NSTextField *appSubtitle = [NSTextField labelWithString:
        [NSString stringWithFormat:@"TN3270 / 5250 Terminal Emulator  \u2013  v%@", version]];
    appSubtitle.font = [NSFont systemFontOfSize:11];
    appSubtitle.textColor = [NSColor secondaryLabelColor];
    appSubtitle.alignment = NSTextAlignmentCenter;
    appSubtitle.frame = NSMakeRect(margin, 388, hdrW, 16);
    [cv addSubview:appSubtitle];

    NSMutableAttributedString *linkTitle = [[NSMutableAttributedString alloc]
        initWithString:@"by Swen Kalski  \u00b7  github.com/el-dockerr/X3270"
            attributes:@{
                NSFontAttributeName: [NSFont systemFontOfSize:11],
                NSForegroundColorAttributeName: [NSColor linkColor],
            }];
    NSButton *linkBtn = [[NSButton alloc] initWithFrame:NSMakeRect(margin, 366, hdrW, 18)];
    [linkBtn setAttributedTitle:linkTitle];
    linkBtn.buttonType = NSButtonTypeMomentaryLight;
    linkBtn.bordered = NO;
    linkBtn.target = self;
    linkBtn.action = @selector(openGitHub:);
    linkBtn.alignment = NSTextAlignmentCenter;
    [cv addSubview:linkBtn];

    // Donation link
    NSMutableAttributedString *donateTitle = [[NSMutableAttributedString alloc]
        initWithString:@"\u2665  Support this project — Buy me a coffee"
            attributes:@{
                NSFontAttributeName: [NSFont systemFontOfSize:11],
                NSForegroundColorAttributeName: [NSColor systemPinkColor],
            }];
    _donateBtn = [[NSButton alloc] initWithFrame:NSMakeRect(margin, 346, hdrW, 16)];
    [_donateBtn setAttributedTitle:donateTitle];
    _donateBtn.buttonType = NSButtonTypeMomentaryLight;
    _donateBtn.bordered = NO;
    _donateBtn.target = self;
    _donateBtn.action = @selector(openDonation:);
    _donateBtn.alignment = NSTextAlignmentCenter;
    [cv addSubview:_donateBtn];

    NSBox *separator = [[NSBox alloc] initWithFrame:NSMakeRect(margin, 332, hdrW, 1)];
    separator.boxType = NSBoxSeparator;
    [cv addSubview:separator];

    // ── Helper block ──────────────────────────────────────────────────────────
    void(^addRow)(NSString*, NSView*) = ^(NSString *label, NSView *field) {
        NSTextField *lbl = [NSTextField labelWithString:label];
        lbl.frame = NSMakeRect(margin, curY, labelW, rowH);
        lbl.alignment = NSTextAlignmentRight;
        [cv addSubview:lbl];

        field.frame = NSMakeRect(margin + labelW + gap, curY, fieldW, rowH);
        [cv addSubview:field];
        curY -= rowH + gap;
    };

    // Protocol selection
    _protocolPopup = [[NSPopUpButton alloc] init];
    [_protocolPopup addItemsWithTitles:@[
        @"TN3270  —  Mainframe (z/OS)",
        @"TN5250  —  Midrange (IBM i / AS400)",
    ]];
    [_protocolPopup setTarget:self];
    [_protocolPopup setAction:@selector(protocolChanged:)];
    addRow(@"Protocol:", _protocolPopup);

    // Host — editable combo with connection history
    _hostCombo = [[NSComboBox alloc] init];
    _hostCombo.placeholderString = @"hostname or IP";
    _hostCombo.completes = YES;
    _hostCombo.numberOfVisibleItems = 10;
    _hostCombo.delegate = self;
    addRow(@"Host:", _hostCombo);

    // Port
    _portField = [NSTextField textFieldWithString:@"23"];
    _portField.placeholderString = @"23";
    addRow(@"Port:", _portField);

    // SSL
    _sslCheckbox = [NSButton checkboxWithTitle:@"Use SSL/TLS (port 992)"
                                        target:self
                                        action:@selector(sslToggled:)];
    _sslCheckbox.frame = NSMakeRect(margin + labelW + gap, curY, fieldW, rowH);
    [cv addSubview:_sslCheckbox];
    curY -= rowH + gap;

    // Insert the new checkbox for certificate verification HERE
    _verifyCertCheckbox = [NSButton checkboxWithTitle:@"Verify SSL Certificate"
                                           target:self
                                           action:nil]; // No immediate action needed
    _verifyCertCheckbox.frame = NSMakeRect(margin + labelW + gap, curY, fieldW, rowH);
    _verifyCertCheckbox.state = NSControlStateValueOn; // Enabled by default for security
    [cv addSubview:_verifyCertCheckbox];
    curY -= rowH + gap;

    // CA Bundle (hidden by default)
    _caField = [NSTextField textFieldWithString:@""];
    _caField.placeholderString = @"(optional) path to CA bundle .pem";
    _caField.hidden = YES;
    addRow(@"CA Bundle:", _caField);

    // Code page
    _codePagePopup = [[NSPopUpButton alloc] init];
    [_codePagePopup addItemsWithTitles:@[@"CP037 (US/Canada)", @"CP500 (International)", @"CP1047 (Open Systems)"]];
    addRow(@"Code Page:", _codePagePopup);

    // Screen model
    _modelPopup = [[NSPopUpButton alloc] init];
    [_modelPopup addItemsWithTitles:@[
        @"Model 2 \u2014 24\u00d780 (default)",
        @"Model 3 \u2014 32\u00d780",
        @"Model 4 \u2014 43\u00d780",
        @"Model 5 \u2014 27\u00d7132 (wide)",
        @"Large \u2014 62\u00d7160 (non-standard)",
    ]];
    addRow(@"Screen Model:", _modelPopup);

    // Status label
    _statusLabel = [NSTextField labelWithString:@""];
    _statusLabel.textColor = [NSColor systemRedColor];
    _statusLabel.frame = NSMakeRect(margin, curY, 380, rowH);
    [cv addSubview:_statusLabel];
    curY -= rowH + gap;

    // Connect button
    _connectButton = [NSButton buttonWithTitle:@"Connect"
                                        target:self
                                        action:@selector(connect:)];
    _connectButton.bezelStyle = NSBezelStyleRounded;
    _connectButton.frame = NSMakeRect(self.window.contentView.bounds.size.width - 120 - margin,
                                       12, 120, 32);
    [cv addSubview:_connectButton];
    self.window.defaultButtonCell = _connectButton.cell;
}

- (void)openGitHub:(id)sender {
    [[NSWorkspace sharedWorkspace] openURL:
        [NSURL URLWithString:@"https://github.com/el-dockerr/X3270"]];
}

- (void)openDonation:(id)sender {
    [[NSWorkspace sharedWorkspace] openURL:
        [NSURL URLWithString:@"https://buy.stripe.com/7sY9AT3VMfKi53942m3VC05"]];
}

- (void)applyBirthdayEasterEggIfNeeded {
    NSDateComponents *today = [[NSCalendar currentCalendar]
        components:NSCalendarUnitMonth | NSCalendarUnitDay
          fromDate:[NSDate date]];
    if (today.month == 6 && today.day == 21) {
        [self showBirthdayMessage];
    }
}

- (void)showBirthdayMessage {
    NSMutableAttributedString *title = [[NSMutableAttributedString alloc]
        initWithString:@"\U0001F382  Today is Swen's birthday — buy him a gift!"
            attributes:@{
                NSFontAttributeName: [NSFont boldSystemFontOfSize:11],
                NSForegroundColorAttributeName: [NSColor systemPinkColor],
            }];
    [_donateBtn setAttributedTitle:title];
}

- (void)protocolChanged:(id)sender {
    BOOL is5250 = (_protocolPopup.indexOfSelectedItem == 1);
    if (is5250) {
        // 5250 only supports Standard (24x80) and Wide (27x132)
        [_modelPopup removeAllItems];
        [_modelPopup addItemsWithTitles:@[
            @"Standard \u2014 24\u00d780",
            @"Wide \u2014 27\u00d7132",
        ]];
    } else {
        [_modelPopup removeAllItems];
        [_modelPopup addItemsWithTitles:@[
            @"Model 2 \u2014 24\u00d780 (default)",
            @"Model 3 \u2014 32\u00d780",
            @"Model 4 \u2014 43\u00d780",
            @"Model 5 \u2014 27\u00d7132 (wide)",
            @"Large \u2014 62\u00d7160 (non-standard)",
        ]];
    }
}

- (void)sslToggled:(id)sender {
    BOOL sslOn = _sslCheckbox.state == NSControlStateValueOn;
    _caField.hidden = !sslOn;
    _verifyCertCheckbox.enabled = sslOn; // Disable the checkbox if SSL is off
    
    if (sslOn && [_portField.stringValue isEqualToString:@"23"]) {
        _portField.stringValue = @"992";
    } else if (!sslOn && [_portField.stringValue isEqualToString:@"992"]) {
        _portField.stringValue = @"23";
    }
}

/// Split a "host:port" string — returns YES and sets *outHost/*outPort if a port was embedded.
- (BOOL)splitHostPort:(NSString *)raw intoHost:(NSString **)outHost port:(NSString **)outPort {
    // Handle IPv6 addresses like [::1]:23
    if ([raw hasPrefix:@"["] ) {
        NSRange closeBracket = [raw rangeOfString:@"]"];
        if (closeBracket.location != NSNotFound) {
            NSString *ipv6 = [raw substringWithRange:NSMakeRange(1, closeBracket.location - 1)];
            NSUInteger afterBracket = NSMaxRange(closeBracket);
            if (afterBracket < raw.length && [raw characterAtIndex:afterBracket] == ':') {
                *outHost = ipv6;
                *outPort = [raw substringFromIndex:afterBracket + 1];
                return YES;
            }
        }
        return NO;
    }
    NSRange lastColon = [raw rangeOfString:@":" options:NSBackwardsSearch];
    if (lastColon.location == NSNotFound) return NO;
    // Make sure the part after the colon looks like a port number
    NSString *portPart = [raw substringFromIndex:lastColon.location + 1];
    NSCharacterSet *digits = [NSCharacterSet decimalDigitCharacterSet];
    if ([portPart rangeOfCharacterFromSet:digits.invertedSet].location != NSNotFound) return NO;
    *outHost = [raw substringToIndex:lastColon.location];
    *outPort = portPart;
    return YES;
}

- (void)connect:(id)sender {
    NSString *raw  = [_hostCombo.stringValue stringByTrimmingCharactersInSet:
                      [NSCharacterSet whitespaceCharacterSet]];
    // Easter egg: typing Swen's birthday in the host field reveals the
    // birthday support message regardless of the current date.
    if ([raw isEqualToString:@"21.06.1979"]) {
        [self showBirthdayMessage];
        _statusLabel.stringValue = @"";
        return;
    }
    // If the user (or autocomplete) left a :port suffix in the host field, split it out.
    NSString *host = raw;
    NSString *embeddedPort = nil;
    if ([self splitHostPort:raw intoHost:&host port:&embeddedPort] && embeddedPort.length > 0) {
        _hostCombo.stringValue = host;
        _portField.stringValue = embeddedPort;
    }
    host = [host stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (host.length == 0) {
        _statusLabel.stringValue = @"Please enter a hostname.";
        return;
    }

    int port = _portField.intValue;
    if (port <= 0 || port > 65535) {
        _statusLabel.stringValue = @"Invalid port number.";
        return;
    }

    BOOL useSSL = _sslCheckbox.state == NSControlStateValueOn;
    BOOL verifyCert = _verifyCertCheckbox.state == NSControlStateValueOn; // <--- New line
    NSString *caBundle = useSSL ? _caField.stringValue : @"";

    // Map code page selection
    x3270::CodePage cp;
    switch (_codePagePopup.indexOfSelectedItem) {
    case 1:  cp = x3270::CodePage::CP500;  break;
    case 2:  cp = x3270::CodePage::CP1047; break;
    default: cp = x3270::CodePage::CP037;  break;
    }

    // Map screen model selection (5250 uses simpler mapping)
    x3270::TerminalModel model;
    BOOL is5250 = (_protocolPopup.indexOfSelectedItem == 1);
    if (is5250) {
        // 5250 model popup: 0=Standard(24x80), 1=Wide(27x132)
        model = (_modelPopup.indexOfSelectedItem == 1)
                ? x3270::TerminalModel::Model5
                : x3270::TerminalModel::Model2;
    } else {
        switch (_modelPopup.indexOfSelectedItem) {
        case 1:  model = x3270::TerminalModel::Model3;      break;
        case 2:  model = x3270::TerminalModel::Model4;      break;
        case 3:  model = x3270::TerminalModel::Model5;      break;
        case 4:  model = x3270::TerminalModel::LargeCustom; break;
        default: model = x3270::TerminalModel::Model2;      break;
        }
    }

    x3270::TerminalProtocol protocol = is5250
        ? x3270::TerminalProtocol::TN5250
        : x3270::TerminalProtocol::TN3270;

    _connectButton.enabled = NO;
    _statusLabel.stringValue = @"Connecting…";
    [self saveConnectionToHistory];

    TerminalWindowController *twc =
        [[TerminalWindowController alloc] initWithHost:host
                                                  port:(uint16_t)port
                                                useSSL:useSSL
                                                verifyCert:verifyCert
                                              caBundle:caBundle
                                             codePage:cp
                                                model:model
                                             protocol:protocol];
    [_terminals addObject:twc];
    [twc showWindow:nil];

    // Observe connection result
    __weak typeof(self) weakSelf = self;
    __weak typeof(twc)  weakTwc  = twc;
    twc.onConnectError = ^(NSString *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) s = weakSelf;
            if (s) {
                s.statusLabel.stringValue = error ?: @"Connection failed.";
                s.connectButton.enabled = YES;
                [s.terminals removeObject:weakTwc];
            }
        });
    };
    twc.onConnected = ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) s = weakSelf;
            if (s) {
                s.statusLabel.stringValue = @"";
                s.connectButton.enabled = YES;
            }
        });
    };
    twc.onClosed = ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) s = weakSelf;
            __strong typeof(weakTwc)  t = weakTwc;
            if (s && t) [s.terminals removeObject:t];
        });
    };
}

// Expose for connection result callbacks
- (NSTextField*)statusLabel { return _statusLabel; }
- (NSButton*)connectButton  { return _connectButton; }
- (NSMutableArray*)terminals { return _terminals; }

// ── Connection history persistence ───────────────────────────────────────────
static NSString * const kHistoryKey = @"x3270.connectionHistory";
static const NSInteger  kHistoryMax = 20;

/// Label shown in the drop-down for a history entry ("host:port" or "host:port [SSL]").
- (NSString *)labelForEntry:(NSDictionary *)entry {
    NSString *suffix = [entry[@"ssl"] boolValue] ? @" [SSL]" : @"";
    return [NSString stringWithFormat:@"%@:%@%@", entry[@"host"], entry[@"port"], suffix];
}

/// Rebuild combo box items from _connectionHistory.
- (void)rebuildComboItems {
    [_hostCombo removeAllItems];
    for (NSDictionary *e in _connectionHistory)
        [_hostCombo addItemWithObjectValue:[self labelForEntry:e]];
}

/// Load history and pre-fill fields from the most recent entry.
- (void)restoreConnectionHistory {
    NSArray *saved = [[NSUserDefaults standardUserDefaults] arrayForKey:kHistoryKey];
    _connectionHistory = saved ? [saved mutableCopy] : [NSMutableArray array];
    [self rebuildComboItems];
    if (_connectionHistory.count > 0) {
        NSDictionary *last = _connectionHistory[0];
        _hostCombo.stringValue  = last[@"host"] ?: @"";
        _portField.stringValue  = last[@"port"] ?: @"23";
        BOOL ssl = [last[@"ssl"] boolValue];
        _sslCheckbox.state = ssl ? NSControlStateValueOn : NSControlStateValueOff;
        _caField.hidden = !ssl;
        _caField.stringValue = last[@"ca"] ?: @"";
        NSInteger cp = [last[@"codepage"] integerValue];
        if (cp >= 0 && cp < _codePagePopup.numberOfItems)
            [_codePagePopup selectItemAtIndex:cp];
        // Restore protocol first (it may change model popup items)
        NSInteger proto = [last[@"protocol"] integerValue];
        if (proto >= 0 && proto < _protocolPopup.numberOfItems) {
            [_protocolPopup selectItemAtIndex:proto];
            [self protocolChanged:nil];
        }
        NSInteger model = [last[@"model"] integerValue];
        if (model >= 0 && model < _modelPopup.numberOfItems)
            [_modelPopup selectItemAtIndex:model];
        _verifyCertCheckbox.state = [last[@"verifyCert"] boolValue] ? NSControlStateValueOn : NSControlStateValueOff;
        _verifyCertCheckbox.enabled = [last[@"ssl"] boolValue];
    }
}

/// Push current connection to top of history; deduplicate by host:port; cap at kHistoryMax.
- (void)saveConnectionToHistory {
    NSString *raw = [_hostCombo.stringValue
                     stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    // Strip any embedded :port (defensive, in case the host field wasn't cleaned up)
    NSString *host = raw;
    NSString *embeddedPort = nil;
    if ([self splitHostPort:raw intoHost:&host port:&embeddedPort] && embeddedPort.length > 0)
        _portField.stringValue = embeddedPort;
    NSString *port = _portField.stringValue;
    BOOL      ssl  = (_sslCheckbox.state == NSControlStateValueOn);

    NSDictionary *entry = @{
        @"host":     host,
        @"port":     port,
        @"ssl":      @(ssl),
        @"ca":       _caField.stringValue ?: @"",
        @"codepage": @(_codePagePopup.indexOfSelectedItem),
        @"model":    @(_modelPopup.indexOfSelectedItem),
        @"protocol": @(_protocolPopup.indexOfSelectedItem),
        @"verifyCert": @(_verifyCertCheckbox.state == NSControlStateValueOn),
    };

    // Remove existing entry for same host:port so it moves to top
    NSString *key = [NSString stringWithFormat:@"%@:%@", host, port];
    [_connectionHistory filterUsingPredicate:[NSPredicate predicateWithBlock:
        ^BOOL(NSDictionary *e, id __unused b) {
            return ![[NSString stringWithFormat:@"%@:%@", e[@"host"], e[@"port"]]
                     isEqualToString:key];
        }]];

    [_connectionHistory insertObject:entry atIndex:0];
    if (_connectionHistory.count > kHistoryMax)
        [_connectionHistory removeLastObject];

    [[NSUserDefaults standardUserDefaults] setObject:_connectionHistory forKey:kHistoryKey];
    [self rebuildComboItems];
}

// ── NSComboBoxDelegate ────────────────────────────────────────────────────────
- (void)comboBoxSelectionDidChange:(NSNotification *)notification {
    NSInteger idx = _hostCombo.indexOfSelectedItem;
    if (idx < 0 || idx >= (NSInteger)_connectionHistory.count) return;
    NSDictionary *entry = _connectionHistory[idx];
    // Defer field update to the next run loop turn so it wins over
    // NSComboBox's internal string restoration (Cocoa quirk with completes=YES).
    NSString *host = entry[@"host"];
    NSString *port = entry[@"port"];
    dispatch_async(dispatch_get_main_queue(), ^{
        _hostCombo.stringValue = host;
        _portField.stringValue = port;
    });
    BOOL ssl = [entry[@"ssl"] boolValue];
    _sslCheckbox.state = ssl ? NSControlStateValueOn : NSControlStateValueOff;
    _caField.hidden = !ssl;
    _caField.stringValue = entry[@"ca"] ?: @"";
    NSInteger cp = [entry[@"codepage"] integerValue];
    if (cp >= 0 && cp < _codePagePopup.numberOfItems)
        [_codePagePopup selectItemAtIndex:cp];
    NSInteger proto = [entry[@"protocol"] integerValue];
    if (proto >= 0 && proto < _protocolPopup.numberOfItems) {
        [_protocolPopup selectItemAtIndex:proto];
        [self protocolChanged:nil];
    }
    NSInteger model = [entry[@"model"] integerValue];
    if (model >= 0 && model < _modelPopup.numberOfItems)
        [_modelPopup selectItemAtIndex:model];
}

@end
