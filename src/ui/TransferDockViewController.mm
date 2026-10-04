#import "TransferDockViewController.h"
#import <netdb.h>
#import <sys/socket.h>
#import <Security/Security.h>

#pragma mark - DragDropTextField Component

@interface DragDropTextField : NSTextField
@end

@implementation DragDropTextField

- (instancetype)initWithFrame:(NSRect)frameRect {
    if ((self = [super initWithFrame:frameRect])) {
        [self registerForDraggedTypes:@[NSPasteboardTypeFileURL]];
    }
    return self;
}

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender {
    NSPasteboard *pb = [sender draggingPasteboard];
    if ([pb.types containsObject:NSPasteboardTypeFileURL]) {
        return NSDragOperationCopy;
    }
    return NSDragOperationNone;
}

- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
    NSPasteboard *pb = [sender draggingPasteboard];
    NSURL *fileURL = [NSURL URLFromPasteboard:pb];
    if (fileURL) {
        self.stringValue = fileURL.path;
        return YES;
    }
    return NO;
}

@end

#pragma mark - TransferDockViewController

@interface TransferDockViewController () <NSTextFieldDelegate>
@property (nonatomic, strong) NSPopUpButton *toolPopup;
@property (nonatomic, strong) NSPopUpButton *modePopup;
@property (nonatomic, strong) NSPopUpButton *directionPopup;
@property (nonatomic, strong) NSTextField   *userField;
@property (nonatomic, strong) NSSecureTextField *passwordField;
@property (nonatomic, strong) NSButton      *useKeyCheckbox;
@property (nonatomic, strong) NSTextField   *remoteDSField;
@property (nonatomic, strong) DragDropTextField *localPathField;
@property (nonatomic, strong) NSProgressIndicator *spinner;
@property (nonatomic, strong) NSTextView    *consoleView;
@property (nonatomic, strong) NSButton      *actionButton;
@property (nonatomic, strong) NSTask        *currentTask;
@property (nonatomic, copy)   NSString      *zowePath;

- (void)savePasswordToKeychain:(NSString *)password forUser:(NSString *)user;
- (void)loadPasswordFromKeychainForUser:(NSString *)user;
@end

@implementation TransferDockViewController

- (void)setCurrentHost:(NSString *)currentHost {
    _currentHost = [currentHost copy];
    // Re-Calculate the open ports (SSH/FTP) when the active terminal changes
    if (self.isViewLoaded) {
        [self runProtocolProbes];
    }
}

