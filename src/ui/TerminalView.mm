#import "TerminalView.h"
#import <CoreText/CoreText.h>
#import <CoreGraphics/CoreGraphics.h>
#include "EbcdicCodec.h"
#include "GraphicsBuffer.h"
#include <string>

/// NSUserDefaults key – BOOL; YES = use bundled IBM 3270 font
NSString * const kPref3270FontEnabled = @"use3270Font";

// ── 3270-font loader (called once) ───────────────────────────────────────────
// Registers all three weight variants from the app bundle's Resources/fonts/
// folder with Core Text so they can be loaded by name.
static void register3270FontsIfNeeded(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSArray<NSString*> *names = @[
            @"3270-Regular",
            @"3270SemiCondensed-Regular",
            @"3270Condensed-Regular",
        ];
        NSBundle *bundle = [NSBundle mainBundle];
        for (NSString *name in names) {
            NSURL *url = [bundle URLForResource:name
                                  withExtension:@"otf"
                                   subdirectory:@"fonts"];
            if (!url) continue;
            CFErrorRef err = NULL;
            CTFontManagerRegisterFontsForURL((__bridge CFURLRef)url,
                                             kCTFontManagerScopeProcess,
                                             &err);
            if (err) { CFRelease(err); }
        }
    });
}

static const int kOIARows = 2;

// ── IBM 3279 extended colour palette ─────────────────────────────────────────
// Maps the 3270 extended attribute colour code (0xF1-0xF7) to an NSColor.
// Returns nil for unknown/default codes; caller uses the field-attribute default.
static NSColor *colorFor3270Code(uint8_t code) {
    switch (code) {
    case 0xF1: return [NSColor colorWithRed:0.22 green:0.52 blue:1.00 alpha:1.0]; // blue
    case 0xF2: return [NSColor colorWithRed:1.00 green:0.33 blue:0.33 alpha:1.0]; // red
    case 0xF3: return [NSColor colorWithRed:1.00 green:0.44 blue:1.00 alpha:1.0]; // pink/magenta
    case 0xF4: return [NSColor colorWithRed:0.20 green:0.85 blue:0.20 alpha:1.0]; // green
    case 0xF5: return [NSColor colorWithRed:0.20 green:0.85 blue:0.85 alpha:1.0]; // turquoise/cyan
    case 0xF6: return [NSColor colorWithRed:0.85 green:0.85 blue:0.20 alpha:1.0]; // yellow
    case 0xF7: return [NSColor colorWithRed:0.85 green:0.85 blue:0.85 alpha:1.0]; // neutral white
    default:   return nil;
    }
}

// IBM 5250 display attribute decoding (per IBM 5250 Functions Reference,
// SA21-9247, §15 "Display Attributes").  Each attribute byte 0x20-0x3F
// encodes a base colour plus modifier flags (reverse, underline, blink,
// non-display, column-separator).  The full 32-entry table:
//
//   0x20 Green                 0x30 Turquoise/CS
//   0x21 Green RI              0x31 Turquoise/CS RI
//   0x22 White                 0x32 Yellow/CS
//   0x23 White RI              0x33 Yellow/CS RI
//   0x24 Green UL              0x34 Turquoise UL
//   0x25 Green UL RI           0x35 Turquoise UL RI
//   0x26 White UL              0x36 Yellow UL
//   0x27 Non-display           0x37 Non-display
//   0x28 Red                   0x38 Pink
//   0x29 Red RI                0x39 Pink RI
//   0x2A Red UL                0x3A Blue
//   0x2B Red UL RI             0x3B Blue RI
//   0x2C Red RI BL             0x3C Pink UL
//   0x2D Red BL                0x3D Pink UL RI
//   0x2E Red UL BL             0x3E Blue UL
//   0x2F Non-display           0x3F Non-display

typedef NS_OPTIONS(uint8_t, X5250Modifier) {
    X5250ModNone      = 0,
    X5250ModReverse   = 1 << 0,
    X5250ModUnderline = 1 << 1,
    X5250ModBlink     = 1 << 2,
    X5250ModNonDisp   = 1 << 3,
    X5250ModColSep    = 1 << 4,
};

typedef NS_ENUM(uint8_t, X5250Color) {
    X5250ColorGreen,
    X5250ColorWhite,
    X5250ColorRed,
    X5250ColorTurquoise,
    X5250ColorYellow,
    X5250ColorPink,
    X5250ColorBlue,
};

