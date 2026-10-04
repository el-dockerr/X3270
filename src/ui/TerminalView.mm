#import "TerminalView.h"
#import <CoreText/CoreText.h>
#import <CoreGraphics/CoreGraphics.h>
#include "EbcdicCodec.h"
#include "GraphicsBuffer.h"
#import "DataInspectorViewController.h"
#include "LogIsolatorEngine.h"
#include "../core/MacroRecorder.h"
#include "../core/MacroRunner.h"
#include "../core/MacroSerializer.h"
#import "../utils/ConfigLoader.h"
#import "TimeMachineHUDView.h"
#import "../utils/TimeMachineManager.h"
#include "../utils/VideoRecorder.h"

#include "ScreenStructuralAnalyzer.h"

#include <string>
#include <memory>

/// NSUserDefaults key – BOOL; YES = use bundled IBM 3270 font
NSString * const kPref3270FontEnabled = @"use3270Font";

/// NSUserDefaults key – BOOL; YES = render Hercules-style bracket bytes
/// (0xAD/0xBD and 0x4A/0x5A) as '[' / ']' on display. Outbound keystrokes
/// still use the canonical CP037 0xBA/0xBB so the host can store them.
NSString * const kPrefHerculesBrackets = @"herculesBrackets";

/// NSUserDefaults key – BOOL; YES = show the crosshair ruler
NSString * const kPrefCrosshairRuler = @"crosshairRuler";

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
// non-display, column-separator).
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

@interface TerminalView ()
@property (nonatomic, strong) TimeMachineHUDView *timeMachineHUD;
@property (nonatomic, assign) BOOL isTimeMachineActive;
@property (nonatomic, assign) BOOL isDiffActive;
@property (nonatomic, assign) NSInteger currentTimeMachineIndex;
@end

