#pragma once
#import <AppKit/AppKit.h>
#include "ScreenBuffer.h"
#include "KeyboardState.h"
#include "KeyboardState5250.h"
#include "GraphicsBuffer.h"
#include "EbcdicCodec.h"

/// NSUserDefaults key – BOOL; YES = use bundled IBM 3270 font (by Ricardo Bánffy)
extern NSString * const kPref3270FontEnabled;
extern NSString * const kPrefHerculesBrackets;

/// TerminalView renders the 3270/5250 screen buffer as a character grid using
/// Core Text.  It also handles all keyboard input and forwards it to
/// whichever keyboard state (TN3270 or TN5250) is active.
@interface TerminalView : NSView

/// Set the EBCDIC code page used for display rendering.
- (void)setCodePage:(x3270::CodePage)codePage;

/// Wire up a TN3270 engine (sets 3270 keyboard state).
- (void)setScreenBuffer:(x3270::ScreenBuffer*)screen
          keyboardState:(x3270::KeyboardState*)kbd;

/// Wire up a TN5250 engine (sets 5250 keyboard state; no graphics buffer needed).
- (void)setScreenBuffer:(x3270::ScreenBuffer*)screen
      keyboardState5250:(x3270::KeyboardState5250*)kbd;

/// Wire up the GOCA graphics buffer (call after setScreenBuffer:keyboardState:).
- (void)setGraphicsBuffer:(x3270::GraphicsBuffer*)graphics;

/// Call this (on main thread) whenever the screen buffer has changed.
- (void)screenDidUpdate;

/// Call this (on main thread) whenever the graphics buffer has changed.
- (void)graphicsDidUpdate;

/// Preferred window content size for the attached screen buffer's model + OIA
- (NSSize)preferredSize;

/// Colour scheme
@property (nonatomic, strong) NSColor *foregroundColor;
@property (nonatomic, strong) NSColor *backgroundColor;
@property (nonatomic, strong) NSColor *intensifiedColor;
@property (nonatomic, strong) NSColor *cursorColor;
@property (nonatomic, strong) NSFont  *terminalFont;

@end
