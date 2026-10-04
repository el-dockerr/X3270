#include "ScreenStructuralAnalyzer.h"
#include <sstream>
#include <algorithm>
#include <cctype>

namespace dx3270 {

static std::string escapeJsonString(const std::string& input) {
    std::ostringstream ss;
    for (char c : input) {
        switch (c) {
            case '"':  ss << "\\\""; break;
            case '\\': ss << "\\\\"; break;
            case '\b': ss << "\\b";  break;
            case '\f': ss << "\\f";  break;
            case '\n': ss << "\\n";  break;
            case '\r': ss << "\\r";  break;
            case '\t': ss << "\\t";  break;
            default:
                if (static_cast<unsigned char>(c) < 0x20) {
                    ss << "\\u" << std::hex << std::uppercase << (int)c;
                } else {
                    ss << c;
                }
                break;
        }
    }
    return ss.str();
}

std::string ScreenStructure::toJson() const {
    std::ostringstream ss;
    ss << "{\n";
    ss << "  \"panel_title\": \"" << escapeJsonString(panelTitle) << "\",\n";
    ss << "  \"grid\": { \"rows\": " << rows << ", \"cols\": " << cols << " },\n";
    ss << "  \"cursor\": { \"row\": " << cursorRow << ", \"col\": " << cursorCol << " },\n";
    ss << "  \"fields\": [\n";

    for (size_t i = 0; i < fields.size(); ++i) {
        const auto& f = fields[i];
        std::string typeStr = "input";
        if (f.type == FieldType::Display) typeStr = "display";
        else if (f.type == FieldType::Secret) typeStr = "secret";

        ss << "    {\n";
        ss << "      \"name\": \"" << escapeJsonString(f.name) << "\",\n";
        ss << "      \"type\": \"" << typeStr << "\",\n";
        ss << "      \"row\": " << f.startRow << ",\n";
        ss << "      \"col\": " << f.startCol << ",\n";
        ss << "      \"length\": " << f.length << ",\n";
        ss << "      \"modified\": " << (f.isModified ? "true" : "false") << ",\n";
        ss << "      \"numeric\": " << (f.isNumeric ? "true" : "false") << ",\n";
        ss << "      \"value\": \"" << escapeJsonString(f.value) << "\"\n";
        ss << "    }" << (i + 1 < fields.size() ? "," : "") << "\n";
    }

    ss << "  ]\n";
    ss << "}";
    return ss.str();
}

ScreenStructuralAnalyzer::ScreenStructuralAnalyzer(x3270::ScreenBuffer& screen, x3270::EbcdicCodec& codec)
    : screen_(screen), codec_(codec) {}

std::string ScreenStructuralAnalyzer::readStringFromBuffer(int startPos, int length) const {
    std::string result;
    int totalSize = screen_.size();
    for (int i = 0; i < length; ++i) {
        int pos = (startPos + i) % totalSize;
        const auto& cell = screen_.at(pos);
        if (cell.isFA) continue;
        uint16_t uc = codec_.toUnicode(cell.ch);
        if (uc >= 0x20 && uc != 0x7F) {
            result.push_back(static_cast<char>(uc));
        } else {
            result.push_back(' ');
        }
    }
    // Trim trailing spaces
    size_t end = result.find_last_not_of(" \t\f\v\n\r");
    return (end == std::string::npos) ? "" : result.substr(0, end + 1);
}

std::string ScreenStructuralAnalyzer::extractPanelTitle() const {
    // Read the first row (0..cols-1) to identify the panel title (e.g., ISPF, CICS)
    return readStringFromBuffer(0, screen_.cols());
}

std::string ScreenStructuralAnalyzer::inferFieldLabel(int fieldStartPos) const {
    int cols = screen_.cols();
    int row = fieldStartPos / cols;
    int col = fieldStartPos % cols;

    // Strategy 1: Look for fixed text to the left on the same row (up to 20 characters before)
    int searchLen = std::min(col, 20);
    if (searchLen > 0) {
        int startPos = fieldStartPos - searchLen;
        std::string leftText = readStringFromBuffer(startPos, searchLen);
        
        // Clean classic prompt symbols like "===>", ":", "."
        size_t lastAlpha = leftText.find_last_of("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789");
        if (lastAlpha != std::string::npos) {
            size_t startAlpha = leftText.find_last_of(" \t", lastAlpha);
            startAlpha = (startAlpha == std::string::npos) ? 0 : startAlpha + 1;
            std::string label = leftText.substr(startAlpha, lastAlpha - startAlpha + 1);
            if (label.length() >= 2) {
                return label;
            }
        }
    }

    // Strategy 2: Fallback with position-based identifier
    return "FIELD_R" + std::to_string(row + 1) + "_C" + std::to_string(col + 1);
}

ScreenStructure ScreenStructuralAnalyzer::analyzeCurrentScreen() {
    ScreenStructure structData;
    structData.rows = screen_.rows();
    structData.cols = screen_.cols();
    
    int totalSize = screen_.size();
    if (totalSize <= 0) return structData; // Guardrail against uninitialized buffer

    int curPos = screen_.cursorPos();
    structData.cursorRow = curPos / structData.cols;
    structData.cursorCol = curPos % structData.cols;
    
    // 1. Extraction of the panel title
    structData.panelTitle = extractPanelTitle();

    int pos = 0;

    // Guardrail: limit the number of iterations to avoid infinite loops
    int safetyCounter = 0;

    while (pos < totalSize && safetyCounter++ < totalSize) {
        if (screen_.at(pos).isFA) {
            uint8_t attr = screen_.at(pos).attr;
            bool isProtected = (attr & 0x20) != 0;
            bool isNumeric   = (attr & 0x10) != 0;
            bool isSecret    = (attr & 0x0C) == 0x0C; // Non-display
            bool isModified  = (attr & 0x01) != 0;

            // Calculate the field length handling the circular wrap-around of the buffer
            int startDataPos = (pos + 1) % totalSize;
            int len = 0;
            int scanPos = startDataPos;

            // Scan until the next FA field (handling wrap-around correctly)
            while (scanPos != pos && !screen_.at(scanPos).isFA) {
                len++;
                scanPos = (scanPos + 1) % totalSize;
                
                // Safety break to avoid wrapping the screen indefinitely
                if (scanPos == startDataPos) break; 
            }

            if (len > 0) {
                ExtractedField field;
                field.startRow = startDataPos / structData.cols;
                field.startCol = startDataPos % structData.cols;
                field.length = len;
                field.isModified = isModified;
                field.isNumeric = isNumeric;
                
                if (isSecret) field.type = FieldType::Secret;
                else if (isProtected) field.type = FieldType::Display;
                else field.type = FieldType::Input;

                field.value = isSecret ? "********" : readStringFromBuffer(startDataPos, len);
                
                // Assign label
                if (field.type == FieldType::Input || field.type == FieldType::Secret) {
                    // Safety fallback if inferFieldLabel takes too long to respond
                    std::string label = inferFieldLabel(startDataPos);
                    field.name = !label.empty() ? label : ("INPUT_R" + std::to_string(field.startRow + 1) + "_C" + std::to_string(field.startCol + 1));
                } else {
                    field.name = "LABEL_R" + std::to_string(field.startRow + 1) + "_C" + std::to_string(field.startCol + 1);
                }

                structData.fields.push_back(field);
            }
            
            // Advance the main scanner position
            if (scanPos <= pos) {
                break; // Completed a full screen loop (wrap-around)
            }
            pos = scanPos;
        } else {
            pos++;
        }
    }

    // 2. Notify the result via callback
    if (callback_) {
        std::string jsonOutput = structData.toJson();
        callback_(structData, jsonOutput);
    }

    return structData;
}


} // namespace dx3270