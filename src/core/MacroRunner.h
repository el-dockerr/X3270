#pragma once
#include "MacroModel.h"
#include "KeyboardState.h"
#include "KeyboardState5250.h"
#include "ScreenBuffer.h"
#include <functional>
#include <atomic>
#include <thread>
#include <string>

namespace x3270 {

enum class MacroPlaybackSpeed {
    Fast,         // Minimal delays, pure automation speed
    Normal,       // Exact real-time delays recorded by the user
    Presentation  // Slower, exaggerated delays for demonstrations
};

enum class MacroRunnerState {
    Idle,
    Running,
    Paused,
    Error,
    Finished
};

class MacroRunner {
public:
    using StateCallback = std::function<void(MacroRunnerState state, const std::string& errorMsg)>;
    using ProgressCallback = std::function<void(size_t currentStep, size_t totalSteps)>;

    MacroRunner(ScreenBuffer& screen, KeyboardState* kbd3270, KeyboardState5250* kbd5250);
    ~MacroRunner();

    void setCallbacks(StateCallback stateCb, ProgressCallback progressCb);

    bool loadScript(const MacroScript& script);
    void start(MacroPlaybackSpeed speed = MacroPlaybackSpeed::Normal);
    void stop();
    void pause();
    void resume();

    MacroRunnerState state() const { return state_; }
    size_t currentStepIndex() const { return currentStepIndex_; }

private:
    void runLoop();
    bool executeEvent(const MacroEvent& event);
    bool waitForKeyboardUnlock(int timeoutMs = 15000);
    bool verifyScreenGuard(const std::string& expectedText);

    ScreenBuffer& screen_;
    KeyboardState* kbd3270_{nullptr};
    KeyboardState5250* kbd5250_{nullptr};

    MacroScript currentScript_;
    std::atomic<MacroRunnerState> state_{MacroRunnerState::Idle};
    std::atomic<size_t> currentStepIndex_{0};
    std::atomic<bool> stopRequested_{false};
    MacroPlaybackSpeed playbackSpeed_{MacroPlaybackSpeed::Normal};

    StateCallback stateCb_;
    ProgressCallback progressCb_;
    std::thread executionThread_;
};

} // namespace x3270