static void decode5250Attr(uint8_t attr, X5250Color *outColor, uint8_t *outMod) {
    static const struct { X5250Color color; uint8_t mod; } kTable[32] = {
        /*0x20*/ { X5250ColorGreen,     X5250ModNone },
        /*0x21*/ { X5250ColorGreen,     X5250ModReverse },
        /*0x22*/ { X5250ColorWhite,     X5250ModNone },
        /*0x23*/ { X5250ColorWhite,     X5250ModReverse },
        /*0x24*/ { X5250ColorGreen,     X5250ModUnderline },
        /*0x25*/ { X5250ColorGreen,     X5250ModUnderline | X5250ModReverse },
        /*0x26*/ { X5250ColorWhite,     X5250ModUnderline },
        /*0x27*/ { X5250ColorGreen,     X5250ModNonDisp },
        /*0x28*/ { X5250ColorRed,       X5250ModNone },
        /*0x29*/ { X5250ColorRed,       X5250ModReverse },
        /*0x2A*/ { X5250ColorRed,       X5250ModUnderline },
        /*0x2B*/ { X5250ColorRed,       X5250ModUnderline | X5250ModReverse },
        /*0x2C*/ { X5250ColorRed,       X5250ModReverse | X5250ModBlink },
        /*0x2D*/ { X5250ColorRed,       X5250ModBlink },
        /*0x2E*/ { X5250ColorRed,       X5250ModUnderline | X5250ModBlink },
        /*0x2F*/ { X5250ColorGreen,     X5250ModNonDisp },
        /*0x30*/ { X5250ColorTurquoise, X5250ModColSep },
        /*0x31*/ { X5250ColorTurquoise, X5250ModColSep | X5250ModReverse },
        /*0x32*/ { X5250ColorYellow,    X5250ModColSep },
        /*0x33*/ { X5250ColorYellow,    X5250ModColSep | X5250ModReverse },
        /*0x34*/ { X5250ColorTurquoise, X5250ModUnderline },
        /*0x35*/ { X5250ColorTurquoise, X5250ModUnderline | X5250ModReverse },
        /*0x36*/ { X5250ColorYellow,    X5250ModUnderline },
        /*0x37*/ { X5250ColorGreen,     X5250ModNonDisp },
        /*0x38*/ { X5250ColorPink,      X5250ModNone },
        /*0x39*/ { X5250ColorPink,      X5250ModReverse },
        /*0x3A*/ { X5250ColorBlue,      X5250ModNone },
        /*0x3B*/ { X5250ColorBlue,      X5250ModReverse },
        /*0x3C*/ { X5250ColorPink,      X5250ModUnderline },
        /*0x3D*/ { X5250ColorPink,      X5250ModUnderline | X5250ModReverse },
        /*0x3E*/ { X5250ColorBlue,      X5250ModUnderline },
        /*0x3F*/ { X5250ColorGreen,     X5250ModNonDisp },
    };
    uint8_t idx = (attr - 0x20) & 0x1F;
    if (outColor) *outColor = kTable[idx].color;
    if (outMod)   *outMod   = kTable[idx].mod;
}

static NSColor *colorFor5250Attr(uint8_t attr) {
    X5250Color c;
    decode5250Attr(attr, &c, NULL);
    switch (c) {
    case X5250ColorGreen:     return [NSColor colorWithRed:0.20 green:0.85 blue:0.20 alpha:1.0];
    case X5250ColorWhite:     return [NSColor colorWithRed:0.85 green:0.85 blue:0.85 alpha:1.0];
    case X5250ColorRed:       return [NSColor colorWithRed:1.00 green:0.33 blue:0.33 alpha:1.0];
    case X5250ColorTurquoise: return [NSColor colorWithRed:0.20 green:0.85 blue:0.85 alpha:1.0];
    case X5250ColorYellow:    return [NSColor colorWithRed:0.95 green:0.95 blue:0.30 alpha:1.0];
    case X5250ColorPink:      return [NSColor colorWithRed:1.00 green:0.44 blue:1.00 alpha:1.0];
    case X5250ColorBlue:      return [NSColor colorWithRed:0.22 green:0.52 blue:1.00 alpha:1.0];
    }
    return [NSColor colorWithRed:0.20 green:0.85 blue:0.20 alpha:1.0];
}

@implementation TerminalView {
    x3270::ScreenBuffer*      _screen;
    x3270::KeyboardState*     _kbd;     // TN3270 keyboard (nil in 5250 mode)
    x3270::KeyboardState5250* _kbd5250; // TN5250 keyboard (nil in 3270 mode)
    x3270::GraphicsBuffer*    _graphics;   // GOCA drawing command list (3270 only)
    x3270::EbcdicCodec        _codec;

    NSTimer* _cursorTimer;
    BOOL     _cursorVisible;

    int      _rows;    // character grid rows (mirrors _screen->rows())
    int      _cols;    // character grid cols (mirrors _screen->cols())
    CGFloat  _charW;   // character cell width
    CGFloat  _charH;   // character cell height (ascent + descent + leading)
    CGFloat  _baseline; // distance from cell bottom to text baseline
}

- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _codec = x3270::EbcdicCodec(x3270::CodePage::CP037);
        _cursorVisible = YES;
        _rows = 24;  // default; updated when screen buffer is attached
        _cols = 80;

        // Register the bundled 3270 font variants with Core Text (once per process)
        register3270FontsIfNeeded();

        // Default 3270 colour palette (matches IBM 3279 standard defaults)
        _foregroundColor  = [NSColor colorWithRed:0.20 green:0.85 blue:0.20 alpha:1.0]; // green (unprotected normal)
        _backgroundColor  = [NSColor colorWithRed:0.0  green:0.0  blue:0.0  alpha:1.0]; // black
        _intensifiedColor = [NSColor colorWithRed:1.00 green:0.33 blue:0.33 alpha:1.0]; // red  (unprotected intensified)
        _cursorColor      = [NSColor colorWithRed:0.20 green:0.85 blue:0.20 alpha:1.0]; // green

        [self applyFontFromPreferences];
        [self recalcCellSize];

        _cursorTimer = [NSTimer scheduledTimerWithTimeInterval:0.6
                                                        target:self
                                                      selector:@selector(blinkCursor:)
                                                      userInfo:nil
                                                       repeats:YES];

        // React to preference changes made in the Preferences window
        [[NSNotificationCenter defaultCenter]
            addObserver:self
               selector:@selector(userDefaultsDidChange:)
                   name:NSUserDefaultsDidChangeNotification
                 object:nil];
    }
    return self;
}

// ── Font preference helpers ───────────────────────────────────────────────────

/// Pick the right NSFont based on the current kPref3270FontEnabled user default.
- (void)applyFontFromPreferences {
    BOOL use3270 = [[NSUserDefaults standardUserDefaults] boolForKey:kPref3270FontEnabled];
    if (use3270) {
        // PostScript name is "3270-Regular" (confirmed from the OTF name table)
        _terminalFont = [NSFont fontWithName:@"3270-Regular" size:16.0]
                     ?: [NSFont fontWithName:@"Menlo" size:14.0]
                     ?: [NSFont monospacedSystemFontOfSize:14.0 weight:NSFontWeightRegular];
    } else {
        _terminalFont = [NSFont fontWithName:@"Menlo" size:14.0]
                     ?: [NSFont monospacedSystemFontOfSize:14.0 weight:NSFontWeightRegular];
    }
}

- (void)userDefaultsDidChange:(NSNotification *)note {
    [self applyFontFromPreferences];
    [self recalcCellSize];
    [self setNeedsDisplay:YES];
    // Resize the window to the new preferred size (cell dimensions may have changed)
    [self.window setContentSize:[self preferredSize]];
}

- (void)dealloc {
    [_cursorTimer invalidate];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    // ARC handles object release
}

- (void)recalcCellSize {
    CTFontRef ctFont = (__bridge CTFontRef)_terminalFont;

    // Use Core Text advance width for pixel-precise grid alignment
    UniChar mChar = 'M';
    CGGlyph mGlyph;
    CTFontGetGlyphsForCharacters(ctFont, &mChar, &mGlyph, 1);
    CGSize adv;
    CTFontGetAdvancesForGlyphs(ctFont, kCTFontOrientationHorizontal, &mGlyph, &adv, 1);
    _charW = ceil(adv.width);

    CGFloat ascent  = CTFontGetAscent(ctFont);
    CGFloat descent = CTFontGetDescent(ctFont);
    CGFloat leading = CTFontGetLeading(ctFont);
    _charH    = ceil(ascent + descent + leading) + 1.0;
    _baseline = descent;
}

- (NSSize)preferredSize {
    return NSMakeSize(_charW * _cols, _charH * (_rows + kOIARows));
}

- (void)setScreenBuffer:(x3270::ScreenBuffer*)screen
          keyboardState:(x3270::KeyboardState*)kbd {
    _screen  = screen;
    _kbd     = kbd;
    _kbd5250 = nullptr;
    if (screen) {
        _rows = screen->rows();
        _cols = screen->cols();
    }
}

- (void)setScreenBuffer:(x3270::ScreenBuffer*)screen
      keyboardState5250:(x3270::KeyboardState5250*)kbd {
    _screen  = screen;
    _kbd     = nullptr;
    _kbd5250 = kbd;
    if (screen) {
        _rows = screen->rows();
        _cols = screen->cols();
    }
}

- (void)setGraphicsBuffer:(x3270::GraphicsBuffer*)graphics {
    _graphics = graphics;
}

- (void)screenDidUpdate {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self setNeedsDisplay:YES];
    });
}

- (void)graphicsDidUpdate {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self setNeedsDisplay:YES];
    });
}

- (void)blinkCursor:(NSTimer*)timer {
    _cursorVisible = !_cursorVisible;
    [self setNeedsDisplay:YES];
}

