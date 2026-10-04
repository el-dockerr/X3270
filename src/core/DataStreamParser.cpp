#include "DataStreamParser.h"
#include <cstring>

namespace x3270 {

DataStreamParser::DataStreamParser(ScreenBuffer& screen, EbcdicCodec& codec)
    : screen_(screen), codec_(codec) {}

// ── Main entry point ──────────────────────────────────────────────────────────
void DataStreamParser::processRecord(const std::vector<uint8_t>& record) {
    if (record.empty()) return;

    // WSF records are handled separately (need full record to parse SFs)
    if (record[0] == CMD_WRITE_STRUCTURED_FIELD ||
        record[0] == CMD_WRITE_STRUCTURED_FIELD_SNA) {
        handleWSF(record);
        return;
    }

    // Reset FSM for each new record
    state_ = ParseState::Command;

    for (uint8_t b : record) {
        if (state_ == ParseState::SkipRecord) break;  // discard rest of WSF/unknown record
        switch (state_) {
        case ParseState::Command:
            handleCommand(b);
            break;
        case ParseState::WCC:
            handleWCC(b);
            break;
        case ParseState::Data:
            handleDataByte(b);
            break;
        case ParseState::SF_Attr:
            screen_.startField(b);
            state_ = ParseState::Data;
            break;
        case ParseState::SBA_Byte1:
            sbaByte1_ = b;
            state_ = ParseState::SBA_Byte2;
            break;
        case ParseState::SBA_Byte2:
            screen_.setBufferAddress(ScreenBuffer::decodeAddress(sbaByte1_, b));
            state_ = ParseState::Data;
            break;
        case ParseState::RA_Addr1:
            raAddr1_ = b;
            state_ = ParseState::RA_Addr2;
            break;
        case ParseState::RA_Addr2:
            sbaByte1_ = b; // reuse to store addr2
            state_ = ParseState::RA_Char;
            break;
        case ParseState::RA_Char:
            screen_.repeatToAddress(ScreenBuffer::decodeAddress(raAddr1_, sbaByte1_), b);
            state_ = ParseState::Data;
            break;
        case ParseState::EUA_Addr1:
            euaAddr1_ = b;
            state_ = ParseState::EUA_Addr2;
            break;
        case ParseState::EUA_Addr2:
            screen_.eraseUnprotectedToAddress(ScreenBuffer::decodeAddress(euaAddr1_, b));
            state_ = ParseState::Data;
            break;
        case ParseState::SFE_Count:
            sfeCount_    = b;
            sfeCurAttr_  = 0x00;
            sfeFgColor_  = 0x00;
            sfeBgColor_  = 0x00;
            sfeHighlight_= 0x00;
            if (sfeCount_ == 0) {
                screen_.startField(0x00);
                state_ = ParseState::Data;
            } else {
                state_ = ParseState::SFE_Type;
            }
            break;
        case ParseState::SFE_Type:
            sfeType_ = b;
            state_ = ParseState::SFE_Value;
            break;
        case ParseState::SFE_Value:
            // Attribute type dispatch:
            //   0xC0 = basic field attribute (FA byte)
            //   0x41 = extended highlighting (0xF1=blink, 0xF2=reverse, 0xF4=underscore)
            //   0x42 = foreground colour (0xF1-0xF7 IBM 3279 palette)
            //   0x45 = background colour
            if      (sfeType_ == 0xC0) sfeCurAttr_   = b;
            else if (sfeType_ == 0x41) sfeHighlight_  = b;
            else if (sfeType_ == 0x42) sfeFgColor_    = b;
            else if (sfeType_ == 0x45) sfeBgColor_    = b;
            --sfeCount_;
            if (sfeCount_ == 0) {
                screen_.startField(sfeCurAttr_, sfeFgColor_, sfeBgColor_, sfeHighlight_);
                state_ = ParseState::Data;
            } else {
                state_ = ParseState::SFE_Type;
            }
            break;
        case ParseState::SA_Type:
            sfeType_ = b;
            state_ = ParseState::SA_Value;
            break;
        case ParseState::SA_Value:
            // SA (Set Attribute) applies to subsequent characters until field boundary.
            // Type codes match SFE: 0x42=fg colour, 0x45=bg colour, 0x41=highlight.
            // A value of 0x00 resets that attribute to the field default.
            if      (sfeType_ == 0x42) screen_.setCurrentFgColor(b);
            else if (sfeType_ == 0x45) screen_.setCurrentBgColor(b);
            else if (sfeType_ == 0x41) screen_.setCurrentHighlight(b);
            state_ = ParseState::Data;
            break;
        case ParseState::MF_Count:
            mfCount_ = b;
            if (mfCount_ == 0) state_ = ParseState::Data;
            else                state_ = ParseState::MF_Type;
            break;
        case ParseState::MF_Type:
            mfType_ = b;
            state_ = ParseState::MF_Value;
            break;
        case ParseState::MF_Value:
            // Phase 1: ignore MF (used to change attrs without rewriting field)
            --mfCount_;
            state_ = (mfCount_ > 0) ? ParseState::MF_Type : ParseState::Data;
            break;
        case ParseState::GE_Char:
            // Graphic Escape: display character from alternate code page
            // Phase 1: treat as normal EBCDIC character
            screen_.writeChar(b);
            state_ = ParseState::Data;
            break;
        case ParseState::SkipRecord:
            break; // unreachable — caught by early-exit before the switch
        }
    }
}

// ── Command dispatch ──────────────────────────────────────────────────────────
void DataStreamParser::handleCommand(uint8_t cmd) {
    // Reset extended attributes at the beginning of each host command (IBM 3270 Specification)
    screen_.setCurrentFgColor(0x00);
    screen_.setCurrentBgColor(0x00);
    screen_.setCurrentHighlight(0x00);

    switch (cmd) {
    case CMD_WRITE:
    case CMD_WRITE_SNA:
        doWrite(false, false);
        break;
    case CMD_ERASE_WRITE:
    case CMD_ERASE_WRITE_SNA:
        doWrite(true, false);
        break;
    case CMD_ERASE_WRITE_ALT:
    case CMD_ERASE_WRITE_ALT_SNA:
        doWrite(true, true);  // alternate size (Phase 1: same as default)
        break;
    case CMD_ERASE_ALL_UNPROTECTED:
    case CMD_ERASE_ALL_UNPROTECTED_SNA:
        screen_.eraseAllUnprotected();
        state_ = ParseState::Command; // no further data
        break;
    case CMD_READ_MODIFIED:
    case CMD_READ_MODIFIED_SNA:
        // Host-solicited Read Modified: unprotected MDT fields only.
        if (sendCb_) {
            auto data = screen_.buildReadModifiedRecord(0x60 /*no-AID*/);
            sendCb_(data);
        }
        state_ = ParseState::Command;
        break;
    case CMD_READ_MODIFIED_ALL:
    case CMD_READ_MODIFIED_ALL_SNA:
        // Host-solicited Read Modified All: ALL MDT fields including protected.
        if (sendCb_) {
            auto data = screen_.buildReadModifiedRecord(0x60 /*no-AID*/, true);
            sendCb_(data);
        }
        state_ = ParseState::Command;
        break;
    case CMD_WRITE_STRUCTURED_FIELD:
    case CMD_WRITE_STRUCTURED_FIELD_SNA:
        // Handled in processRecord before the FSM — should not reach here
        state_ = ParseState::SkipRecord;
        break;
    default:
        // Unknown command — skip to Data state
        state_ = ParseState::Data;
        break;
    }
}

void DataStreamParser::doWrite(bool eraseFirst, bool alternate) {
    if (eraseFirst) {
        screen_.setAlternateMode(alternate);  // Dynamically switch between 24x80 and the extended size
    }
    state_ = ParseState::WCC;
}

// ── Write Control Character ───────────────────────────────────────────────────
void DataStreamParser::handleWCC(uint8_t wcc) {
    if (wcc & WCC_RESET_MDT) screen_.resetAllMDT();
    if (wcc & WCC_ALARM)     { if (alarmCb_) alarmCb_(); }
    if (wcc & WCC_UNLOCK)    { if (unlockCb_) unlockCb_(); }
    state_ = ParseState::Data;
}

// ── Data / Order byte dispatch ────────────────────────────────────────────────
void DataStreamParser::handleDataByte(uint8_t b) {
    // Check if this byte is an order code
    switch (b) {
    case ORD_SF:   state_ = ParseState::SF_Attr;  break;
    case ORD_SFE:  state_ = ParseState::SFE_Count; break;
    case ORD_SBA:  state_ = ParseState::SBA_Byte1; break;
    case ORD_SA:   state_ = ParseState::SA_Type;   break;
    case ORD_IC:   screen_.insertCursorHere();     break; // IC: no params
    case ORD_PT:
        // Program Tab: advance bufPtr to next unprotected field
        // Phase 1 simplified: advance one cell at a time until FA that is not protected
        {
            const int sz = screen_.size();
            int pos = screen_.bufferPointer();
            for (int i = 0; i < sz; ++i) {
                pos = (pos + 1) % sz;
                if (screen_.at(pos).isFA && !screen_.at(pos).isProtected()) {
                    screen_.setBufferAddress((pos + 1) % sz);
                    break;
                }
            }
        }
        break;
    case ORD_RA:   state_ = ParseState::RA_Addr1;  break;
    case ORD_EUA:  state_ = ParseState::EUA_Addr1; break;
    case ORD_GE:   state_ = ParseState::GE_Char;   break;
    case ORD_MF:   state_ = ParseState::MF_Count;  break;
    default:
        // Plain data byte — write to buffer
        screen_.writeChar(b);
        break;
    }
}

// ── setGraphicsBuffer ─────────────────────────────────────────────────────────
void DataStreamParser::setGraphicsBuffer(GraphicsBuffer& buf) {
    graphics_   = &buf;
    gocaParser_ = std::make_unique<GocaParser>(buf, codec_);
}

// ── Write Structured Field ────────────────────────────────────────────────────
// Parse each SF in the record.  Respond to Read Partition Query with a minimal
// Query Reply so ISPF/GDDM can identify the terminal and paint its screens.
//
// GOCA-bearing SF types (confirmed by traffic captures; update as needed):
//   0x01 — Read Partition (Query / QueryList)
//   0x0D — Begin/End of Graphics — signals a GOCA frame boundary
//   0x0E — Write Graphics Object (GOCA) — payload is a GOCA order stream
//   0x0F — Erase Graphics — discard the current graphics frame
//
// NOTE: The exact SF type bytes for GOCA records are implementation-defined by
// the host application (typically GDDM on VM/CMS).  The values above match the
// common GDDM-generated structured fields observed in typical TN3270E captures.
// Verify against Debug Window captures and adjust if the host uses different codes.
void DataStreamParser::handleWSF(const std::vector<uint8_t>& record) {
    bool graphicsUpdated = false;

    size_t i = 1; // skip WSF command byte
    while (i + 2 < record.size()) {
        // Each SF: [length_hi][length_lo][type][data...]
        // Length field includes itself (min 3 bytes).
        uint16_t sfLen = (static_cast<uint16_t>(record[i]) << 8) | record[i + 1];
        if (sfLen < 3 || i + sfLen > record.size()) break;

        uint8_t sfType = record[i + 2];

        // Pointer to the SF data payload (after the 3-byte header).
        const uint8_t* payload     = record.data() + i + 3;
        size_t         payloadSize = (sfLen >= 3) ? (sfLen - 3) : 0;

        switch (sfType) {

        case 0x01:
            // ── Read Partition (Query / QueryList) ────────────────────────────
            if (sfLen >= 5) {
                uint8_t queryType = record[i + 4]; // [partition_id][query_type]
                if ((queryType == 0x02 || queryType == 0x03) && sendCb_) {
                    sendCb_(buildQueryReply());
                }
            }
            break;

        case 0x0D:
            // ── Begin/End of Graphics ─────────────────────────────────────────
            // Signals the start of a new GOCA frame.  Reset parser state so
            // stale drawing commands from a previous frame are not re-applied.
            //if (graphics_ && gocaParser_) {
            //    graphics_->clear();
            //    gocaParser_->reset();
            //}
            // ── Read Partition (Query / QueryList) ────────────────────────────
            if (sendCb_) {
                sendCb_(buildQueryReply());
            }
            break;

        case 0x0E:
            // ── Write Graphics Object (GOCA order stream) ─────────────────────
            if (graphics_ && gocaParser_ && payloadSize > 0) {
                gocaParser_->parseOrders(payload, payloadSize);
                graphicsUpdated = true;
            }
            break;

        case 0x0F:
            // ── Erase Graphics ────────────────────────────────────────────────
            if (graphics_ && gocaParser_) {
                graphics_->clear();
                gocaParser_->reset();
                graphicsUpdated = true;
            }
            break;

        default:
            // Unknown SF type — safely skip using sfLen.
            break;
        }

        i += sfLen;
    }

    if (graphicsUpdated && graphics_) {
        graphics_->markDirty();          // fires the update callback wired in Phase 6
        if (graphicsUpdateCb_) graphicsUpdateCb_();
    }
}

// ── Query Reply builder ───────────────────────────────────────────────────────
// Returns a Query Reply record with Usable Area dimensions taken from the
// attached ScreenBuffer so the host sees the correct model dimensions.
std::vector<uint8_t> DataStreamParser::buildQueryReply() const {
    std::vector<uint8_t> r;

    const int rows = screen_.rows();
    const int cols = screen_.cols();
    const int sz   = screen_.size();

    // AID byte: Query Reply (0x88)
    r.push_back(0x88);

    // ── Query Reply (Summary) — SF ID: 0x81, QR Type: 0x81 ──────────────────
    // Lunghezza 10 byte: 2 (len) + 1 (SF ID) + 1 (QR Type) + 6 codici dichiarati
    r.push_back(0x00); r.push_back(0x0A); // Length = 10
    r.push_back(0x81);                    // SF ID: Query Reply
    r.push_back(0x81);                    // QR Type: Summary
    r.push_back(0x80);                    // Usable Area
    r.push_back(0x81);                    // Summary
    r.push_back(0x84);                    // Data Streams (GOCA)
    r.push_back(0x86);                    // Color
    r.push_back(0x87);                    // Highlighting
    r.push_back(0xA6);                    // Implicit Partition (Necessario per ISPF ADDPOP!)

    // ── Query Reply (Usable Area) — SF ID: 0x81, QR Type: 0x80 ──────────────
    r.push_back(0x00); r.push_back(0x13); // Length = 19
    r.push_back(0x81);                    // SF ID: Query Reply
    r.push_back(0x80);                    // QR Type: Usable Area
    r.push_back(0x03);                    // Addressing flags: 12-bit & 14-bit
    r.push_back(0x00);                    // Flags (reserved)
    r.push_back(static_cast<uint8_t>(cols >> 8));
    r.push_back(static_cast<uint8_t>(cols & 0xFF));                 // Usable cols (80)
    r.push_back(static_cast<uint8_t>(rows >> 8));
    r.push_back(static_cast<uint8_t>(rows & 0xFF));                 // Usable rows (43)
    r.push_back(0x01);                                               // Units: mm
    r.push_back(0x00); r.push_back(0x60);                           // Xr = 96 units/mm
    r.push_back(0x00); r.push_back(0x70);                           // Yr = 112 units/mm
    r.push_back(0x09);                                               // AW = 9 (cell width)
    r.push_back(0x0C);                                               // AH = 12 (cell height)
    r.push_back(static_cast<uint8_t>(sz >> 8));
    r.push_back(static_cast<uint8_t>(sz & 0xFF));                   // Buffer size

    // ── Query Reply (Color) — SF ID: 0x81, QR Type: 0x86 ─────────────────────
    r.push_back(0x00); r.push_back(0x16); // Length = 22
    r.push_back(0x81);                    // SF ID: Query Reply
    r.push_back(0x86);                    // QR Type: Color
    r.push_back(0x00);                    // Flags
    r.push_back(0x08);                    // Np = 8 color pairs
    r.push_back(0x00); r.push_back(0xF4); // Default fg → Green
    r.push_back(0xF1); r.push_back(0xF1); // Blue
    r.push_back(0xF2); r.push_back(0xF2); // Red
    r.push_back(0xF3); r.push_back(0xF3); // Pink
    r.push_back(0xF4); r.push_back(0xF4); // Green
    r.push_back(0xF5); r.push_back(0xF5); // Turquoise
    r.push_back(0xF6); r.push_back(0xF6); // Yellow
    r.push_back(0xF7); r.push_back(0xF7); // White

    // ── Query Reply (Highlighting) — SF ID: 0x81, QR Type: 0x87 ──────────────
    r.push_back(0x00); r.push_back(0x0F); // Length = 15
    r.push_back(0x81);                    // SF ID: Query Reply
    r.push_back(0x87);                    // QR Type: Highlighting
    r.push_back(0x05);                    // Np = 5 highlight pairs
    r.push_back(0x00); r.push_back(0x00); // Default
    r.push_back(0xF1); r.push_back(0xF1); // Blink
    r.push_back(0xF2); r.push_back(0xF2); // Reverse
    r.push_back(0xF4); r.push_back(0xF4); // Underscore
    r.push_back(0xF8); r.push_back(0xF8); // Intensify

    // ── Query Reply (Data Streams) — SF ID: 0x81, QR Type: 0x84 ──────────────
    r.push_back(0x00); r.push_back(0x07); // Length = 7
    r.push_back(0x81);                    // SF ID: Query Reply
    r.push_back(0x84);                    // QR Type: Data Streams
    r.push_back(0x00);                    // Flags
    r.push_back(0x01);                    // Np = 1
    r.push_back(0x02);                    // GOCA

    // ── Query Reply (Implicit Partition) — SF ID: 0x81, QR Type: 0xA6 ────────
    r.push_back(0x00); r.push_back(0x0D); // Length = 13
    r.push_back(0x81);                    // SF ID: Query Reply
    r.push_back(0xA6);                    // QR Type: Implicit Partition
    r.push_back(0x00);                    // Flags
    r.push_back(0x00);                    // Reserved
    r.push_back(0x00); r.push_back(0x50); // Primary Width (80)
    r.push_back(0x00); r.push_back(0x18); // Primary Height (24)
    r.push_back(static_cast<uint8_t>(cols >> 8));
    r.push_back(static_cast<uint8_t>(cols & 0xFF)); // Alternate Width (80)
    r.push_back(static_cast<uint8_t>(rows >> 8));
    r.push_back(static_cast<uint8_t>(rows & 0xFF)); // Alternate Height (43)

    return r;
}

} // namespace x3270