@implementation TerminalView {
    x3270::ScreenBuffer* _screen;
    x3270::KeyboardState* _kbd;     // TN3270 keyboard (nil in 5250 mode)
    x3270::KeyboardState5250* _kbd5250; // TN5250 keyboard (nil in 3270 mode)
    x3270::GraphicsBuffer* _graphics;   // GOCA drawing command list (3270 only)
    x3270::EbcdicCodec        _codec;

    std::unique_ptr<dx3270::ScreenStructuralAnalyzer> _analyzer; // Screen structural analyzer instance

    x3270::MacroRecorder _macroRecorder; // Macro recorder instance
    std::unique_ptr<x3270::MacroRunner> _macroRunner; // Macro runner instance
    std::unique_ptr<x3270::VideoRecorder> _videoRecorder; // Video recorder instance
    BOOL _isPendingVideoFrame; // Indicates if there is a pending video frame to be recorded

    NSTimer* _cursorTimer;
    BOOL     _cursorVisible;
    NSArray<NSDictionary *> *_panelRules;
    NSPopover *_dataInspectorPopover;

    int      _rows;    // character grid rows (mirrors _screen->rows())
    int      _cols;    // character grid cols (mirrors _screen->cols())
    CGFloat  _charW;   // character cell width
    CGFloat  _charH;   // character cell height (ascent + descent + leading)
    CGFloat  _baseline; // distance from cell bottom to text baseline
    
    int      _selStart; // Linear offset of selection start (-1 if none)
    int      _selEnd;   // Linear offset of selection end

    dx3270::LogIsolatorEngine _logIsolator;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _codec = x3270::EbcdicCodec(x3270::CodePage::CP037);
        _codec.setHerculesBrackets([[NSUserDefaults standardUserDefaults] boolForKey:kPrefHerculesBrackets]);
        _cursorVisible = YES;
        _rows = 24;  // default; updated when screen buffer is attached
        _cols = 80;

        _selStart = -1;
        _selEnd = -1;

        // Register the bundled 3270 font variants with Core Text (once per process)
        register3270FontsIfNeeded();

        // Default 3270 colour palette (matches IBM 3279 standard defaults)
        _foregroundColor  = [NSColor colorWithRed:0.20 green:0.85 blue:0.20 alpha:1.0]; // green (unprotected normal)
        _backgroundColor  = [NSColor colorWithRed:0.0  green:0.0  blue:0.0  alpha:1.0]; // black
        _intensifiedColor = [NSColor colorWithRed:1.00 green:0.33 blue:0.33 alpha:1.0]; // red  (unprotected intensified)
        _cursorColor      = [NSColor colorWithRed:0.20 green:0.85 blue:0.20 alpha:1.0]; // green
        _showCrosshairRuler = [[NSUserDefaults standardUserDefaults] boolForKey:kPrefCrosshairRuler]; // initialize from user defaults
        [self applyFontFromPreferences];
        [self recalcCellSize];

        _cursorTimer = [NSTimer scheduledTimerWithTimeInterval:0.6
                                                        target:self
                                                      selector:@selector(blinkCursor:)
                                                      userInfo:nil
                                                       repeats:YES];

        // Load context rules from JSON (Bundle + Local Overrides)
        _panelRules = [ConfigLoader loadMergedJSONNamed:@"panel_rules.json"];

        // Failsafe fallback if missing or unparseable
        if (![_panelRules isKindOfClass:[NSArray class]]) {
            _panelRules = @[
                @{@"keywords": @[@"STATUS", @"HELD", @"DISPLAY ACTIVE", @"OUTPUT DISPLAY", @"INPUT QUEUE"], @"action": @"?"},
                @{@"keywords": @[@"JOB DATA SET", @"DS DISPLAY"], @"action": @"S"}
            ];
        }

        // React to preference changes made in the Preferences window
        [[NSNotificationCenter defaultCenter]
            addObserver:self
               selector:@selector(userDefaultsDidChange:)
                   name:NSUserDefaultsDidChangeNotification
                 object:nil];
        // Initialize the current user for the log isolator engine
        NSString *currentUser = [[NSUserDefaults standardUserDefaults] stringForKey:@"DX3270_TransferUser"];
        if (!currentUser || currentUser.length == 0) {
            currentUser = @"IBMUSER"; // Or your default ID
        }
        _logIsolator.setCurrentUser([currentUser UTF8String]);
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

- (void)setCodePage:(x3270::CodePage)codePage {
    _codec.setCodePage(codePage);
    [self setNeedsDisplay:YES];
}

- (void)userDefaultsDidChange:(NSNotification *)note {
    // Save the expected size before recalculating
    NSSize oldPref = [self preferredSize];

    [self applyFontFromPreferences];
    _codec.setHerculesBrackets([[NSUserDefaults standardUserDefaults] boolForKey:kPrefHerculesBrackets]);
    [self recalcCellSize];
    [self setNeedsDisplay:YES];

    // Resize the window ONLY if the font (and therefore the grid) has changed
    NSSize newPref = [self preferredSize];
    if (!NSEqualSizes(oldPref, newPref)) {
        [self.window setContentSize:newPref];
    }
}

- (void)dealloc {
    [_cursorTimer invalidate];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewWillMoveToWindow:(NSWindow *)newWindow {
    [super viewWillMoveToWindow:newWindow];
    if (newWindow == nil) {
        // The view is being removed from the screen: stop the timer to break the retain cycle
        [_cursorTimer invalidate];
        _cursorTimer = nil;
    } else if (_cursorTimer == nil) {
        // The view becomes visible again (e.g., tab change): restart the timer
        _cursorTimer = [NSTimer scheduledTimerWithTimeInterval:0.6
                                                        target:self
                                                      selector:@selector(blinkCursor:)
                                                      userInfo:nil
                                                       repeats:YES];
    }
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
    if (_kbd) {
        _kbd->setMacroRecorder(&_macroRecorder); // Hook recorder
    }
    if (screen) {
        _rows = screen->rows();
        _cols = screen->cols();
        // Initialize the screen structural analyzer for live JSON mapping
        _analyzer = std::make_unique<dx3270::ScreenStructuralAnalyzer>(*_screen, _codec);
        _analyzer->setOnStructureUpdated([](const dx3270::ScreenStructure& structure, const std::string& json) {
            printf("\n=== [DX3270 LIVE JSON MAP - %s] ===\n%s\n===================================\n", 
                   structure.panelTitle.c_str(), json.c_str());
            fflush(stdout);
        });

    }
}

- (void)setScreenBuffer:(x3270::ScreenBuffer*)screen
      keyboardState5250:(x3270::KeyboardState5250*)kbd {
    _screen  = screen;
    _kbd     = nullptr;
    _kbd5250 = kbd;
    if (_kbd5250) {
        _kbd5250->setMacroRecorder(&_macroRecorder); // Hook recorder
    }
    if (screen) {
        _rows = screen->rows();
        _cols = screen->cols();

        // Initialize the screen structural analyzer for live JSON mapping
        _analyzer = std::make_unique<dx3270::ScreenStructuralAnalyzer>(*_screen, _codec);
        _analyzer->setOnStructureUpdated([](const dx3270::ScreenStructure& structure, const std::string& json) {
            printf("\n=== [DX3270 LIVE JSON MAP - %s] ===\n%s\n===================================\n", 
                   structure.panelTitle.c_str(), json.c_str());
            fflush(stdout);
        });
    }
}

- (void)setGraphicsBuffer:(x3270::GraphicsBuffer*)graphics {
    _graphics = graphics;
}

- (void)screenDidUpdate {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->_screen) {
            self->_rows = self->_screen->rows();
            self->_cols = self->_screen->cols();
        }
        [self captureCurrentScreenSnapshot];
        if (self->_analyzer && self->_screen) {
            self->_analyzer->analyzeCurrentScreen();
        }
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

    // --- TIME MACHINE MODE ---
    if (self.isTimeMachineActive) {
        ScreenSnapshot *snap = [[TimeMachineManager sharedManager] snapshotAtIndex:self.currentTimeMachineIndex];
        if (!snap) return;

        [_backgroundColor setFill];
        NSRectFill(self.bounds);

        NSSize pref = [self preferredSize];
        CGFloat scaleX = self.bounds.size.width / pref.width;
        CGFloat scaleY = self.bounds.size.height / pref.height;
        
        [NSGraphicsContext saveGraphicsState];
        NSAffineTransform *transform = [NSAffineTransform transform];
        [transform scaleXBy:scaleX yBy:scaleY];
        [transform concat];

        CGFloat effectiveHeight = pref.height;
        const unichar *chars = (const unichar *)snap.characterBuffer.bytes;
        const uint32_t *attrs = (const uint32_t *)snap.attributeBuffer.bytes;

        NSArray<NSNumber *> *diffMap = nil;
        if (self.isDiffActive) {
            NSInteger baselineIdx = [TimeMachineManager sharedManager].baselinePinIndex;
            
            // If there is a Baseline (Pin) set and it is valid, compare with it!
            if (baselineIdx >= 0 && baselineIdx < (NSInteger)[[TimeMachineManager sharedManager] allSnapshots].count) {
                ScreenSnapshot *baseSnap = [[TimeMachineManager sharedManager] snapshotAtIndex:baselineIdx];
                diffMap = [[TimeMachineManager sharedManager] compareSnapshot:snap withSnapshot:baseSnap];
            } 
            // Standard fallback: compare with the immediately preceding frame (N vs N-1)
            else if (self.currentTimeMachineIndex > 0) {
                ScreenSnapshot *prevSnap = [[TimeMachineManager sharedManager] snapshotAtIndex:self.currentTimeMachineIndex - 1];
                diffMap = [[TimeMachineManager sharedManager] compareSnapshot:snap withSnapshot:prevSnap];
            }
        }

        for (int row = 0; row < snap.rows; ++row) {
            for (int col = 0; col < snap.cols; ++col) {
                int pos = row * snap.cols + col;
                unichar uc = chars[pos];

                CGFloat cx = col * _charW;
                CGFloat cy = effectiveHeight - (row + 1) * _charH;

                BOOL isModified = (diffMap && (NSUInteger)pos < diffMap.count && [diffMap[pos] integerValue] == CellDiffModified);

                // Native Color for the 3270 screen
                NSColor *nativeFg = _foregroundColor;
                NSColor *bg = _backgroundColor;

                if (attrs) {
                    uint32_t packed = attrs[pos];
                    uint8_t colorType = (packed >> 16) & 0xFF;
                    uint8_t colorVal  = (packed >> 8) & 0xFF;

                    if (colorType == 1) {
                        nativeFg = colorFor3270Code(colorVal) ?: _foregroundColor;
                    } else if (colorType == 2) {
                        switch (colorVal) {
                            case 1:  nativeFg = _intensifiedColor; break;
                            case 2:  nativeFg = [NSColor colorWithRed:0.22 green:0.52 blue:1.00 alpha:1.0]; break;
                            case 3:  nativeFg = [NSColor colorWithRed:0.85 green:0.85 blue:0.85 alpha:1.0]; break;
                            default: nativeFg = _foregroundColor; break;
                        }
                    } else if (colorType == 3) {
                        nativeFg = colorFor5250Attr(colorVal);
                    }
                }

                // Diff highlighting: Dark Amber Background
                if (isModified) {
                    bg = [NSColor colorWithCalibratedRed:0.45 green:0.20 blue:0.00 alpha:0.65];
                }

                // Historical Screen Text Selection Overlay
                BOOL isSelected = NO;
                if (_selStart != -1 && _selEnd != -1) {
                    int r1 = _selStart / snap.cols, c1 = _selStart % snap.cols;
                    int r2 = _selEnd / snap.cols,   c2 = _selEnd % snap.cols;
                    int minRow = MIN(r1, r2), maxRow = MAX(r1, r2);
                    int minCol = MIN(c1, c2), maxCol = MAX(c1, c2);
                    
                    if (row >= minRow && row <= maxRow && col >= minCol && col <= maxCol) {
                        isSelected = YES;
                        bg = [NSColor selectedTextBackgroundColor];
                        nativeFg = [NSColor selectedTextColor];
                    }
                }

                // Render background if not standard black
                if (bg != _backgroundColor) {
                    [bg setFill];
                    NSRectFill(NSMakeRect(cx, cy, _charW, _charH));
                }

                if (uc > 0x20) {
                    NSString *ch = [NSString stringWithCharacters:&uc length:1];
                    NSColor *textColor = (isModified && !isSelected) ? [NSColor colorWithCalibratedRed:1.0 green:0.92 blue:0.30 alpha:1.0] : nativeFg;
                    NSDictionary *charAttrs = @{
                        NSFontAttributeName: _terminalFont,
                        NSForegroundColorAttributeName: textColor,
                    };
                    [ch drawAtPoint:NSMakePoint(cx, cy + _baseline) withAttributes:charAttrs];
                }
            }
        }

        [self drawOIA];
        [NSGraphicsContext restoreGraphicsState];
        return;
    }

    // --- LIVE STANDARD MODE ---
    [_backgroundColor setFill];
    NSRectFill(self.bounds);

    if (!_screen) {
        return;
    }

    // --- Start SCALING ---
    NSSize pref = [self preferredSize];
    CGFloat scaleX = self.bounds.size.width / pref.width;
    CGFloat scaleY = self.bounds.size.height / pref.height;
    
    [NSGraphicsContext saveGraphicsState];
    NSAffineTransform *transform = [NSAffineTransform transform];
    [transform scaleXBy:scaleX yBy:scaleY];
    [transform concat];
    
    CGFloat effectiveHeight = pref.height;
    // --- End SCALING ---

    // Draw each cell
    for (int row = 0; row < _rows; ++row) {

        // =========================================================================
        // STEP 1: Reconstruct the line and evaluate with the Isolator (BEFORE the column loop)
        // =========================================================================
        NSMutableString *lineText = [NSMutableString string];
        for (int c = 0; c < _cols; ++c) {
            const x3270::Cell& cell = _screen->at(row * _cols + c);
            uint16_t uc = _codec.toUnicode(cell.ch);
            [lineText appendFormat:@"%C", static_cast<unichar>((uc >= 0x20) ? uc : ' ')];
        }

        std::string cLineStr = [lineText UTF8String];
        _logIsolator.inspectStreamForEvents(cLineStr); // Auto-intercettazione JOBID/ASID
        dx3270::LineOwnership ownership = _logIsolator.evaluateLine(cLineStr);

        // If the mode is Strict and the line is "Foreign" (other users), skip the entire line
        if (_logIsolator.mode() == dx3270::FilterMode::Strict && ownership == dx3270::LineOwnership::Foreign) {
            continue;
        }

        for (int col = 0; col < _cols; ++col) {
            int pos = row * _cols + col;
            const x3270::Cell& cell = _screen->at(pos);

            // Attribute positions are rendered as blanks (background colour only)
            if (cell.isFA) continue;

            // Skip non-display (password) fields — draw nothing
            if (cell.isNonDisplay()) continue;

            // ── UNIFIED COLOR ENGINE (TN3270 & TN5250) ───────────────────────
            NSColor *fg = nil;
            NSColor *bg = (cell.bgColor >= 0xF1 && cell.bgColor <= 0xF7)
                ? (colorFor3270Code(cell.bgColor) ?: _backgroundColor)
                : _backgroundColor;
            
            BOOL is5250Reverse   = NO;
            BOOL is5250Underline = NO;
            
            if (_kbd5250 != nil) {
                // 1. TN5250 EMULATOR COLOR LOGIC
                int faIdx = _screen->findFieldStart(pos);
                uint8_t dispAttr = (faIdx >= 0) ? _screen->at(faIdx).fgColor : 0x20;
                if (dispAttr < 0x20 || dispAttr > 0x3F) dispAttr = 0x20;
                
                X5250Color base5250;
                uint8_t    mod5250;
                decode5250Attr(dispAttr, &base5250, &mod5250);
                
                if (mod5250 & X5250ModNonDisp) continue; 
                
                fg = colorFor5250Attr(dispAttr);
                is5250Reverse   = (mod5250 & X5250ModReverse)   != 0;
                is5250Underline = (mod5250 & X5250ModUnderline) != 0;

            } else {
                // 2. TN3270 EMULATOR COLOR LOGIC
                if (cell.fgColor >= 0xF1 && cell.fgColor <= 0xF7) {
                    fg = colorFor3270Code(cell.fgColor);
                }
                
                if (!fg) {
                    int faIdx = _screen->findFieldStart(pos);
                    uint8_t activeAttr = 0x00;
                    
                    if (faIdx >= 0) {
                        activeAttr = _screen->at(faIdx).attr;
                    } else {
                        activeAttr = cell.attr;
                    }
                    
                    BOOL isProtected   = (activeAttr & 0x20) != 0;
                    BOOL isIntensified = (activeAttr & 0x08) != 0;
                    
                    // Determine foreground color based on protection and intensity
                    if (isProtected) {
                        if (isIntensified) {
                            // Protected High-Intense (Titles ISPF/SDSF, CSR, status) -> WHITE
                            fg = [NSColor colorWithRed:0.85 green:0.85 blue:0.85 alpha:1.0];
                        } else {
                            // Protected Normal (Header of column, static text) -> BLUE
                            fg = [NSColor colorWithRed:0.22 green:0.52 blue:1.00 alpha:1.0];
                        }
                    } else {
                        if (isIntensified) {
                            // Unprotected High-Intense (Active input areas, Errors) -> RED
                            fg = _intensifiedColor;
                        } else {
                            // Unprotected Normal (Standard data, JOB rows) -> GREEN
                            fg = _foregroundColor;
                        }
                    }
                }
            }

            // ── Reverse Video Highlight (0xF2) ──────────────────────────────
            if (cell.highlight == 0xF2 || is5250Reverse) {
                NSColor *tmp = fg;
                fg = bg;
                bg = tmp;
            }

            // ── Mouse Selection Overrides (Rectangular Selection) ─────────────
            if (_selStart != -1 && _selEnd != -1) {
                int r1 = _selStart / _cols;
                int c1 = _selStart % _cols;
                int r2 = _selEnd / _cols;
                int c2 = _selEnd % _cols;
                
                int minRow = MIN(r1, r2);
                int maxRow = MAX(r1, r2);
                int minCol = MIN(c1, c2);
                int maxCol = MAX(c1, c2);
                
                // If cell is inside the selection rectangle, apply native macOS selection colors
                if (row >= minRow && row <= maxRow && col >= minCol && col <= maxCol) {
                    bg = [NSColor selectedTextBackgroundColor];
                    fg = [NSColor selectedTextColor];
                }
            }
            // =========================================================================
            // STEP 2: Noise Dimming
            // =========================================================================
            if (_logIsolator.mode() == dx3270::FilterMode::Dimming && ownership == dx3270::LineOwnership::Foreign) {
                fg = [fg colorWithAlphaComponent:0.25]; // Dim the foreground color to 25% opacity for foreign lines in Dimming mode
            }
            // Calculate pixel coordinates (Y=0 is bottom in Cocoa)
            CGFloat cx = col * _charW;
            CGFloat cy = effectiveHeight - (row + 1) * _charH;

            // Fill cell background when it differs from the global background
            if (bg != _backgroundColor) {
                [bg setFill];
                NSRectFill(NSMakeRect(cx, cy, _charW, _charH));
            }

            // ── Draw Character ────────────────────────────────────────────────
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
                [line moveToPoint:NSMakePoint(cx, cy + 1.0)];
                [line lineToPoint:NSMakePoint(cx + _charW, cy + 1.0)];
                [line stroke];
            }
        }
    }

    // ── Draw block cursor ─────────────────────────────────────────────────────
    if (_cursorVisible && _screen) {
        int curPos = _screen->cursorPos();
        int curRow = curPos / _cols;
        int curCol = curPos % _cols;
        const x3270::Cell& curCell = _screen->at(curPos);
        CGFloat cx = curCol * _charW;
        CGFloat cy = effectiveHeight - (curRow + 1) * _charH;

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

    // ── Draw OIA (status bar) ─────────────────────────────────────────────────
    [self drawOIA];

    // --- Draw Crosshair Ruler Overlay ---
    if (self.showCrosshairRuler && _screen) {
        int curPos = _screen->cursorPos();
        int curRow = curPos / _cols;
        int curCol = curPos % _cols;
        
        // Calculate the bottom-left corner of the cursor cell
        CGFloat lineX = curCol * _charW; 
        CGFloat lineY = effectiveHeight - (curRow + 1) * _charH; // Bottom margin of the row
        CGFloat textBottomY = effectiveHeight - _rows * _charH;  // Avoid covering the OIA
        
        // Red color with 40% opacity
        [[NSColor colorWithRed:1.0 green:0.2 blue:0.2 alpha:0.4] setStroke];
        NSBezierPath *ruler = [NSBezierPath bezierPath];
        [ruler setLineWidth:2.0];
        
        // Horizontal line (underline the cursor row)        
        [ruler moveToPoint:NSMakePoint(0, lineY)];
        [ruler lineToPoint:NSMakePoint(_cols * _charW, lineY)];
        
        // Vertical line (aligns with the left edge of the cursor)
        [ruler moveToPoint:NSMakePoint(lineX, effectiveHeight)];
        [ruler lineToPoint:NSMakePoint(lineX, textBottomY)];
        
        [ruler stroke];
    }

    // --- NEW: Draw Red Bounding Box for Inspected Data ---
    if (self.hasInspectedBlock && _screen) {
        [[NSColor systemRedColor] setStroke];
        NSBezierPath *box = [NSBezierPath bezierPath];
        [box setLineWidth:1.5]; // Slightly thinner because the transform will thicken it
        
        // FIX: We are currently INSIDE the NSAffineTransform block!
        // We must use the raw _charW, _charH, and effectiveHeight.
        // The graphics context will automatically stretch the box to match the text.
        CGFloat startX = self.inspectedMinCol * _charW;
        CGFloat bottomY = effectiveHeight - ((self.inspectedMaxRow + 1) * _charH);
        CGFloat width = (self.inspectedMaxCol - self.inspectedMinCol + 1) * _charW;
        CGFloat height = (self.inspectedMaxRow - self.inspectedMinRow + 1) * _charH;
        
        [box appendBezierPathWithRect:NSMakeRect(startX, bottomY, width, height)];
        [box stroke];
    }

    // ── Draw GOCA graphics overlay ────────────────────────────────────────────
    if (_graphics && !_graphics->commands().empty()) {
        CGContextRef cgctx = [[NSGraphicsContext currentContext] CGContext];
        [self drawGraphicsOverlay:cgctx];
        _graphics->clearDirty();
    }
    // Restore the graphics context at the end of the method
    [NSGraphicsContext restoreGraphicsState];
}

// ── GOCA Graphics Overlay ─────────────────────────────────────────────────────
static constexpr CGFloat kGocaCellW = 9.0;  // must match AW in buildQueryReply()
static constexpr CGFloat kGocaCellH = 12.0; // must match AH in buildQueryReply()

- (void)drawGraphicsOverlay:(CGContextRef)ctx {
    const CGFloat textAreaH = _rows * _charH;
    const CGFloat textAreaY = kOIARows * _charH; // Cocoa Y of text-area bottom edge
    const CGFloat scaleX    = _charW / kGocaCellW;
    const CGFloat scaleY    = _charH / kGocaCellH;

    auto toPoint = [&](int16_t gx, int16_t gy) -> CGPoint {
        CGFloat px = gx * scaleX;
        CGFloat py = textAreaY + textAreaH - gy * scaleY; // flip Y
        return CGPointMake(px, py);
    };

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
    }

    (void)inLinePath;
}

