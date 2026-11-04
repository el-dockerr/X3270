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

// -----------------------------------------------------------------------------
// Navigation & Deletion Handlers
// -----------------------------------------------------------------------------
bool KeyboardState::handleBackspace() {
    if (isLocked()) return false;
    int pos = screen_.cursorPos();
    if (!isCurrentFieldEditable()) {
        lock(LockReason::OErr);
        return false;
    }

    int fa = screen_.findFieldStart(pos);
    int sz = screen_.size();
    int firstPos = (fa >= 0) ? (fa + 1) % sz : 0;
    int lastPos = sz - 1;

    if (fa >= 0) {
        for (int i = 1; i <= sz; ++i) {
            int p = (fa + i) % sz;
            if (screen_.at(p).isFA) {
                lastPos = (p - 1 + sz) % sz;
                break;
            }
        }
    }

    // If the cursor is at the first character of the field,
    // do not move back further! This prevents landing on the attribute (isFA) and locking the keyboard in OErr.
    if (fa >= 0 && pos == firstPos) {
        return true; 
    }

    if (recorder_ && recorder_->isRecording()) {
        recorder_->recordNavKey(MacroNavCode::Backspace, pos);
    }

    int targetPos = (pos - 1 + sz) % sz;
    screen_.setCursor(targetPos);

    if (insertMode_) {
        // In insert mode: delete the character and shift the subsequent text to the left
        for (int p = targetPos; p != lastPos; p = (p + 1) % sz) {
            int next = (p + 1) % sz;
            screen_.at(p).ch        = screen_.at(next).ch;
            screen_.at(p).fgColor   = screen_.at(next).fgColor;
            screen_.at(p).bgColor   = screen_.at(next).bgColor;
            screen_.at(p).highlight = screen_.at(next).highlight;
        }
        screen_.at(lastPos).ch        = 0x00; // Inserisce null alla fine del campo
        screen_.at(lastPos).fgColor   = 0x00;
        screen_.at(lastPos).bgColor   = 0x00;
        screen_.at(lastPos).highlight = 0x00;
    } else {
        // In overwrite mode: blank out the position
        screen_.at(targetPos).ch = codec_.fromAscii(' ');
    }

    screen_.setMDT(targetPos);
    screen_.markDirty();
    return true;
}

bool KeyboardState::handleDelete() {
    if (isLocked()) return false;
    int pos = screen_.cursorPos();
    if (!isCurrentFieldEditable()) {
        lock(LockReason::OErr);
        return false;
    }

    if (recorder_ && recorder_->isRecording()) {
        recorder_->recordNavKey(MacroNavCode::Delete, pos);
    }

    int fa = screen_.findFieldStart(pos);
    int sz = screen_.size();
    int lastPos = sz - 1;

    if (fa >= 0) {
        for (int i = 1; i <= sz; ++i) {
            int p = (fa + i) % sz;
            if (screen_.at(p).isFA) {
                lastPos = (p - 1 + sz) % sz;
                break;
            }
        }
    }

    // Shift all characters to the left of the cursor
    for (int p = pos; p != lastPos; p = (p + 1) % sz) {
        int next = (p + 1) % sz;
        screen_.at(p).ch        = screen_.at(next).ch;
        screen_.at(p).fgColor   = screen_.at(next).fgColor;
        screen_.at(p).bgColor   = screen_.at(next).bgColor;
        screen_.at(p).highlight = screen_.at(next).highlight;
    }
    screen_.at(lastPos).ch        = 0x00;
    screen_.at(lastPos).fgColor   = 0x00;
    screen_.at(lastPos).bgColor   = 0x00;
    screen_.at(lastPos).highlight = 0x00;

    screen_.setMDT(pos);
    screen_.markDirty();
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

// -----------------------------------------------------------------------------
// Data Insertion with Real 3270 Insert Mode Support
// -----------------------------------------------------------------------------
bool KeyboardState::insertCharAtCursor(uint8_t ebcdic) {
    if (!isCurrentFieldEditable()) {
        lock(LockReason::OErr);
        return false;
    }

    int pos = screen_.cursorPos();
    int sz = screen_.size();
    int fa = screen_.findFieldStart(pos);
    int lastPos = sz - 1;

    if (fa >= 0) {
        for (int i = 1; i <= sz; ++i) {
            int p = (fa + i) % sz;
            if (screen_.at(p).isFA) {
                lastPos = (p - 1 + sz) % sz;
                break;
            }
        }
    }

    if (insertMode_) {
        // Check field saturation (3270 Insert Overflow):
        // The last character of the field must be null (0x00) or space to allow insertion
        uint8_t lastCh = screen_.at(lastPos).ch;
        if (lastCh != 0x00 && lastCh != 0x40 && lastCh != codec_.fromAscii(' ')) {
            lock(LockReason::OErr); // Field full: standard 3270 keyboard lock
            return false;
        }

        // Shift all characters from lastPos backwards to pos to the right
        for (int p = lastPos; p != pos; p = (p - 1 + sz) % sz) {
            int prev = (p - 1 + sz) % sz;
            screen_.at(p).ch        = screen_.at(prev).ch;
            screen_.at(p).fgColor   = screen_.at(prev).fgColor;
            screen_.at(p).bgColor   = screen_.at(prev).bgColor;
            screen_.at(p).highlight = screen_.at(prev).highlight;
        }
    }

    // Write the character at the cursor position
    screen_.at(pos).ch        = ebcdic;
    screen_.at(pos).fgColor   = 0x00;
    screen_.at(pos).bgColor   = 0x00;
    screen_.at(pos).highlight = 0x00;
    screen_.setMDT(pos);

    // Advance the cursor (if the limit is reached, move to the next field instead of landing on the attribute)
    if (pos == lastPos) {
        advanceToNextField(true);
    } else {
        screen_.setCursor((pos + 1) % sz);
    }

    screen_.markDirty();
    return true;
}

} // namespace x3270