// ── Drawing ───────────────────────────────────────────────────────────────────
- (void)drawRect:(NSRect)dirtyRect {
    [_backgroundColor setFill];
    NSRectFill(self.bounds);

    if (!_screen) {
        return;
    }

    // Draw each cell
    for (int row = 0; row < _rows; ++row) {
        for (int col = 0; col < _cols; ++col) {
            int pos = row * _cols + col;
            const x3270::Cell& cell = _screen->at(pos);

            // Attribute positions are rendered as blanks (background colour only)
            if (cell.isFA) continue;

            // Skip non-display (password) fields — draw nothing
            if (cell.isNonDisplay()) continue;

            // ── Foreground colour ─────────────────────────────────────────────
            // Priority: per-cell SA extended colour > FA-attribute default colour
            NSColor *fg;
            BOOL    is5250Reverse   = NO;
            BOOL    is5250Underline = NO;
            if (_kbd5250 != nil) {
                // 5250 mode: resolve colour from the raw 5250 display attr stored in
                // the FA cell's fgColor (set by SF order parsing in DataStream5250Parser
                // and by inline attribute bytes in the data stream).
                int faIdx = _screen->findFieldStart(pos);
                uint8_t dispAttr = (faIdx >= 0) ? _screen->at(faIdx).fgColor : 0x20;
                if (dispAttr < 0x20 || dispAttr > 0x3F) dispAttr = 0x20;
                X5250Color base5250;
                uint8_t    mod5250;
                decode5250Attr(dispAttr, &base5250, &mod5250);
                // Non-display fields (password masking)
                if (mod5250 & X5250ModNonDisp) continue;
                fg = colorFor5250Attr(dispAttr);
                is5250Reverse   = (mod5250 & X5250ModReverse)   != 0;
                is5250Underline = (mod5250 & X5250ModUnderline) != 0;
            } else if (cell.fgColor != 0x00) {
                fg = colorFor3270Code(cell.fgColor) ?: _foregroundColor;
            } else {
                // DEFCOLOR_MAP: index 0-3 from protected (bit5) + intensified (bit3)
                // 0=unprotected-normal, 1=unprotected-intensified,
                // 2=protected-normal,   3=protected-intensified
                int colorIdx = ((cell.attr & 0x20) >> 4) | ((cell.attr & 0x08) >> 3);
                switch (colorIdx) {
                case 1:  fg = _intensifiedColor; break;  // red
                case 2:  fg = [NSColor colorWithRed:0.22 green:0.52 blue:1.00 alpha:1.0]; break; // blue
                case 3:  fg = [NSColor colorWithRed:0.85 green:0.85 blue:0.85 alpha:1.0]; break; // white
                default: fg = _foregroundColor; break;   // green
                }
            }

            // ── Background colour ─────────────────────────────────────────────
            NSColor *bg = (cell.bgColor != 0x00)
                ? (colorFor3270Code(cell.bgColor) ?: _backgroundColor)
                : _backgroundColor;

            // ── Reverse-video highlight (0xF2) ────────────────────────────────
            if (cell.highlight == 0xF2 || is5250Reverse) {
                NSColor *tmp = fg; fg = bg; bg = tmp;
            }

            // Cell rect (Y=0 is bottom in Cocoa)
            CGFloat cx = col * _charW;
            CGFloat cy = self.bounds.size.height - (row + 1) * _charH;

            // Fill cell background when it differs from the global background
            if (bg != _backgroundColor) {
                [bg setFill];
                NSRectFill(NSMakeRect(cx, cy, _charW, _charH));
            }

            // Draw character
            uint16_t unicode = _codec.toUnicode(cell.ch);
            if (unicode >= 0x20) {
                NSString *ch = [NSString stringWithFormat:@"%C", (unichar)unicode];
                NSDictionary *charAttrs = @{
                    NSFontAttributeName:            _terminalFont,
                    NSForegroundColorAttributeName: fg,
                };
                [ch drawAtPoint:NSMakePoint(cx, cy + _baseline) withAttributes:charAttrs];
            }

            // ── Underscore highlight (0xF4) ───────────────────────────────────
            if (cell.highlight == 0xF4 || is5250Underline) {
                [fg setStroke];
                NSBezierPath *line = [NSBezierPath bezierPath];
                [line setLineWidth:1.0];
                [line moveToPoint:NSMakePoint(cx,          cy + 1.0)];
                [line lineToPoint:NSMakePoint(cx + _charW, cy + 1.0)];
                [line stroke];
            }
        }
    }

    // Draw block cursor (always visible during blink-on phase, regardless of lock state)
    if (_cursorVisible && _screen) {
        int curPos = _screen->cursorPos();
        int curRow = curPos / _cols;
        int curCol = curPos % _cols;
        const x3270::Cell& curCell = _screen->at(curPos);
        CGFloat cx = curCol * _charW;
        CGFloat cy = self.bounds.size.height - (curRow + 1) * _charH;

        // Block cursor: fill cell with cursor colour, then re-draw character inverted
        [_cursorColor setFill];
        NSRectFill(NSMakeRect(cx, cy, _charW, _charH));

        if (!curCell.isFA && !curCell.isNonDisplay()) {
            uint16_t cunicode = _codec.toUnicode(curCell.ch);
            if (cunicode >= 0x20) {
                NSString *cch = [NSString stringWithFormat:@"%C", (unichar)cunicode];
                NSDictionary *cAttrs = @{
                    NSFontAttributeName:            _terminalFont,
                    NSForegroundColorAttributeName: _backgroundColor,
                };
                [cch drawAtPoint:NSMakePoint(cx, cy + _baseline) withAttributes:cAttrs];
            }
        }
    }

    // Draw OIA (status bar)
    [self drawOIA];

    // Draw GOCA graphics overlay (on top of text, below OIA)
    if (_graphics && !_graphics->commands().empty()) {
        CGContextRef cgctx = [[NSGraphicsContext currentContext] CGContext];
        [self drawGraphicsOverlay:cgctx];
        _graphics->clearDirty();
    }
}