- (void)drawOIA {
    CGFloat effectiveHeight = [self preferredSize].height;
    CGFloat effectiveWidth  = [self preferredSize].width;
    
    CGFloat oiaY = effectiveHeight - (_rows + 1) * _charH;
    
    // Separator line
    [[NSColor colorWithWhite:0.4 alpha:1.0] setFill];
    NSRectFill(NSMakeRect(0, oiaY + _charH - 1, effectiveWidth, 1.0));

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
        if (_kbd->isInsertMode()) statusStr = [statusStr stringByAppendingString:@" ^"];
    } else if (_kbd5250) {
        switch (_kbd5250->lockReason()) {
        case x3270::KeyboardState5250::LockReason::None:        statusStr = @"5250"; break;
        case x3270::KeyboardState5250::LockReason::Connecting:  statusStr = @"5250  Connecting..."; break;
        case x3270::KeyboardState5250::LockReason::System:      statusStr = @"5250  X SYS"; break;
        case x3270::KeyboardState5250::LockReason::OErr:        statusStr = @"5250  X OERR"; break;
        }
        if (_kbd5250->isInsertMode()) statusStr = [statusStr stringByAppendingString:@" ^"];
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
    [cursorInfo drawAtPoint:NSMakePoint(effectiveWidth - 80, oiaTextY) withAttributes:attrs];

    // Version string drawn dimly in the lower OIA row (does not overlap status)
    static NSString *versionStr = nil;
    static dispatch_once_t vOnce;
    dispatch_once(&vOnce, ^{
        NSDictionary *info = [[NSBundle mainBundle] infoDictionary];
        NSString *v = info[@"CFBundleShortVersionString"] ?: @"1.7.6";
        NSString *b = info[@"CFBundleVersion"] ?: @"1";
        versionStr = [NSString stringWithFormat:@"DX3270 v%@ build %@  \u2014  \u00a9 2026 Swen Skalski", v, b];
    });
    NSColor *dimColor = [NSColor colorWithWhite:0.3 alpha:1.0];
    NSDictionary *dimAttrs = @{
        NSFontAttributeName:            _terminalFont,
        NSForegroundColorAttributeName: dimColor,
    };
    NSSize vSize = [versionStr sizeWithAttributes:dimAttrs];
    // Use the effectiveWidth to center the string relative to the terminal grid!
    CGFloat vX = floor((effectiveWidth - vSize.width) / 2.0);
    [versionStr drawAtPoint:NSMakePoint(vX, _baseline) withAttributes:dimAttrs];
}

// ── Key handling ──────────────────────────────────────────────────────────────
- (BOOL)acceptsFirstResponder { return YES; }

