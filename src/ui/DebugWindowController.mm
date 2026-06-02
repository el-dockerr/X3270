#import "DebugWindowController.h"
#import <AppKit/AppKit.h>
#import <float.h>
#include "EbcdicCodec.h"

static const CGFloat kFontSize = 11.0;

@implementation DebugWindowController {
    NSTextView         *_textView;
    NSFont             *_monoFont;
    NSFont             *_boldFont;
    NSDateFormatter    *_dateFmt;
    x3270::EbcdicCodec  _codec;   // used to decode EBCDIC bytes in the right column
}

// ── Initialisation ────────────────────────────────────────────────────────────

- (instancetype)init {
    NSPanel *panel = [[NSPanel alloc]
        initWithContentRect:NSMakeRect(0, 0, 940, 540)
                  styleMask:NSWindowStyleMaskTitled
                           |NSWindowStyleMaskClosable
                           |NSWindowStyleMaskResizable
                           |NSWindowStyleMaskMiniaturizable
                           |NSWindowStyleMaskUtilityWindow
                  backing:NSBackingStoreBuffered
                    defer:NO];
    panel.title = @"Traffic Monitor";
    panel.releasedWhenClosed = NO;
    [panel center];

    if ((self = [super initWithWindow:panel])) {
        _monoFont = [NSFont fontWithName:@"Menlo" size:kFontSize]
                 ?: [NSFont monospacedSystemFontOfSize:kFontSize
                                               weight:NSFontWeightRegular];
        _boldFont = [[NSFontManager sharedFontManager]
                         convertFont:_monoFont toHaveTrait:NSBoldFontMask]
                 ?: _monoFont;

        _dateFmt = [[NSDateFormatter alloc] init];
        _dateFmt.dateFormat = @"HH:mm:ss.SSS";

        [self buildUI];
    }
    return self;
}

- (void)buildUI {
    NSView *content = self.window.contentView;
    NSRect  cr      = content.bounds;
    const CGFloat stripH = 36.0;

    // ── Bottom button strip ───────────────────────────────────────────────────
    NSView *strip = [[NSView alloc]
        initWithFrame:NSMakeRect(0, 0, cr.size.width, stripH)];
    strip.autoresizingMask = NSViewWidthSizable;

    NSButton *clearBtn = [NSButton buttonWithTitle:@"Clear"
                                            target:self
                                            action:@selector(clearLog:)];
    clearBtn.frame = NSMakeRect(8, 6, 76, 24);
    [strip addSubview:clearBtn];

    NSButton *saveBtn = [NSButton buttonWithTitle:@"Save to File..."
                                           target:self
                                           action:@selector(saveLog:)];
    saveBtn.frame = NSMakeRect(92, 6, 120, 24);
    [strip addSubview:saveBtn];

    [content addSubview:strip];

    // ── Scroll view + text view ───────────────────────────────────────────────
    NSScrollView *sv = [[NSScrollView alloc]
        initWithFrame:NSMakeRect(0, stripH,
                                 cr.size.width,
                                 cr.size.height - stripH)];
    sv.autoresizingMask  = NSViewWidthSizable | NSViewHeightSizable;
    sv.hasVerticalScroller   = YES;
    sv.hasHorizontalScroller = YES;
    sv.autohidesScrollers    = YES;
    sv.borderType            = NSNoBorder;

    NSTextView *tv = [[NSTextView alloc]
        initWithFrame:sv.contentView.bounds];
    tv.editable           = NO;
    tv.selectable         = YES;
    tv.richText           = YES;
    tv.backgroundColor    = [NSColor colorWithWhite:0.07 alpha:1.0];
    tv.textContainerInset = NSMakeSize(6.0, 6.0);
    tv.autoresizingMask   = NSViewWidthSizable | NSViewHeightSizable;

    [tv.textContainer setWidthTracksTextView:NO];
    [tv.textContainer setContainerSize:NSMakeSize(CGFLOAT_MAX, CGFLOAT_MAX)];
    tv.maxSize = NSMakeSize(CGFLOAT_MAX, CGFLOAT_MAX);

    sv.documentView = tv;
    _textView = tv;

    [content addSubview:sv];
}

// ── Configuration ────────────────────────────────────────────────────────────

- (void)configureCodePage:(int)codePage herculesBrackets:(BOOL)hb {
    _codec.setCodePage((x3270::CodePage)codePage);
    _codec.setHerculesBrackets(hb);
}

// ── Public API (thread-safe) ──────────────────────────────────────────────────

- (void)appendBytes:(const uint8_t *)bytes
             length:(NSUInteger)length
         isOutgoing:(BOOL)isOutgoing {
    if (length == 0) return;
    NSData *copy = [NSData dataWithBytes:bytes length:length];
    BOOL tx = isOutgoing;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self _renderData:copy tx:tx];
    });
}

