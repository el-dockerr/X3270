#import "WorkspaceManager.h"

@implementation DXSessionConfig
- (instancetype)init {
    if (self = [super init]) {
        _name = @"New Session";
        _host = @"";
        _port = 23;
        _useSSL = NO;
        _verifyCert = YES;
        _caBundle = @"";
        _codePage = 0; // CP037
        _model = 0;    // Model2
        _protocol = 0; // TN3270
        _customFastPaths = @[]; // Inizializzazione del nuovo array
    }
    return self;
}

- (NSDictionary *)toDictionary {
    NSMutableDictionary *dict = [@{
        @"name": self.name ?: @"",
        @"host": self.host ?: @"",
        @"port": @(self.port),
        @"useSSL": @(self.useSSL),
        @"verifyCert": @(self.verifyCert),
        @"caBundle": self.caBundle ?: @"",
        @"codePage": @(self.codePage),
        @"model": @(self.model),
        @"protocol": @(self.protocol)
    } mutableCopy];
    
    // Salva l'array dei percorsi personalizzati se esiste e non è vuoto
    if (self.customFastPaths && self.customFastPaths.count > 0) {
        dict[@"customFastPaths"] = self.customFastPaths;
    }
    
    return dict;
}

+ (instancetype)fromDictionary:(NSDictionary *)dict {
    DXSessionConfig *config = [[DXSessionConfig alloc] init];
    if (!dict) return config;
    
    config.name = dict[@"name"] ?: @"";
    config.host = dict[@"host"] ?: @"";
    config.port = [dict[@"port"] unsignedShortValue];
    config.useSSL = [dict[@"useSSL"] boolValue];
    config.verifyCert = dict[@"verifyCert"] ? [dict[@"verifyCert"] boolValue] : YES;
    config.caBundle = dict[@"caBundle"] ?: @"";
    config.codePage = [dict[@"codePage"] integerValue];
    config.model = [dict[@"model"] integerValue];
    config.protocol = [dict[@"protocol"] integerValue];
    
    // Carica l'array dei percorsi personalizzati
    NSArray *paths = dict[@"customFastPaths"];
    if ([paths isKindOfClass:[NSArray class]]) {
        config.customFastPaths = paths;
    }
    
    return config;
}
@end

@implementation DXWorkspaceGroup
- (instancetype)init {
    if (self = [super init]) {
        _name = @"New Group";
        _sessions = [NSMutableArray array];
    }
    return self;
}

- (NSDictionary *)toDictionary {
    NSMutableArray *sessionsArray = [NSMutableArray array];
    for (DXSessionConfig *session in self.sessions) {
        [sessionsArray addObject:[session toDictionary]];
    }
    return @{@"name": self.name ?: @"", @"sessions": sessionsArray};
}

+ (instancetype)fromDictionary:(NSDictionary *)dict {
    DXWorkspaceGroup *group = [[DXWorkspaceGroup alloc] init];
    if (!dict) return group;
    
    group.name = dict[@"name"] ?: @"";
    NSArray *sessionsData = dict[@"sessions"];
    if ([sessionsData isKindOfClass:[NSArray class]]) {
        for (NSDictionary *sDict in sessionsData) {
            [group.sessions addObject:[DXSessionConfig fromDictionary:sDict]];
        }
    }
    return group;
}
@end

@implementation DXWorkspace
- (instancetype)init {
    if (self = [super init]) {
        _name = @"New Workspace";
        _groups = [NSMutableArray array];
    }
    return self;
}

- (NSDictionary *)toDictionary {
    NSMutableArray *groupsArray = [NSMutableArray array];
    for (DXWorkspaceGroup *group in self.groups) {
        [groupsArray addObject:[group toDictionary]];
    }
    return @{@"name": self.name ?: @"", @"groups": groupsArray};
}

+ (instancetype)fromDictionary:(NSDictionary *)dict {
    DXWorkspace *workspace = [[DXWorkspace alloc] init];
    if (!dict) return workspace;
    
    workspace.name = dict[@"name"] ?: @"";
    NSArray *groupsData = dict[@"groups"];
    if ([groupsData isKindOfClass:[NSArray class]]) {
        for (NSDictionary *gDict in groupsData) {
            [workspace.groups addObject:[DXWorkspaceGroup fromDictionary:gDict]];
        }
    }
    return workspace;
}
@end

@implementation WorkspaceManager

+ (instancetype)sharedManager {
    static WorkspaceManager *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[WorkspaceManager alloc] init];
        [shared loadWorkspaces];
    });
    return shared;
}

- (instancetype)init {
    if (self = [super init]) {
        _workspaces = [NSMutableArray array];
    }
    return self;
}

- (NSURL *)storageURL {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSURL *appSupport = [fm URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *dxDir = [appSupport URLByAppendingPathComponent:@"DX3270"];
    [fm createDirectoryAtURL:dxDir withIntermediateDirectories:YES attributes:nil error:nil];
    return [dxDir URLByAppendingPathComponent:@"workspaces.json"];
}

- (void)loadWorkspaces {
    NSData *data = [NSData dataWithContentsOfURL:[self storageURL]];
    if (data) {
        NSArray *jsonArray = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if ([jsonArray isKindOfClass:[NSArray class]]) {
            [self.workspaces removeAllObjects];
            for (NSDictionary *wDict in jsonArray) {
                [self.workspaces addObject:[DXWorkspace fromDictionary:wDict]];
            }
        }
    }
    [self createDefaultWorkspaceIfNeeded];
}

- (void)saveWorkspaces {
    NSMutableArray *jsonArray = [NSMutableArray array];
    for (DXWorkspace *workspace in self.workspaces) {
        [jsonArray addObject:[workspace toDictionary]];
    }
    NSData *data = [NSJSONSerialization dataWithJSONObject:jsonArray options:NSJSONWritingPrettyPrinted error:nil];
    if (data) {
        [data writeToURL:[self storageURL] atomically:YES];
    }
}

- (void)createDefaultWorkspaceIfNeeded {
    if (self.workspaces.count == 0) {
        DXWorkspace *defaultWs = [[DXWorkspace alloc] init];
        defaultWs.name = @"Development";
        
        DXWorkspaceGroup *defaultGrp = [[DXWorkspaceGroup alloc] init];
        defaultGrp.name = @"Main Systems";
        
        // ADD A DEFAULT SESSION TO THE GROUP
        DXSessionConfig *defaultSession = [[DXSessionConfig alloc] init];
        defaultSession.name = @"Localhost Test";
        defaultSession.host = @"127.0.0.1";
        defaultSession.port = 23;
        [defaultGrp.sessions addObject:defaultSession];
        
        [defaultWs.groups addObject:defaultGrp];
        [self.workspaces addObject:defaultWs];
        [self saveWorkspaces];
    }
}

@end