// macOS sometimes routes function-key events through performKeyEquivalent:
// instead of keyDown: (e.g. when the key overlaps with a menu key-equivalent
// lookup, or on certain keyboard layouts).  Mirror the PF-key logic here so
// those events are not silently dropped.
- (BOOL)performKeyEquivalent:(NSEvent *)event {
    // If the active view with focus in the window is NOT this TerminalView,
    // ignore the event to allow the active view to handle it.
    NSResponder *firstResponder = self.window.firstResponder;
    if ([firstResponder isKindOfClass:[NSView class]]) {
        NSView *focusView = (NSView *)firstResponder;
        if (focusView != self && ![focusView isDescendantOf:self]) {
            return NO;
        }
    }

    if (!_kbd && !_kbd5250) return NO;

    NSUInteger modifiers = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;

    unichar key = [event.charactersIgnoringModifiers length] > 0
                  ? [event.charactersIgnoringModifiers characterAtIndex:0] : 0;
    BOOL shiftDown = (modifiers & NSEventModifierFlagShift) != 0;

    // ⌘ + B — Toggle Bookmark / PIN in Time-Machine
    if ((modifiers & NSEventModifierFlagCommand) &&
        !(modifiers & (NSEventModifierFlagOption | NSEventModifierFlagControl | NSEventModifierFlagShift)) &&
        (key == 'b' || key == 'B')) {
        if (self.isTimeMachineActive) {
            [[TimeMachineManager sharedManager] togglePinAtIndex:self.currentTimeMachineIndex];
            [self updateHUDState];
        } else {
            [self captureCurrentScreenSnapshot];
            NSArray *snaps = [[TimeMachineManager sharedManager] allSnapshots];
            if (snaps.count > 0) {
                [[TimeMachineManager sharedManager] togglePinAtIndex:(snaps.count - 1)];
                NSBeep();
            }
        }
        return YES;
    }

    // ⌘ + ⇧ + L — Toggle Smart Log Isolator
    if ((modifiers & NSEventModifierFlagCommand) &&
        (modifiers & NSEventModifierFlagShift) &&
        (key == 'l' || key == 'L')) {
        [self toggleLogIsolatorMode];
        return YES;
    }

    // ⌘ + I — toggle insert mode
    if ((modifiers & NSEventModifierFlagCommand) &&
        !(modifiers & (NSEventModifierFlagOption | NSEventModifierFlagControl)) &&
        (key == 'i' || key == 'I')) {
        if (_kbd)          _kbd->toggleInsert();
        else if (_kbd5250) _kbd5250->handleInsert();
        [self setNeedsDisplay:YES];
        return YES;
    }

    // Let Cmd+Fkey pass through so app-level shortcuts (⌘Q, ⌘N …) still work.
    if (modifiers & NSEventModifierFlagCommand) return [super performKeyEquivalent:event];

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
        else if (key == NSInsertFunctionKey || key == NSHelpFunctionKey) {
            handled = _kbd5250->handleInsert();
        }
        else if (key == NSUpArrowFunctionKey)    { handled = _kbd5250->handleArrow(-1, 0); }
        else if (key == NSDownArrowFunctionKey)  { handled = _kbd5250->handleArrow(+1, 0); }
        else if (key == NSLeftArrowFunctionKey)  { handled = _kbd5250->handleArrow(0, -1); }
        else if (key == NSRightArrowFunctionKey) { handled = _kbd5250->handleArrow(0, +1); }
        // Fallback for all printable characters (including Option-key symbols like @, #, [, ])
        else {
            NSString *chars = event.characters;
            if (chars.length > 0) {
                unichar c = [chars characterAtIndex:0];
                if (c >= 0x20 && c != 0x7F && key < 0xF700) {
                    handled = _kbd5250->handleChar(c);
                }
            }
        }

        if (handled) {
            [self setNeedsDisplay:YES];
        } else if (_kbd5250->lockReason() == x3270::KeyboardState5250::LockReason::OErr) {
            NSBeep();
        }
        return;
    }

    // ── 3270 keyboard ─────────────────────────────────────────────────────────
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
    // Insert mode — PC Insert key or Apple Help key (MacBooks: use ⌘+I instead)
    else if (key == NSInsertFunctionKey || key == NSHelpFunctionKey) {
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
    // Fallback for all printable characters (including Option-key symbols like @, #, [, ])
    else {
        NSString *chars = event.characters;
        if (chars.length > 0) {
            unichar c = [chars characterAtIndex:0];
            if (c >= 0x20 && c != 0x7F && key < 0xF700) {
                handled = _kbd->handleChar(c);
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

// ── Mouse handling ────────────────────────────────────────────────────────────

- (int)offsetForPoint:(NSPoint)pt {
    NSSize pref = [self preferredSize];
    CGFloat scaleX = self.bounds.size.width / pref.width;
    CGFloat scaleY = self.bounds.size.height / pref.height;
    
    CGFloat realX = pt.x / scaleX;
    CGFloat realY = pt.y / scaleY;
    
    int col = (int)(realX / _charW);
    int row = (int)((pref.height - realY) / _charH);
    
    if (col < 0 || col >= _cols || row < 0 || row >= _rows) {
        return -1;
    }
    
    return (row * _cols) + col;
}

- (void)mouseDown:(NSEvent *)event {
    // 1. Pass mouse clicks over the HUD back to AppKit
    if (self.isTimeMachineActive && self.timeMachineHUD) {
        NSPoint locationInSelf = [self convertPoint:[event locationInWindow] fromView:nil];
        if (NSPointInRect(locationInSelf, self.timeMachineHUD.frame)) {
            [super mouseDown:event];
            return;
        }
    }

    // 2. Option + Shift + Click = Isolation Filter
    if (([event modifierFlags] & NSEventModifierFlagOption) && ([event modifierFlags] & NSEventModifierFlagShift)) {
        NSPoint pt = [self convertPoint:[event locationInWindow] fromView:nil];
        int offset = [self offsetForPoint:pt];
        if (offset >= 0 && _screen) {
            int row = offset / _cols;
            int col = offset % _cols;
            int startCol = col, endCol = col;
            while (startCol > 0 && _screen->at(row * _cols + (startCol - 1)).ch > 0x40) startCol--;
            while (endCol < _cols - 1 && _screen->at(row * _cols + (endCol + 1)).ch > 0x40) endCol++;
            
            NSMutableString *token = [NSMutableString string];
            for (int c = startCol; c <= endCol; c++) {
                uint16_t uc = _codec.toUnicode(_screen->at(row * _cols + c).ch);
                if (uc > 0x20) [token appendFormat:@"%C", (unichar)uc];
            }
            
            if (token.length > 0) {
                _logIsolator.setFilterPattern([token UTF8String]);
                _logIsolator.setMode(dx3270::FilterMode::Dimming);
                [self setNeedsDisplay:YES];
            }
        }
        return;
    }
    
    NSPoint pt = [self convertPoint:[event locationInWindow] fromView:nil];
    int offset = [self offsetForPoint:pt];
    
    // 3. Option + Click = Data Inspector
    if (([event modifierFlags] & NSEventModifierFlagOption) != 0 && !self.isTimeMachineActive) {
        if (offset >= 0) {
            BOOL insideSelection = (_selStart >= 0 && _selEnd >= _selStart && offset >= _selStart && offset <= _selEnd);
            if (!insideSelection) {
                if (_screen) _screen->setCursor(offset);
                _selStart = offset;
                _selEnd = offset;
                [self setNeedsDisplay:YES];
            }
            [self showDataInspectorAtOffset:offset event:event];
        }
        return;
    }

    // 4. Standard mouse text selection tracking (both LIVE and Time-Machine)
    if (offset >= 0) {
        if (!self.isTimeMachineActive && _screen) {
            _screen->setCursor(offset);
        }
        _selStart = offset;
        _selEnd = offset;
        [self setNeedsDisplay:YES];
    } else {
        _selStart = -1;
        _selEnd = -1;
        [self setNeedsDisplay:YES];
    }
}

- (void)showDataInspectorAtOffset:(int)offset event:(NSEvent *)event {
    if (!_screen) return;
    
    NSMutableData *rawBytes = [NSMutableData data];
    NSMutableString *decodedText = [NSMutableString string];
    NSMutableData *verticalHexBytes = [NSMutableData data];
    NSMutableString *verticalDecodedText = [NSMutableString string];
    
    int maxScreenSize = _rows * _cols;
    int minRow, maxRow, minCol, maxCol;
    
    // Check if the click occurred inside an active multi-character selection
    BOOL isBlockSelection = (_selStart >= 0 && _selEnd > _selStart && offset >= _selStart && offset <= _selEnd);
    
    if (isBlockSelection) {
        // Calculate the Bounding Box (Min/Max Rows and Columns)
        int r1 = _selStart / _cols;
        int c1 = _selStart % _cols;
        int r2 = _selEnd / _cols;
        int c2 = _selEnd % _cols;
        
        minRow = MIN(r1, r2);
        maxRow = MAX(r1, r2);
        minCol = MIN(c1, c2);
        maxCol = MAX(c1, c2);
    } else {
        // Smart Word Extraction: automatically expands the selection to the entire word under the cursor
        minRow = offset / _cols;
        maxRow = minRow;
        int clickCol = offset % _cols;
        
        minCol = clickCol;
        while (minCol > 0 && _screen->at(minRow * _cols + (minCol - 1)).ch > 0x40) minCol--;
        
        maxCol = clickCol;
        while (maxCol < _cols - 1 && _screen->at(minRow * _cols + (maxCol + 1)).ch > 0x40) maxCol++;
    }
    
    // --- Dynamic Bounds Cap ---
    // Cap rows to prevent UI lag on massive vertical drags
    if (maxRow - minRow > 50) maxRow = minRow + 50;
    
    // Dynamic column cap: allow selection up to the physical right edge of the current terminal grid
    int maxAllowedCol = _cols - 1;
    if (maxCol > maxAllowedCol) {
        maxCol = maxAllowedCol;
    }
    
    // Save block geometry for the red bounding box renderer
    self.hasInspectedBlock = YES;
    self.inspectedMinRow = minRow;
    self.inspectedMaxRow = maxRow;
    self.inspectedMinCol = minCol;
    self.inspectedMaxCol = maxCol;
    [self setNeedsDisplay:YES];
    
    auto hexCharToInt = [](uint16_t c) -> int {
        if (c >= '0' && c <= '9') return c - '0';
        if (c >= 'A' && c <= 'F') return c - 'A' + 10;
        if (c >= 'a' && c <= 'f') return c - 'a' + 10;
        return -1;
    };
    
    // Extract data strictly within the calculated bounding box
    for (int r = minRow; r <= maxRow; r++) {
        
        // ISPF Hex uses the bottom two rows of a block.
        // If it's a block selection, only evaluate Vertical Hex on the second-to-last row.
        BOOL canCheckVertical = (!isBlockSelection) || (r == maxRow - 1);
        
        for (int c = minCol; c <= maxCol; c++) {
            int pos = r * _cols + c;
            if (pos >= maxScreenSize) continue;
            
            // 1. Raw EBCDIC Buffer
            uint8_t byte = _screen->at(pos).ch;
            [rawBytes appendBytes:&byte length:1];
            
            // 2. Translated Text
            uint16_t uc = _codec.toUnicode(byte);
            if (uc >= 0x20) {
                [decodedText appendFormat:@"%C", (unichar)uc];
            } else {
                [decodedText appendString:@"."];
            }
            
            // 3. ISPF Vertical Hex (Strict Alignment)
            if (canCheckVertical) {
                int posBottom = pos + _cols;
                if (posBottom < maxScreenSize) {
                    uint16_t uTop = _codec.toUnicode(_screen->at(pos).ch);
                    uint16_t uBot = _codec.toUnicode(_screen->at(posBottom).ch);
                    
                    int hTop = hexCharToInt(uTop);
                    int hBot = hexCharToInt(uBot);
                    
                    if (hTop >= 0 && hBot >= 0) {
                        uint8_t vByte = (uint8_t)((hTop << 4) | hBot);
                        [verticalHexBytes appendBytes:&vByte length:1];
                        
                        uint16_t vUc = _codec.toUnicode(vByte);
                        if (vUc >= 0x20) {
                            [verticalDecodedText appendFormat:@"%C", (unichar)vUc];
                        } else {
                            [verticalDecodedText appendString:@"."];
                        }
                    } else {
                        // FIX: Append a dummy byte to maintain string alignment if parsing fails
                        uint8_t dummy = 0x00;
                        [verticalHexBytes appendBytes:&dummy length:1];
                        [verticalDecodedText appendString:@"."];
                    }
                }
            }
        }
    }
    
    // --- LOGIC BIFURCATION: Pointer Hopper vs Data Inspector ---
    
    // Clean the string from spaces and null bytes (which are translated to '.' visually)
    NSString *cleanToken = [decodedText stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@" \n\r."]];
    
    NSRegularExpression *ptrRegex = [NSRegularExpression regularExpressionWithPattern:@"^[0-9A-Fa-f]{8}$|^[0-9A-Fa-f]{16}$" options:0 error:nil];
    BOOL isPointer = (cleanToken.length > 0 && [ptrRegex firstMatchInString:cleanToken options:0 range:NSMakeRange(0, cleanToken.length)] != nil);

    if (isPointer) {
        // =========================================================
        // 1. POINTER HOPPER (Contextual Mini Popover)
        // =========================================================
        
        // Close any existing popover to reset the state safely
        if (_dataInspectorPopover && _dataInspectorPopover.isShown) {
            [_dataInspectorPopover close];
        }
        
        NSViewController *jumpVC = [[NSViewController alloc] init];
        NSView *container = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 220, 48)];
        
        NSButton *jumpBtn = [NSButton buttonWithTitle:[NSString stringWithFormat:@"Jump to (L %@)", cleanToken.uppercaseString] 
                                               target:self 
                                               action:@selector(executePointerJump:)];
        
        jumpBtn.identifier = cleanToken.uppercaseString;
        jumpBtn.bezelStyle = NSBezelStyleRounded;
        jumpBtn.image = [NSImage imageWithSystemSymbolName:@"arrow.up.forward.app" accessibilityDescription:nil];
        
        // CRITICAL FIX 1: Force the button to display both the image and the text.
        // Without this, NSPopover will crush the button into an "Image Only" square.
        jumpBtn.imagePosition = NSImageLeft;
        
        // CRITICAL FIX 2: Lock the dimensions using Auto Layout so the popover cannot shrink it.
        jumpBtn.translatesAutoresizingMaskIntoConstraints = NO;
        [container addSubview:jumpBtn];
        
        [NSLayoutConstraint activateConstraints:@[
            [jumpBtn.centerXAnchor constraintEqualToAnchor:container.centerXAnchor],
            [jumpBtn.centerYAnchor constraintEqualToAnchor:container.centerYAnchor],
            [jumpBtn.widthAnchor constraintEqualToConstant:190],
            [jumpBtn.heightAnchor constraintEqualToConstant:28]
        ]];
        
        jumpVC.view = container;
        
        // Explicitly set the preferred size so the popover knows how large to draw itself
        jumpVC.preferredContentSize = NSMakeSize(220, 48); 

        if (!_dataInspectorPopover) {
            _dataInspectorPopover = [[NSPopover alloc] init];
            _dataInspectorPopover.behavior = NSPopoverBehaviorTransient;
            _dataInspectorPopover.appearance = [NSAppearance appearanceNamed:NSAppearanceNameVibrantDark];
            
            // Use weakSelf to prevent a retain cycle that could keep the red box stuck
            __weak typeof(self) weakSelf = self;
            [[NSNotificationCenter defaultCenter] addObserverForName:NSPopoverDidCloseNotification
                                                              object:_dataInspectorPopover
                                                               queue:[NSOperationQueue mainQueue]
                                                          usingBlock:^(NSNotification * _Nonnull note) {
                weakSelf.hasInspectedBlock = NO;
                [weakSelf setNeedsDisplay:YES];
            }];
        }
        
        _dataInspectorPopover.contentViewController = jumpVC;
        _dataInspectorPopover.contentSize = NSMakeSize(220, 48);
        
        // IMPORTANT: Calculate the scaling multipliers based on the current window bounds
        NSSize prefSize = [self preferredSize];
        CGFloat scaleX = self.bounds.size.width / prefSize.width;
        CGFloat scaleY = self.bounds.size.height / prefSize.height;
        
        // Calculate the raw unscaled coordinates
        CGFloat unscaledX = self.inspectedMinCol * _charW;
        CGFloat unscaledY = prefSize.height - ((self.inspectedMaxRow + 1) * _charH);
        CGFloat unscaledW = (self.inspectedMaxCol - self.inspectedMinCol + 1) * _charW;
        CGFloat unscaledH = (self.inspectedMaxRow - self.inspectedMinRow + 1) * _charH;
        
        // Apply the affine transform scaling to the target rectangle
        // This ensures the popover anchors perfectly to the scaled text on screen
        NSRect targetRect = NSMakeRect(unscaledX * scaleX, 
                                       unscaledY * scaleY, 
                                       unscaledW * scaleX, 
                                       unscaledH * scaleY);
        
        // Dispatch asynchronously to guarantee the current mouse tracking loop finishes.
        dispatch_async(dispatch_get_main_queue(), ^{
            [self->_dataInspectorPopover showRelativeToRect:targetRect ofView:self preferredEdge:NSRectEdgeMinY];
        });
        
    } else {
        // =========================================================
        // 2. CLASSIC DATA INSPECTOR (Original NSPanel)
        // =========================================================
        DataInspectorViewController *inspector = [[DataInspectorViewController alloc] initWithRawBytes:rawBytes decodedString:decodedText verticalHex:verticalHexBytes verticalDecodedString:verticalDecodedText];
        
        static NSPanel *inspectorPanel = nil;
        if (!inspectorPanel) {
            inspectorPanel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 520, 480)
                                                        styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskUtilityWindow | NSWindowStyleMaskResizable)
                                                          backing:NSBackingStoreBuffered
                                                            defer:NO];
            inspectorPanel.title = @"Mainframe Data Inspector";
            inspectorPanel.floatingPanel = YES;
            inspectorPanel.releasedWhenClosed = NO;
            inspectorPanel.hidesOnDeactivate = NO;
            
            [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowWillCloseNotification
                                                              object:inspectorPanel
                                                               queue:[NSOperationQueue mainQueue]
                                                          usingBlock:^(NSNotification * _Nonnull note) {
                self.hasInspectedBlock = NO;
                [self setNeedsDisplay:YES];
            }];
        }
        
        inspectorPanel.contentViewController = inspector;
        
        NSPoint screenPoint = [event.window convertPointToScreen:event.locationInWindow];
        screenPoint.x += 15;
        screenPoint.y -= 15;
        
        [inspectorPanel setFrameTopLeftPoint:screenPoint];
        [inspectorPanel makeKeyAndOrderFront:nil];
    }
}