// ── GOCA Graphics Overlay ─────────────────────────────────────────────────────
// Coordinate mapping:
//   GOCA device units are defined by the AW/AH values in the Usable Area Query
//   Reply: 1 x-unit = 1/9 of a character cell width, 1 y-unit = 1/12 of height.
//   The GOCA origin (0,0) is the top-left of the character area (not the OIA).
//   Cocoa Y-origin is bottom-left, so we flip Y relative to the text area height.
//
// Pixel from GOCA unit:
//   px = goca_x * (_charW / kGocaCellW)
//   py = (_rows * _charH) - goca_y * (_charH / kGocaCellH)   (Cocoa coords)
//
// The OIA rows are below the text area in Cocoa Y, so no offset is needed here
// because TerminalView reserves (kOIARows * _charH) at the very bottom and text
// rows start at y = kOIARows * _charH.  The overall view height is:
//   (_rows + kOIARows) * _charH
// Text area top (in Cocoa) = view height,  text area bottom = kOIARows * _charH.

static constexpr CGFloat kGocaCellW = 9.0;  // must match AW in buildQueryReply()
static constexpr CGFloat kGocaCellH = 12.0; // must match AH in buildQueryReply()

- (void)drawGraphicsOverlay:(CGContextRef)ctx {
    const CGFloat textAreaH = _rows * _charH;
    const CGFloat textAreaY = kOIARows * _charH; // Cocoa Y of text-area bottom edge
    const CGFloat scaleX    = _charW / kGocaCellW;
    const CGFloat scaleY    = _charH / kGocaCellH;

    // Helper lambda (C++ block) — GOCA (x,y) → Cocoa point.
    auto toPoint = [&](int16_t gx, int16_t gy) -> CGPoint {
        CGFloat px = gx * scaleX;
        CGFloat py = textAreaY + textAreaH - gy * scaleY; // flip Y
        return CGPointMake(px, py);
    };

    // Current CG stroke/fill colour (defaults to green = 0xF4).
    NSColor *currentNSColor = _foregroundColor;
    auto applyColor = [&](uint8_t code) {
        NSColor *c = (code != 0x00) ? colorFor3270Code(code) : _foregroundColor;
        if (!c) c = _foregroundColor;
        currentNSColor = c;
        CGFloat r, g, b, a;
        [c getRed:&r green:&g blue:&b alpha:&a];
        CGContextSetRGBStrokeColor(ctx, r, g, b, a);
        CGContextSetRGBFillColor(ctx,   r, g, b, a);
    };

    CGContextSetLineWidth(ctx, 1.0);
    applyColor(0x00); // set default colour

    // Accumulated line path start point (for LineTo sequences).
    CGPoint lineStart = CGPointZero;
    bool    inLinePath = false;

    for (const x3270::GocaCommand& cmd : _graphics->commands()) {

        if (std::holds_alternative<x3270::GocaSetColor>(cmd)) {
            auto& c = std::get<x3270::GocaSetColor>(cmd);
            applyColor(c.index);
            inLinePath = false;
        }

        else if (std::holds_alternative<x3270::GocaSetMix>(cmd)) {
            auto& m = std::get<x3270::GocaSetMix>(cmd);
            // 0x04 = XOR (exclusive-or); anything else = normal overpaint.
            CGContextSetBlendMode(ctx, (m.mode == 0x04) ? kCGBlendModeXOR : kCGBlendModeNormal);
        }

        else if (std::holds_alternative<x3270::GocaMoveTo>(cmd)) {
            auto& mv = std::get<x3270::GocaMoveTo>(cmd);
            lineStart   = toPoint(mv.x, mv.y);
            inLinePath  = false;
        }

        else if (std::holds_alternative<x3270::GocaLineTo>(cmd)) {
            auto& ln = std::get<x3270::GocaLineTo>(cmd);
            if (ln.pts.empty()) break;

            CGContextBeginPath(ctx);
            CGContextMoveToPoint(ctx, lineStart.x, lineStart.y);

            CGPoint last = lineStart;
            for (auto& [gx, gy] : ln.pts) {
                CGPoint dest;
                if (ln.absolute) {
                    dest = toPoint(gx, gy);
                } else {
                    dest = CGPointMake(last.x + gx * scaleX,
                                       last.y - gy * scaleY); // relative, Y already flipped
                }
                CGContextAddLineToPoint(ctx, dest.x, dest.y);
                last = dest;
            }
            CGContextStrokePath(ctx);
            lineStart  = last;
            inLinePath = false;
        }

        else if (std::holds_alternative<x3270::GocaArc>(cmd)) {
            auto& arc = std::get<x3270::GocaArc>(cmd);
            CGPoint center = toPoint(arc.cx, arc.cy);
            CGFloat radius = arc.radius * scaleX; // use X scale; assume uniform
            CGContextBeginPath(ctx);
            CGContextAddArc(ctx, center.x, center.y, radius,
                            0, static_cast<CGFloat>(2 * M_PI), 0);
            CGContextStrokePath(ctx);
            inLinePath = false;
        }

        else if (std::holds_alternative<x3270::GocaFilledRect>(cmd)) {
            auto& fr = std::get<x3270::GocaFilledRect>(cmd);
            CGPoint p1 = toPoint(fr.x1, fr.y1);
            CGPoint p2 = toPoint(fr.x2, fr.y2);
            CGFloat rx = std::min(p1.x, p2.x);
            CGFloat ry = std::min(p1.y, p2.y);
            CGFloat rw = std::abs(p2.x - p1.x);
            CGFloat rh = std::abs(p2.y - p1.y);
            CGContextFillRect(ctx, CGRectMake(rx, ry, rw, rh));
            inLinePath = false;
        }

        else if (std::holds_alternative<x3270::GocaCharString>(cmd)) {
            auto& cs = std::get<x3270::GocaCharString>(cmd);
            CGPoint pt = toPoint(cs.x, cs.y);
            NSString *str = [NSString stringWithUTF8String:cs.text.c_str()];
            if (str.length > 0) {
                CGFloat r, g, b, a;
                [currentNSColor getRed:&r green:&g blue:&b alpha:&a];
                NSDictionary *attrs = @{
                    NSFontAttributeName:            _terminalFont,
                    NSForegroundColorAttributeName: currentNSColor,
                };
                [str drawAtPoint:NSMakePoint(pt.x, pt.y) withAttributes:attrs];
            }
            inLinePath = false;
        }

        // GocaBeginSegment / GocaEndSegment — no rendering action, metadata only.
    }

    (void)inLinePath; // suppress unused-variable warning
}

