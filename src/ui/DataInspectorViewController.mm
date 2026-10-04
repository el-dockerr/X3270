#import "DataInspectorViewController.h"
#import "../utils/ConfigLoader.h"
#import <math.h>

@implementation DataInspectorViewController {
    NSData *_rawBytes;
    NSString *_decodedString;
    NSData *_verticalHex;
    NSString *_verticalDecodedString;
    NSTextView *_textView;
}

#pragma mark - Initializers

- (instancetype)initWithRawBytes:(NSData *)bytes decodedString:(NSString *)text verticalHex:(NSData *)vertBytes verticalDecodedString:(NSString *)vertText {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _rawBytes = bytes;
        _decodedString = text;
        _verticalHex = vertBytes;
        _verticalDecodedString = vertText;
    }
    return self;
}

- (instancetype)initWithRawBytes:(NSData *)bytes {
    return [self initWithRawBytes:bytes decodedString:nil verticalHex:nil verticalDecodedString:nil];
}

#pragma mark - View Lifecycle

- (void)loadView {
    NSStackView *mainStack = [[NSStackView alloc] initWithFrame:NSMakeRect(0, 0, 520, 480)];
    mainStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    mainStack.edgeInsets = NSEdgeInsetsMake(10, 10, 10, 10);
    mainStack.spacing = 10;
    self.view = mainStack;
    
    // Scroller and TextView
    NSScrollView *scrollView = [[NSScrollView alloc] init];
    scrollView.hasVerticalScroller = YES;
    [scrollView setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationVertical];
    
    _textView = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 500, 460)];
    _textView.autoresizingMask = NSViewWidthSizable;
    _textView.drawsBackground = NO;
    _textView.editable = NO;
    _textView.selectable = YES;
    
    scrollView.documentView = _textView;
    [mainStack addArrangedSubview:scrollView];
    
    // --- IPCS POINTER DETECTION ENGINE ---
    NSString *cleanStr = [_decodedString stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"^[0-9A-Fa-f]{8}$|^[0-9A-Fa-f]{16}$" options:0 error:nil];
    
    if (cleanStr.length > 0 && [regex firstMatchInString:cleanStr options:0 range:NSMakeRange(0, cleanStr.length)]) {
        NSButton *jumpBtn = [NSButton buttonWithTitle:[NSString stringWithFormat:@"  Jump to Address (L %@)", cleanStr.uppercaseString] target:self action:@selector(jumpClicked:)];
        jumpBtn.bezelStyle = NSBezelStyleRounded;
        jumpBtn.controlSize = NSControlSizeLarge;
        jumpBtn.image = [NSImage imageWithSystemSymbolName:@"arrow.up.forward.app" accessibilityDescription:nil];
        [jumpBtn setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationVertical];
        [mainStack addArrangedSubview:jumpBtn];
    }
    
    [self decodeData];
}

