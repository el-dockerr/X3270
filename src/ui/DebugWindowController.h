#pragma once
#import <AppKit/AppKit.h>
#include <cstdint>

/// Floating panel that logs all raw Telnet traffic (both TX and RX).
/// Thread-safe: -appendBytes:length:isOutgoing: may be called from any thread.
@interface DebugWindowController : NSWindowController

/// Append a block of raw bytes to the traffic log.
/// @param bytes     Pointer to the raw data.
/// @param length    Number of bytes.
/// @param isOutgoing YES = bytes sent to host, NO = bytes received from host.
- (void)appendBytes:(const uint8_t *)bytes
             length:(NSUInteger)length
         isOutgoing:(BOOL)isOutgoing;

/// Update the EBCDIC code page and bracket mode used for the right-column display.
/// @param codePage       An x3270::CodePage value cast to int (0=CP037, 1=CP500, 2=CP1047).
/// @param hb             YES to enable Hercules/CP1047-style bracket remapping.
- (void)configureCodePage:(int)codePage herculesBrackets:(BOOL)hb;

@end