- (void)loadView {
    NSVisualEffectView *containerView = [[NSVisualEffectView alloc] initWithFrame:NSMakeRect(0, 0, 280, 640)];
    containerView.material = NSVisualEffectMaterialSidebar;
    containerView.appearance = [NSAppearance appearanceNamed:NSAppearanceNameVibrantDark];
    containerView.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    containerView.state = NSVisualEffectStateActive;
    containerView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    
    self.view = containerView;
    NSStackView *stack = [[NSStackView alloc] initWithFrame:containerView.bounds];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 8;
    stack.edgeInsets = NSEdgeInsetsMake(14, 12, 14, 12);
    stack.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    // --- Header ---
    NSTextField *titleLabel = [NSTextField labelWithString:@"z/OS File Transfer Dock"];
    titleLabel.font = [NSFont boldSystemFontOfSize:13];
    [stack addArrangedSubview:titleLabel];

    NSBox *sep1 = [[NSBox alloc] init];
    sep1.boxType = NSBoxSeparator;
    [sep1.widthAnchor constraintEqualToConstant:256].active = YES;
    [stack addArrangedSubview:sep1];

    // --- Protocol / Engine Selector ---
    [stack addArrangedSubview:[self createLabel:@"Protocol / Engine:"]];
    self.toolPopup = [[NSPopUpButton alloc] init];
    [self.toolPopup addItemsWithTitles:@[
        @"CoZ SFTP (SSH + EBCDIC)",
        @"Standard SFTP (USS / Binary)",
        @"FTP / FTPS (IBM z/OS FTP)",
        @"z/OSMF REST API (curl)",
        @"Zowe CLI"
    ]];
    [self.toolPopup.widthAnchor constraintEqualToConstant:254].active = YES;
    [stack addArrangedSubview:self.toolPopup];

    // --- Direction & Mode ---
    NSStackView *hStack = [[NSStackView alloc] init];
    hStack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    hStack.spacing = 6;

    self.directionPopup = [[NSPopUpButton alloc] init];
    [self.directionPopup addItemsWithTitles:@[@"Download ↓", @"Upload ↑"]];
    [self.directionPopup.widthAnchor constraintEqualToConstant:122].active = YES;

    self.modePopup = [[NSPopUpButton alloc] init];
    [self.modePopup addItemsWithTitles:@[@"Text (EBCDIC)", @"Binary"]];
    [self.modePopup.widthAnchor constraintEqualToConstant:126].active = YES;

    [hStack addArrangedSubview:self.directionPopup];
    [hStack addArrangedSubview:self.modePopup];
    [stack addArrangedSubview:hStack];

    // --- z/OS Credentials ---
    [stack addArrangedSubview:[self createLabel:@"z/OS Credentials:"]];
    
    NSStackView *credStack = [[NSStackView alloc] init];
    credStack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    credStack.spacing = 6;

    self.userField = [NSTextField textFieldWithString:@""];
    self.userField.placeholderString = @"User";
    self.userField.delegate = self;
    [self.userField.widthAnchor constraintEqualToConstant:120].active = YES;
    self.userField.usesSingleLineMode = YES;
    self.userField.cell.wraps = NO;
    self.userField.cell.scrollable = YES;
    [self.userField setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    
    NSString *savedUser = [[NSUserDefaults standardUserDefaults] stringForKey:@"DX3270_TransferUser"];
    if (savedUser) {
        self.userField.stringValue = savedUser;
    }
    
    self.passwordField = [NSSecureTextField textFieldWithString:@""];
    self.passwordField.placeholderString = @"Password";
    [self.passwordField.widthAnchor constraintEqualToConstant:128].active = YES;
    self.passwordField.usesSingleLineMode = YES;
    self.passwordField.cell.wraps = NO;
    self.passwordField.cell.scrollable = YES;
    [self.passwordField setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];

    [credStack addArrangedSubview:self.userField];
    [credStack addArrangedSubview:self.passwordField];
    [stack addArrangedSubview:credStack];

    // Checkbox Key/Keychain
    self.useKeyCheckbox = [NSButton checkboxWithTitle:@"Use SSH Key / Keychain" target:self action:@selector(toggleKeyAuth:)];
    self.useKeyCheckbox.font = [NSFont systemFontOfSize:10];
    [stack addArrangedSubview:self.useKeyCheckbox];

    // Tentativo recupero password da Keychain se utente salvato
    if (savedUser.length > 0) {
        [self loadPasswordFromKeychainForUser:savedUser];
    }

    // --- Remote Dataset / USS Path ---
    [stack addArrangedSubview:[self createLabel:@"z/OS Dataset or USS Path:"]];
    self.remoteDSField = [NSTextField textFieldWithString:@""];
    self.remoteDSField.placeholderString = @"e.g. 'USER.COBOL(MEMBER)'";
    [self.remoteDSField.widthAnchor constraintEqualToConstant:254].active = YES;
    self.remoteDSField.usesSingleLineMode = YES;
    self.remoteDSField.cell.wraps = NO;
    self.remoteDSField.cell.scrollable = YES;
    [self.remoteDSField setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    [stack addArrangedSubview:self.remoteDSField];

    // --- Local File Path (con DRAG & DROP) ---
    [stack addArrangedSubview:[self createLabel:@"Local Target File (Drop supported):"]];
    
    NSStackView *localFileStack = [[NSStackView alloc] init];
    localFileStack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    localFileStack.spacing = 6;

    self.localPathField = [[DragDropTextField alloc] initWithFrame:NSZeroRect];
    self.localPathField.placeholderString = @"(Drop file here or leave blank)";
    self.localPathField.lineBreakMode = NSLineBreakByTruncatingHead;
    [self.localPathField.widthAnchor constraintEqualToConstant:180].active = YES;
    self.localPathField.usesSingleLineMode = YES;
    self.localPathField.cell.wraps = NO;
    self.localPathField.cell.scrollable = YES;
    [self.localPathField setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];

    NSButton *browseBtn = [NSButton buttonWithTitle:@"Browse…" target:self action:@selector(browseLocalFile:)];
    browseBtn.bezelStyle = NSBezelStyleRounded;

    [localFileStack addArrangedSubview:self.localPathField];
    [localFileStack addArrangedSubview:browseBtn];
    [stack addArrangedSubview:localFileStack];

    // --- Action Button & Spinner ---
    NSStackView *actionStack = [[NSStackView alloc] init];
    actionStack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    actionStack.spacing = 8;
    actionStack.detachesHiddenViews = NO; 

    self.actionButton = [NSButton buttonWithTitle:@"Start Transfer" target:self action:@selector(executeTransfer:)];
    self.actionButton.bezelStyle = NSBezelStyleRounded;

    self.spinner = [[NSProgressIndicator alloc] init];
    self.spinner.style = NSProgressIndicatorStyleSpinning;
    self.spinner.controlSize = NSControlSizeSmall;
    self.spinner.displayedWhenStopped = YES; 
    self.spinner.alphaValue = 0.0;

    [actionStack addArrangedSubview:self.actionButton];
    [actionStack addArrangedSubview:self.spinner];
    [stack addArrangedSubview:actionStack];

    // --- Console Header with Clear Button ---
    NSStackView *consoleHeaderStack = [[NSStackView alloc] init];
    consoleHeaderStack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    consoleHeaderStack.alignment = NSLayoutAttributeCenterY;

    NSTextField *consoleLabel = [self createLabel:@"Transfer Output:"];
    NSButton *clearBtn = [NSButton buttonWithTitle:@"Clear" target:self action:@selector(clearConsole:)];
    clearBtn.bezelStyle = NSBezelStyleInline;
    clearBtn.controlSize = NSControlSizeSmall;
    clearBtn.font = [NSFont systemFontOfSize:10 weight:NSFontWeightRegular];

    [consoleHeaderStack addArrangedSubview:consoleLabel];
    [consoleHeaderStack addArrangedSubview:clearBtn];
    [stack addArrangedSubview:consoleHeaderStack];

    // --- Console Output ---
    NSScrollView *scroll = [[NSScrollView alloc] init];
    scroll.hasVerticalScroller = YES;
    scroll.hasHorizontalScroller = NO;
    scroll.autohidesScrollers = YES;
    scroll.borderType = NSBezelBorder;
    [scroll.heightAnchor constraintEqualToConstant:120].active = YES;
    [scroll.widthAnchor constraintEqualToConstant:254].active = YES;

    self.consoleView = [[NSTextView alloc] initWithFrame:scroll.bounds];
    self.consoleView.editable = NO;
    self.consoleView.selectable = YES;
    self.consoleView.font = [NSFont monospacedSystemFontOfSize:10 weight:NSFontWeightRegular];
    self.consoleView.backgroundColor = [NSColor colorWithWhite:0.08 alpha:1.0];
    self.consoleView.textColor = [NSColor colorWithRed:0.4 green:0.9 blue:0.4 alpha:1.0];
    
    self.consoleView.selectedTextAttributes = @{
        NSBackgroundColorAttributeName: [NSColor colorWithRed:0.2 green:0.6 blue:0.2 alpha:1.0],
        NSForegroundColorAttributeName: [NSColor blackColor]
    };
    
    self.consoleView.horizontallyResizable = NO;
    self.consoleView.verticallyResizable = YES;
    self.consoleView.autoresizingMask = NSViewWidthSizable;
    [self.consoleView.textContainer setWidthTracksTextView:YES];
    self.consoleView.textContainer.lineBreakMode = NSLineBreakByCharWrapping;

    scroll.documentView = self.consoleView;
    [stack addArrangedSubview:scroll];

    [containerView addSubview:stack];

    [self runProtocolProbes];
}

#pragma mark - Keychain & Auth Helpers

- (void)toggleKeyAuth:(id)sender {
    BOOL useKey = (self.useKeyCheckbox.state == NSControlStateValueOn);
    self.passwordField.enabled = !useKey;
    if (useKey) {
        self.passwordField.stringValue = @"";
    }
}

- (void)savePasswordToKeychain:(NSString *)password forUser:(NSString *)user {
    if (!user.length || !password.length) return;
    
    NSString *host = self.currentHost ?: @"localhost";
    NSString *serviceName = [NSString stringWithFormat:@"DX3270_Mainframe_%@", host];
    
    NSData *passData = [password dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: serviceName,
        (__bridge id)kSecAttrAccount: user
    };
    
    SecItemDelete((__bridge CFDictionaryRef)query);
    
    NSMutableDictionary *attributes = [query mutableCopy];
    attributes[(__bridge id)kSecValueData] = passData;
    
    SecItemAdd((__bridge CFDictionaryRef)attributes, NULL);
}

- (NSString *)promptForPasswordForUser:(NSString *)user host:(NSString *)host {
    __block NSString *enteredPassword = nil;
    
    dispatch_sync(dispatch_get_main_queue(), ^{
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = [NSString stringWithFormat:@"Autenticazione SSH OOB per %@", host];
        alert.informativeText = [NSString stringWithFormat:@"Inserisci la password SSH per l'utente '%@':", user];
        alert.alertStyle = NSAlertStyleInformational;
        
        NSSecureTextField *input = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(0, 0, 260, 24)];
        alert.accessoryView = input;
        
        [alert addButtonWithTitle:@"OK"];
        [alert addButtonWithTitle:@"Annulla"];
        
        [alert.window makeFirstResponder:input];
        
        NSModalResponse response = [alert runModal];
        if (response == NSAlertFirstButtonReturn) {
            enteredPassword = input.stringValue;
        }
    });
    
    if (enteredPassword.length > 0) {
        [self savePasswordToKeychain:enteredPassword forUser:user];
    }
    
    return enteredPassword;
}

- (void)loadPasswordFromKeychainForUser:(NSString *)user {
    if (!user.length) return;
    
    NSString *host = self.currentHost ?: @"localhost";
    NSString *serviceName = [NSString stringWithFormat:@"DX3270_Mainframe_%@", host];
    
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: serviceName,
        (__bridge id)kSecAttrAccount: user,
        (__bridge id)kSecReturnData: @YES,
        (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitOne
    };
    
    CFTypeRef dataTypeRef = NULL;
    if (SecItemCopyMatching((__bridge CFDictionaryRef)query, &dataTypeRef) == errSecSuccess) {
        NSData *data = (__bridge_transfer NSData *)dataTypeRef;
        NSString *pass = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (pass) {
            self.passwordField.stringValue = pass;
        }
    }
}

- (void)controlTextDidChange:(NSNotification *)obj {
    if (obj.object == self.userField) {
        [self loadPasswordFromKeychainForUser:self.userField.stringValue];
    }
}

#pragma mark - Background Probes

- (void)runProtocolProbes {
    NSString *host = self.currentHost ?: @"localhost";
    
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:@"/opt/homebrew/bin/zowe"]) {
        self.zowePath = @"/opt/homebrew/bin/zowe";
    } else if ([fm fileExistsAtPath:@"/usr/local/bin/zowe"]) {
        self.zowePath = @"/usr/local/bin/zowe";
    } else {
        self.zowePath = nil;
        [self.toolPopup itemAtIndex:4].enabled = NO;
    }

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        BOOL ftpOpen    = [self checkPort:21 host:host] || [self checkPort:990 host:host];
        BOOL zosmfOpen  = [self checkPort:10443 host:host];
        BOOL sshOpen    = [self checkPort:22 host:host];

        dispatch_async(dispatch_get_main_queue(), ^{
            [self.toolPopup itemAtIndex:0].enabled = sshOpen;
            [self.toolPopup itemAtIndex:1].enabled = sshOpen;
            [self.toolPopup itemAtIndex:2].enabled = ftpOpen;
            [self.toolPopup itemAtIndex:3].enabled = zosmfOpen;

            if (!self.toolPopup.selectedItem.isEnabled) {
                for (NSMenuItem *item in self.toolPopup.itemArray) {
                    if (item.isEnabled) {
                        [self.toolPopup selectItem:item];
                        break;
                    }
                }
            }
        });
    });
}

