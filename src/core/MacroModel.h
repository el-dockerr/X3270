#pragma once
#include <cstdint>
#include <string>
#include <vector>

namespace x3270 {

enum class MacroEventType {
    CharInput,      // Standard printable character (16-bit Unicode)
    NavKey,         // Navigation keys (Tab, BackTab, Arrows, Backspace)
    AIDKey,         // Host attention keys (Enter, PF1-24, PA1-3, Clear)
    ScreenGuard     // Screen text assertion to verify correct host state
};

enum class MacroNavCode {
    Tab,
    BackTab,
    CursorUp,
    CursorDown,
    CursorLeft,
    CursorRight,
    Backspace,
    Delete,
    Home,
    EraseEOF,
    EraseInput,
    InsertToggle
};

struct MacroEvent {
    MacroEventType type{MacroEventType::CharInput};
    uint16_t unicodeChar{0};                 // Used if type == CharInput
    MacroNavCode navCode{MacroNavCode::Tab}; // Used if type == NavKey
    uint8_t aidCode{0x7D};                   // Used if type == AIDKey (e.g., 0x7D for ENTER)
    int cursorOffset{0};                     // Screen cursor position when the event occurred
    uint64_t delayMs{0};                     // Milliseconds elapsed since the previous event
    std::string assertionText;               // Expected screen text for host synchronization
};

struct MacroScript {
    std::string name;
    std::string description;
    std::string targetHost;
    std::string codePage{"CP037"};
    uint64_t createdAtMs{0};
    std::vector<MacroEvent> events;
};

} // namespace x3270