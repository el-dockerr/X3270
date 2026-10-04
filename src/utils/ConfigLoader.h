#import <Foundation/Foundation.h>

@interface ConfigLoader : NSObject

/// Loads base JSON from Bundle Resources and merges custom JSON from User Application Support.
/// @param filename File name to load (e.g., "patterns.json" or "commands.json").
/// @return Merged NSDictionary or NSArray object.
+ (id)loadMergedJSONNamed:(NSString *)filename;

/// User configuration directory path (~/Library/Application Support/DX3270/).
+ (NSString *)userConfigDirectoryPath;

@end