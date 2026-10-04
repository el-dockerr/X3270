#include "MacroRecorder.h"
#include "EbcdicCodec.h"
#include <algorithm>

namespace x3270 {

void MacroRecorder::startRecording(const std::string& scriptName, const std::string& codePage) {
    currentScript_ = MacroScript();
    currentScript_.name = scriptName;
    currentScript_.codePage = codePage;
    
    auto now = std::chrono::system_clock::now().time_since_epoch();
    currentScript_.createdAtMs = std::chrono::duration_cast<std::chrono::milliseconds>(now).count();

    state_ = State::Recording;
    lastEventTime_ = std::chrono::steady_clock::now();
}

void MacroRecorder::stopRecording() {
    state_ = State::Idle;
}

void MacroRecorder::pauseRecording() {
    if (state_ == State::Recording) state_ = State::Paused;
}

void MacroRecorder::resumeRecording() {
    if (state_ == State::Paused) {
        state_ = State::Recording;
        lastEventTime_ = std::chrono::steady_clock::now();
    }
}

void MacroRecorder::clear() {
    currentScript_ = MacroScript();
    state_ = State::Idle;
}

uint64_t MacroRecorder::consumeElapsedDelay() {
    auto now = std::chrono::steady_clock::now();
    auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(now - lastEventTime_).count();
    lastEventTime_ = now;
    return static_cast<uint64_t>(elapsed);
}

void MacroRecorder::recordChar(uint16_t unicodeChar, int cursorOffset) {
    if (state_ != State::Recording) return;
    MacroEvent ev;
    ev.type = MacroEventType::CharInput;
    ev.unicodeChar = unicodeChar;
    ev.cursorOffset = cursorOffset;
    ev.delayMs = consumeElapsedDelay();
    currentScript_.events.push_back(ev);
}

void MacroRecorder::recordNavKey(MacroNavCode navCode, int cursorOffset) {
    if (state_ != State::Recording) return;
    MacroEvent ev;
    ev.type = MacroEventType::NavKey;
    ev.navCode = navCode;
    ev.cursorOffset = cursorOffset;
    ev.delayMs = consumeElapsedDelay();
    currentScript_.events.push_back(ev);
}

void MacroRecorder::recordAIDKey(uint8_t aidCode, int cursorOffset, const ScreenBuffer* screen) {
    if (state_ != State::Recording) return;
    MacroEvent ev;
    ev.type = MacroEventType::AIDKey;
    ev.aidCode = aidCode;
    ev.cursorOffset = cursorOffset;
    ev.delayMs = consumeElapsedDelay();

    if (screen) {
        ev.assertionText = captureScreenGuardText(*screen);
    }
    currentScript_.events.push_back(ev);
}

std::string MacroRecorder::captureScreenGuardText(const ScreenBuffer& screen) const {
    int pos = screen.cursorPos();
    int cols = screen.cols();
    if (cols <= 0 || screen.size() == 0) return "";

    std::string label;
    EbcdicCodec defaultCodec(CodePage::CP037);

    // We only want to capture text on the EXACT SAME ROW as the cursor.
    // This prevents grabbing volatile system messages from lines above.
    int startRow = pos / cols;
    int currentPos = (pos - 1 + screen.size()) % screen.size();
    
    // Limit to at most 40 chars, or the start of the row, or a protected field attribute
    int charsToCapture = 40; 

    while (charsToCapture > 0 && (currentPos / cols) == startRow) {
        const Cell& c = screen.at(currentPos);
        
        if (c.isFA) {
            break; // Stop cleanly at the field attribute that defines this input field
        }
        
        if (c.ch != 0x00) {
            uint16_t u = defaultCodec.toUnicode(c.ch);
            char asciiChar = (u >= 0x20 && u < 0x7F) ? static_cast<char>(u) : ' ';
            label += asciiChar;
        } else {
            label += ' '; // Treat empty EBCDIC cells as spaces
        }
        
        charsToCapture--;
        currentPos = (currentPos - 1 + screen.size()) % screen.size();
    }

    // Because we walked backwards from the cursor, we must reverse the string
    std::reverse(label.begin(), label.end());
    
    // Clean up and collapse multiple spaces into a single space
    std::string cleanText;
    bool lastWasSpace = true; // Start true to automatically trim leading spaces
    for (char ch : label) {
        if (ch == ' ') {
            if (!lastWasSpace) { cleanText += ' '; lastWasSpace = true; }
        } else {
            cleanText += ch;
            lastWasSpace = false;
        }
    }
    // Trim trailing space if necessary
    if (!cleanText.empty() && cleanText.back() == ' ') cleanText.pop_back();

    return cleanText;
}

} // namespace x3270