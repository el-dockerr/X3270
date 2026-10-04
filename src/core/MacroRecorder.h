#pragma once
#include "MacroModel.h"
#include "ScreenBuffer.h"
#include <chrono>
#include <string>

namespace x3270 {

class MacroRecorder {
public:
    enum class State {
        Idle,
        Recording,
        Paused
    };

    MacroRecorder() = default;

    void startRecording(const std::string& scriptName, const std::string& codePage = "CP037");
    void stopRecording();
    void pauseRecording();
    void resumeRecording();

    bool isRecording() const { return state_ == State::Recording; }
    State state() const { return state_; }

    // Event hooks called by KeyboardState / KeyboardState5250
    void recordChar(uint16_t unicodeChar, int cursorOffset);
    void recordNavKey(MacroNavCode navCode, int cursorOffset);
    void recordAIDKey(uint8_t aidCode, int cursorOffset, const ScreenBuffer* screen = nullptr);

    const MacroScript& script() const { return currentScript_; }
    void clear();

private:
    uint64_t consumeElapsedDelay();
    std::string captureScreenGuardText(const ScreenBuffer& screen) const;

    State state_{State::Idle};
    MacroScript currentScript_;
    std::chrono::steady_clock::time_point lastEventTime_;
};

} // namespace x3270