#pragma once
#include "ScreenBuffer.h"
#include "EbcdicCodec.h"
#include <cstdint>
#include <vector>
#include <functional>

namespace x3270 {

// ── AID Codes (client → host first byte) ─────────────────────────────────────
static constexpr uint8_t AID_NO_AID  = 0x60; // no AID (data transmission only)
static constexpr uint8_t AID_ENTER   = 0x7D;
static constexpr uint8_t AID_CLEAR   = 0x6D;
static constexpr uint8_t AID_PA1     = 0x6C;
static constexpr uint8_t AID_PA2     = 0x6E;
static constexpr uint8_t AID_PA3     = 0x6B;
// PF1-PF24 AID codes per IBM GA23-0059 (3270 Data Stream Programming Reference)
// Note: PF10-12 are 0x7A-7C (NOT 0xFA-FC); PF22-24 are 0x4A-4C (NOT 0xCA-CC).
static constexpr uint8_t AID_SYSREQ  = 0xF0;
static constexpr uint8_t AID_STRUCTURED_FIELD = 0x88;

// Map PF1-24 to AID codes (IBM standard lookup table)
inline uint8_t pfAID(int n) {
    static constexpr uint8_t kPFAid[24] = {
        0xF1, 0xF2, 0xF3, 0xF4, 0xF5, 0xF6, 0xF7, 0xF8, // PF1-8
        0xF9, 0x7A, 0x7B, 0x7C,                          // PF9-12
        0xC1, 0xC2, 0xC3, 0xC4, 0xC5, 0xC6, 0xC7, 0xC8, // PF13-20
        0xC9, 0x4A, 0x4B, 0x4C                           // PF21-24
    };
    if (n >= 1 && n <= 24) return kPFAid[n - 1];
    return AID_ENTER;
}

// ── KeyboardState ─────────────────────────────────────────────────────────────
class KeyboardState {
public:
    enum class LockReason {
        None,        // Keyboard unlocked
        Connecting,  // Session not yet established — waiting for TN3270 negotiation
        System,      // Locked after AID key — waiting for host unlock
        OErr,        // Operator error (typing in protected/numeric/full field)
    };

    using SendRecordCallback = std::function<bool(const std::vector<uint8_t>&)>;

    KeyboardState(ScreenBuffer& screen, EbcdicCodec& codec);

    void setSendCallback(SendRecordCallback cb) { sendCb_ = std::move(cb); }

    // ── Lock/unlock ───────────────────────────────────────────────────────────
    void lock(LockReason reason);
    void unlock();
    bool isLocked()     const { return lockReason_ != LockReason::None; }
    LockReason lockReason() const { return lockReason_; }

    bool isInsertMode() const { return insertMode_; }
    void toggleInsert()       { insertMode_ = !insertMode_; }

    // ── Key handlers (called by UI on keyDown) ────────────────────────────────
    // Returns false if the key was rejected (keyboard locked / protected field)
    bool handleChar(uint8_t asciiChar);   // printable character input
    bool handleEbcdicChar(uint8_t ebcdic); // raw EBCDIC input (used for pasting)
    bool handleTab(bool backward = false);
    bool handleEnter();
    bool handleClear();
    bool handlePF(int n);                 // PF1-24
    bool handlePA(int n);                 // PA1-3
    bool handleBackspace();
    bool handleDelete();
    bool handleHome();
    bool handleEraseEOF();
    bool handleEraseInput();
    bool handleNewLine();
    bool handleCursorUp();
    bool handleCursorDown();
    bool handleCursorLeft();
    bool handleCursorRight();
    bool handleReset();

private:
    void sendAID(uint8_t aidCode, bool includeModifiedFields);
    void sendPAKey(uint8_t aidCode);
    void moveCursorToFirstUnprotected();
    void advanceToNextField(bool forward);
    // Returns the field attribute governing cursorPos, or 0 if unformatted
    uint8_t currentFieldAttr() const;
    bool isCurrentFieldEditable() const;
    // Insert char at cursor position in current field (handles insert mode)
    bool insertCharAtCursor(uint8_t ebcdic);

    ScreenBuffer&       screen_;
    EbcdicCodec&        codec_;
    LockReason          lockReason_  { LockReason::Connecting };
    bool                insertMode_  { false };
    SendRecordCallback  sendCb_;
};

} // namespace x3270