- (void)executePointerJump:(NSButton *)sender {
    NSString *cmd = [NSString stringWithFormat:@"L %@", sender.identifier];
    NSWindowController *wc = self.window.windowController;
    if ([wc respondsToSelector:@selector(executeISPFCommandLocally:)]) {
        [wc performSelector:@selector(executeISPFCommandLocally:) withObject:cmd];
    }
    [_dataInspectorPopover close];
}

- (void)mouseDragged:(NSEvent *)event {
    if (_selStart == -1) return;
    
    NSPoint pt = [self convertPoint:[event locationInWindow] fromView:nil];
    int offset = [self offsetForPoint:pt];
    
    if (offset >= 0 && offset != _selEnd) {
        _selEnd = offset;
        [self setNeedsDisplay:YES];
    }
}

- (void)mouseUp:(NSEvent *)event {
    // ── Double-Click Handler ──────────────────────────────────────────────
    if (event.clickCount == 2) {
        NSPoint pt = [self convertPoint:[event locationInWindow] fromView:nil];
        int offset = [self offsetForPoint:pt];
        
        if (offset >= 0 && _screen) {
            int row = offset / _cols;
            int col = offset % _cols;
            
            // Step A: Determine word boundaries around the clicked cell
            int startCol = col;
            while (startCol > 0) {
                const x3270::Cell& c = _screen->at(row * _cols + (startCol - 1));
                if (c.isFA || c.ch == 0x00 || c.ch == x3270::EbcdicCodec::EBCDIC_SPACE) break;
                startCol--;
            }
            
            int endCol = col;
            while (endCol < _cols - 1) {
                const x3270::Cell& c = _screen->at(row * _cols + (endCol + 1));
                if (c.isFA || c.ch == 0x00 || c.ch == x3270::EbcdicCodec::EBCDIC_SPACE) break;
                endCol++;
            }
            
            // Step B: Visually highlight the entire double-clicked word for Copy/Paste
            _selStart = row * _cols + startCol;
            _selEnd   = row * _cols + endCol;
            [self setNeedsDisplay:YES];
            
            // Step C: Extract the UTF-16 string token from EBCDIC cells
            NSMutableString *extractedToken = [NSMutableString string];
            for (int c = startCol; c <= endCol; c++) {
                const x3270::Cell& cell = _screen->at(row * _cols + c);
                uint16_t uc = _codec.toUnicode(cell.ch);
                if (uc >= 0x20) {
                    [extractedToken appendFormat:@"%C", (unichar)uc];
                }
            }
            
            NSString *token = [extractedToken stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            
            if (token.length > 0) {
                // CASE 1: Dataset Pattern (e.g., QUAL.DATASET.NAME or DATASET(MEMBER)) -> Open ISPF 3.4
                if ([token containsString:@"."] || [token containsString:@"("]) {
                    NSString *targetCmd = [NSString stringWithFormat:@"=3.4 %@", token];
                    NSWindowController *wc = self.window.windowController;
                    if ([wc respondsToSelector:@selector(executeISPFCommandLocally:)]) {
                        [wc performSelector:@selector(executeISPFCommandLocally:) withObject:targetCmd];
                        return;
                    }
                }
                
                // CASE 2: SDSF / ISPF Context-Aware Actions for Data Rows (row >= 3)
                if (row >= 3) {
                    // Extract panel header text (rows 0 to 2) to evaluate panel type
                    NSMutableString *headerText = [NSMutableString string];
                    for (int r = 0; r < MIN(3, _rows); r++) {
                        for (int c = 0; c < _cols; c++) {
                            const x3270::Cell& cell = _screen->at(r * _cols + c);
                            if (!cell.isFA) {
                                uint16_t uc = _codec.toUnicode(cell.ch);
                                if (uc >= 0x20) [headerText appendFormat:@"%C", (unichar)uc];
                                else [headerText appendString:@" "];
                            } else {
                                [headerText appendString:@" "];
                            }
                        }
                    }
                    NSString *upperHeader = headerText.uppercaseString;
                    
                    // Match header text against panel_rules.json to select action ('?' or 'S')
                    char actionChar = 'S'; // Default fallback action
                    
                    if (_panelRules) {
                        for (NSDictionary *rule in _panelRules) {
                            NSArray<NSString *> *keywords = rule[@"keywords"];
                            NSString *ruleAction = rule[@"action"];
                            BOOL matched = NO;
                            
                            for (NSString *kw in keywords) {
                                if ([upperHeader containsString:kw.uppercaseString]) {
                                    matched = YES;
                                    break;
                                }
                            }
                            
                            if (matched && ruleAction.length > 0) {
                                actionChar = [ruleAction characterAtIndex:0];
                                break;
                            }
                        }
                    }
                    
                    // Dynamically locate the NP/action field (first unprotected cell on target row)
                    int npOffset = -1;
                    for (int c = 0; c < _cols; c++) {
                        int pos = row * _cols + c;
                        const x3270::Cell& cell = _screen->at(pos);
                        if (cell.isFA) continue;
                        
                        int faIdx = _screen->findFieldStart(pos);
                        if (faIdx >= 0) {
                            uint8_t attr = _screen->at(faIdx).attr;
                            bool isProtected = (attr & 0x20) != 0; // Bit 2: 1 = Protected
                            if (!isProtected) {
                                npOffset = pos;
                                break;
                            }
                        }
                    }
                    
                    // Position cursor, send the dynamic action character, and execute ENTER
                    if (npOffset >= 0) {
                        _screen->setCursor(npOffset);
                        
                        if (_kbd) {
                            _kbd->handleChar(actionChar);
                            _kbd->handleEnter();
                            [self setNeedsDisplay:YES];
                            return;
                        } else if (_kbd5250) {
                            _kbd5250->handleChar(actionChar);
                            _kbd5250->handleEnter();
                            [self setNeedsDisplay:YES];
                            return;
                        }
                    }
                }
            }
        }
        return;
    }
}

// ── Clipboard (Copy / Paste) ──────────────────────────────────────────────────
- (uint8_t)ebcdicForUnichar:(unichar)c {
    // 1. Reverse-lookup using the active Code Page
    for (int i = 0; i < 256; i++) {
        if (_codec.toUnicode((uint8_t)i) == c) {
            return (uint8_t)i;
        }
    }
    // 2. ASCII fallback
    if (c < 128) {
        return _codec.fromAscii((uint8_t)c);
    }
    // 3. Unmapped character -> EBCDIC '?'
    return 0x3F;
}

- (void)copy:(id)sender {
    if (_selStart == -1 || _selEnd == -1) {
        NSBeep();
        return;
    }
    
    int cols = _cols;
    if (cols <= 0) cols = 80;

    int r1 = _selStart / cols;
    int c1 = _selStart % cols;
    int r2 = _selEnd / cols;
    int c2 = _selEnd % cols;
    
    int minRow = MIN(r1, r2);
    int maxRow = MAX(r1, r2);
    int minCol = MIN(c1, c2);
    int maxCol = MAX(c1, c2);
    
    NSMutableString *copiedText = [NSMutableString string];
    
    if (self.isTimeMachineActive) {
        // Extract selected text block from Time-Machine screen snapshot
        ScreenSnapshot *snap = [[TimeMachineManager sharedManager] snapshotAtIndex:self.currentTimeMachineIndex];
        if (!snap) return;
        const unichar *chars = (const unichar *)snap.characterBuffer.bytes;
        
        for (int r = minRow; r <= maxRow; ++r) {
            NSMutableString *rowText = [NSMutableString string];
            for (int c = minCol; c <= maxCol; ++c) {
                int pos = r * snap.cols + c;
                unichar uc = chars[pos];
                [rowText appendFormat:@"%C", (unichar)((uc >= 0x20) ? uc : ' ')];
            }
            [copiedText appendString:rowText];
            if (r < maxRow) [copiedText appendString:@"\n"];
        }
    } else {
        // Extract selected text block from live screen buffer
        if (!_screen) return;
        for (int r = minRow; r <= maxRow; ++r) {
            NSMutableString *rowText = [NSMutableString string];
            for (int c = minCol; c <= maxCol; ++c) {
                int pos = r * _cols + c;
                const x3270::Cell& cell = _screen->at(pos);
                if (cell.isFA || cell.isNonDisplay() || cell.ch == 0x00) {
                    [rowText appendString:@" "];
                } else {
                    uint16_t uc = _codec.toUnicode(cell.ch);
                    [rowText appendFormat:@"%C", (unichar)((uc >= 0x20) ? uc : ' ')];
                }
            }
            [copiedText appendString:rowText];
            if (r < maxRow) [copiedText appendString:@"\n"];
        }
    }
    
    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    [pb clearContents];
    [pb setString:copiedText forType:NSPasteboardTypeString];
}

- (void)paste:(id)sender {
    if (!_kbd && !_kbd5250) return;
    
    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    NSString *text = [pb stringForType:NSPasteboardTypeString];
    
    if (!text || text.length == 0) {
        NSBeep();
        return;
    }
    
    // Memorize the exact column where the user starts pasting
    int startCol = 0;
    if (_screen) {
        startCol = _screen->cursorPos() % _cols;
    }
    
    for (NSUInteger i = 0; i < text.length; i++) {
        unichar c = [text characterAtIndex:i];
        
        // Ignore completely the 'Carriage Return' (\r) to avoid double newlines
        // (Windows texts with \r\n will become simple \n)
        if (c == '\r') {
            continue;
        }
        
        BOOL success = NO;
        
        if (c == '\n') {
            // Paste in Block Mode: move down one row and align precisely to the starting column, 
            // ignoring ISPF row numbers.
            if (_screen) {
                int curRow = _screen->cursorPos() / _cols;
                int nextRow = curRow + 1;
                
                if (nextRow < _rows) {
                    _screen->setCursor(nextRow * _cols + startCol);
                    success = YES;
                } else {
                    success = NO; // Reached the bottom of the screen
                }
            }
        } else {
            // Digit the EBCDIC character normally
            uint8_t ebcdic = [self ebcdicForUnichar:c];
            if (_kbd) success = _kbd->handleEbcdicChar(ebcdic);
            else if (_kbd5250) success = _kbd5250->handleEbcdicChar(ebcdic);
        }
        
        // Stop the paste (and emit a beep) if we hit a protected field or the end of the screen
        if (!success) {
            NSBeep();
            break;
        }
    }
    
    [self setNeedsDisplay:YES];
}

- (void)toggleCrosshairRuler {
    self.showCrosshairRuler = !self.showCrosshairRuler;
    [self setNeedsDisplay:YES];
}

- (void)toggleLogIsolatorMode {
    using namespace dx3270;
    
    // 1. If you have selected text with the mouse, use it as the filter key
    if (_selStart != -1 && _selEnd != -1 && _screen) {
        int r1 = _selStart / _cols, c1 = _selStart % _cols;
        int r2 = _selEnd / _cols,   c2 = _selEnd % _cols;
        int minRow = MIN(r1, r2), maxRow = MAX(r1, r2);
        int minCol = MIN(c1, c2), maxCol = MAX(c1, c2);
        
        NSMutableString *selectedText = [NSMutableString string];
        for (int r = minRow; r <= maxRow; ++r) {
            for (int c = minCol; c <= maxCol; ++c) {
                const x3270::Cell& cell = _screen->at(r * _cols + c);
                uint16_t uc = _codec.toUnicode(cell.ch);
                if (uc > 0x20) [selectedText appendFormat:@"%C", (unichar)uc];
            }
        }
        
        NSString *trimmed = [selectedText stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (trimmed.length > 0) {
            _logIsolator.setFilterPattern([trimmed UTF8String]);
            _logIsolator.setMode(FilterMode::Dimming);
            
            // Clear the visual selection to better show the filter
            _selStart = -1;
            _selEnd = -1;
            
            [self setNeedsDisplay:YES];
            return;
        }
    }

    // 2. If no text is selected, cycle through the modes: Off -> Dimming -> Strict -> Off
    if (_logIsolator.mode() == FilterMode::Off) {
        _logIsolator.setMode(FilterMode::Dimming);
    } else if (_logIsolator.mode() == FilterMode::Dimming) {
        _logIsolator.setMode(FilterMode::Strict);
    } else {
        _logIsolator.setMode(FilterMode::Off);
        _logIsolator.setFilterPattern(""); // Reset the pattern
    }
    [self setNeedsDisplay:YES];
}

#pragma mark - Time Machine Engine

- (void)captureCurrentScreenSnapshot {
    BOOL recordingEnabled = [[NSUserDefaults standardUserDefaults] objectForKey:@"DX3270_EnableTimeMachine"] 
                            ? [[NSUserDefaults standardUserDefaults] boolForKey:@"DX3270_EnableTimeMachine"] 
                            : YES; // Enabled by default
    if (!recordingEnabled) return;

    if (self.isTimeMachineActive || !_screen) return;

    int rows = _screen->rows();
    int cols = _screen->cols();
    if (rows <= 0 || cols <= 0) return;

    unichar *chars = (unichar *)malloc(sizeof(unichar) * rows * cols);
    uint32_t *attrs = (uint32_t *)malloc(sizeof(uint32_t) * rows * cols);

    for (int r = 0; r < rows; r++) {
        for (int c = 0; c < cols; c++) {
            int pos = r * cols + c;
            const x3270::Cell& cell = _screen->at(pos);
            uint16_t uc = _codec.toUnicode(cell.ch);
            chars[pos] = (uc >= 0x20) ? uc : ' ';

            uint8_t colorType = 0; // 1=3270 ext, 2=3270 base, 3=5250
            uint8_t colorVal = 0;

            if (_kbd5250 != nil) {
                int faIdx = _screen->findFieldStart(pos);
                colorVal = (faIdx >= 0) ? _screen->at(faIdx).fgColor : 0x20;
                colorType = 3;
            } else if (cell.fgColor != 0x00) {
                colorVal = cell.fgColor;
                colorType = 1;
            } else {
                int faIdx = _screen->findFieldStart(pos);
                uint8_t activeAttr = (faIdx >= 0) ? _screen->at(faIdx).attr : 0x00;
                colorVal = ((activeAttr & 0x20) >> 4) | ((activeAttr & 0x08) >> 3);
                colorType = 2;
            }

            attrs[pos] = ((uint32_t)colorType << 16) | ((uint32_t)colorVal << 8) | (uint32_t)cell.attr;
        }
    }

    int curPos = _screen->cursorPos();
    int curRow = curPos / cols;
    int curCol = curPos % cols;

    [[TimeMachineManager sharedManager] captureSnapshotWithRows:rows
                                                           cols:cols
                                                          chars:chars
                                                     attributes:attrs
                                                      cursorRow:curRow
                                                      cursorCol:curCol];

    free(chars);
    free(attrs);
}

- (void)toggleTimeMachine {
    BOOL tmEnabled = [[NSUserDefaults standardUserDefaults] objectForKey:@"DX3270_EnableTimeMachine"] 
                     ? [[NSUserDefaults standardUserDefaults] boolForKey:@"DX3270_EnableTimeMachine"] 
                     : YES;

    if (!tmEnabled && !self.isTimeMachineActive) {
        NSBeep();
        return;
    }

    if (self.isTimeMachineActive) {
        [self timeMachineDidReturnToLive];
    } else {
        NSArray *snaps = [[TimeMachineManager sharedManager] allSnapshots];
        if (snaps.count == 0) return;

        self.isTimeMachineActive = YES;
        self.currentTimeMachineIndex = snaps.count - 1;

        if (!self.timeMachineHUD) {
            self.timeMachineHUD = [[TimeMachineHUDView alloc] initWithFrame:NSZeroRect];
        }
        
        self.timeMachineHUD.delegate = self;

        [self.timeMachineHUD showInParentView:self];
        [self updateHUDState];
        [self setNeedsDisplay:YES];
    }
}

- (void)updateHUDState {
    NSArray *snaps = [[TimeMachineManager sharedManager] allSnapshots];
    if (snaps.count == 0) return;
    
    ScreenSnapshot *currentSnap = snaps[self.currentTimeMachineIndex];
    [self.timeMachineHUD updateWithSnapshotsCount:snaps.count
                                    currentIndex:self.currentTimeMachineIndex
                                       timestamp:currentSnap.timestamp];
}

#pragma mark - TimeMachineHUDDelegate Implementation (PIN / POI Navigation)

- (void)timeMachineDidTogglePin {
    [[TimeMachineManager sharedManager] togglePinAtIndex:self.currentTimeMachineIndex];
    [self updateHUDState]; // Refresh HUD state to display active pin indicator
}

- (void)timeMachineDidRequestJumpToNextPin:(BOOL)forward {
    NSInteger targetIndex = -1;
    if (forward) {
        targetIndex = [[TimeMachineManager sharedManager] nextPinnedIndexAfter:self.currentTimeMachineIndex];
    } else {
        targetIndex = [[TimeMachineManager sharedManager] prevPinnedIndexBefore:self.currentTimeMachineIndex];
    }
    
    if (targetIndex != -1) {
        self.currentTimeMachineIndex = targetIndex;
        [self updateHUDState];
        [self setNeedsDisplay:YES];
    } else {
        NSBeep(); // Boundary reached in POI history
    }
}

#pragma mark - TimeMachineHUDDelegate Implementation

- (void)timeMachineDidRequestSearch:(NSString *)query searchBackward:(BOOL)backward {
    if (query.length == 0) return;
    
    NSArray *snaps = [[TimeMachineManager sharedManager] allSnapshots];
    if (snaps.count == 0) return;
    
    // Decide the direction of iteration
    NSInteger step = backward ? -1 : 1;
    NSInteger startIdx = self.currentTimeMachineIndex + step;
    
    BOOL matchFound = NO;
    
    // Iterate over the time frames
    for (NSInteger i = startIdx; i >= 0 && i < (NSInteger)snaps.count; i += step) {
        ScreenSnapshot *snap = snaps[i];
        
        // Extract the character buffer in one go
        const unichar *chars = (const unichar *)snap.characterBuffer.bytes;
        int totalCells = snap.rows * snap.cols;
        
        // Convert the raw buffer into an NSString to leverage macOS's fast search
        NSString *screenText = [[NSString alloc] initWithCharacters:chars length:totalCells];
        
        // Case-insensitive search
        if ([screenText localizedCaseInsensitiveContainsString:query]) {
            self.currentTimeMachineIndex = i;
            [self updateHUDState];
            [self setNeedsDisplay:YES];
            matchFound = YES;
            break;
        }
    }
    
    // If the string is not found, beep to alert the user
    if (!matchFound) {
        NSBeep();
    }
}

- (void)timeMachineDidSelectSnapshotAtIndex:(NSInteger)index {
    self.currentTimeMachineIndex = index;
    [self updateHUDState];
    [self setNeedsDisplay:YES];
}

- (void)timeMachineDidToggleDiffMode:(BOOL)diffEnabled {
    self.isDiffActive = diffEnabled;
    
    if (diffEnabled) {
        // Set active frame as baseline anchor if it is pinned
        if ([[TimeMachineManager sharedManager] isPinnedAtIndex:self.currentTimeMachineIndex]) {
            [TimeMachineManager sharedManager].baselinePinIndex = self.currentTimeMachineIndex;
        }
    } else {
        // Reset baseline when disabling diff mode
        [TimeMachineManager sharedManager].baselinePinIndex = -1;
    }
    
    [self updateHUDState];
    [self setNeedsDisplay:YES];
}

- (void)timeMachineDidReturnToLive {
    self.isTimeMachineActive = NO;
    self.isDiffActive = NO;
    [self.timeMachineHUD hide];
    [self setNeedsDisplay:YES];
}

#pragma mark - Macro Engine Actions

- (IBAction)startRecordingMacro:(id)sender {
    if (_macroRecorder.isRecording()) return;
    _macroRecorder.startRecording("DX3270 Macro");
    self.window.title = [self.window.title stringByAppendingString:@" [RECORDING ●]"];
}

- (IBAction)stopRecordingMacro:(id)sender {
    if (!_macroRecorder.isRecording()) return;
    _macroRecorder.stopRecording();
    self.window.title = [self.window.title stringByReplacingOccurrencesOfString:@" [RECORDING ●]" withString:@""];
    
    NSSavePanel *savePanel = [NSSavePanel savePanel];
    savePanel.title = @"Save Macro";

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    savePanel.allowedFileTypes = @[@"dxmacro"];
#pragma clang diagnostic pop

    savePanel.nameFieldStringValue = @"Untitled.dxmacro";
    
    [savePanel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
        if (result == NSModalResponseOK) {
            x3270::MacroSerializer::saveToFile(self->_macroRecorder.script(), [savePanel.URL.path UTF8String]);
        }
        self->_macroRecorder.clear();
    }];
}

- (IBAction)playMacro:(id)sender {
    if (_macroRecorder.isRecording()) return;
    if (_macroRunner && _macroRunner->state() == x3270::MacroRunnerState::Running) return;
    
    NSOpenPanel *openPanel = [NSOpenPanel openPanel];
    openPanel.title = @"Select Macro to Play";

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    openPanel.allowedFileTypes = @[@"dxmacro"];
#pragma clang diagnostic pop

    // --- Create Accessory View for Playback Speed ---
    NSView *accessory = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 260, 44)];
    NSTextField *label = [NSTextField labelWithString:@"Playback Speed:"];
    label.frame = NSMakeRect(0, 12, 110, 20);
    [accessory addSubview:label];
    
    NSPopUpButton *speedPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(110, 10, 140, 24) pullsDown:NO];
    [speedPopup addItemsWithTitles:@[@"Fast (Automation)", @"Normal (Real-time)", @"Presentation (Slow)"]];
    [speedPopup selectItemAtIndex:1]; // Default to Normal
    [accessory addSubview:speedPopup];
    
    openPanel.accessoryView = accessory;
    openPanel.accessoryViewDisclosed = YES;
    
    [openPanel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
        if (result == NSModalResponseOK) {
            x3270::MacroScript script;
            if (x3270::MacroSerializer::loadFromFile([openPanel.URL.path UTF8String], script)) {
                // Map the popup selection directly to the C++ enum
                x3270::MacroPlaybackSpeed selectedSpeed = static_cast<x3270::MacroPlaybackSpeed>(speedPopup.indexOfSelectedItem);
                [self executeScript:script withSpeed:selectedSpeed];
            } else {
                NSBeep();
            }
        }
    }];
}

