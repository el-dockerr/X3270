#pragma once

#include "ScreenBuffer.h"
#include "EbcdicCodec.h"
#include <string>
#include <vector>
#include <functional>

namespace dx3270 {

enum class FieldType {
    Input,     // Unprotected 
    Display,   // Protected 
    Secret     // Non-display (password)
};

struct ExtractedField {
    int startRow;
    int startCol;
    int length;
    FieldType type;
    bool isModified;
    bool isNumeric;
    std::string name;   // Label automatically inferred from the fixed text to the left/above
    std::string value;  // Field content
};

struct ScreenStructure {
    int rows;
    int cols;
    int cursorRow;
    int cursorCol;
    std::string panelTitle; // Screen title automatically extracted from the first lines
    std::vector<ExtractedField> fields;

    // Clean C++ serialization to JSON string
    std::string toJson() const;
};

class ScreenStructuralAnalyzer {
public:
    using StructureCallback = std::function<void(const ScreenStructure& structure, const std::string& json)>;

    ScreenStructuralAnalyzer(x3270::ScreenBuffer& screen, x3270::EbcdicCodec& codec);

    // Analyzes the current state of the buffer and emits the structure
    ScreenStructure analyzeCurrentScreen();

    // Sets the callback for notifications on every screen update
    void setOnStructureUpdated(StructureCallback cb) { callback_ = std::move(cb); }

private:
    x3270::ScreenBuffer& screen_;
    x3270::EbcdicCodec&  codec_;
    StructureCallback    callback_;

    std::string extractPanelTitle() const;
    std::string inferFieldLabel(int fieldStartPos) const;
    std::string readStringFromBuffer(int startPos, int length) const;
};

} // namespace dx3270