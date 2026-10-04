#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, CellDiffState) {
    CellDiffUnchanged = 0,
    CellDiffModified,
    CellDiffAdded
};

@interface ScreenSnapshot : NSObject
@property (nonatomic, assign) NSTimeInterval timestamp;
@property (nonatomic, assign) int rows;
@property (nonatomic, assign) int cols;
@property (nonatomic, strong) NSData *characterBuffer; // Unichar array
@property (nonatomic, strong) NSData *attributeBuffer; // Color/style attributes
@property (nonatomic, assign) int cursorRow;
@property (nonatomic, assign) int cursorCol;
@property (nonatomic, copy) NSString *screenTitle;
@end

@interface TimeMachineManager : NSObject

@property (nonatomic, readonly) NSSet<NSNumber *> *pinnedIndices;
@property (nonatomic, assign) NSInteger baselinePinIndex;

+ (instancetype)sharedManager;

- (void)captureSnapshotWithRows:(int)rows
                           cols:(int)cols
                          chars:(const unichar *)chars
                     attributes:(const uint32_t *)attrs
                      cursorRow:(int)cursorRow
                      cursorCol:(int)cursorCol;

- (NSArray<ScreenSnapshot *> *)allSnapshots;
- (ScreenSnapshot *)snapshotAtIndex:(NSInteger)index;
- (void)clearHistory;

// Diff Engine
- (NSArray<NSNumber *> *)compareSnapshot:(ScreenSnapshot *)snapA
                            withSnapshot:(ScreenSnapshot *)snapB;

// Pinning & POI
- (void)togglePinAtIndex:(NSInteger)index;
- (BOOL)isPinnedAtIndex:(NSInteger)index;
- (NSInteger)nextPinnedIndexAfter:(NSInteger)index;
- (NSInteger)prevPinnedIndexBefore:(NSInteger)index;

// --- EXPORT & IMPORT ENGINE ---
- (BOOL)exportAuditTraceToURL:(NSURL *)fileURL error:(NSError **)outError;
- (BOOL)exportPDFReportToURL:(NSURL *)fileURL error:(NSError **)outError;
- (BOOL)importAuditTraceFromURL:(NSURL *)fileURL error:(NSError **)outError;

@end