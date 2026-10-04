#import "TerminalPaneViewController.h"

@interface TerminalPaneViewController ()
@property (nonatomic, strong) NSView *headerView;
@property (nonatomic, strong) NSTextField *titleLabel;
@end

@implementation TerminalPaneViewController

- (instancetype)initWithTerminal:(TerminalViewController *)terminalVC {
    if (self = [super initWithNibName:nil bundle:nil]) {
        _terminalVC = terminalVC;
        _isActive = NO;
        [_terminalVC addObserver:self forKeyPath:@"title" options:NSKeyValueObservingOptionNew context:nil];
    }
    return self;
}

- (void)dealloc {
    [_terminalVC removeObserver:self forKeyPath:@"title"];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if ([keyPath isEqualToString:@"title"]) {
        self.titleLabel.stringValue = self.terminalVC.title ?: @"Unknown";
    }
}

- (void)loadView {
    self.view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 600, 400)];
    self.view.wantsLayer = YES;
    self.view.layer.backgroundColor = [NSColor blackColor].CGColor;
    
    // --- 1. Header Bar (Ancorata in alto) ---
    self.headerView = [[NSView alloc] init];
    self.headerView.translatesAutoresizingMaskIntoConstraints = NO;
    self.headerView.wantsLayer = YES;
    [self updateHeaderAppearance];
    [self.view addSubview:self.headerView];
    
    // --- 2. Terminal Container (Sotto l'header) ---
    [self addChildViewController:self.terminalVC];
    NSView *termView = self.terminalVC.view;
    termView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:termView];
    
    // Costruiamo la griglia del pannello con Auto Layout
    [NSLayoutConstraint activateConstraints:@[
        [self.headerView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.headerView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.headerView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.headerView.heightAnchor constraintEqualToConstant:24],
        
        [termView.topAnchor constraintEqualToAnchor:self.headerView.bottomAnchor],
        [termView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [termView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [termView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor]
    ]];
    
    // --- 3. Elementi Interni dell'Header ---
    self.titleLabel = [NSTextField labelWithString:self.terminalVC.title ?: @"Terminal"];
    self.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.titleLabel.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    self.titleLabel.textColor = [NSColor lightGrayColor];
    [self.headerView addSubview:self.titleLabel];
    
    NSButton *closeBtn = [self createHeaderButtonWithIcon:@"xmark" action:@selector(closeClicked:)];
    NSButton *splitDownBtn = [self createHeaderButtonWithIcon:@"rectangle.split.1x2" action:@selector(splitDownClicked:)];
    NSButton *splitRightBtn = [self createHeaderButtonWithIcon:@"rectangle.split.2x1" action:@selector(splitRightClicked:)];
    
    closeBtn.translatesAutoresizingMaskIntoConstraints = NO;
    splitDownBtn.translatesAutoresizingMaskIntoConstraints = NO;
    splitRightBtn.translatesAutoresizingMaskIntoConstraints = NO;
    
    [self.headerView addSubview:closeBtn];
    [self.headerView addSubview:splitDownBtn];
    [self.headerView addSubview:splitRightBtn];
    
    [NSLayoutConstraint activateConstraints:@[
        // Titolo a sinistra
        [self.titleLabel.centerYAnchor constraintEqualToAnchor:self.headerView.centerYAnchor],
        [self.titleLabel.leadingAnchor constraintEqualToAnchor:self.headerView.leadingAnchor constant:10],
        
        // Pulsanti allineati a destra, in successione
        [closeBtn.centerYAnchor constraintEqualToAnchor:self.headerView.centerYAnchor],
        [closeBtn.trailingAnchor constraintEqualToAnchor:self.headerView.trailingAnchor constant:-4],
        
        [splitDownBtn.centerYAnchor constraintEqualToAnchor:self.headerView.centerYAnchor],
        [splitDownBtn.trailingAnchor constraintEqualToAnchor:closeBtn.leadingAnchor constant:-4],
        
        [splitRightBtn.centerYAnchor constraintEqualToAnchor:self.headerView.centerYAnchor],
        [splitRightBtn.trailingAnchor constraintEqualToAnchor:splitDownBtn.leadingAnchor constant:-4]
    ]];
}

- (NSButton *)createHeaderButtonWithIcon:(NSString *)iconName action:(SEL)action {
    NSButton *btn = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:iconName accessibilityDescription:nil] target:self action:action];
    btn.bordered = NO;
    btn.bezelStyle = NSBezelStyleInline;
    btn.contentTintColor = [NSColor grayColor];
    return btn;
}

- (void)setIsActive:(BOOL)isActive {
    _isActive = isActive;
    [self updateHeaderAppearance];
}

- (void)updateHeaderAppearance {
    if (!self.headerView) return;
    
    if (_isActive) {
        self.headerView.layer.backgroundColor = [NSColor colorWithRed:0.1 green:0.3 blue:0.6 alpha:1.0].CGColor;
        self.titleLabel.textColor = [NSColor whiteColor];
    } else {
        self.headerView.layer.backgroundColor = [NSColor colorWithWhite:0.15 alpha:1.0].CGColor;
        self.titleLabel.textColor = [NSColor lightGrayColor];
    }
}

- (void)mouseDown:(NSEvent *)event {
    [super mouseDown:event];
    
    // Officially move the window's First Responder to the terminal of this panel
    if (self.terminalVC && self.terminalVC.view) {
        [self.view.window makeFirstResponder:self.terminalVC.view];
    }

    if (self.delegate) [self.delegate paneDidGainFocus:self];
}

#pragma mark - Actions

- (void)closeClicked:(id)sender {
    if (self.delegate) [self.delegate paneDidRequestClose:self];
}

- (void)splitRightClicked:(id)sender {
    if (self.delegate) [self.delegate paneDidRequestSplitRight:self];
}

- (void)splitDownClicked:(id)sender {
    if (self.delegate) [self.delegate paneDidRequestSplitDown:self];
}

@end