- (void)drawOIA {
    CGFloat oiaY = self.bounds.size.height - (_rows + 1) * _charH;
    // Separator line
    [[NSColor colorWithWhite:0.4 alpha:1.0] setFill];
    NSRectFill(NSMakeRect(0, oiaY + _charH - 1, self.bounds.size.width, 1.0));

    NSColor *oiaColor = [NSColor colorWithWhite:0.6 alpha:1.0];
    NSDictionary *attrs = @{
        NSFontAttributeName:            _terminalFont,
        NSForegroundColorAttributeName: oiaColor,
    };

    NSString *statusStr = @"";
    if (_kbd) {
        switch (_kbd->lockReason()) {
        case x3270::KeyboardState::LockReason::None:        statusStr = @""; break;
        case x3270::KeyboardState::LockReason::Connecting:  statusStr = @"Connecting..."; break;
        case x3270::KeyboardState::LockReason::System:      statusStr = @"X SYS"; break;
        case x3270::KeyboardState::LockReason::OErr:        statusStr = @"X OERR"; break;
        }
        if (_kbd->isInsertMode()) statusStr = [statusStr stringByAppendingString:@" INS"];
    } else if (_kbd5250) {
        switch (_kbd5250->lockReason()) {
        case x3270::KeyboardState5250::LockReason::None:        statusStr = @"5250"; break;
        case x3270::KeyboardState5250::LockReason::Connecting:  statusStr = @"5250  Connecting..."; break;
        case x3270::KeyboardState5250::LockReason::System:      statusStr = @"5250  X SYS"; break;
        case x3270::KeyboardState5250::LockReason::OErr:        statusStr = @"5250  X OERR"; break;
        }
        if (_kbd5250->isInsertMode()) statusStr = [statusStr stringByAppendingString:@" INS"];
    }

    // Cursor position (1-based)
    NSString *cursorInfo = @"";
    if (_screen) {
        int pos = _screen->cursorPos();
        cursorInfo = [NSString stringWithFormat:@"%03d/%03d",
                      pos / _cols + 1, pos % _cols + 1];
    }

    CGFloat oiaTextY = oiaY + _baseline;
    [statusStr drawAtPoint:NSMakePoint(4, oiaTextY) withAttributes:attrs];
    [cursorInfo drawAtPoint:NSMakePoint(self.bounds.size.width - 80, oiaTextY) withAttributes:attrs];

    // Version string drawn dimly in the lower OIA row (does not overlap status)
    static NSString *versionStr = nil;
    static dispatch_once_t vOnce;
    dispatch_once(&vOnce, ^{
        NSDictionary *info = [[NSBundle mainBundle] infoDictionary];
        NSString *v = info[@"CFBundleShortVersionString"] ?: @"1.7.2";
        NSString *b = info[@"CFBundleVersion"] ?: @"1";
        versionStr = [NSString stringWithFormat:@"DX3270 v%@ build %@  \u2014  \u00a9 2026 Swen Skalski", v, b];
    });
    NSColor *dimColor = [NSColor colorWithWhite:0.3 alpha:1.0];
    NSDictionary *dimAttrs = @{
        NSFontAttributeName:            _terminalFont,
        NSForegroundColorAttributeName: dimColor,
    };
    NSSize vSize = [versionStr sizeWithAttributes:dimAttrs];
    CGFloat vX = floor((self.bounds.size.width - vSize.width) / 2.0);
    [versionStr drawAtPoint:NSMakePoint(vX, _baseline) withAttributes:dimAttrs];
}

