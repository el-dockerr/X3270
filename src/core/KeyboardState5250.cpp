#include "KeyboardState5250.h"
#include <algorithm>

namespace x3270 {

KeyboardState5250::KeyboardState5250(ScreenBuffer& screen, EbcdicCodec& codec)
    : screen_(screen), codec_(codec) {}

// ── Lock/unlock ───────────────────────────────────────────────────────────────

void KeyboardState5250::lock(LockReason reason) {
    lockReason_ = reason;
}

void KeyboardState5250::unlock() {
    lockReason_ = LockReason::None;
    insertMode_ = false;
}

// ── Internal helpers ──────────────────────────────────────────────────────────

void KeyboardState5250::encodeCursor(uint8_t& row, uint8_t& col) const {
    int pos  = screen_.cursorPos();
    row      = static_cast<uint8_t>(pos / screen_.cols() + 1); // 1-indexed
    col      = static_cast<uint8_t>(pos % screen_.cols() + 1);
}

uint8_t KeyboardState5250::currentFieldAttr() const {
    int pos = screen_.cursorPos();
    for (int i = 0; i < screen_.size(); ++i) {
        int p = (pos - i + screen_.size()) % screen_.size();
        if (screen_.at(p).isFA) return screen_.at(p).attr;
    }
    return 0x00;
}

bool KeyboardState5250::isCurrentFieldEditable() const {
    uint8_t attr = currentFieldAttr();
    bool prot    = (attr & FA_PROTECTED) != 0;
    bool skip    = (attr & (FA_PROTECTED | FA_NUMERIC)) == (FA_PROTECTED | FA_NUMERIC);
    return !prot && !skip;
}

void KeyboardState5250::moveCursorToFirstUnprotected() {
    for (int i = 0; i < screen_.size(); ++i) {
        const Cell& c = screen_.at(i);
        if (c.isFA && !c.isProtected() && !c.isSkip()) {
            screen_.setCursor((i + 1) % screen_.size());
            return;
        }
    }
    screen_.setCursor(0);
}

void KeyboardState5250::advanceToNextField(bool forward) {
    int cur   = screen_.cursorPos();
    int delta = forward ? 1 : -1;
    for (int i = 1; i <= screen_.size(); ++i) {
        int pos = (cur + delta * i + screen_.size() * 2) % screen_.size();
        const Cell& c = screen_.at(pos);
        // Tab lands only on input fields. Inline 5250 attribute bytes create
        // FA cells marked FA_PROTECTED (output sub-fields for colour); those
        // must be skipped, otherwise Tab gets stuck on each colour boundary
        // before ever reaching the next input field (e.g. the password field).
        if (c.isFA && !c.isProtected() && !c.isSkip()) {
            int target = (pos + 1) % screen_.size();
            if (!forward && target == cur) continue;
            screen_.setCursor(target);
            return;
        }
    }
}

bool KeyboardState5250::insertCharAtCursor(uint8_t ebcdic) {
    int cur = screen_.cursorPos();
    const Cell& cell = screen_.at(cur);
    if (cell.isFA) return false;

    // Find the governing FA to get field length
    int faPos = screen_.findFieldStart(cur);
    if (faPos >= 0) {
        const Cell& fa = screen_.at(faPos);
        if (fa.fieldLen > 0) {
            // Compute position within field (0-based from first char after FA)
            int firstChar = (faPos + 1) % screen_.size();
            int posInField = (cur - firstChar + screen_.size()) % screen_.size();
            if (posInField >= static_cast<int>(fa.fieldLen)) {
                // Field is full — lock keyboard with OErr
                lock(LockReason::OErr);
                return false;
            }
        }
    }

    if (insertMode_) {
        int fieldEnd = (cur + 1) % screen_.size();
        for (int i = 0; i < screen_.size(); ++i) {
            if (screen_.at(fieldEnd).isFA) break;
            fieldEnd = (fieldEnd + 1) % screen_.size();
        }
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

    int next = (cur + 1) % screen_.size();
    if (!screen_.at(next).isFA) {
        screen_.setCursor(next);
    }
    return true;
}

// ── AID transmission ──────────────────────────────────────────────────────────

void KeyboardState5250::sendAID(uint8_t aidCode, bool includeModifiedFields) {
    uint8_t curRow, curCol;
    encodeCursor(curRow, curCol);

    // 5250 input record format (IBM SA21-9247 §7.2 "Transmitting Data"):
    //   [row][col][AID][SBA+data per MDT field...]
    // row/col are 1-indexed, placed BEFORE the AID byte.
    std::vector<uint8_t> record;
    record.push_back(curRow);
    record.push_back(curCol);
    record.push_back(aidCode);

    if (includeModifiedFields) {
        // Walk all cells; for each modified unprotected field, emit SBA + data
        // 5250 SBA inside input records: 0x11 [row] [col]
        int inField       = 0; // 0=no field, 1=unprotected modified
        int fieldStart    = -1;
        std::vector<uint8_t> fieldData;

        auto flushField = [&](int faPos) {
            if (inField == 1 && !fieldData.empty()) {
                // The FA is at faPos; characters start one position after it
                int startOffset = (fieldStart + 1) % screen_.size();
                uint8_t sbaRow = static_cast<uint8_t>(startOffset / screen_.cols() + 1);
                uint8_t sbaCol = static_cast<uint8_t>(startOffset % screen_.cols() + 1);
                record.push_back(0x11); // SBA order
                record.push_back(sbaRow);
                record.push_back(sbaCol);
                // Trim trailing nulls
                while (!fieldData.empty() && fieldData.back() == 0x00)
                    fieldData.pop_back();
                record.insert(record.end(), fieldData.begin(), fieldData.end());
                fieldData.clear();
            }
            (void)faPos;
            inField = 0;
            fieldStart = -1;
        };

        for (int i = 0; i < screen_.size(); ++i) {
            const Cell& c = screen_.at(i);
            if (c.isFA) {
                flushField(i - 1 >= 0 ? i - 1 : screen_.size() - 1);
                if (!c.isProtected() && !c.isSkip() && c.isMDT()) {
                    inField    = 1;
                    fieldStart = i;
                } else {
                    inField    = 0;
                    fieldStart = -1;
                }
            } else if (inField == 1) {
                fieldData.push_back(c.ch);
            }
        }
        // Flush last field
        flushField(screen_.size() - 1);
    }

    if (sendCb_ && sendCb_(record)) {
        lock(LockReason::System);
    }
}

// ── Key handlers ──────────────────────────────────────────────────────────────

/*bool KeyboardState5250::handleChar(uint8_t asciiChar) {
    if (isLocked()) {
        if (lockReason_ == LockReason::System) lock(LockReason::OErr);
        return false;
    }
    if (!isCurrentFieldEditable()) {
        lock(LockReason::OErr);
        return false;
    }
    uint8_t ebcdic = codec_.fromAscii(asciiChar);
    return insertCharAtCursor(ebcdic);
}*/

// ── Key handlers ──────────────────────────────────────────────────────────────

bool KeyboardState5250::handleChar(uint8_t asciiChar) {
    uint8_t ebcdic = codec_.fromAscii(asciiChar);
    return handleEbcdicChar(ebcdic);
}

bool KeyboardState5250::handleEbcdicChar(uint8_t ebcdic) {
    if (isLocked()) {
        if (lockReason_ == LockReason::System) lock(LockReason::OErr);
        return false;
    }
    if (!isCurrentFieldEditable()) {
        lock(LockReason::OErr);
        return false;
    }
    return insertCharAtCursor(ebcdic);
}

bool KeyboardState5250::handleTab(bool backward) {
    if (isLocked()) return false;
    advanceToNextField(!backward);
    return true;
}

bool KeyboardState5250::handleEnter() {
    if (isLocked()) return false;
    insertMode_ = false;
    sendAID(AID5250_ENTER, true);
    return true;
}

bool KeyboardState5250::handleClear() {
    unlock();
    screen_.eraseAll();
    sendAID(AID5250_CLEAR, false);
    return true;
}

bool KeyboardState5250::handlePFKey(int n) {
    if (isLocked()) return false;
    sendAID(pf5250AID(n), true);
    return true;
}

bool KeyboardState5250::handlePageUp() {
    if (isLocked()) return false;
    sendAID(AID5250_ROLL_DN, false);
    return true;
}

bool KeyboardState5250::handlePageDown() {
    if (isLocked()) return false;
    sendAID(AID5250_ROLL_UP, false);
    return true;
}

bool KeyboardState5250::handleHelp() {
    if (isLocked()) return false;
    sendAID(AID5250_HELP, false);
    return true;
}

bool KeyboardState5250::handleAttn() {
    if (isLocked()) unlock();
    sendAID(AID5250_ATTN, false);
    return true;
}

bool KeyboardState5250::handleHome() {
    if (isLocked()) return false;
    moveCursorToFirstUnprotected();
    return true;
}

bool KeyboardState5250::handleArrow(int dRow, int dCol) {
    if (isLocked()) return false;
    int cur  = screen_.cursorPos();
    int row  = cur / screen_.cols();
    int col  = cur % screen_.cols();
    row = (row + dRow + screen_.rows()) % screen_.rows();
    col = (col + dCol + screen_.cols()) % screen_.cols();
    screen_.setCursor(row * screen_.cols() + col);
    return true;
}

bool KeyboardState5250::handleBackspace() {
    if (isLocked()) return false;
    int cur = screen_.cursorPos();
    if (cur > 0 && !screen_.at(cur - 1).isFA) {
        screen_.setCursor(cur - 1);
        screen_.at(cur - 1).ch = 0x00;
        screen_.setMDT(cur - 1);
        screen_.markDirty();
    }
    return true;
}

bool KeyboardState5250::handleDelete() {
    if (isLocked()) return false;
    int cur = screen_.cursorPos();
    if (screen_.at(cur).isFA) return false;
    // Shift field left from cursor
    int pos = cur;
    while (true) {
        int next = (pos + 1) % screen_.size();
        if (screen_.at(next).isFA) { screen_.at(pos).ch = 0x00; break; }
        screen_.at(pos).ch = screen_.at(next).ch;
        pos = next;
    }
    screen_.setMDT(cur);
    screen_.markDirty();
    return true;
}

bool KeyboardState5250::handleEraseField() {
    if (isLocked()) return false;
    int cur = screen_.cursorPos();
    for (int i = cur; i < screen_.size(); ++i) {
        if (screen_.at(i).isFA) break;
        screen_.at(i).ch = 0x00;
    }
    screen_.setMDT(cur);
    screen_.markDirty();
    return true;
}

bool KeyboardState5250::handleInsert() {
    if (isLocked()) return false;
    toggleInsert();
    return true;
}

} // namespace x3270