- (void)executeScript:(const x3270::MacroScript&)script withSpeed:(x3270::MacroPlaybackSpeed)speed {
    _macroRunner = std::make_unique<x3270::MacroRunner>(*_screen, _kbd, _kbd5250);
    
    __weak typeof(self) weakSelf = self;
    
    _macroRunner->setCallbacks([weakSelf](x3270::MacroRunnerState state, const std::string& errorMsg) {
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            
            if (state == x3270::MacroRunnerState::Error) {
                NSAlert *alert = [[NSAlert alloc] init];
                alert.messageText = @"Macro Execution Error";
                alert.informativeText = [NSString stringWithUTF8String:errorMsg.c_str()];
                alert.alertStyle = NSAlertStyleWarning;
                [alert beginSheetModalForWindow:strongSelf.window completionHandler:nil];
            }
            [strongSelf setNeedsDisplay:YES];
        });
    }, [weakSelf](size_t currentStep, size_t totalSteps) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf setNeedsDisplay:YES];
        });
    });
    
    _macroRunner->loadScript(script);
    _macroRunner->start(speed);
}

- (void)startVideoRecordingToURL:(NSURL *)url {
    if (!_videoRecorder) {
        _videoRecorder = std::make_unique<x3270::VideoRecorder>();
    }
    _videoRecorder->startRecording(url.path.UTF8String, self.bounds.size.width, self.bounds.size.height);
}