// ── Key handling ──────────────────────────────────────────────────────────────
- (BOOL)acceptsFirstResponder { return YES; }

// macOS sometimes routes function-key events through performKeyEquivalent:
// instead of keyDown: (e.g. when the key overlaps with a menu key-equivalent
// lookup, or on certain keyboard layouts).  Mirror the PF-key logic here so
// those events are not silently dropped.
- (BOOL)performKeyEquivalent:(NSEvent *)event {
    if (!_kbd && !_kbd5250) return NO;

    NSUInteger modifiers = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
    // Let Cmd+Fkey pass through so app-level shortcuts (⌘Q, ⌘N …) still work.
    if (modifiers & NSEventModifierFlagCommand) return [super performKeyEquivalent:event];

    unichar key = [event.charactersIgnoringModifiers length] > 0
                  ? [event.charactersIgnoringModifiers characterAtIndex:0] : 0;
    BOOL shiftDown = (modifiers & NSEventModifierFlagShift) != 0;

    if (key >= NSF1FunctionKey && key <= NSF12FunctionKey) {
        int pfNum = (int)(key - NSF1FunctionKey + 1);
        if (shiftDown) pfNum += 12;   // Shift+F1-F12 → PF13-24
        BOOL handled = NO;
        if (_kbd)     handled = _kbd->handlePF(pfNum);
        if (_kbd5250) handled = _kbd5250->handlePFKey(pfNum);
        if (handled) [self setNeedsDisplay:YES];
        else NSBeep();
        return YES;
    }
    return [super performKeyEquivalent:event];
}

