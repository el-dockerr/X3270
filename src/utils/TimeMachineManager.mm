#import "TimeMachineManager.h"
#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ApplicationServices/ApplicationServices.h>

static const NSUInteger kMaxSnapshots = 50;

@implementation ScreenSnapshot
@end

@interface TimeMachineManager ()
@property (nonatomic, strong) NSMutableArray<ScreenSnapshot *> *history;
@property (nonatomic, strong) NSMutableSet<NSNumber *> *internalPinnedIndices; // Internal set for managing pinned indices
@end

@implementation TimeMachineManager

+ (instancetype)sharedManager {
    static TimeMachineManager *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[TimeMachineManager alloc] init];
    });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _history = [NSMutableArray array];
        _internalPinnedIndices = [NSMutableSet set];
        _baselinePinIndex = -1;
    }
    return self;
}

// Baseline Pin Management
- (void)setBaselinePinIndex:(NSInteger)index {
    _baselinePinIndex = index;
}

// Read-only property for external access
- (NSSet<NSNumber *> *)pinnedIndices {
    return [_internalPinnedIndices copy];
}

- (void)captureSnapshotWithRows:(int)rows
                           cols:(int)cols
                          chars:(const unichar *)chars
                     attributes:(const uint32_t *)attrs
                      cursorRow:(int)cursorRow
                      cursorCol:(int)cursorCol {
    if (!chars || rows <= 0 || cols <= 0) return;

    // Avoid duplicates if the buffer hasn't changed compared to the last snapshot
    NSData *charData = [NSData dataWithBytes:chars length:sizeof(unichar) * rows * cols];
    if (self.history.count > 0) {
        ScreenSnapshot *last = self.history.lastObject;
        if ([last.characterBuffer isEqualToData:charData]) {
            return; // No visible screen change
        }
    }

    ScreenSnapshot *snap = [[ScreenSnapshot alloc] init];
    snap.timestamp = [[NSDate date] timeIntervalSince1970];
    snap.rows = rows;
    snap.cols = cols;
    snap.characterBuffer = charData;
    snap.attributeBuffer = [NSData dataWithBytes:attrs length:sizeof(uint32_t) * rows * cols];
    snap.cursorRow = cursorRow;
    snap.cursorCol = cursorCol;

    [self.history addObject:snap];
    
    // Handle the maximum limit: discard the oldest and "shift" the PINs to keep them consistent
    if (self.history.count > kMaxSnapshots) {
        [self.history removeObjectAtIndex:0];
        
        NSMutableSet<NSNumber *> *shiftedPins = [NSMutableSet set];
        for (NSNumber *pin in self.internalPinnedIndices) {
            NSInteger val = pin.integerValue;
            if (val > 0) {
                [shiftedPins addObject:@(val - 1)]; // Shift to the left. If it was 0, it disappears along with the  snapshot.
            }
        }
        self.internalPinnedIndices = shiftedPins;
    }
}

- (NSArray<ScreenSnapshot *> *)allSnapshots {
    return [self.history copy];
}

- (ScreenSnapshot *)snapshotAtIndex:(NSInteger)index {
    if (index < 0 || (NSUInteger)index >= self.history.count) return nil;
    return self.history[index];
}

- (void)clearHistory {
    [self.history removeAllObjects];
    [self.internalPinnedIndices removeAllObjects];
}

- (NSArray<NSNumber *> *)compareSnapshot:(ScreenSnapshot *)snapA withSnapshot:(ScreenSnapshot *)snapB {
    if (!snapA || !snapB || snapA.rows != snapB.rows || snapA.cols != snapB.cols) {
        return @[];
    }

    NSUInteger totalCells = snapA.rows * snapA.cols;
    NSMutableArray<NSNumber *> *diffMap = [NSMutableArray arrayWithCapacity:totalCells];

    const unichar *bufA = (const unichar *)snapA.characterBuffer.bytes;
    const unichar *bufB = (const unichar *)snapB.characterBuffer.bytes;

    for (NSUInteger i = 0; i < totalCells; i++) {
        unichar cA = bufA[i];
        unichar cB = bufB[i];

        BOOL isAEmpty = (cA == 0 || cA == ' ' || cA == 0x20 || cA == 0x40);
        BOOL isBEmpty = (cB == 0 || cB == ' ' || cB == 0x20 || cB == 0x40);

        if (isAEmpty && isBEmpty) {
            [diffMap addObject:@(CellDiffUnchanged)];
        } else if (cA == cB) {
            [diffMap addObject:@(CellDiffUnchanged)];
        } else {
            [diffMap addObject:@(CellDiffModified)];
        }
    }

    return [diffMap copy];
}