- (void)stopVideoRecording {
    if (_videoRecorder && _videoRecorder->isRecording()) {
        _videoRecorder->stopRecording([]() {
            NSLog(@"[DX3270] Esportazione video completata.");
        });
    }
}

- (BOOL)isVideoRecording {
    return _videoRecorder && _videoRecorder->isRecording();
}

// =========================================================
// GRAPHICS INTERCEPTION FOR VIDEO/GIF
// =========================================================

- (void)setNeedsDisplay:(BOOL)needsDisplay {
    [super setNeedsDisplay:needsDisplay];
    if (needsDisplay && [self isVideoRecording]) {
        [self scheduleVideoFrameCapture];
    }
}

- (void)setNeedsDisplayInRect:(NSRect)invalidRect {
    [super setNeedsDisplayInRect:invalidRect];
    if ([self isVideoRecording]) {
        [self scheduleVideoFrameCapture];
    }
}

- (void)scheduleVideoFrameCapture {
    if (_isPendingVideoFrame) return; // Avoid duplicate frames within the same millisecond
    _isPendingVideoFrame = YES;
    
    // Capture at the end of the current graphics cycle (Debounce)
    dispatch_async(dispatch_get_main_queue(), ^{
        self->_isPendingVideoFrame = NO;
        if ([self isVideoRecording]) {
            // Draw the current actual state of the view (including selection, cursor, input)
            NSBitmapImageRep *rep = [self bitmapImageRepForCachingDisplayInRect:self.bounds];
            [self cacheDisplayInRect:self.bounds toBitmapImageRep:rep];
            self->_videoRecorder->appendFrame((void *)rep.CGImage);
        }
    });
}

