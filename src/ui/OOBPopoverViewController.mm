#import "OOBPopoverViewController.h"

@implementation OOBPopoverViewController

- (instancetype)initWithTitle:(NSString *)title content:(NSString *)content {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        [self loadViewWithTitle:title content:content];
    }
    return self;
}

- (void)loadViewWithTitle:(NSString *)title content:(NSString *)content {
    NSView *container = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 560, 320)];
    
    // Header Bar
    NSVisualEffectView *headerView = [[NSVisualEffectView alloc] initWithFrame:NSMakeRect(0, 280, 560, 40)];
    headerView.material = NSVisualEffectMaterialHeaderView;
    headerView.blendingMode = NSVisualEffectBlendingModeWithinWindow;
    
    self.titleLabel = [NSTextField labelWithString:title ?: @"OOB Result"];
    self.titleLabel.font = [NSFont systemFontOfSize:12 weight:NSFontWeightBold];
    self.titleLabel.frame = NSMakeRect(12, 10, 420, 20);
    [headerView addSubview:self.titleLabel];
    
    NSButton *copyBtn = [NSButton buttonWithTitle:@"Copy" target:self action:@selector(copyToClipboard:)];
    copyBtn.bezelStyle = NSBezelStyleInline;
    copyBtn.controlSize = NSControlSizeSmall;
    copyBtn.frame = NSMakeRect(480, 8, 68, 22);
    [headerView addSubview:copyBtn];
    
    [container addSubview:headerView];
    
    // Scrollable Monospaced Output View
    NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 560, 280)];
    scrollView.hasVerticalScroller = YES;
    scrollView.hasHorizontalScroller = YES;
    scrollView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    
    self.textView = [[NSTextView alloc] initWithFrame:scrollView.bounds];
    self.textView.editable = NO;
    self.textView.selectable = YES;
    self.textView.backgroundColor = [NSColor colorWithRed:0.1 green:0.1 blue:0.12 alpha:1.0];
    self.textView.textColor = [NSColor colorWithRed:0.85 green:0.85 blue:0.85 alpha:1.0];
    self.textView.font = [NSFont fontWithName:@"Menlo" size:11.0] ?: [NSFont userFixedPitchFontOfSize:11.0];
    self.textView.string = content ?: @"";
    
    scrollView.documentView = self.textView;
    [container addSubview:scrollView];
    
    self.view = container;
}

- (void)updateContent:(NSString *)content {
    if (self.textView) {
        self.textView.string = content ?: @"";
    }
}

- (void)copyToClipboard:(id)sender {
    if (self.textView.string.length > 0) {
        NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
        [pasteboard clearContents];
        [pasteboard writeObjects:@[self.textView.string]];
    }
}

@end