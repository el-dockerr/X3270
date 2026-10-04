#pragma once
#include "MacroModel.h"
#include <string>

namespace x3270 {

class MacroSerializer {
public:
    static std::string serializeToJson(const MacroScript& script);
    static bool deserializeFromJson(const std::string& jsonString, MacroScript& outScript);
    
    static bool saveToFile(const MacroScript& script, const std::string& filePath);
    static bool loadFromFile(const std::string& filePath, MacroScript& outScript);
};

} // namespace x3270