#include "KeyboardState5250.h"

namespace x3270 {

// -----------------------------------------------------------------------------
// Constructor
// -----------------------------------------------------------------------------
KeyboardState5250::KeyboardState5250(ScreenBuffer& screen, EbcdicCodec& codec)
    : screen_(screen), codec_(codec) {}

// -----------------------------------------------------------------------------
// State Management
// -----------------------------------------------------------------------------
void KeyboardState5250::lock(LockReason reason) {
    lockReason_ = reason;
}

void KeyboardState5250::unlock() {
    lockReason_ = LockReason::None;
}

// -----------------------------------------------------------------------------
// Data Input Handlers
// -----------------------------------------------------------------------------
bool KeyboardState5250::handleChar(uint16_t unicodeChar) {
    if (isLocked()) return false;
    int posBefore = screen_.cursorPos();
    uint8_t ebcdic = codec_.fromUnichar(unicodeChar);
    
    bool ok = insertCharAtCursor(ebcdic);
    
    if (ok && recorder_ && recorder_->isRecording()) {
        recorder_->recordChar(unicodeChar, posBefore);
    }
    return ok;
}

bool KeyboardState5250::handleEbcdicChar(uint8_t ebcdic) {
    if (isLocked()) return false;
    int posBefore = screen_.cursorPos();
    
    bool ok = insertCharAtCursor(ebcdic);
    
    if (ok && recorder_ && recorder_->isRecording()) {
        uint16_t unicodeChar = codec_.toUnicode(ebcdic);
        recorder_->recordChar(unicodeChar, posBefore);
    }
    return ok;
}

// -----------------------------------------------------------------------------
// Navigation Handlers
// -----------------------------------------------------------------------------
bool KeyboardState5250::handleTab(bool backward) {
    if (isLocked()) return false;
    int posBefore = screen_.cursorPos();
    
    advanceToNextField(!backward);
    
    if (recorder_ && recorder_->isRecording()) {
        recorder_->recordNavKey(backward ? MacroNavCode::BackTab : MacroNavCode::Tab, posBefore);
    }
    return true;
}

bool KeyboardState5250::handleHome() {
    if (isLocked()) return false;
    int posBefore = screen_.cursorPos();
    
    if (recorder_ && recorder_->isRecording()) {
        recorder_->recordNavKey(MacroNavCode::Home, posBefore);
    }
    
    moveCursorToFirstUnprotected();
    return true;
}

bool KeyboardState5250::handleArrow(int dRow, int dCol) {
    if (isLocked()) return false;
    int posBefore = screen_.cursorPos();
    
    if (recorder_ && recorder_->isRecording()) {
        MacroNavCode code = MacroNavCode::CursorRight;
        if (dRow == -1) code = MacroNavCode::CursorUp;
        else if (dRow == 1) code = MacroNavCode::CursorDown;
        else if (dCol == -1) code = MacroNavCode::CursorLeft;
        recorder_->recordNavKey(code, posBefore);
    }
    
    // Calculate new position using 2D grid logic
    int newRow = (posBefore / screen_.cols()) + dRow;
    int newCol = (posBefore % screen_.cols()) + dCol;
    
    newRow = (newRow + screen_.rows()) % screen_.rows();
    newCol = (newCol + screen_.cols()) % screen_.cols();
    
    screen_.setCursor(newRow * screen_.cols() + newCol);
    return true;
}

bool KeyboardState5250::handleBackspace() {
    if (isLocked()) return false;
    int posBefore = screen_.cursorPos();
    
    if (recorder_ && recorder_->isRecording()) {
        recorder_->recordNavKey(MacroNavCode::Backspace, posBefore);
    }
    
    if (isCurrentFieldEditable()) {
        int newPos = (screen_.cursorPos() - 1 + screen_.size()) % screen_.size();
        screen_.setCursor(newPos);
        screen_.at(newPos).ch = codec_.fromAscii(' ');
        screen_.setMDT(newPos);
    } else {
        lock(LockReason::OErr);
        return false;
    }
    return true;
}

bool KeyboardState5250::handleDelete() {
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

bool KeyboardState5250::handleEraseField() {
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

bool KeyboardState5250::handleInsert() {
    toggleInsert();
    
    if (recorder_ && recorder_->isRecording()) {
        recorder_->recordNavKey(MacroNavCode::InsertToggle, screen_.cursorPos());
    }
    return true;
}

// -----------------------------------------------------------------------------
// AID Handlers (Host Transmission)
// -----------------------------------------------------------------------------
bool KeyboardState5250::handleEnter() {
    if (isLocked()) return false;
    int posBefore = screen_.cursorPos();
    
    if (recorder_ && recorder_->isRecording()) {
        recorder_->recordAIDKey(AID5250_ENTER, posBefore, &screen_);
    }
    
    sendAID(AID5250_ENTER, true);
    return true;
}

bool KeyboardState5250::handleClear() {
    if (isLocked()) return false;
    int posBefore = screen_.cursorPos();
    
    if (recorder_ && recorder_->isRecording()) {
        recorder_->recordAIDKey(AID5250_CLEAR, posBefore, &screen_);
    }
    
    sendAID(AID5250_CLEAR, false);
    return true;
}

bool KeyboardState5250::handlePFKey(int n) {
    if (isLocked()) return false;
    int posBefore = screen_.cursorPos();
    
    if (recorder_ && recorder_->isRecording()) {
        recorder_->recordAIDKey(pf5250AID(n), posBefore, &screen_);
    }
    
    sendAID(pf5250AID(n), true);
    return true;
}

bool KeyboardState5250::handlePageUp() {
    if (isLocked()) return false;
    int posBefore = screen_.cursorPos();
    
    // 5250 PageUp corresponds to Roll Down (AID5250_ROLL_DN)
    if (recorder_ && recorder_->isRecording()) {
        recorder_->recordAIDKey(AID5250_ROLL_DN, posBefore, &screen_);
    }
    
    sendAID(AID5250_ROLL_DN, true);
    return true;
}

bool KeyboardState5250::handlePageDown() {
    if (isLocked()) return false;
    int posBefore = screen_.cursorPos();
    
    // 5250 PageDown corresponds to Roll Up (AID5250_ROLL_UP)
    if (recorder_ && recorder_->isRecording()) {
        recorder_->recordAIDKey(AID5250_ROLL_UP, posBefore, &screen_);
    }
    
    sendAID(AID5250_ROLL_UP, true);
    return true;
}

bool KeyboardState5250::handleHelp() {
    if (isLocked()) return false;
    int posBefore = screen_.cursorPos();
    
    if (recorder_ && recorder_->isRecording()) {
        recorder_->recordAIDKey(AID5250_HELP, posBefore, &screen_);
    }
    
    sendAID(AID5250_HELP, true);
    return true;
}

bool KeyboardState5250::handleAttn() {
    if (isLocked()) return false;
    int posBefore = screen_.cursorPos();
    
    if (recorder_ && recorder_->isRecording()) {
        recorder_->recordAIDKey(AID5250_ATTN, posBefore, &screen_);
    }
    
    sendAID(AID5250_ATTN, false);
    return true;
}

// -----------------------------------------------------------------------------
// Internal Helpers (5250 Format)
// -----------------------------------------------------------------------------
void KeyboardState5250::sendAID(uint8_t aidCode, bool includeModifiedFields) {
    lock(LockReason::System); // Lock keyboard waiting for host
    if (!sendCb_) return;
    
    std::vector<uint8_t> rec;
    
    // 5250 Record Layout: [AID][Cursor Row][Cursor Col][SBA + Data for each modified field...]
    rec.push_back(aidCode);
    
    uint8_t cRow, cCol;
    encodeCursor(cRow, cCol);
    rec.push_back(cRow);
    rec.push_back(cCol);
    
    if (includeModifiedFields) {
        auto fields = screen_.getModifiedFields(false);
        for (const auto& mf : fields) {
            rec.push_back(0x11); // SBA Order (Set Buffer Address)
            
            uint8_t fRow, fCol;
            int fOffset = (mf.startPos + 1) % screen_.size();
            fRow = static_cast<uint8_t>((fOffset / screen_.cols()) + 1);
            fCol = static_cast<uint8_t>((fOffset % screen_.cols()) + 1);
            
            rec.push_back(fRow);
            rec.push_back(fCol);
            
            // Append modified data
            for (uint8_t b : mf.data) {
                rec.push_back(b);
            }
        }
    }
    
    sendCb_(rec);
}

void KeyboardState5250::encodeCursor(uint8_t& row, uint8_t& col) const {
    // 5250 uses 1-indexed coordinates for transmission
    int pos = screen_.cursorPos();
    row = static_cast<uint8_t>((pos / screen_.cols()) + 1);
    col = static_cast<uint8_t>((pos % screen_.cols()) + 1);
}

uint8_t KeyboardState5250::currentFieldAttr() const {
    int fa = screen_.findFieldStart(screen_.cursorPos());
    return (fa >= 0) ? screen_.at(fa).attr : 0;
}

bool KeyboardState5250::isCurrentFieldEditable() const {
    int fa = screen_.findFieldStart(screen_.cursorPos());
    if (fa < 0) return true; // CRITICAL FIX: Unformatted screens are fully editable
    return (screen_.at(fa).attr & FA_PROTECTED) == 0;
}

void KeyboardState5250::advanceToNextField(bool forward) {
    int pos = screen_.cursorPos();
    int sz = screen_.size();
    for (int i = 0; i < sz; ++i) {
        pos = (pos + (forward ? 1 : -1) + sz) % sz;
        if (screen_.at(pos).isFA && !screen_.at(pos).isProtected()) {
            screen_.setCursor((pos + 1) % sz);
            return;
        }
    }
}

void KeyboardState5250::moveCursorToFirstUnprotected() {
    int sz = screen_.size();
    for (int i = 0; i < sz; ++i) {
        if (screen_.at(i).isFA && !screen_.at(i).isProtected()) {
            screen_.setCursor((i + 1) % sz);
            return;
        }
    }
}

bool KeyboardState5250::insertCharAtCursor(uint8_t ebcdic) {
    if (!isCurrentFieldEditable()) {
        lock(LockReason::OErr);
        return false;
    }
    
    int pos = screen_.cursorPos();
    screen_.at(pos).ch = ebcdic;
    screen_.setMDT(pos); // Tag field as modified
    
    screen_.setCursor((pos + 1) % screen_.size());
    screen_.markDirty();
    
    return true;
}

} // namespace x3270