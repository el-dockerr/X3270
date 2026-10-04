#pragma once
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// ==========================================
// Level 3: The single Session (Autonomous)
// ==========================================
@interface DXSessionConfig : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *host;
@property (nonatomic, assign) uint16_t port;
@property (nonatomic, assign) BOOL useSSL;
@property (nonatomic, assign) BOOL verifyCert;
@property (nonatomic, copy) NSString *caBundle;
@property (nonatomic, assign) NSInteger codePage;
@property (nonatomic, assign) NSInteger model;
@property (nonatomic, assign) NSInteger protocol;
@property (nonatomic, strong) NSArray<NSDictionary *> *customFastPaths;

- (NSDictionary *)toDictionary;
+ (instancetype)fromDictionary:(NSDictionary *)dict;
@end

// ==========================================
// Level 2: The Group (Logical Grouping)
// ==========================================
@interface DXWorkspaceGroup : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, strong) NSMutableArray<DXSessionConfig *> *sessions;

- (NSDictionary *)toDictionary;
+ (instancetype)fromDictionary:(NSDictionary *)dict;
@end

// ==========================================
// Level 1: The Workspace (Environment / Project)
// ==========================================
@interface DXWorkspace : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, strong) NSMutableArray<DXWorkspaceGroup *> *groups;

- (NSDictionary *)toDictionary;
+ (instancetype)fromDictionary:(NSDictionary *)dict;
@end

// ==========================================
// Manager: Persistence Manager
// ==========================================
@interface WorkspaceManager : NSObject
@property (nonatomic, strong) NSMutableArray<DXWorkspace *> *workspaces;

+ (instancetype)sharedManager;
- (void)loadWorkspaces;
- (void)saveWorkspaces;
- (void)createDefaultWorkspaceIfNeeded;

@end

NS_ASSUME_NONNULL_END