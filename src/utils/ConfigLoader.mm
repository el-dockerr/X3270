#import "ConfigLoader.h"

@implementation ConfigLoader

+ (NSString *)userConfigDirectoryPath {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES);
    return [paths.firstObject stringByAppendingPathComponent:@"DX3270"];
}

+ (id)loadMergedJSONNamed:(NSString *)filename {
    NSFileManager *fm = [NSFileManager defaultManager];
    
    // 1. Load Base JSON from App Bundle
    NSString *nameWithoutExt = [filename stringByDeletingPathExtension];
    NSString *ext = [filename pathExtension];
    NSString *basePath = [[NSBundle mainBundle] pathForResource:nameWithoutExt ofType:ext];
    
    id baseJSON = nil;
    if (basePath && [fm fileExistsAtPath:basePath]) {
        NSData *baseData = [NSData dataWithContentsOfFile:basePath];
        if (baseData) {
            baseJSON = [NSJSONSerialization JSONObjectWithData:baseData options:0 error:nil];
        }
    }
    
    // 2. Load User Custom JSON from ~/Library/Application Support/DX3270/
    NSString *userPath = [[self userConfigDirectoryPath] stringByAppendingPathComponent:filename];
    id userJSON = nil;
    if ([fm fileExistsAtPath:userPath]) {
        NSData *userData = [NSData dataWithContentsOfFile:userPath];
        if (userData) {
            userJSON = [NSJSONSerialization JSONObjectWithData:userData options:0 error:nil];
            NSLog(@"[DX3270 ConfigLoader] Found custom override file at: %@", userPath);
        }
    }
    
    // 3. Perform Merge Logic
    if ([baseJSON isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *mergedDict = [NSMutableDictionary dictionaryWithDictionary:(NSDictionary *)baseJSON];
        if ([userJSON isKindOfClass:[NSDictionary class]]) {
            // User key/value pairs overwrite or extend base dictionary
            [mergedDict addEntriesFromDictionary:(NSDictionary *)userJSON];
        }
        return [mergedDict copy];
    } 
    else if ([baseJSON isKindOfClass:[NSArray class]]) {
        NSMutableArray *mergedArray = [NSMutableArray arrayWithArray:(NSArray *)baseJSON];
        if ([userJSON isKindOfClass:[NSArray class]]) {
            // Append custom commands or rules
            [mergedArray addObjectsFromArray:(NSArray *)userJSON];
        }
        return [mergedArray copy];
    }
    
    // Fallback if bundle is empty but user file exists
    return userJSON ?: baseJSON;
}

@end