#include "KeyboardState.h"
#include <algorithm>

namespace x3270 {

KeyboardState::KeyboardState(ScreenBuffer& screen, EbcdicCodec& codec)
    : screen_(screen), codec_(codec) {}

// ── Lock/unlock ───────────────────────────────────────────────────────────────
void KeyboardState::lock(LockReason reason) {
    lockReason_ = reason;
}

void KeyboardState::unlock() {
    lockReason_ = LockReason::None;
    insertMode_ = false;
}

// ── Internal helpers ──────────────────────────────────────────────────────────
uint8_t KeyboardState::currentFieldAttr() const {
    int pos = screen_.cursorPos();
    // Walk back to find the governing FA
    for (int i = 0; i < screen_.size(); ++i) {
        int p = (pos - i + screen_.size()) % screen_.size();
        if (screen_.at(p).isFA) return screen_.at(p).attr;
    }
    return 0x00; // unformatted screen — default unprotected
}

bool KeyboardState::isCurrentFieldEditable() const {
    uint8_t attr = currentFieldAttr();
    bool prot    = (attr & FA_PROTECTED) != 0;
    bool numeric = (attr & FA_NUMERIC)   != 0;
    bool skip    = prot && numeric;
    return !prot && !skip;
}

void KeyboardState::moveCursorToFirstUnprotected() {
    for (int i = 0; i < screen_.size(); ++i) {
        const Cell& c = screen_.at(i);
        if (c.isFA && !c.isProtected()) {
            screen_.setCursor((i + 1) % screen_.size());
            return;
        }
    }
    screen_.setCursor(0);
}

void KeyboardState::advanceToNextField(bool forward) {
    int cur   = screen_.cursorPos();
    int delta = forward ? 1 : -1;
    for (int i = 1; i <= screen_.size(); ++i) {
        int pos = (cur + delta * i + screen_.size() * 2) % screen_.size();
        const Cell& c = screen_.at(pos);
        if (c.isFA && !c.isProtected()) {
            int target = (pos + 1) % screen_.size();
            // BackTab: if we are already at the first character of this
            // field (target == cur), this is the *current* field's FA --
            // keep scanning backward to find the previous input field.
            if (!forward && target == cur) continue;
            screen_.setCursor(target);
            return;
        }
    }
}

bool KeyboardState::insertCharAtCursor(uint8_t ebcdic) {
    int cur = screen_.cursorPos();
    const Cell& cell = screen_.at(cur);
    if (cell.isFA) return false; // cursor is on FA position — skip

    if (insertMode_) {
        // Shift cells right within the field until end of field or null cell
        // Find end of field (next FA or wraps)
        int fieldEnd = (cur + 1) % screen_.size();
        for (int i = 0; i < screen_.size(); ++i) {
            if (screen_.at(fieldEnd).isFA) break;
            fieldEnd = (fieldEnd + 1) % screen_.size();
        }
        // fieldEnd is now the position of the next FA (exclusive)
        // shift from end-1 back to cur, dropping the last char
        int shiftEnd = (fieldEnd - 1 + screen_.size()) % screen_.size();
        while (shiftEnd != cur) {
            int prev = (shiftEnd - 1 + screen_.size()) % screen_.size();
            screen_.at(shiftEnd).ch = screen_.at(prev).ch;
            shiftEnd = prev;
        }
    }

    screen_.at(cur).ch = ebcdic;
    screen_.setMDT(cur);
    screen_.markDirty();

    // Advance cursor (stay within field)
    int next = (cur + 1) % screen_.size();
    if (!screen_.at(next).isFA) {
        screen_.setCursor(next);
    }
    return true;
}

// ── AID transmission ──────────────────────────────────────────────────────────
void KeyboardState::sendAID(uint8_t aidCode, bool includeModifiedFields) {
    std::vector<uint8_t> record;
    if (includeModifiedFields) {
        record = screen_.buildReadModifiedRecord(aidCode);
    } else {
        // PA keys: just AID byte + cursor address
        record.push_back(aidCode);
        uint8_t addr[2];
        ScreenBuffer::encodeAddress(screen_.cursorPos(), addr);
        record.push_back(addr[0]);
        record.push_back(addr[1]);
    }
    if (sendCb_ && sendCb_(record)) lock(LockReason::System);
}

void KeyboardState::sendPAKey(uint8_t aidCode) {
    sendAID(aidCode, false);
}

// ── Key handlers ──────────────────────────────────────────────────────────────
bool KeyboardState::handleChar(uint8_t asciiChar) {
    if (isLocked()) {
        // Only escalate to OErr when we're in a normal System lock;
        // Connecting and OErr states must not be overwritten.
        if (lockReason_ == LockReason::System)
            lock(LockReason::OErr);
        return false;
    }
    if (!isCurrentFieldEditable()) {
        lock(LockReason::OErr);
        return false;
    }
    uint8_t ebcdic = codec_.fromAscii(asciiChar);
    return insertCharAtCursor(ebcdic);
}

bool KeyboardState::handleTab(bool backward) {
    if (isLocked()) return false;
    advanceToNextField(!backward);
    return true;
}

bool KeyboardState::handleEnter() {
    if (isLocked()) return false;
    sendAID(AID_ENTER, true);
    return true;
}

bool KeyboardState::handleClear() {
    // Clear always sends even when locked
    unlock();
    screen_.eraseAll();
    if (sendCb_) {
        std::vector<uint8_t> record = { AID_CLEAR, 0x40, 0x40 }; // cursor at 0,0 encoded
        if (sendCb_(record)) lock(LockReason::System);
    }
    return true;
}

bool KeyboardState::handlePF(int n) {
    if (isLocked()) return false;
    sendAID(pfAID(n), true);
    return true;
}

bool KeyboardState::handlePA(int n) {
    if (isLocked()) return false;
    uint8_t aidCode = (n == 1) ? AID_PA1 : (n == 2) ? AID_PA2 : AID_PA3;
    sendPAKey(aidCode);
    return true;
}

bool KeyboardState::handleBackspace() {
    if (isLocked()) return false;
    if (!isCurrentFieldEditable()) return false;
    int cur = screen_.cursorPos();
    int prev = (cur - 1 + screen_.size()) % screen_.size();
    // Don't move past an FA
    if (screen_.at(prev).isFA) return false;
    screen_.setCursor(prev);
    screen_.at(prev).ch = 0x00;
    screen_.setMDT(prev);
    screen_.markDirty();
    return true;
}

bool KeyboardState::handleDelete() {
    if (isLocked()) return false;
    if (!isCurrentFieldEditable()) return false;
    int cur = screen_.cursorPos();
    // Shift everything left within the field
    int pos = cur;
    while (true) {
        int next = (pos + 1) % screen_.size();
        if (screen_.at(next).isFA) {
            screen_.at(pos).ch = 0x00;
            break;
        }
        screen_.at(pos).ch = screen_.at(next).ch;
        pos = next;
    }
    screen_.setMDT(cur);
    screen_.markDirty();
    return true;
}

bool KeyboardState::handleHome() {
    if (isLocked()) return false;
    moveCursorToFirstUnprotected();
    return true;
}

bool KeyboardState::handleEraseEOF() {
    if (isLocked()) return false;
    if (!isCurrentFieldEditable()) return false;
    int cur = screen_.cursorPos();
    int pos = cur;
    while (!screen_.at(pos).isFA) {
        screen_.at(pos).ch = 0x00;
        pos = (pos + 1) % screen_.size();
        if (pos == cur) break; // wrapped all the way around
    }
    screen_.setMDT(cur);
    screen_.markDirty();
    return true;
}

bool KeyboardState::handleEraseInput() {
    if (isLocked()) return false;
    screen_.eraseAllUnprotected();
    moveCursorToFirstUnprotected();
    return true;
}

bool KeyboardState::handleNewLine() {
    if (isLocked()) return false;
    // Move cursor to first unprotected field on the next line
    int curRow = screen_.cursorPos() / screen_.cols();
    int nextRowStart = ((curRow + 1) % screen_.rows()) * screen_.cols();
    // Search forward from nextRowStart for first unprotected field
    for (int i = 0; i < screen_.size(); ++i) {
        int pos = (nextRowStart + i) % screen_.size();
        if (screen_.at(pos).isFA && !screen_.at(pos).isSkip()) {
            screen_.setCursor((pos + 1) % screen_.size());
            return true;
        }
    }
    return true;
}

bool KeyboardState::handleCursorUp() {
    if (isLocked()) return false;
    int pos = screen_.cursorPos();
    screen_.setCursor((pos - screen_.cols() + screen_.size()) % screen_.size());
    return true;
}

bool KeyboardState::handleCursorDown() {
    if (isLocked()) return false;
    int pos = screen_.cursorPos();
    screen_.setCursor((pos + screen_.cols()) % screen_.size());
    return true;
}

bool KeyboardState::handleCursorLeft() {
    if (isLocked()) return false;
    screen_.setCursor((screen_.cursorPos() - 1 + screen_.size()) % screen_.size());
    return true;
}

bool KeyboardState::handleCursorRight() {
    if (isLocked()) return false;
    screen_.setCursor((screen_.cursorPos() + 1) % screen_.size());
    return true;
}

bool KeyboardState::handleReset() {
    if (lockReason_ == LockReason::OErr || lockReason_ == LockReason::System) {
        unlock();
    }
    insertMode_ = false;
    return true;
}

} // namespace x3270