- (BOOL)checkPort:(int)port host:(NSString *)host {
    struct sockaddr_in addr;
    int sock = socket(AF_INET, SOCK_STREAM, 0);
    if (sock < 0) return NO;

    struct hostent *hp = gethostbyname([host UTF8String]);
    if (!hp) {
        close(sock);
        return NO;
    }

    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    memcpy(&addr.sin_addr, hp->h_addr, hp->h_length);

    struct timeval tv;
    tv.tv_sec = 1;
    tv.tv_usec = 0;
    setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, (const char*)&tv, sizeof(tv));
    setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, (const char*)&tv, sizeof(tv));

    int res = connect(sock, (struct sockaddr *)&addr, sizeof(addr));
    close(sock);
    return (res == 0);
}

- (NSTextField *)createLabel:(NSString *)text {
    NSTextField *lbl = [NSTextField labelWithString:text];
    lbl.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    lbl.textColor = [NSColor secondaryLabelColor];
    return lbl;
}

- (void)clearConsole:(id)sender {
    [self.consoleView.textStorage beginEditing];
    [self.consoleView.textStorage setAttributedString:[[NSAttributedString alloc] initWithString:@""]];
    [self.consoleView.textStorage endEditing];
}

- (void)logMessage:(NSString *)msg {
    NSLog(@"[TransferDock] %@", msg);
    
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *formatted = [NSString stringWithFormat:@"%@\n", msg];
        NSAttributedString *attrStr = [[NSAttributedString alloc] initWithString:formatted
             attributes:@{
                NSFontAttributeName: [NSFont monospacedSystemFontOfSize:10 weight:NSFontWeightRegular],
                NSForegroundColorAttributeName: [NSColor colorWithRed:0.4 green:0.9 blue:0.4 alpha:1.0]
            }];
        
        [self.consoleView.textStorage beginEditing];
        [self.consoleView.textStorage appendAttributedString:attrStr];
        [self.consoleView.textStorage endEditing];
        
        NSRange endRange = NSMakeRange(self.consoleView.textStorage.length, 0);
        [self.consoleView scrollRangeToVisible:endRange];
    });
}

