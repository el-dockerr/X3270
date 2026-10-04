#include "ScreenBuffer.h"
#include <cstring>
#include <algorithm>

namespace x3270 {

// ── Buffer address code table (RFC 1576 / IBM GA23-0059) ─────────────────────
const uint8_t ScreenBuffer::kCodeTable[64] = {
    0x40,0xC1,0xC2,0xC3,0xC4,0xC5,0xC6,0xC7,
    0xC8,0xC9,0x4A,0x4B,0x4C,0x4D,0x4E,0x4F,
    0x50,0xD1,0xD2,0xD3,0xD4,0xD5,0xD6,0xD7,
    0xD8,0xD9,0x5A,0x5B,0x5C,0x5D,0x5E,0x5F,
    0x60,0x61,0xE2,0xE3,0xE4,0xE5,0xE6,0xE7,
    0xE8,0xE9,0x6A,0x6B,0x6C,0x6D,0x6E,0x6F,
    0xF0,0xF1,0xF2,0xF3,0xF4,0xF5,0xF6,0xF7,
    0xF8,0xF9,0x7A,0x7B,0x7C,0x7D,0x7E,0x7F
};

ScreenBuffer::ScreenBuffer(TerminalModel model)
    : model_(model)
    , rows_(rowsForModel(model))
    , cols_(colsForModel(model))
    , cells_(rows_ * cols_)
{
    eraseAll();
}

// ── Buffer operations ─────────────────────────────────────────────────────────
void ScreenBuffer::eraseAll() {
    for (auto& c : cells_) {
        c.ch        = 0x00;
        c.attr      = 0x00;
        c.isFA      = false;
        c.fgColor   = 0x00;
        c.bgColor   = 0x00;
        c.highlight = 0x00;
    }
    cursorPos_        = 0;
    bufPtr_           = 0;
    currentAttr_      = 0x00;
    currentFgColor_   = 0x00;
    currentBgColor_   = 0x00;
    currentHighlight_ = 0x00;
    dirty_            = true;
}

void ScreenBuffer::eraseAllUnprotected() {
    const int sz = rows_ * cols_;
    for (int i = 0; i < sz; ++i) {
        if (!cells_[i].isFA && !cells_[i].isProtected()) {
            cells_[i].ch = 0x00;
        }
    }
    // Clear MDT on all unprotected field attrs
    for (int i = 0; i < sz; ++i) {
        if (cells_[i].isFA && !cells_[i].isProtected()) {
            cells_[i].attr &= ~FA_MDT;
        }
    }
    dirty_ = true;
}

void ScreenBuffer::resetAllMDT() {
    const int sz = rows_ * cols_;
    for (int i = 0; i < sz; ++i) {
        if (cells_[i].isFA) {
            cells_[i].attr &= ~FA_MDT;
        }
    }
    dirty_ = true;
}

// ── Alternate mode handling ───────────────────────────────────────────────────
void ScreenBuffer::setAlternateMode(bool alternate) {
    int newRows = alternate ? rowsForModel(model_) : 24;
    int newCols = alternate ? colsForModel(model_) : 80;

    if (rows_ != newRows || cols_ != newCols) {
        rows_ = newRows;
        cols_ = newCols;
        cells_.resize(rows_ * cols_);
    }
    eraseAll();
}

void ScreenBuffer::setCursorToHome() {
    // Walk cells in order and find the first FA cell that is editable (not protected,
    // not bypass).  In 5250 mode, input fields have attr = ffw1ToAttr(FFW1) which
    // leaves FA_PROTECTED(0x20) clear for normal input fields and sets it only for
    // bypass fields.  In 3270 mode this finds the first unprotected field.
    const int sz = rows_ * cols_;
    for (int i = 0; i < sz; ++i) {
        if (cells_[i].isFA && !cells_[i].isProtected()) {
            // Set cursor to the first data position of this field (one past the FA cell)
            cursorPos_ = (i + 1) % sz;
            dirty_ = true;
            return;
        }
    }
    // No editable field found — leave cursor unchanged
}

void ScreenBuffer::writeChar(uint8_t ebcdic) {
    Cell& c     = cells_[bufPtr_];
    c.ch        = ebcdic;
    c.attr      = currentAttr_;
    c.isFA      = false;
    c.fgColor   = currentFgColor_;
    c.bgColor   = currentBgColor_;
    c.highlight = currentHighlight_;
    bufPtr_ = clamp(bufPtr_ + 1);
    dirty_ = true;
}

void ScreenBuffer::startField(uint8_t attrByte, uint8_t fgColor, uint8_t bgColor, uint8_t highlight, uint16_t fieldLen) {
    Cell& c     = cells_[bufPtr_];
    c.ch        = 0x00;
    c.attr      = attrByte;
    c.isFA      = true;
    c.fgColor   = fgColor;
    c.bgColor   = bgColor;
    c.highlight = highlight;
    c.fieldLen  = fieldLen;
    // The field’s extended colour becomes the default for subsequent characters
    currentAttr_      = attrByte;
    currentFgColor_   = fgColor;
    currentBgColor_   = bgColor;
    currentHighlight_ = highlight;
    bufPtr_ = clamp(bufPtr_ + 1);
    dirty_ = true;
}

void ScreenBuffer::startInlineAttr5250(uint8_t attrByte5250) {
    // Inline 5250 attribute byte (0x20-0x3F) — starts an output-only sub-field.
    // Marked FA_PROTECTED so the cursor / input handlers won't treat the area as
    // editable.  fgColor stores the raw 5250 attr byte for the renderer.
    uint8_t safe = (attrByte5250 >= 0x20 && attrByte5250 <= 0x3F) ? attrByte5250 : 0x20;
    Cell& c = cells_[bufPtr_];
    // If the host re-positions onto an existing SF FA and emits an inline attribute,
    // do NOT clobber the field definition — preserve fieldLen / protection bits and
    // simply update the renderer-side colour state for following cells.
    if (!(c.isFA && c.fieldLen > 0)) {
        c.ch        = 0x00;
        c.attr      = FA_PROTECTED;
        c.isFA      = true;
        c.fgColor   = safe;
        c.bgColor   = 0x00;
        c.highlight = 0x00;
        c.fieldLen  = 0;
    }
    currentAttr_      = c.attr;
    currentFgColor_   = safe;
    currentBgColor_   = 0x00;
    currentHighlight_ = 0x00;
    bufPtr_ = clamp(bufPtr_ + 1);
    dirty_ = true;
}

void ScreenBuffer::repeatToAddress(int destOffset, uint8_t ebcdic) {
    int dest = clamp(destOffset);
    do {
        Cell& c     = cells_[bufPtr_];
        c.ch        = ebcdic;
        c.attr      = currentAttr_;
        c.isFA      = false;
        c.fgColor   = currentFgColor_;
        c.bgColor   = currentBgColor_;
        c.highlight = currentHighlight_;
        bufPtr_ = clamp(bufPtr_ + 1);
    } while (bufPtr_ != dest);
    dirty_ = true;
}

void ScreenBuffer::eraseUnprotectedToAddress(int destOffset) {
    int dest = clamp(destOffset);
    do {
        if (!cells_[bufPtr_].isFA && !cells_[bufPtr_].isProtected()) {
            cells_[bufPtr_].ch = 0x00;
        }
        bufPtr_ = clamp(bufPtr_ + 1);
    } while (bufPtr_ != dest);
    dirty_ = true;
}

// ── Field attribute resolution ────────────────────────────────────────────────
// Walk backwards from bufPos to find the governing FA cell.
// The cell's .attr field on FA cells holds the raw attribute byte.
// For non-FA cells, we need to look up the nearest preceding FA.
// We also propagate attrs to all cells during this scan.
int ScreenBuffer::findFieldStart(int bufPos) const {
    const int sz = rows_ * cols_;
    for (int i = 1; i <= sz; ++i) {
        int pos = (bufPos - i + sz) % sz;
        if (cells_[pos].isFA) return pos;
    }
    return -1; // no FA found (entire screen is unformatted)
}

// ── MDT operations ────────────────────────────────────────────────────────────
void ScreenBuffer::setMDT(int bufferPos) {
    int fa = findFieldStart(bufferPos);
    if (fa >= 0) {
        cells_[fa].attr |= FA_MDT;
    }
}

// ── Read Modified ─────────────────────────────────────────────────────────────
std::vector<ScreenBuffer::ModifiedField> ScreenBuffer::getModifiedFields(bool includeProtected) const {
    std::vector<ModifiedField> result;
    const int sz = rows_ * cols_;
    for (int i = 0; i < sz; ++i) {
        if (!cells_[i].isFA) continue;
        if (!(cells_[i].attr & FA_MDT)) continue;
        // IBM GA23-0059: Read Modified returns only unprotected (input) fields.
        // Protected fields with MDT set are host-placed data, not user input;
        // sending them causes ISPF screen input error code 23.
        // Read Modified All (includeProtected=true) returns every MDT field.
        if (!includeProtected && (cells_[i].attr & FA_PROTECTED)) continue;
        // Collect data from this FA+1 to next FA
        ModifiedField mf;
        mf.startPos = i;
        mf.attrByte = cells_[i].attr;
        int pos = clamp(i + 1);
        while (pos != i && !cells_[pos].isFA) {
            if (cells_[pos].ch != 0x00) { // strip NUL
                mf.data.push_back(cells_[pos].ch);
            }
            pos = clamp(pos + 1);
        }
        result.push_back(std::move(mf));
    }
    return result;
}

std::vector<uint8_t> ScreenBuffer::buildReadModifiedRecord(int aidByte, bool includeProtected) const {
    std::vector<uint8_t> rec;
    // AID byte
    rec.push_back(static_cast<uint8_t>(aidByte));
    // Cursor address (2 bytes encoded)
    uint8_t cursorAddr[2];
    encodeAddress(cursorPos_, cursorAddr);
    rec.push_back(cursorAddr[0]);
    rec.push_back(cursorAddr[1]);

    // Each modified field: SBA(addr) + data
    auto fields = getModifiedFields(includeProtected);
    // SBA order code
    static constexpr uint8_t SBA_ORDER = 0x11;
    for (const auto& mf : fields) {
        uint8_t addr[2];
        // Data starts at FA+1
        encodeAddress(clamp(mf.startPos + 1), addr);
        rec.push_back(SBA_ORDER);
        rec.push_back(addr[0]);
        rec.push_back(addr[1]);
        for (uint8_t b : mf.data) rec.push_back(b);
    }
    return rec;
}

// ── Address encoding/decoding ─────────────────────────────────────────────────
int ScreenBuffer::decodeAddress(uint8_t b0, uint8_t b1) {
    // 14-bit binary encoding: top 2 bits of b0 are 00 (range 0x00–0x3F)
    if ((b0 & 0xC0) == 0x00) {
        return (static_cast<int>(b0 & 0x3F) << 8) | b1;
    }
    // 12-bit code-table encoding: strip top 2 bits and reassemble
    return ((b0 & 0x3F) << 6) | (b1 & 0x3F);
}

void ScreenBuffer::encodeAddress(int offset, uint8_t out[2]) {
    if (offset > 4095) {
        // 14-bit binary encoding (top 2 bits = 00) for large screens
        out[0] = static_cast<uint8_t>((offset >> 8) & 0x3F);
        out[1] = static_cast<uint8_t>(offset & 0xFF);
    } else {
        // 12-bit code-table encoding
        out[0] = kCodeTable[(offset >> 6) & 0x3F];
        out[1] = kCodeTable[offset & 0x3F];
    }
}

} // namespace x3270
