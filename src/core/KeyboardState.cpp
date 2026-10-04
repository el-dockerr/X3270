#include "KeyboardState.h"

namespace x3270 {

// -----------------------------------------------------------------------------
// Constructor
// -----------------------------------------------------------------------------
KeyboardState::KeyboardState(ScreenBuffer& screen, EbcdicCodec& codec)
    : screen_(screen), codec_(codec) {}

// -----------------------------------------------------------------------------
// State Management
// -----------------------------------------------------------------------------
void KeyboardState::lock(LockReason reason) {
    lockReason_ = reason;
}

void KeyboardState::unlock() {
    lockReason_ = LockReason::None;
}

// -----------------------------------------------------------------------------
// Data Input Handlers
// -----------------------------------------------------------------------------
bool KeyboardState::handleChar(uint16_t unicodeChar) {
    if (isLocked()) return false;
    int posBefore = screen_.cursorPos();
    uint8_t ebcdic = codec_.fromUnichar(unicodeChar);
    
    // Attempt to insert the character into the screen buffer
    bool ok = insertCharAtCursor(ebcdic);
    
    // Record the keystroke only if the insertion was successful (e.g., not blocked by protected fields)
    if (ok && recorder_ && recorder_->isRecording()) {
        recorder_->recordChar(unicodeChar, posBefore);
    }
    return ok;
}

bool KeyboardState::handleEbcdicChar(uint8_t ebcdic) {
    if (isLocked()) return false;
    int posBefore = screen_.cursorPos();
    
    // Attempt to insert the raw EBCDIC character
    bool ok = insertCharAtCursor(ebcdic);
    
    // Record the keystroke, mapping back to Unicode for the macro script
    if (ok && recorder_ && recorder_->isRecording()) {
        uint16_t unicodeChar = codec_.toUnicode(ebcdic);
        recorder_->recordChar(unicodeChar, posBefore);
    }
    return ok;
}

// -----------------------------------------------------------------------------
// Navigation Handlers
// -----------------------------------------------------------------------------
bool KeyboardState::handleTab(bool backward) {
    if (isLocked()) return false;
    int posBefore = screen_.cursorPos();
    
    // Move cursor to the next or previous unprotected field
    advanceToNextField(!backward);
    
    // Record the navigation event
    if (recorder_ && recorder_->isRecording()) {
        recorder_->recordNavKey(backward ? MacroNavCode::BackTab : MacroNavCode::Tab, posBefore);
    }
    return true;
}

bool KeyboardState::handleBackspace() {
    if (isLocked()) return false;
    int posBefore = screen_.cursorPos();
    
    // Record navigation BEFORE the destructive action
    if (recorder_ && recorder_->isRecording()) {
        recorder_->recordNavKey(MacroNavCode::Backspace, posBefore);
    }
    
    if (isCurrentFieldEditable()) {
        int newPos = (screen_.cursorPos() - 1 + screen_.size()) % screen_.size();
        screen_.setCursor(newPos);
        screen_.at(newPos).ch = codec_.fromAscii(' '); // Clear character with EBCDIC space
        screen_.setMDT(newPos); // Set Modified Data Tag
    } else {
        lock(LockReason::OErr); // Operator Error if trying to backspace in protected field
        return false;
    }
    return true;
}

bool KeyboardState::handleDelete() {
    if (isLocked()) return false;
    int posBefore = screen_.cursorPos();
    
    if (recorder_ && recorder_->isRecording()) {
        recorder_->recordNavKey(MacroNavCode::Delete, posBefore);
    }
    
    if (isCurrentFieldEditable()) {
        screen_.at(posBefore).ch = codec_.fromAscii(' ');
        screen_.setMDT(posBefore);
    } else {
        lock(LockReason::OErr);
        return false;
    }
    return true;
}

bool KeyboardState::handleHome() {
    if (isLocked()) return false;
    int posBefore = screen_.cursorPos();
    
    if (recorder_ && recorder_->isRecording()) {
        recorder_->recordNavKey(MacroNavCode::Home, posBefore);
    }
    
    moveCursorToFirstUnprotected();
    return true;
}

bool KeyboardState::handleEraseEOF() {
    if (isLocked()) return false;
    int posBefore = screen_.cursorPos();
    
    if (recorder_ && recorder_->isRecording()) {
        recorder_->recordNavKey(MacroNavCode::EraseEOF, posBefore);
    }
    
    if (isCurrentFieldEditable()) {
        screen_.eraseUnprotectedToAddress(screen_.findFieldStart(posBefore));
        screen_.setMDT(posBefore);
    } else {
        lock(LockReason::OErr);
        return false;
    }
    return true;
}

bool KeyboardState::handleEraseInput() {
    if (isLocked()) return false;
    int posBefore = screen_.cursorPos();
    
    if (recorder_ && recorder_->isRecording()) {
        recorder_->recordNavKey(MacroNavCode::EraseInput, posBefore);
    }
    
    // Clear all unprotected fields across the entire screen
    screen_.eraseAllUnprotected();
    moveCursorToFirstUnprotected();
    return true;
}

bool KeyboardState::handleNewLine() {
    if (isLocked()) return false;
    // NewLine behaves similarly to Tab in moving to the next field
    advanceToNextField(true);
    return true;
}

bool KeyboardState::handleCursorUp() {
    if (isLocked()) return false;
    int posBefore = screen_.cursorPos();
    
    if (recorder_ && recorder_->isRecording()) {
        recorder_->recordNavKey(MacroNavCode::CursorUp, posBefore);
    }
    
    screen_.setCursor((posBefore - screen_.cols() + screen_.size()) % screen_.size());
    return true;
}

bool KeyboardState::handleCursorDown() {
    if (isLocked()) return false;
    int posBefore = screen_.cursorPos();
    
    if (recorder_ && recorder_->isRecording()) {
        recorder_->recordNavKey(MacroNavCode::CursorDown, posBefore);
    }
    
    screen_.setCursor((posBefore + screen_.cols()) % screen_.size());
    return true;
}

bool KeyboardState::handleCursorLeft() {
    if (isLocked()) return false;
    int posBefore = screen_.cursorPos();
    
    if (recorder_ && recorder_->isRecording()) {
        recorder_->recordNavKey(MacroNavCode::CursorLeft, posBefore);
    }
    
    screen_.setCursor((posBefore - 1 + screen_.size()) % screen_.size());
    return true;
}

bool KeyboardState::handleCursorRight() {
    if (isLocked()) return false;
    int posBefore = screen_.cursorPos();
    
    if (recorder_ && recorder_->isRecording()) {
        recorder_->recordNavKey(MacroNavCode::CursorRight, posBefore);
    }
    
    screen_.setCursor((posBefore + 1) % screen_.size());
    return true;
}

// -----------------------------------------------------------------------------
// AID Handlers (Host Transmission)
// -----------------------------------------------------------------------------
bool KeyboardState::handleEnter() {
    if (isLocked()) return false;
    int posBefore = screen_.cursorPos();
    
    // Record AID and capture the screen guard BEFORE sending and locking
    if (recorder_ && recorder_->isRecording()) {
        recorder_->recordAIDKey(AID_ENTER, posBefore, &screen_);
    }
    
    sendAID(AID_ENTER, true);
    return true;
}

bool KeyboardState::handleClear() {
    if (isLocked()) return false;
    int posBefore = screen_.cursorPos();
    
    // Record Clear AID. Screen guard is captured here as well.
    if (recorder_ && recorder_->isRecording()) {
        recorder_->recordAIDKey(AID_CLEAR, posBefore, &screen_);
    }
    
    // Clear does not send modified fields
    sendAID(AID_CLEAR, false);
    return true;
}

bool KeyboardState::handlePF(int n) {
    if (isLocked()) return false;
    int posBefore = screen_.cursorPos();
    
    if (recorder_ && recorder_->isRecording()) {
        recorder_->recordAIDKey(pfAID(n), posBefore, &screen_);
    }
    
    sendAID(pfAID(n), true);
    return true;
}

bool KeyboardState::handlePA(int n) {
    if (isLocked()) return false;
    int posBefore = screen_.cursorPos();
    
    uint8_t aidCode = AID_PA1;
    if (n == 2) aidCode = AID_PA2;
    if (n == 3) aidCode = AID_PA3;
    
    if (recorder_ && recorder_->isRecording()) {
        recorder_->recordAIDKey(aidCode, posBefore, &screen_);
    }
    
    sendPAKey(aidCode);
    return true;
}

bool KeyboardState::handleReset() {
    // Reset unlocks the keyboard after an operator error (OErr)
    unlock();
    return true;
}

// -----------------------------------------------------------------------------
// Internal Helpers
// -----------------------------------------------------------------------------
void KeyboardState::sendAID(uint8_t aidCode, bool includeModifiedFields) {
    lock(LockReason::System); // Lock keyboard waiting for host response
    if (sendCb_) {
        sendCb_(screen_.buildReadModifiedRecord(aidCode, includeModifiedFields));
    }
}

void KeyboardState::sendPAKey(uint8_t aidCode) {
    lock(LockReason::System);
    if (sendCb_) {
        // PA keys send only the AID code, no modified fields
        sendCb_({aidCode});
    }
}

bool KeyboardState::isCurrentFieldEditable() const {
    int fa = screen_.findFieldStart(screen_.cursorPos());
    if (fa < 0) return true; // CRITICAL FIX: Unformatted screens are fully editable
    return (screen_.at(fa).attr & FA_PROTECTED) == 0;
}

uint8_t KeyboardState::currentFieldAttr() const {
    int fa = screen_.findFieldStart(screen_.cursorPos());
    return (fa >= 0) ? screen_.at(fa).attr : 0;
}

void KeyboardState::advanceToNextField(bool forward) {
    int pos = screen_.cursorPos();
    int sz = screen_.size();
    
    // Scan up to one full screen size to find the next Field Attribute
    for (int i = 0; i < sz; ++i) {
        pos = (pos + (forward ? 1 : -1) + sz) % sz;
        if (screen_.at(pos).isFA) {
            int nextData = (pos + 1) % sz;
            if (!screen_.at(pos).isProtected()) {
                screen_.setCursor(nextData);
                return;
            }
        }
    }
}

void KeyboardState::moveCursorToFirstUnprotected() {
    int sz = screen_.size();
    for (int i = 0; i < sz; ++i) {
        if (screen_.at(i).isFA && !screen_.at(i).isProtected()) {
            screen_.setCursor((i + 1) % sz);
            return;
        }
    }
}

bool KeyboardState::insertCharAtCursor(uint8_t ebcdic) {
    if (!isCurrentFieldEditable()) {
        lock(LockReason::OErr);
        return false;
    }
    
    // Write exactly at the user's visual cursor, NOT the host's background pointer
    int pos = screen_.cursorPos();
    screen_.at(pos).ch = ebcdic;
    screen_.setMDT(pos); // Mark field as modified
    
    // Advance the visual cursor
    screen_.setCursor((pos + 1) % screen_.size());
    screen_.markDirty();
    
    return true;
}

} // namespace x3270