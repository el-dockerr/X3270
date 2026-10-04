#import "MacroSerializer.h"
#import <Foundation/Foundation.h>

namespace x3270 {

std::string MacroSerializer::serializeToJson(const MacroScript& script) {
    @autoreleasepool {
        NSMutableDictionary *jsonDict = [NSMutableDictionary dictionary];
        jsonDict[@"name"] = [NSString stringWithUTF8String:script.name.c_str()];
        jsonDict[@"description"] = [NSString stringWithUTF8String:script.description.c_str()];
        jsonDict[@"targetHost"] = [NSString stringWithUTF8String:script.targetHost.c_str()];
        jsonDict[@"codePage"] = [NSString stringWithUTF8String:script.codePage.c_str()];
        jsonDict[@"createdAtMs"] = @(script.createdAtMs);

        NSMutableArray *eventsArray = [NSMutableArray array];
        for (const auto& ev : script.events) {
            NSMutableDictionary *evDict = [NSMutableDictionary dictionary];
            evDict[@"type"] = @(static_cast<int>(ev.type));
            evDict[@"unicodeChar"] = @(ev.unicodeChar);
            evDict[@"navCode"] = @(static_cast<int>(ev.navCode));
            evDict[@"aidCode"] = @(ev.aidCode);
            evDict[@"cursorOffset"] = @(ev.cursorOffset);
            evDict[@"delayMs"] = @(ev.delayMs);
            if (!ev.assertionText.empty()) {
                evDict[@"assertionText"] = [NSString stringWithUTF8String:ev.assertionText.c_str()];
            }
            [eventsArray addObject:evDict];
        }
        jsonDict[@"events"] = eventsArray;

        NSError *error = nil;
        NSData *jsonData = [NSJSONSerialization dataWithJSONObject:jsonDict options:NSJSONWritingPrettyPrinted error:&error];
        if (error || !jsonData) return "";
        
        NSString *jsonString = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
        return [jsonString UTF8String];
    }
}

bool MacroSerializer::deserializeFromJson(const std::string& jsonString, MacroScript& outScript) {
    @autoreleasepool {
        NSData *jsonData = [NSData dataWithBytes:jsonString.data() length:jsonString.size()];
        if (!jsonData) return false;

        NSError *error = nil;
        NSDictionary *jsonDict = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:&error];
        if (error || ![jsonDict isKindOfClass:[NSDictionary class]]) return false;

        outScript.name = [jsonDict[@"name"] UTF8String] ?: "";
        outScript.description = [jsonDict[@"description"] UTF8String] ?: "";
        outScript.targetHost = [jsonDict[@"targetHost"] UTF8String] ?: "";
        outScript.codePage = [jsonDict[@"codePage"] UTF8String] ?: "CP037";
        outScript.createdAtMs = [jsonDict[@"createdAtMs"] unsignedLongLongValue];

        outScript.events.clear();
        NSArray *eventsArray = jsonDict[@"events"];
        if ([eventsArray isKindOfClass:[NSArray class]]) {
            for (NSDictionary *evDict in eventsArray) {
                MacroEvent ev;
                ev.type = static_cast<MacroEventType>([evDict[@"type"] intValue]);
                ev.unicodeChar = [evDict[@"unicodeChar"] unsignedShortValue];
                ev.navCode = static_cast<MacroNavCode>([evDict[@"navCode"] intValue]);
                ev.aidCode = [evDict[@"aidCode"] unsignedCharValue];
                ev.cursorOffset = [evDict[@"cursorOffset"] intValue];
                ev.delayMs = [evDict[@"delayMs"] unsignedLongLongValue];
                if (evDict[@"assertionText"]) {
                    ev.assertionText = [evDict[@"assertionText"] UTF8String] ?: "";
                }
                outScript.events.push_back(ev);
            }
        }
        return true;
    }
}

bool MacroSerializer::saveToFile(const MacroScript& script, const std::string& filePath) {
    std::string json = serializeToJson(script);
    if (json.empty()) return false;
    @autoreleasepool {
        NSString *path = [NSString stringWithUTF8String:filePath.c_str()];
        NSString *content = [NSString stringWithUTF8String:json.c_str()];
        return [content writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
}

bool MacroSerializer::loadFromFile(const std::string& filePath, MacroScript& outScript) {
    @autoreleasepool {
        NSString *path = [NSString stringWithUTF8String:filePath.c_str()];
        NSString *content = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
        if (!content) return false;
        return deserializeFromJson([content UTF8String], outScript);
    }
}

} // namespace x3270