- (void)browseLocalFile:(id)sender {
    BOOL isUpload = (self.directionPopup.indexOfSelectedItem == 1);
    
    if (isUpload) {
        NSOpenPanel *panel = [NSOpenPanel openPanel];
        panel.canChooseFiles = YES;
        panel.canChooseDirectories = NO;
        [panel beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse result) {
            if (result == NSModalResponseOK && panel.URL) {
                self.localPathField.stringValue = panel.URL.path;
            }
        }];
    } else {
        NSSavePanel *panel = [NSSavePanel savePanel];
        [panel beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse result) {
            if (result == NSModalResponseOK && panel.URL) {
                self.localPathField.stringValue = panel.URL.path;
            }
        }];
    }
}

- (void)executeTransfer:(id)sender {
    NSString *remoteTarget = [self.remoteDSField.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@" '"]];
    __block NSString *localTarget  = [self.localPathField.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    
    NSString *user = [self.userField.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    NSString *password = self.passwordField.stringValue;
    BOOL useKey = (self.useKeyCheckbox.state == NSControlStateValueOn);
    
    BOOL isUpload = (self.directionPopup.indexOfSelectedItem == 1);

    if (user.length > 0) {
        [[NSUserDefaults standardUserDefaults] setObject:user forKey:@"DX3270_TransferUser"];
    }

    if (localTarget.length == 0 && !isUpload && remoteTarget.length > 0) {
        NSString *safeName = [[remoteTarget componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"'()\\/"]] componentsJoinedByString:@"_"];
        safeName = [safeName stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"_"]];
        if (safeName.length == 0) safeName = @"zos_download";
        
        localTarget = [NSString stringWithFormat:@"%@/Downloads/%@", NSHomeDirectory(), safeName];
        
        dispatch_async(dispatch_get_main_queue(), ^{
            self.localPathField.stringValue = localTarget;
        });
    }

    if (remoteTarget.length == 0 || localTarget.length == 0) {
        NSBeep();
        [self logMessage:@"[ERROR] Please specify the z/OS target. For uploads, a local file is also required."];
        return;
    }

    self.spinner.alphaValue = 1.0; 
    [self.spinner startAnimation:nil];
    self.actionButton.enabled = NO;

    NSInteger protocolIndex = self.toolPopup.indexOfSelectedItem;
    BOOL isBinary           = (self.modePopup.indexOfSelectedItem == 1);
    NSString *host          = self.currentHost ?: @"localhost";
    NSString *targetHost    = (user.length > 0) ? [NSString stringWithFormat:@"%@@%@", user, host] : host;

    [self logMessage:[NSString stringWithFormat:@"[START] %@ %@ on host %@", 
                      self.toolPopup.titleOfSelectedItem, 
                      isUpload ? @"Upload" : @"Download", host]];

    self.currentTask = [[NSTask alloc] init];
    NSPipe *pipe = [NSPipe pipe];
    self.currentTask.standardOutput = pipe;
    self.currentTask.standardError = pipe;

    if (protocolIndex == 0 || protocolIndex == 1) {
        self.currentTask.launchPath = @"/usr/bin/expect";
        NSMutableDictionary *env = [[NSProcessInfo processInfo].environment mutableCopy];
        if (password.length > 0 && !useKey) env[@"SFTP_PASS"] = password;
        self.currentTask.environment = env;
        
        self.currentTask.arguments = @[@"-"];
        NSPipe *inputPipe = [NSPipe pipe];
        self.currentTask.standardInput = inputPipe;
        
        NSMutableString *script = [NSMutableString string];
        
        // Flag -o BatchMode=yes se si usa la chiave SSH, così non chiede password
        if (useKey) {
            [script appendFormat:@"spawn sftp -o BatchMode=yes %@\n", targetHost];
        } else {
            [script appendFormat:@"spawn sftp %@\n", targetHost];
        }
        
        [script appendString:@"set timeout 30\n"];
        [script appendString:@"expect {\n"];
        [script appendString:@"  \"*yes/no*\" { send \"yes\\r\"; exp_continue }\n"];
        
        if (!useKey) {
            [script appendString:@"  \"*assword:*\" {\n"];
            [script appendString:@"      if {[info exists env(SFTP_PASS)]} {\n"];
            [script appendString:@"          send \"$env(SFTP_PASS)\\r\"\n"];
            [script appendString:@"          exp_continue\n"];
            [script appendString:@"      } else {\n"];
            [script appendString:@"          puts \"\\nERROR: Password required but not provided!\"\n"];
            [script appendString:@"          exit 1\n"];
            [script appendString:@"      }\n"];
            [script appendString:@"  }\n"];
        }
        
        [script appendString:@"  \"sftp>\" { }\n"];
        [script appendString:@"}\n"];

        if (protocolIndex == 0) { 
            if (isBinary) {
                [script appendString:@"send \"ls /+mode=binary\\r\"\n"];
            } else {
                [script appendString:@"send \"ls /+mode=text,servercp=IBM-1047,clientcp=UTF-8\\r\"\n"];
            }
            [script appendString:@"expect \"sftp>\"\n"];
            
            if (isUpload) {
                [script appendFormat:@"send \"put \\\"%@\\\" //%@\\r\"\n", localTarget, remoteTarget];
            } else {
                [script appendFormat:@"send \"get //%@ \\\"%@\\\"\\r\"\n", remoteTarget, localTarget];
            }
        } else { 
            if (isUpload) {
                [script appendFormat:@"send \"put \\\"%@\\\" \\\"%@\\\"\\r\"\n", localTarget, remoteTarget];
            } else {
                [script appendFormat:@"send \"get \\\"%@\\\" \\\"%@\\\"\\r\"\n", remoteTarget, localTarget];
            }
        }
        
        [script appendString:@"expect \"sftp>\"\n"];
        [script appendString:@"send \"quit\\r\"\n"];
        [script appendString:@"expect eof\n"];
        
        NSData *inputData = [script dataUsingEncoding:NSUTF8StringEncoding];
        [inputPipe.fileHandleForWriting writeData:inputData];
        [inputPipe.fileHandleForWriting closeFile];

    } else if (protocolIndex == 2) {
        self.currentTask.launchPath = @"/usr/bin/curl";
        NSMutableArray *args = [NSMutableArray arrayWithObject:@"-sS"];
        if (user.length > 0 && password.length > 0 && !useKey) {
            [args addObjectsFromArray:@[@"-u", [NSString stringWithFormat:@"%@:%@", user, password]]];
        }
        NSString *url = [NSString stringWithFormat:@"ftp://%@/'%@'", host, remoteTarget];
        
        if (isUpload) {
            [args addObjectsFromArray:@[@"-T", localTarget]];
        } else {
            [args addObjectsFromArray:@[@"-o", localTarget]];
        }
        if (!isBinary) [args addObject:@"--use-ascii"];
        [args addObject:url];
        self.currentTask.arguments = args;

    } else if (protocolIndex == 3) {
        self.currentTask.launchPath = @"/usr/bin/curl";
        NSMutableArray *args = [NSMutableArray arrayWithObject:@"-sS"];
        if (user.length > 0 && password.length > 0 && !useKey) {
            [args addObjectsFromArray:@[@"-u", [NSString stringWithFormat:@"%@:%@", user, password]]];
        }
        NSString *url = [NSString stringWithFormat:@"https://%@:10443/zosmf/restfiles/ds/%@", host, remoteTarget];
        
        if (isUpload) {
            [args addObjectsFromArray:@[@"-X", @"PUT", @"--data-binary", [NSString stringWithFormat:@"@%@", localTarget]]];
        } else {
            [args addObjectsFromArray:@[@"-X", @"GET", @"-o", localTarget]];
        }
        [args addObjectsFromArray:@[@"-H", isBinary ? @"X-IBM-Data-Type: binary" : @"X-IBM-Data-Type: text"]];
        [args addObject:url];
        self.currentTask.arguments = args;

    } else if (protocolIndex == 4) {
        self.currentTask.launchPath = self.zowePath ?: @"/opt/homebrew/bin/zowe";
        NSMutableArray *args = [NSMutableArray array];
        if (isUpload) {
            [args addObjectsFromArray:@[@"zos-files", @"upload", @"file-to-data-set", localTarget, remoteTarget]];
        } else {
            [args addObjectsFromArray:@[@"zos-files", @"download", @"data-set", remoteTarget, @"--file", localTarget]];
        }
        if (isBinary) [args addObject:@"--binary"];
        self.currentTask.arguments = args;
    }

    [pipe.fileHandleForReading setReadabilityHandler:^(NSFileHandle *handle) {
        NSData *data = [handle availableData];
        if (data.length > 0) {
            NSString *outStr = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            [self logMessage:outStr];
        }
    }];

    __weak typeof(self) weakSelf = self;
    self.currentTask.terminationHandler = ^(NSTask *task) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (strongSelf) {
                strongSelf.spinner.alphaValue = 0.0; 
                [strongSelf.spinner stopAnimation:nil];
                strongSelf.actionButton.enabled = YES;
                [strongSelf logMessage:[NSString stringWithFormat:@"[FINISHED] Exit code: %d", task.terminationStatus]];
                
                // Salva nel Keychain se il trasferimento ha avuto successo ed è stata usata una password
                if (task.terminationStatus == 0 && user.length > 0 && password.length > 0 && !useKey) {
                    [strongSelf savePasswordToKeychain:password forUser:user];
                }
            }
        });
    };

    NSError *err = nil;
    if (![self.currentTask launchAndReturnError:&err]) {
        [self logMessage:[NSString stringWithFormat:@"[ERROR] Launch failed: %@", err.localizedDescription]];
        self.spinner.alphaValue = 0.0; 
        [self.spinner stopAnimation:nil];
        self.actionButton.enabled = YES;
    }
}

@end