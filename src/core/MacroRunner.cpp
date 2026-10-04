#include "MacroRunner.h"
#include "EbcdicCodec.h"
#include <chrono>
#include <algorithm>

namespace x3270 {

MacroRunner::MacroRunner(ScreenBuffer& screen, KeyboardState* kbd3270, KeyboardState5250* kbd5250)
    : screen_(screen), kbd3270_(kbd3270), kbd5250_(kbd5250) {}

MacroRunner::~MacroRunner() {
    stop();
}

void MacroRunner::setCallbacks(StateCallback stateCb, ProgressCallback progressCb) {
    stateCb_ = std::move(stateCb);
    progressCb_ = std::move(progressCb);
}

bool MacroRunner::loadScript(const MacroScript& script) {
    if (state_ == MacroRunnerState::Running) return false;
    currentScript_ = script;
    currentStepIndex_ = 0;
    state_ = MacroRunnerState::Idle;
    return true;
}

void MacroRunner::start(MacroPlaybackSpeed speed) {
    if (state_ == MacroRunnerState::Running || currentScript_.events.empty()) return;

    playbackSpeed_ = speed;
    stopRequested_ = false;
    currentStepIndex_ = 0;
    state_ = MacroRunnerState::Running;

    if (stateCb_) stateCb_(MacroRunnerState::Running, "");

    if (executionThread_.joinable()) {
        executionThread_.join();
    }
    executionThread_ = std::thread(&MacroRunner::runLoop, this);
}

void MacroRunner::stop() {
    stopRequested_ = true;
    if (executionThread_.joinable()) executionThread_.join();
    state_ = MacroRunnerState::Idle;
}

void MacroRunner::pause() {
    if (state_ == MacroRunnerState::Running) {
        state_ = MacroRunnerState::Paused;
        if (stateCb_) stateCb_(MacroRunnerState::Paused, "");
    }
}

void MacroRunner::resume() {
    if (state_ == MacroRunnerState::Paused) {
        state_ = MacroRunnerState::Running;
        if (stateCb_) stateCb_(MacroRunnerState::Running, "");
    }
}

void MacroRunner::runLoop() {
    size_t total = currentScript_.events.size();

    while (currentStepIndex_ < total && !stopRequested_) {
        while (state_ == MacroRunnerState::Paused && !stopRequested_) {
            std::this_thread::sleep_for(std::chrono::milliseconds(50));
        }
        if (stopRequested_) break;

        const auto& event = currentScript_.events[currentStepIndex_];

        
        // --- Process Delays based on Playback Speed ---
        uint64_t sleepTime = 15; // Base fast execution

        if (playbackSpeed_ == MacroPlaybackSpeed::Fast) {
            sleepTime = 15; // Fixed minimal delay for high-speed automation
        } else if (event.delayMs > 0) {
            sleepTime = std::min(event.delayMs, static_cast<uint64_t>(3000)); // Max wait 3s
            sleepTime = std::max(sleepTime, static_cast<uint64_t>(15));      // Min wait 15ms
            
            if (playbackSpeed_ == MacroPlaybackSpeed::Presentation) {
                sleepTime *= 2; // Double the recorded delay
                // Enforce a minimum 150ms delay between keystrokes so the audience can read them
                sleepTime = std::max(sleepTime, static_cast<uint64_t>(150)); 
            }
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(sleepTime));

        // Execute Event
        if (!executeEvent(event)) {
            state_ = MacroRunnerState::Error;
            
            // Build detailed error message for UI
            std::string errMsg = "Execution failed at step " + std::to_string(currentStepIndex_ + 1);
            if (!event.assertionText.empty()) {
                errMsg += ".\nTimeout waiting for screen text:\n[" + event.assertionText + "]";
            } else {
                errMsg += ".\nTimeout waiting for keyboard to unlock.";
            }
            
            if (stateCb_) stateCb_(MacroRunnerState::Error, errMsg);
            return;
        }

        currentStepIndex_++;
        
        // Trigger the Progress Callback to redraw the UI after every keystroke
        if (progressCb_) progressCb_(currentStepIndex_.load(), total);
    }

    if (!stopRequested_) {
        state_ = MacroRunnerState::Finished;
        if (stateCb_) stateCb_(MacroRunnerState::Finished, "");
    }
}

bool MacroRunner::executeEvent(const MacroEvent& event) {
    // 1. Verify Screen Guard BEFORE taking action
    // POLLING LOOP: Wait up to 10 seconds for the screen to render the expected text
    if (!event.assertionText.empty()) {
        bool guardPassed = false;
        for (int i = 0; i < 100; i++) { // 100 checks * 100ms = 10 seconds max timeout
            if (verifyScreenGuard(event.assertionText)) {
                guardPassed = true;
                break;
            }
            if (stopRequested_) return false;
            std::this_thread::sleep_for(std::chrono::milliseconds(100));
        }
        
        if (!guardPassed) {
            return false; // Guard assertion failed!
        }
    }

    // REMOVED: screen_.setCursor(event.cursorOffset); 
    // We let the Host and the simulated Nav Keys dictate the cursor naturally!

    // 2. Execute the Key Input
    switch (event.type) {
    case MacroEventType::CharInput:
        return kbd3270_ ? kbd3270_->handleChar(event.unicodeChar) : kbd5250_->handleChar(event.unicodeChar);
    
    case MacroEventType::NavKey:
        switch (event.navCode) {
        case MacroNavCode::Tab:         return kbd3270_ ? kbd3270_->handleTab(false) : kbd5250_->handleTab(false);
        case MacroNavCode::BackTab:     return kbd3270_ ? kbd3270_->handleTab(true)  : kbd5250_->handleTab(true);
        case MacroNavCode::CursorUp:    return kbd3270_ ? kbd3270_->handleCursorUp() : kbd5250_->handleArrow(-1, 0);
        case MacroNavCode::CursorDown:  return kbd3270_ ? kbd3270_->handleCursorDown() : kbd5250_->handleArrow(+1, 0);
        case MacroNavCode::CursorLeft:  return kbd3270_ ? kbd3270_->handleCursorLeft() : kbd5250_->handleArrow(0, -1);
        case MacroNavCode::CursorRight: return kbd3270_ ? kbd3270_->handleCursorRight() : kbd5250_->handleArrow(0, +1);
        case MacroNavCode::Backspace:   return kbd3270_ ? kbd3270_->handleBackspace() : kbd5250_->handleBackspace();
        case MacroNavCode::Delete:      return kbd3270_ ? kbd3270_->handleDelete() : kbd5250_->handleDelete();
        case MacroNavCode::Home:        return kbd3270_ ? kbd3270_->handleHome() : kbd5250_->handleHome();
        case MacroNavCode::EraseEOF:    return kbd3270_ ? kbd3270_->handleEraseEOF() : kbd5250_->handleEraseField();
        case MacroNavCode::EraseInput:  return kbd3270_ ? kbd3270_->handleEraseInput() : kbd5250_->handleEraseField();
        case MacroNavCode::InsertToggle:
            if (kbd3270_) kbd3270_->toggleInsert();
            if (kbd5250_) kbd5250_->toggleInsert();
            return true;
        }
        return false;

    case MacroEventType::AIDKey: {
        bool sent = false;
        if (event.aidCode == 0x7D) { // ENTER
            sent = kbd3270_ ? kbd3270_->handleEnter() : kbd5250_->handleEnter();
        } else if (event.aidCode == 0x6D) { // CLEAR
            sent = kbd3270_ ? kbd3270_->handleClear() : kbd5250_->handleClear();
        } else { // PF Keys
            int pfNum = 1;
            if (event.aidCode >= 0xF1 && event.aidCode <= 0xF9) pfNum = event.aidCode - 0xF0;
            else if (event.aidCode >= 0x7A && event.aidCode <= 0x7C) pfNum = event.aidCode - 0x71; // PF10-PF12
            sent = kbd3270_ ? kbd3270_->handlePF(pfNum) : kbd5250_->handlePFKey(pfNum);
        }
        
        if (!sent) return false;
        
        // Wait up to 15 seconds for the host to process the command and unlock the keyboard
        if (!waitForKeyboardUnlock()) return false;
        
        return true;
    }
    case MacroEventType::ScreenGuard:
        return true; 
    }
    return false;
}

bool MacroRunner::waitForKeyboardUnlock(int timeoutMs) {
    auto start = std::chrono::steady_clock::now();
    while (!stopRequested_) {
        bool locked = kbd3270_ ? kbd3270_->isLocked() : kbd5250_->isLocked();
        if (!locked) return true;

        auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now() - start).count();

        if (elapsed > timeoutMs) return false; // Timeout reached
        
        std::this_thread::sleep_for(std::chrono::milliseconds(20));
    }
    return false;
}

bool MacroRunner::verifyScreenGuard(const std::string& expectedText) {
    if (expectedText.empty()) return true;

    int sz = screen_.size();
    std::string text;
    EbcdicCodec defaultCodec(CodePage::CP037);
    text.reserve(sz);

    for (int i = 0; i < sz; i++) {
        const Cell& c = screen_.at(i);
        if (!c.isFA && c.ch != 0x00) {
            uint16_t u = defaultCodec.toUnicode(c.ch);
            text += (u >= 0x20 && u < 0x7F) ? static_cast<char>(u) : ' ';
        } else {
            text += ' ';
        }
    }

    std::string cleanText;
    cleanText.reserve(sz);
    bool lastSpace = true;
    for (char ch : text) {
        if (ch == ' ') {
            if (!lastSpace) { cleanText += ' '; lastSpace = true; }
        } else {
            cleanText += ch;
            lastSpace = false;
        }
    }
    if (!cleanText.empty() && cleanText.back() == ' ') cleanText.pop_back();

    return cleanText.find(expectedText) != std::string::npos;
}

} // namespace x3270