#pragma once
#include <cstdint>
#include <vector>
#include <functional>
#include "TerminalModel.h"

namespace x3270 {

// ── Field Attribute byte bit layout ──────────────────────────────────────────
// Bit 2: Protected  (1=output only, 0=input)
// Bit 3: Numeric    (1=numeric only; bits 2+3 both 1 → Skip)
// Bits 4-5: Display (00=normal, 01=normal+LP, 10=intensified, 11=non-display)
// Bit 7: MDT        (Modified Data Tag — set when user edits the field)
static constexpr uint8_t FA_PROTECTED   = 0x20;
static constexpr uint8_t FA_NUMERIC     = 0x10;
static constexpr uint8_t FA_DISP_NORMAL = 0x00;
static constexpr uint8_t FA_DISP_LP     = 0x04;  // bits[3:2]=01 → normal + light-pen detect
static constexpr uint8_t FA_INTENSIFIED = 0x08;  // bits[3:2]=10 → intensified
static constexpr uint8_t FA_NONDISPLAY  = 0x0C;  // bits[3:2]=11 → non-display (hidden)
static constexpr uint8_t FA_MDT        = 0x01;

// ── Cell ─────────────────────────────────────────────────────────────────────
struct Cell {
    uint8_t  ch        { 0x00 }; // EBCDIC character byte (0x00 = empty/null)
    uint8_t  attr      { 0x00 }; // Field attribute byte of the governing field
    bool     isFA      { false }; // true if this cell IS a field attribute position
    // Extended colour/highlight attributes (from SA or SFE orders):
    // 0x00 = use field-attribute default; 0xF1-0xF7 = IBM 3279 colour index
    uint8_t  fgColor   { 0x00 }; // foreground colour (0=field-default)
    uint8_t  bgColor   { 0x00 }; // background colour (0=black)
    uint8_t  highlight { 0x00 }; // 0=normal, 0xF2=reverse, 0xF4=underscore, 0xF1=blink
    uint16_t fieldLen  { 0 };    // (FA cells only) usable character count; 0 = infer from layout

    bool isProtected()  const { return (attr & FA_PROTECTED) != 0; }
    bool isNumeric()    const { return (attr & FA_NUMERIC)   != 0; }
    bool isSkip()       const { return (attr & (FA_PROTECTED|FA_NUMERIC)) == (FA_PROTECTED|FA_NUMERIC); }
    bool isNonDisplay() const { return (attr & 0x0C) == FA_NONDISPLAY; }
    bool isIntensified()const { return (attr & 0x0C) == FA_INTENSIFIED; }
    bool isMDT()        const { return (attr & FA_MDT) != 0; }
};

// ── ScreenBuffer ──────────────────────────────────────────────────────────────
class ScreenBuffer {
public:
    explicit ScreenBuffer(TerminalModel model = TerminalModel::Model2);

    // Runtime grid dimensions
    int rows()  const { return rows_; }
    int cols()  const { return cols_; }
    int size()  const { return rows_ * cols_; }
    TerminalModel model() const { return model_; }

    // ── Buffer access ─────────────────────────────────────────────────────────
    Cell&       at(int offset)       { return cells_[offset]; }
    const Cell& at(int offset) const { return cells_[offset]; }
    Cell&       at(int row, int col) { return cells_[row * cols_ + col]; }

    int   cursorPos()  const { return cursorPos_; }
    void  setCursor(int pos) { cursorPos_ = clamp(pos); }

    // ── Screen operations (called by DataStreamParser) ────────────────────────

    /// Erase entire buffer and reset all fields (used by Erase/Write)
    void eraseAll();

    /// Erase all unprotected fields (Erase All Unprotected command)
    void eraseAllUnprotected();

    /// Write a character at bufferPointer_, then advance it
    void writeChar(uint8_t ebcdic);

    /// Start a new field at bufferPointer_.
    /// fgColor/bgColor/highlight are IBM 3279 extended colour codes (0x00=default, 0xF1-0xF7).
    void startField(uint8_t attrByte,
                    uint8_t fgColor   = 0x00,
                    uint8_t bgColor   = 0x00,
                    uint8_t highlight = 0x00,
                    uint16_t fieldLen = 0);