#pragma mark - Time Machine Export & Import Actions

- (IBAction)exportTimeMachineTrace:(id)sender {
    NSArray *snaps = [[TimeMachineManager sharedManager] allSnapshots];
    if (snaps.count == 0) {
        NSBeep();
        return;
    }

    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.title = @"Export Time-Machine Trace";

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    panel.allowedFileTypes = @[@"dxlog", @"pdf"];
#pragma clang diagnostic pop

    panel.nameFieldStringValue = [NSString stringWithFormat:@"DX3270_Trace_%ld.dxlog", (long)[[NSDate date] timeIntervalSince1970]];
    
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
        if (result == NSModalResponseOK && panel.URL) {
            NSError *error = nil;
            BOOL success = NO;
            
            if ([panel.URL.pathExtension isEqualToString:@"pdf"]) {
                success = [[TimeMachineManager sharedManager] exportPDFReportToURL:panel.URL error:&error];
            } else {
                success = [[TimeMachineManager sharedManager] exportAuditTraceToURL:panel.URL error:&error];
            }
            
            if (!success) {
                NSAlert *alert = [NSAlert alertWithError:error];
                [alert beginSheetModalForWindow:self.window completionHandler:nil];
            }
        }
    }];
}

- (IBAction)importTimeMachineTrace:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.title = @"Import Time-Machine Trace";

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    panel.allowedFileTypes = @[@"dxlog"];
#pragma clang diagnostic pop

    panel.canChooseDirectories = NO;
    panel.allowsMultipleSelection = NO;
    
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
        if (result == NSModalResponseOK && panel.URL) {
            NSError *error = nil;
            BOOL success = [[TimeMachineManager sharedManager] importAuditTraceFromURL:panel.URL error:&error];
            
            if (success) {
                NSArray *snaps = [[TimeMachineManager sharedManager] allSnapshots];
                if (snaps.count > 0) {
                    self.isTimeMachineActive = YES;
                    self.currentTimeMachineIndex = snaps.count - 1;
                    
                    if (!self.timeMachineHUD) {
                        self.timeMachineHUD = [[TimeMachineHUDView alloc] initWithFrame:NSZeroRect];
                    }
                    self.timeMachineHUD.delegate = self;
                    [self.timeMachineHUD showInParentView:self];
                    [self updateHUDState];
                    [self setNeedsDisplay:YES];
                }
            } else {
                NSAlert *alert = [NSAlert alertWithError:error];
                [alert beginSheetModalForWindow:self.window completionHandler:nil];
            }
        }
    }];
}

#pragma mark - TimeMachineHUDDelegate Export & Import Implementation

- (void)timeMachineDidRequestExport {
    [self exportTimeMachineTrace:nil];
}

- (void)timeMachineDidRequestImport {
    [self importTimeMachineTrace:nil];
}

@end