// ── Private rendering (main thread only) ─────────────────────────────────────

- (void)_renderData:(NSData *)data tx:(BOOL)tx {
    const uint8_t *buf = (const uint8_t *)data.bytes;
    NSUInteger     len = data.length;

    NSColor *dirColor = tx
        ? [NSColor colorWithRed:0.40 green:0.75 blue:1.00 alpha:1.0]
        : [NSColor colorWithRed:0.40 green:1.00 blue:0.55 alpha:1.0];
    NSColor *hexColor = tx
        ? [NSColor colorWithRed:0.65 green:0.85 blue:1.00 alpha:1.0]
        : [NSColor colorWithRed:0.65 green:1.00 blue:0.75 alpha:1.0];
    NSColor *ascColor = [NSColor colorWithWhite:0.42 alpha:1.0];

    NSMutableAttributedString *as = [[NSMutableAttributedString alloc] init];

    NSString *ts  = [_dateFmt stringFromDate:[NSDate date]];
    NSString *hdr = [NSString stringWithFormat:@"[%@]  %@  %lu bytes\n",
                     ts, tx ? @"TX" : @"RX", (unsigned long)len];
    [as appendAttributedString:
        [[NSAttributedString alloc] initWithString:hdr
            attributes:@{ NSFontAttributeName:            _boldFont,
                          NSForegroundColorAttributeName: dirColor }]];

    for (NSUInteger offset = 0; offset < len; offset += 16) {
        NSUInteger rowLen = MIN((NSUInteger)16, len - offset);

        NSMutableString *hexPart = [NSMutableString stringWithString:@"  "];
        NSMutableString *ascPart = [NSMutableString string];

        for (NSUInteger j = 0; j < 16; j++) {
            if (j == 8) [hexPart appendString:@" "];
            if (j < rowLen) {
                uint8_t b = buf[offset + j];
                [hexPart appendFormat:@"%02X ", b];
                uint16_t u = _codec.toUnicode(b);
                [ascPart appendString:(u >= 0x20 && u != 0x7F)
                    ? [NSString stringWithFormat:@"%C", u]
                    : @"."];
            } else {
                [hexPart appendString:@"   "];
                [ascPart appendString:@" "];
            }
        }

        [as appendAttributedString:
            [[NSAttributedString alloc] initWithString:hexPart
                attributes:@{ NSFontAttributeName:            _monoFont,
                              NSForegroundColorAttributeName: hexColor }]];

        NSString *ascLine = [NSString stringWithFormat:@" %@\n", ascPart];
        [as appendAttributedString:
            [[NSAttributedString alloc] initWithString:ascLine
                attributes:@{ NSFontAttributeName:            _monoFont,
                              NSForegroundColorAttributeName: ascColor }]];
    }

    [as appendAttributedString:
        [[NSAttributedString alloc] initWithString:@"\n"
            attributes:@{ NSFontAttributeName:            _monoFont,
                          NSForegroundColorAttributeName: [NSColor clearColor] }]];

    NSTextStorage *ts2 = _textView.textStorage;
    [ts2 beginEditing];
    [ts2 appendAttributedString:as];
    [ts2 endEditing];

    NSScrollView *sv = _textView.enclosingScrollView;
    NSClipView   *cv = sv.contentView;
    CGFloat maxY = _textView.frame.size.height - cv.bounds.size.height;
    if (cv.bounds.origin.y >= maxY - 20.0) {
        [_textView scrollToEndOfDocument:nil];
    }
}

// ── Actions ───────────────────────────────────────────────────────────────────

- (void)clearLog:(id)sender {
    [_textView.textStorage
        setAttributedString:[[NSAttributedString alloc] initWithString:@""]];
}

- (void)saveLog:(id)sender {
    NSSavePanel *sp         = [NSSavePanel savePanel];
    sp.title                = @"Save Traffic Log";
    sp.nameFieldStringValue = @"tn3270-traffic.log";
    sp.allowedFileTypes     = @[@"log", @"txt"];

    [sp beginSheetModalForWindow:self.window
               completionHandler:^(NSModalResponse result) {
        if (result != NSModalResponseOK) return;
        NSString *text = self->_textView.textStorage.string;
        NSError  *err  = nil;
        [text writeToURL:sp.URL
              atomically:YES
                encoding:NSUTF8StringEncoding
                   error:&err];
        if (err) {
            NSAlert *alert        = [[NSAlert alloc] init];
            alert.messageText     = @"Save Failed";
            alert.informativeText = err.localizedDescription;
            [alert runModal];
        }
    }];
}

@end