    /// Place an inline 5250 display-attribute byte (0x20-0x3F) at the current
    /// buffer pointer. The attribute occupies a buffer position (rendered as a
    /// blank) and governs all subsequent cells until the next attribute/field.
    /// The cell is marked protected by default — input fields are introduced
    /// only via Start-of-Field orders (which call startField() with FFW-derived
    /// attr bits).
    void startInlineAttr5250(uint8_t attrByte5250);

    /// Update the "current" SA-order colour/highlight applied to subsequent writeChar calls.
    void setCurrentFgColor(uint8_t c)   { currentFgColor_   = c; }
    void setCurrentBgColor(uint8_t c)   { currentBgColor_   = c; }
    void setCurrentHighlight(uint8_t c) { currentHighlight_ = c; }

    /// Set buffer pointer (SetBufferAddress order)
    void setBufferAddress(int offset) { bufPtr_ = clamp(offset); }
    int  bufferPointer() const        { return bufPtr_; }
    /// Set or clear the alternate mode flag. In alternate mode, certain rendering
    /// and addressing behaviors may differ (e.g., for large custom screens).
    void setAlternateMode(bool alternate);

    /// Repeat character from current pointer to destOffset
    void repeatToAddress(int destOffset, uint8_t ebcdic);

    /// Erase unprotected characters from current pointer to destOffset
    void eraseUnprotectedToAddress(int destOffset);

    /// Insert cursor marker at current bufferPointer_
    void insertCursorHere() { cursorPos_ = bufPtr_; }

    // ── Read Modified (build client→host AID data) ────────────────────────────
    struct ModifiedField {
        int              startPos;
        uint8_t          attrByte;
        std::vector<uint8_t> data; // EBCDIC bytes (NUL stripped)
    };
    /// includeProtected=false for Read Modified (user AID keys / solicited poll),
    /// includeProtected=true  for Read Modified All (host solicited — returns every MDT field).
    std::vector<ModifiedField> getModifiedFields(bool includeProtected = false) const;

    /// Build Read Modified data: SBA(cursor) + {SBA(field)+data} for each MDT field.
    /// Pass includeProtected=true only for Read Modified All.
    std::vector<uint8_t> buildReadModifiedRecord(int aidByte, bool includeProtected = false) const;

    /// Clear MDT bit on all unprotected fields
    void resetAllMDT();

    /// Move cursor to the first character of the first non-protected, non-bypass field.
    /// Called by the 5250 parser when CC2 UNLOCK bit is set and no explicit IC order
    /// was seen in the WTD data stream (mirrors tn5250_display_set_cursor_home).
    void setCursorToHome();

    /// Set MDT on the field that owns the given buffer position
    void setMDT(int bufferPos);

    // ── 3270 Buffer Address encoding/decoding ────────────────────────────────
    static int  decodeAddress(uint8_t b0, uint8_t b1);
    static void encodeAddress(int offset, uint8_t out[2]);

    // ── Dirty tracking (for UI redraws) ──────────────────────────────────────
    bool isDirty() const  { return dirty_; }
    void clearDirty()     { dirty_ = false; }
    void markDirty()      { dirty_ = true; }

    /// Find the field attribute cell that governs bufPos.
    /// Returns the index of the FA cell, or -1 if the screen is unformatted.
    int findFieldStart(int bufPos) const;

private:
    int clamp(int pos) const {
        int sz = rows_ * cols_;
        if (pos < 0) pos = (pos % sz + sz) % sz;
        return pos % sz;
    }

    TerminalModel model_;
    int     rows_;
    int     cols_;
    std::vector<Cell> cells_;
    int     cursorPos_        { 0 };
    int     bufPtr_           { 0 };
    bool    dirty_            { false };
    uint8_t currentAttr_      { 0x00 };  // field attr of the most-recently opened field
    uint8_t currentFgColor_   { 0x00 };  // active extended fg colour (SA or SFE)
    uint8_t currentBgColor_   { 0x00 };  // active extended bg colour
    uint8_t currentHighlight_ { 0x00 };  // active highlight (reverse/underscore/blink)

    // Buffer address code table (64 entries, 6-bit index → 8-bit wire byte)
    static const uint8_t kCodeTable[64];
};

} // namespace x3270
