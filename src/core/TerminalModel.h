#pragma once
#include <cstdint>

namespace x3270 {

// ── IBM 3270 terminal models ──────────────────────────────────────────────────
// Each model defines the character grid dimensions reported to the host via
// TN3270E DEVICE-TYPE negotiation and the Usable Area Query Reply.
enum class TerminalModel {
    Model2,      // IBM 3278-2:   24 ×  80  (default; most common)
    Model3,      // IBM 3278-3:   32 ×  80
    Model4,      // IBM 3278-4:   43 ×  80
    Model5,      // IBM 3278-5:   27 × 132  (wide)
    LargeCustom, // Non-standard: 62 × 160  (requires 14-bit addressing)
};

inline int rowsForModel(TerminalModel m) {
    switch (m) {
    case TerminalModel::Model3:      return 32;
    case TerminalModel::Model4:      return 43;
    case TerminalModel::Model5:      return 27;
    case TerminalModel::LargeCustom: return 62;
    default:                         return 24; // Model2
    }
}

inline int colsForModel(TerminalModel m) {
    switch (m) {
    case TerminalModel::Model5:      return 132;
    case TerminalModel::LargeCustom: return 160;
    default:                         return 80; // Model2/3/4
    }
}

// IBM TN3270E DEVICE-TYPE string for each model.
// LargeCustom advertises as Model 5 for TN3270E negotiation and relies on the
// Usable Area Query Reply to communicate its actual non-standard dimensions.
inline const char* modelTypeName(TerminalModel m) {
    switch (m) {
    case TerminalModel::Model3:      return "IBM-3278-3-E";
    case TerminalModel::Model4:      return "IBM-3279-4-E"; //"IBM-3278-4-E";
    case TerminalModel::Model5:      return "IBM-3278-5-E";
    case TerminalModel::LargeCustom: return "IBM-3278-5-E";
    default:                         return "IBM-3278-2-E";
    }
}

} // namespace x3270