#pragma mark - Pinned Bookmarks Engine

- (void)togglePinAtIndex:(NSInteger)index {
    NSNumber *idx = @(index);
    if ([self.internalPinnedIndices containsObject:idx]) {
        [self.internalPinnedIndices removeObject:idx];
    } else {
        [self.internalPinnedIndices addObject:idx];
    }
}

- (BOOL)isPinnedAtIndex:(NSInteger)index {
    return [self.internalPinnedIndices containsObject:@(index)];
}

- (NSInteger)nextPinnedIndexAfter:(NSInteger)index {
    // Sort the indices to find the next one in chronological order
    NSArray *sortedPins = [[self.internalPinnedIndices allObjects] sortedArrayUsingSelector:@selector(compare:)];
    for (NSNumber *pin in sortedPins) {
        if (pin.integerValue > index) return pin.integerValue;
    }
    return -1; // Reached the end of the pins
}

- (NSInteger)prevPinnedIndexBefore:(NSInteger)index {
    // Sort and iterate in reverse order
    NSArray *sortedPins = [[self.internalPinnedIndices allObjects] sortedArrayUsingSelector:@selector(compare:)];
    for (NSNumber *pin in [sortedPins reverseObjectEnumerator]) {
        if (pin.integerValue < index) return pin.integerValue;
    }
    return -1; // Reached the beginning of the pins
}


#pragma mark - Export & Import Engine Implementation

- (BOOL)exportAuditTraceToURL:(NSURL *)fileURL error:(NSError **)outError {
    NSMutableArray *framesArray = [NSMutableArray array];
    
    for (NSUInteger i = 0; i < _history.count; i++) {
        ScreenSnapshot *snap = _history[i];
        BOOL isPinned = [_internalPinnedIndices containsObject:@(i)];
        
        // Encode character buffer as array of unichar integers
        const unichar *chars = (const unichar *)snap.characterBuffer.bytes;
        NSUInteger totalCells = snap.rows * snap.cols;
        NSMutableArray *charArray = [NSMutableArray arrayWithCapacity:totalCells];
        for (NSUInteger c = 0; c < totalCells; c++) {
            [charArray addObject:@(chars[c])];
        }
        
        // Encode attribute buffer if available
        NSMutableArray *attrArray = [NSMutableArray array];
        if (snap.attributeBuffer) {
            const uint32_t *attrs = (const uint32_t *)snap.attributeBuffer.bytes;
            for (NSUInteger a = 0; a < totalCells; a++) {
                [attrArray addObject:@(attrs[a])];
            }
        }
        
        NSDictionary *frameDict = @{
            @"index": @(i),
            @"timestamp": @(snap.timestamp),
            @"rows": @(snap.rows),
            @"cols": @(snap.cols),
            @"cursorRow": @(snap.cursorRow),
            @"cursorCol": @(snap.cursorCol),
            @"pinned": @(isPinned),
            @"chars": charArray,
            @"attrs": attrArray
        };
        [framesArray addObject:frameDict];
    }
    
    NSDictionary *exportPackage = @{
        @"version": @"1.0",
        @"app": @"DX3270",
        @"exportedAt": @([[NSDate date] timeIntervalSince1970]),
        @"baselinePinIndex": @(_baselinePinIndex),
        @"totalFrames": @(_history.count),
        @"frames": framesArray
    };
    
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:exportPackage options:NSJSONWritingPrettyPrinted error:outError];
    if (!jsonData) return NO;
    
    return [jsonData writeToURL:fileURL options:NSDataWritingAtomic error:outError];
}

