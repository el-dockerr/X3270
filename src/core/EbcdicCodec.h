#pragma once
#include <cstdint>
#include <string>
#include <vector>

namespace x3270 {

enum class CodePage {
    CP037,   // US/Canada/Australia — most common z/OS
    CP500,   // International (ISO)
    CP1047,  // Open Systems / MVS C compiler
};

class EbcdicCodec {
public:
    explicit EbcdicCodec(CodePage cp = CodePage::CP037);

    /// EBCDIC byte → Unicode code point (BMP only, returned as uint16_t)
    uint16_t toUnicode(uint8_t ebcdic) const;

    /// ASCII/Latin-1 byte → EBCDIC byte (best-effort; unmapped chars → 0x3F '?')
    uint8_t fromAscii(uint8_t ascii) const;

    /// Convenience: convert a buffer of EBCDIC bytes to a UTF-8 std::string
    std::string ebcdicToUtf8(const uint8_t* data, size_t len) const;

    /// Convenience: convert a UTF-8 string to EBCDIC bytes
    std::vector<uint8_t> utf8ToEbcdic(const std::string& utf8) const;

    void setCodePage(CodePage cp);
    CodePage codePage() const { return cp_; }

    /// Hercules / CP1047-host compatibility. When enabled:
    ///   * Inbound (toUnicode):  0xAD or 0x4A → '[' ; 0xBD or 0x5A → ']'
    ///   * Outbound (fromAscii): '[' → 0xAD ; ']' → 0xBD
    /// This matches the bracket positions used by CP1047, the host code page on
    /// Hercules-MVS-TK5 and most modern z/OS systems. Note: ISPF EDIT may still
    /// blank out brackets in its data row because they fall outside ISPF's
    /// "displayable character set"; HEX ON or BROWSE confirms the bytes are
    /// stored correctly.
    void setHerculesBrackets(bool enabled);
    bool herculesBrackets() const { return herculesBrackets_; }

    // Special EBCDIC values (code-page independent)
    static constexpr uint8_t EBCDIC_NUL   = 0x00;
    static constexpr uint8_t EBCDIC_SPACE = 0x40;
    static constexpr uint8_t EBCDIC_DUP   = 0x1C;
    static constexpr uint8_t EBCDIC_FM    = 0x1E;
    static constexpr uint8_t EBCDIC_SO    = 0x0E;
    static constexpr uint8_t EBCDIC_SI    = 0x0F;

private:
    CodePage cp_;
    bool     herculesBrackets_ { false };
    const uint16_t* toUnicodeTable_   { nullptr }; // [256]
    const uint8_t*  fromAsciiTable_   { nullptr }; // [128]

    void selectTables();
};

} // namespace x3270