- (void)jumpClicked:(id)sender {
    NSString *cleanStr = [_decodedString stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (self.onAddressJump) {
        self.onAddressJump(cleanStr);
    }
}

#pragma mark - Primary Decoding Dispatcher

- (void)decodeData {
    if (_rawBytes.length == 0) return;
    
    NSMutableAttributedString *outStr = [[NSMutableAttributedString alloc] init];
    
    // UI Theme Palette
    NSColor *headerColor = [NSColor systemPurpleColor];
    NSColor *labelColor  = [NSColor darkGrayColor];
    NSColor *valColor    = [NSColor systemBlueColor];
    NSColor *errColor    = [NSColor systemRedColor];
    
    // Helper block for building attributed rich-text output
    void (^append)(NSString *, NSColor *, BOOL) = ^(NSString *text, NSColor *color, BOOL bold) {
        if (!text) return;
        NSFont *font = bold ? [NSFont fontWithName:@"Menlo-Bold" size:11.0] : [NSFont fontWithName:@"Menlo-Regular" size:11.0];
        if (!font) font = [NSFont userFixedPitchFontOfSize:11.0];
        NSDictionary *attrs = @{ NSFontAttributeName: font, NSForegroundColorAttributeName: color };
        [outStr appendAttributedString:[[NSAttributedString alloc] initWithString:text attributes:attrs]];
    };
    
    // 1. ISPF VERTICAL HEX
    if (_verticalHex.length > 0) {
        append(@"=== ISPF VERTICAL HEX ===\n", headerColor, YES);
        [self analyzeBytes:(const uint8_t *)_verticalHex.bytes length:_verticalHex.length appendTo:outStr appendBlock:append valColor:valColor labelColor:labelColor errColor:errColor];
        append(@"EBCDIC : ", labelColor, NO);
        append([NSString stringWithFormat:@"%@\n\n", _verticalDecodedString ?: @""], valColor, NO);
    }
    
    // 2. PARSED SCREEN TEXT
    NSData *parsedHex = [self parseHexString:_decodedString];
    if (parsedHex.length > 0) {
        append(@"=== PARSED SCREEN TEXT (HEX) ===\n", headerColor, YES);
        [self analyzeBytes:(const uint8_t *)parsedHex.bytes length:parsedHex.length appendTo:outStr appendBlock:append valColor:valColor labelColor:labelColor errColor:errColor];
        append(@"\n", labelColor, NO);
    }
    
    // 3. RAW TERMINAL BUFFER
    append(@"=== RAW TERMINAL BUFFER ===\n", headerColor, YES);
    [self analyzeBytes:(const uint8_t *)_rawBytes.bytes length:_rawBytes.length appendTo:outStr appendBlock:append valColor:valColor labelColor:labelColor errColor:errColor];
    append(@"EBCDIC : ", labelColor, NO);
    append([NSString stringWithFormat:@"%@\n", _decodedString ?: @""], valColor, NO);
    
    // Commit the fully formatted attributed string to the NSTextView
    [_textView.textStorage setAttributedString:outStr];
}

#pragma mark - VSAM & Mainframe Analytics Subroutines

/// Decodes VSAM Control Interval Definition Field (CIDF) structure if selected bytes match trailer boundaries.
/// @param bytes Pointer to the byte array.
/// @param len Length of the byte buffer.
/// @param outStr Target attributed string for UI rendering.
- (void)decodeVSAMControlInterval:(const uint8_t *)bytes length:(NSUInteger)len appendTo:(NSMutableAttributedString *)outStr {
    // A standard VSAM CIDF is 4 bytes located at the end of a Control Interval
    if (len < 4) return;
    
    // Extract Free Space Offset (first 2 bytes) and Free Space Length (next 2 bytes)
    uint16_t freeSpaceOffset = (bytes[0] << 8) | bytes[1];
    uint16_t freeSpaceLength = (bytes[2] << 8) | bytes[3];
    
    // Sanity boundary check: valid VSAM Control Interval size boundaries (up to 32KB)
    if (freeSpaceOffset > 32768 && freeSpaceOffset != 0xFFFF) return;
    
    void (^append)(NSString *, NSColor *, BOOL) = ^(NSString *text, NSColor *color, BOOL bold) {
        NSFont *font = bold ? [NSFont fontWithName:@"Menlo-Bold" size:11.0] : [NSFont fontWithName:@"Menlo-Regular" size:11.0];
        NSDictionary *attrs = @{ NSFontAttributeName: font, NSForegroundColorAttributeName: color };
        [outStr appendAttributedString:[[NSAttributedString alloc] initWithString:text attributes:attrs]];
    };
    
    append(@"=== VSAM CONTROL INTERVAL (CIDF) ===\n", [NSColor systemPurpleColor], YES);
    append(@"Free Space Offset : ", [NSColor darkGrayColor], NO);
    append([NSString stringWithFormat:@"%u bytes (0x%04X)\n", freeSpaceOffset, freeSpaceOffset], [NSColor systemBlueColor], NO);
    append(@"Free Space Length : ", [NSColor darkGrayColor], NO);
    append([NSString stringWithFormat:@"%u bytes (0x%04X)\n", freeSpaceLength, freeSpaceLength], [NSColor systemBlueColor], NO);
    append(@"-------------------------------------------------\n", [NSColor darkGrayColor], NO);
}

/// Evaluates if the current selection represents a VSAM Record Key (KSDS/RRDS) or padded key field.
/// @param bytes Pointer to the byte array.
/// @param len Length of the byte buffer.
/// @param outStr Target attributed string for UI rendering.
- (void)analyzeVSAMRecordKey:(const uint8_t *)bytes length:(NSUInteger)len appendTo:(NSMutableAttributedString *)outStr {
    if (len < 2) return;
    
    BOOL isAllZeros = YES;
    BOOL isAllSpaces = YES;
    
    for (NSUInteger i = 0; i < len; i++) {
        if (bytes[i] != 0x00) isAllZeros = NO;
        if (bytes[i] != 0x40) isAllSpaces = NO; // 0x40 is EBCDIC Space
    }
    
    void (^append)(NSString *, NSColor *, BOOL) = ^(NSString *text, NSColor *color, BOOL bold) {
        NSFont *font = bold ? [NSFont fontWithName:@"Menlo-Bold" size:11.0] : [NSFont fontWithName:@"Menlo-Regular" size:11.0];
        NSDictionary *attrs = @{ NSFontAttributeName: font, NSForegroundColorAttributeName: color };
        [outStr appendAttributedString:[[NSAttributedString alloc] initWithString:text attributes:attrs]];
    };
    
    if (isAllZeros) {
        append(@"VSAM KEY METADATA : ", [NSColor darkGrayColor], NO);
        append(@"Binary Zero Padded Key Field\n", [NSColor systemOrangeColor], YES);
    } else if (isAllSpaces) {
        append(@"VSAM KEY METADATA : ", [NSColor darkGrayColor], NO);
        append(@"EBCDIC Blank Padded Key Field\n", [NSColor systemOrangeColor], YES);
    }
}

#pragma mark - Unified Byte Analysis Engine

- (void)analyzeBytes:(const uint8_t *)bytes length:(NSUInteger)len appendTo:(NSMutableAttributedString *)outStr appendBlock:(void (^)(NSString *, NSColor *, BOOL))append valColor:(NSColor *)vCol labelColor:(NSColor *)lCol errColor:(NSColor *)eCol {
    
    NSMutableIndexSet *highlights = [NSMutableIndexSet indexSet];
    NSArray<NSString *> *patternsFound = [self identifyPatternsFromBytes:bytes length:len highlights:highlights];
    
    // 1. Build HEX row with active pattern highlights
    append(@"HEX    : ", lCol, NO);
    for (NSUInteger i = 0; i < len; i++) {
        NSString *byteStr = [NSString stringWithFormat:@"%02X ", bytes[i]];
        if ([highlights containsIndex:i]) {
            append(byteStr, [NSColor systemOrangeColor], YES);
        } else {
            append(byteStr, vCol, NO);
        }
    }
    append(@"\n", vCol, NO);
    
    // 2. Build BINARY row (capped at 32-bit preview for UI cleanliness)
    NSMutableString *binStr = [NSMutableString string];
    NSUInteger binLen = MIN(len, 4UL);
    for (NSUInteger i = 0; i < binLen; i++) {
        uint8_t b = bytes[i];
        for (int j = 7; j >= 0; j--) {
            [binStr appendFormat:@"%d", (b >> j) & 1];
        }
        if (i < binLen - 1) [binStr appendString:@" "];
    }
    append(@"BIN    : ", lCol, NO); append([NSString stringWithFormat:@"%@\n", binStr], vCol, NO);
    
    // 3. Build ASCII row with active pattern highlights
    append(@"ASCII  : ", lCol, NO);
    for (NSUInteger i = 0; i < len; i++) {
        NSString *charStr = (bytes[i] >= 0x20 && bytes[i] <= 0x7E) ? [NSString stringWithFormat:@"%c", bytes[i]] : @".";
        if ([highlights containsIndex:i]) {
            append(charStr, [NSColor systemOrangeColor], YES);
        } else {
            append(charStr, vCol, NO);
        }
    }
    append(@"\n", vCol, NO);
    
    // 4. Output Pattern Recognition Findings
    if (patternsFound) {
        for (NSString *pattern in patternsFound) {
            append(@"FOUND  : ", lCol, NO);
            append([NSString stringWithFormat:@"%@\n", pattern], [NSColor systemOrangeColor], YES);
        }
    }
    append(@"-------------------------------------------------\n", lCol, NO);
    
    // 5. Binary Integer Decoders (COMP / COMP-4)
    if (len >= 2) {
        int16_t hw = (int16_t)(((uint32_t)bytes[0] << 8) | (uint32_t)bytes[1]);
        append(@"COMP-H : ", lCol, NO); append([NSString stringWithFormat:@"%d\n", hw], vCol, NO);
    }
    
    if (len >= 4) {
        uint32_t ufw = ((uint32_t)bytes[0] << 24) | ((uint32_t)bytes[1] << 16) | ((uint32_t)bytes[2] << 8) | (uint32_t)bytes[3];
        int32_t fw = (int32_t)ufw;
        append(@"COMP-F : ", lCol, NO); append([NSString stringWithFormat:@"%d\n", fw], vCol, NO);
        
        // 31-bit z/OS Pointer (High-bit Masking)
        uint32_t ptr31 = ufw & 0x7FFFFFFF;
        append(@"PTR-31 : ", lCol, NO); append([NSString stringWithFormat:@"0x%08X\n", ptr31], vCol, NO);
        
        // IBM Hexadecimal Floating Point (HFP - Short Precision)
        int sign = (ufw >> 31) & 1;
        int exp = (ufw >> 24) & 0x7F;
        uint32_t frac = ufw & 0x00FFFFFF;
        double hfp_short = (1.0 - 2.0 * sign) * ((double)frac / 16777216.0) * pow(16.0, exp - 64);
        append(@"HFP(S) : ", lCol, NO); append([NSString stringWithFormat:@"%g\n", hfp_short], vCol, NO);
    }
    
    if (len >= 8) {
        uint64_t dw = 0;
        for (int i = 0; i < 8; i++) dw = (dw << 8) | (uint64_t)bytes[i];
        append(@"COMP-D : ", lCol, NO); append([NSString stringWithFormat:@"%lld\n", (long long)dw], vCol, NO);
        
        // IBM Hexadecimal Floating Point (HFP - Long Precision)
        int sign = (dw >> 63) & 1;
        int exp = (dw >> 56) & 0x7F;
        uint64_t frac = dw & 0x00FFFFFFFFFFFFFFULL;
        double hfp_long = (1.0 - 2.0 * sign) * ((double)frac / 72057594037927936.0) * pow(16.0, exp - 64);
        append(@"HFP(L) : ", lCol, NO); append([NSString stringWithFormat:@"%.15g\n", hfp_long], vCol, NO);
        
        // z/OS Store Clock (STCK) Timestamp Decoder
        uint64_t micros = dw >> 12;
        uint64_t epochOffset = 2208988800ULL * 1000000ULL;
        if (micros > epochOffset) {
            NSTimeInterval unixTime = (NSTimeInterval)(micros - epochOffset) / 1000000.0;
            NSDate *date = [NSDate dateWithTimeIntervalSince1970:unixTime];
            NSDateFormatter *df = [[NSDateFormatter alloc] init];
            df.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
            df.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
            append(@"STCK   : ", lCol, NO); append([NSString stringWithFormat:@"%@\n", [df stringFromDate:date]], vCol, NO);
        }
    }
    
    // 6. COBOL Packed Decimal (COMP-3) Decoder
    NSUInteger comp3Len = MIN(len, 64UL);
    NSString *comp3 = [self decodeComp3:bytes length:comp3Len];
    append(@"COMP-3 : ", lCol, NO);
    if ([comp3 isEqualToString:@"Invalid"]) {
        append([comp3 stringByAppendingString:@"\n"], eCol, NO);
    } else {
        append([comp3 stringByAppendingString:@"\n"], vCol, NO);
    }
    
    // 7. VSAM Specific Analytics Subroutines
    [self analyzeVSAMRecordKey:bytes length:len appendTo:outStr];
    [self decodeVSAMControlInterval:bytes length:len appendTo:outStr];
}

#pragma mark - Helper Parsing Methods

/// Parses visual hex strings extracted from terminal screen lines into raw NSData bytes.
- (NSData *)parseHexString:(NSString *)str {
    if (!str) return nil;
    NSString *cleanStr = [[str stringByReplacingOccurrencesOfString:@" " withString:@""] uppercaseString];
    NSCharacterSet *hexChars = [NSCharacterSet characterSetWithCharactersInString:@"0123456789ABCDEF"];
    NSMutableString *validHex = [NSMutableString string];
    
    for (NSUInteger i = 0; i < cleanStr.length; i++) {
        unichar c = [cleanStr characterAtIndex:i];
        if ([hexChars characterIsMember:c]) [validHex appendFormat:@"%C", c];
        else break; 
    }
    
    if (validHex.length % 2 != 0) validHex = [[validHex substringToIndex:validHex.length - 1] mutableCopy];
    if (validHex.length == 0) return nil;
    
    NSMutableData *data = [NSMutableData dataWithCapacity:validHex.length / 2];
    for (NSUInteger i = 0; i < validHex.length; i += 2) {
        NSString *byteStr = [validHex substringWithRange:NSMakeRange(i, 2)];
        NSScanner *scanner = [NSScanner scannerWithString:byteStr];
        unsigned int byteValue;
        [scanner scanHexInt:&byteValue];
        uint8_t b = (uint8_t)byteValue;
        [data appendBytes:&b length:1];
    }
    return data;
}

/// Decodes COBOL Packed Decimal (COMP-3) byte streams into signed decimal strings.
- (NSString *)decodeComp3:(const uint8_t *)bytes length:(NSUInteger)len {
    NSMutableString *numStr = [NSMutableString string];
    BOOL valid = YES;
    for (NSUInteger i = 0; i < len; i++) {
        uint8_t b = bytes[i];
        uint8_t high = (b & 0xF0) >> 4;
        uint8_t low  = (b & 0x0F);
        if (i < len - 1) {
            if (high > 9 || low > 9) { valid = NO; break; }
            [numStr appendFormat:@"%d%d", high, low];
        } else {
            if (high > 9) { valid = NO; break; }
            [numStr appendFormat:@"%d", high];
            if (low == 0xC || low == 0xA || low == 0xE || low == 0xF) {
                [numStr insertString:@"+" atIndex:0];
            } else if (low == 0xD || low == 0xB) {
                [numStr insertString:@"-" atIndex:0];
            } else {
                valid = NO;
            }
        }
    }
    return valid ? numStr : @"Invalid";
}

#pragma mark - Data-Driven Pattern Hunting Engine

/// Scans raw byte streams against patterns.json signatures and populates a highlight index set.
/// Uses ConfigLoader to merge base bundle patterns with local user overrides.
/// @param bytes Pointer to selected byte array.
/// @param len Length of selected byte buffer.
/// @param highlights Mutable index set to record matched byte offsets for rich-text highlighting.
/// @return Array of matched signature descriptions.
- (NSArray<NSString *> *)identifyPatternsFromBytes:(const uint8_t *)bytes length:(NSUInteger)len highlights:(NSMutableIndexSet *)highlights {
    if (len == 0) return nil;
    
    NSMutableString *hexStr = [NSMutableString string];
    for (NSUInteger i = 0; i < len; i++) {
        [hexStr appendFormat:@"%02X", bytes[i]];
    }
    
    static NSDictionary *patterns = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // Merges base bundle patterns with local user overrides (~/Library/Application Support/DX3270/patterns.json)
        patterns = [ConfigLoader loadMergedJSONNamed:@"patterns.json"];
        
        if (![patterns isKindOfClass:[NSDictionary class]]) {
            // Fallback signatures if patterns.json is missing or corrupted
            patterns = @{
                @"2A864886F70D010701": @"ASN.1 OID: PKCS#7 Data",
                @"2A864886F70D010702": @"ASN.1 OID: PKCS#7 SignedData",
                @"2A864886F70D01010B": @"ASN.1 OID: sha256WithRSAEncryption",
                @"3082": @"ASN.1 SEQUENCE",
                @"C3C9C3E2": @"z/OS Subsystem: CICS"
            };
        }
    });
    
    NSMutableArray<NSString *> *foundPatterns = [NSMutableArray array];
    
    for (NSString *signature in patterns) {
        // Skip header section dividers in the JSON configuration
        if ([signature hasPrefix:@"="]) continue;
        
        NSRange searchRange = NSMakeRange(0, hexStr.length);
        NSRange matchRange;
        BOOL found = NO;
        
        // Search for all occurrences of the active signature
        while ((matchRange = [hexStr rangeOfString:signature options:0 range:searchRange]).location != NSNotFound) {
            if (!found) {
                [foundPatterns addObject:patterns[signature]];
                found = YES;
            }
            
            // Map character coordinates in hex string back to exact raw byte indices
            if (highlights) {
                NSUInteger startByte = matchRange.location / 2;
                NSUInteger byteLen = matchRange.length / 2;
                [highlights addIndexesInRange:NSMakeRange(startByte, byteLen)];
            }
            
            // Advance search range forward
            searchRange.location = matchRange.location + matchRange.length;
            searchRange.length = hexStr.length - searchRange.location;
        }
    }
    
    return foundPatterns.count > 0 ? foundPatterns : nil;
}

@end