- (void)keyDown:(NSEvent *)event {
    if (!_kbd && !_kbd5250) { [super keyDown:event]; return; }

    NSUInteger modifiers = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
    BOOL altDown   = (modifiers & NSEventModifierFlagOption)  != 0;
    BOOL shiftDown = (modifiers & NSEventModifierFlagShift)   != 0;

    unichar key = [event.charactersIgnoringModifiers length] > 0
                  ? [event.charactersIgnoringModifiers characterAtIndex:0]
                  : 0;

    BOOL handled = NO;

    // ── 5250 keyboard ─────────────────────────────────────────────────────────
    if (_kbd5250) {
        if (key >= NSF1FunctionKey && key <= NSF12FunctionKey) {
            int pfNum = (int)(key - NSF1FunctionKey + 1);
            if (shiftDown) pfNum += 12;
            handled = _kbd5250->handlePFKey(pfNum);
        }
        else if (key == '\r' || key == '\n') {
            handled = _kbd5250->handleEnter();
        }
        else if (key == '\t') {
            handled = _kbd5250->handleTab(altDown);  // Alt+Tab = BackTab
        }
        else if (key == 27) {
            handled = _kbd5250->handleAttn(); // Escape = Attention in 5250
        }
        else if (key == NSPageUpFunctionKey) {
            handled = _kbd5250->handlePageUp();
        }
        else if (key == NSPageDownFunctionKey) {
            handled = _kbd5250->handlePageDown();
        }
        else if (altDown && (key == 'e' || key == 'E')) {
            handled = _kbd5250->handleEraseField();
        }
        else if (key == NSHomeFunctionKey) {
            handled = _kbd5250->handleHome();
        }
        else if (key == NSDeleteFunctionKey) {
            handled = _kbd5250->handleDelete();
        }
        else if (key == NSBackspaceCharacter || key == NSDeleteCharacter) {
            handled = _kbd5250->handleBackspace();
        }
        else if (key == NSInsertFunctionKey) {
            handled = _kbd5250->handleInsert();
        }
        else if (key == NSUpArrowFunctionKey)    { handled = _kbd5250->handleArrow(-1, 0); }
        else if (key == NSDownArrowFunctionKey)  { handled = _kbd5250->handleArrow(+1, 0); }
        else if (key == NSLeftArrowFunctionKey)  { handled = _kbd5250->handleArrow(0, -1); }
        else if (key == NSRightArrowFunctionKey) { handled = _kbd5250->handleArrow(0, +1); }
        else if (!altDown) {
            NSString *chars = event.characters;
            if (chars.length > 0) {
                unichar c = [chars characterAtIndex:0];
                if (c >= 0x20 && c < 0x80) {
                    handled = _kbd5250->handleChar(static_cast<uint8_t>(c));
                }
            }
        }

        if (handled) {
            [self setNeedsDisplay:YES];
        } else {
            if (_kbd5250->lockReason() == x3270::KeyboardState5250::LockReason::OErr) NSBeep();
        }
        return;
    }

    // ── 3270 keyboard (existing logic) ────────────────────────────────────────
    // PF keys: F1-F12 (PF1-12), Shift+F1-F12 (PF13-24)
    if (key >= NSF1FunctionKey && key <= NSF12FunctionKey) {
        int pfNum = (int)(key - NSF1FunctionKey + 1);
        if (shiftDown) pfNum += 12;
        handled = _kbd->handlePF(pfNum);
    }
    // PA keys: Alt+1, Alt+2, Alt+3
    else if (altDown && key >= '1' && key <= '3') {
        handled = _kbd->handlePA((int)(key - '0'));
    }
    // Reset: Escape
    else if (key == 27 && !altDown) {
        handled = _kbd->handleReset();
    }
    // Clear: Alt+Escape or Escape with Option
    else if (key == 27 && altDown) {
        handled = _kbd->handleClear();
    }
    // Enter
    else if (key == '\r' || key == '\n') {
        if (shiftDown) handled = _kbd->handleNewLine();
        else           handled = _kbd->handleEnter();
    }
    // Tab / BackTab (Alt+Tab = previous field; Shift+Tab is consumed by NSWindow)
    else if (key == '\t') {
        handled = _kbd->handleTab(altDown);
    }
    // Backspace
    else if (key == NSBackspaceCharacter || key == NSDeleteCharacter) {
        handled = _kbd->handleBackspace();
    }
    // Delete (forward delete)
    else if (key == NSDeleteFunctionKey) {
        handled = _kbd->handleDelete();
    }
    // Home
    else if (key == NSHomeFunctionKey) {
        handled = _kbd->handleHome();
    }
    // Arrow keys
    else if (key == NSUpArrowFunctionKey)    { handled = _kbd->handleCursorUp(); }
    else if (key == NSDownArrowFunctionKey)  { handled = _kbd->handleCursorDown(); }
    else if (key == NSLeftArrowFunctionKey)  { handled = _kbd->handleCursorLeft(); }
    else if (key == NSRightArrowFunctionKey) { handled = _kbd->handleCursorRight(); }
    // Insert mode
    else if (key == NSInsertFunctionKey) {
        _kbd->toggleInsert();
        handled = YES;
    }
    // ErEOF: Alt+Delete
    else if (altDown && key == NSDeleteFunctionKey) {
        handled = _kbd->handleEraseEOF();
    }
    // ErInput: Alt+E
    else if (altDown && (key == 'e' || key == 'E')) {
        handled = _kbd->handleEraseInput();
    }
    // Printable ASCII
    else if (!altDown) {
        NSString *chars = event.characters;
        if (chars.length > 0) {
            unichar c = [chars characterAtIndex:0];
            if (c >= 0x20 && c < 0x80) {
                handled = _kbd->handleChar(static_cast<uint8_t>(c));
            }
        }
    }

    if (handled) {
        [self setNeedsDisplay:YES];
    } else if (!handled) {
        // Play system beep on OErr
        if (_kbd && _kbd->lockReason() == x3270::KeyboardState::LockReason::OErr) {
            NSBeep();
        }
    }
}

@end