- (BOOL)importAuditTraceFromURL:(NSURL *)fileURL error:(NSError **)outError {
    NSData *jsonData = [NSData dataWithContentsOfURL:fileURL options:0 error:outError];
    if (!jsonData) return NO;
    
    NSDictionary *package = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:outError];
    if (!package || ![package isKindOfClass:[NSDictionary class]]) return NO;
    
    NSArray *frames = package[@"frames"];
    if (!frames || ![frames isKindOfClass:[NSArray class]]) return NO;
    
    [self clearHistory];
    
    _baselinePinIndex = [package[@"baselinePinIndex"] integerValue];
    
    for (NSDictionary *frameDict in frames) {
        int rows = [frameDict[@"rows"] intValue];
        int cols = [frameDict[@"cols"] intValue];
        NSUInteger totalCells = rows * cols;
        
        NSArray *charArray = frameDict[@"chars"];
        unichar *chars = (unichar *)malloc(sizeof(unichar) * totalCells);
        for (NSUInteger c = 0; c < totalCells && c < charArray.count; c++) {
            chars[c] = (unichar)[charArray[c] unsignedShortValue];
        }
        
        NSArray *attrArray = frameDict[@"attrs"];
        uint32_t *attrs = (uint32_t *)malloc(sizeof(uint32_t) * totalCells);
        for (NSUInteger a = 0; a < totalCells && a < attrArray.count; a++) {
            attrs[a] = (uint32_t)[attrArray[a] unsignedIntValue];
        }
        
        ScreenSnapshot *snap = [[ScreenSnapshot alloc] init];
        snap.timestamp = [frameDict[@"timestamp"] doubleValue];
        snap.rows = rows;
        snap.cols = cols;
        snap.cursorRow = [frameDict[@"cursorRow"] intValue];
        snap.cursorCol = [frameDict[@"cursorCol"] intValue];
        snap.characterBuffer = [NSData dataWithBytes:chars length:sizeof(unichar) * totalCells];
        snap.attributeBuffer = [NSData dataWithBytes:attrs length:sizeof(uint32_t) * totalCells];
        
        [_history addObject:snap];
        
        if ([frameDict[@"pinned"] boolValue]) {
            [_internalPinnedIndices addObject:@(_history.count - 1)];
        }
        
        free(chars);
        free(attrs);
    }
    
    return YES;
}

- (BOOL)exportPDFReportToURL:(NSURL *)fileURL error:(NSError **)outError {
    NSMutableData *pdfData = [NSMutableData data];
    
    CGRect pageRect = CGRectMake(0, 0, 612, 792);
    CGDataConsumerRef consumer = CGDataConsumerCreateWithCFData((__bridge CFMutableDataRef)pdfData);
    CGContextRef pdfContext = CGPDFContextCreate(consumer, &pageRect, NULL);
    CGDataConsumerRelease(consumer);
    
    if (!pdfContext) return NO;
    
    NSFont *monoFont = [NSFont fontWithName:@"Menlo" size:8.0] ?: [NSFont monospacedSystemFontOfSize:8.0 weight:NSFontWeightRegular];
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"yyyy-MM-dd HH:mm:ss";
    
    for (NSUInteger i = 0; i < _history.count; i++) {
        ScreenSnapshot *snap = _history[i];
        BOOL isPinned = [_internalPinnedIndices containsObject:@(i)];
        
        CGPDFContextBeginPage(pdfContext, NULL);
        NSGraphicsContext *gc = [NSGraphicsContext graphicsContextWithCGContext:pdfContext flipped:YES];
        [NSGraphicsContext saveGraphicsState];
        [NSGraphicsContext setCurrentContext:gc];
        
        NSString *timeStr = [fmt stringFromDate:[NSDate dateWithTimeIntervalSince1970:snap.timestamp]];
        NSString *header = [NSString stringWithFormat:@"DX3270 Audit Trace - Frame #%ld/%ld  |  %@  %@", 
                            (long)(i + 1), (long)_history.count, timeStr, isPinned ? @"[📍 PINNED]" : @""];
        
        NSDictionary *headerAttrs = @{
            NSFontAttributeName: [NSFont systemFontOfSize:11 weight:NSFontWeightBold],
            NSForegroundColorAttributeName: isPinned ? [NSColor systemOrangeColor] : [NSColor textColor]
        };
        [header drawAtPoint:NSMakePoint(36, 36) withAttributes:headerAttrs];
        
        NSRect screenRect = NSMakeRect(36, 60, 540, 680);
        [[NSColor blackColor] setFill];
        NSRectFill(screenRect);
        
        const unichar *chars = (const unichar *)snap.characterBuffer.bytes;
        CGFloat charW = 540.0 / snap.cols;
        CGFloat charH = 680.0 / snap.rows;
        
        for (int r = 0; r < snap.rows; r++) {
            for (int c = 0; c < snap.cols; c++) {
                unichar ch = chars[r * snap.cols + c];
                if (ch > 0x20) {
                    NSString *str = [NSString stringWithCharacters:&ch length:1];
                    NSDictionary *cellAttrs = @{
                        NSFontAttributeName: monoFont,
                        NSForegroundColorAttributeName: [NSColor greenColor]
                    };
                    [str drawAtPoint:NSMakePoint(36 + c * charW, 60 + r * charH) withAttributes:cellAttrs];
                }
            }
        }
        
        [NSGraphicsContext restoreGraphicsState];
        CGPDFContextEndPage(pdfContext);
    }
    
    CGPDFContextClose(pdfContext);
    CGContextRelease(pdfContext);
    
    return [pdfData writeToURL:fileURL options:NSDataWritingAtomic error:outError];
}


@end