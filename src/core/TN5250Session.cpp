#include "TN5250Session.h"
#include <cstring>

namespace x3270 {

// ── Terminal type strings ─────────────────────────────────────────────────────
// IBM-3477-FC : 24×80 colour display — recognized by IBM i / AS400 Telnet server
// IBM-3180-2  : 27×132 colour display — recognized by IBM i; "IBM-3477-FC-2" is NOT valid
const char* TN5250Session::terminalTypeName() const {
    switch (model_) {
    case TerminalModel::Model5:
    case TerminalModel::LargeCustom:
        return "IBM-3180-2";   // 27×132 colour — valid IBM i terminal type
    default:
        return "IBM-3477-FC";  // 24×80 colour
    }
}

// ── Lifecycle ─────────────────────────────────────────────────────────────────
TN5250Session::TN5250Session()  = default;
TN5250Session::~TN5250Session() { disconnect(); }


bool TN5250Session::connect(const std::string& host, uint16_t port,
                            bool useTLS, bool verifyCert, const std::string& caBundle) {
    state_ = State::Connecting;

    std::string errMsg;
    if (!transport_.connect(host, port, useTLS, verifyCert, caBundle, errMsg)) {
        state_ = State::Disconnected;
        if (errorCb_) errorCb_(errMsg);
        return false;
    }
    state_ = State::NegotiatingTelnet;

    // Reset negotiation state
    willBinary_ = doBinary_ = willEOR_ = doEOR_ = doTermType_ = false;
    sentWillBinary_ = sentDoBinary_ = sentWillEOR_ = sentDoEOR_ =
    sentWillTermType_ = sentTerminalTypeIs_ = sentWillSGA_ = sentDoSGA_ =
    sentWillNewEnv_ = false;
    currentRecord_.clear();
    subnegBuf_.clear();

    // RFC 854 / RFC 2877: do NOT send proactive WILL/DO options.
    // pub400.com (and standard IBM i) drives the negotiation: it sends DO EOR,
    // DO BINARY, DO TERMINAL-TYPE, DO NEW-ENVIRON in sequence.  We respond to
    // each reactively.  Sending WILL EOR proactively and then skipping the WILL EOR
    // reply to the server's DO EOR causes the server to hang waiting for confirmation.
    // This matches the tn5250 reference library (telnetstr.c: sends nothing at connect).

    return true;
}

void TN5250Session::disconnect() {
    state_ = State::Disconnected;
    transport_.disconnect();
}

// ── Send path ─────────────────────────────────────────────────────────────────
bool TN5250Session::sendRecord(const std::vector<uint8_t>& record) {
    if (state_ != State::Connected) return false;
    return sendGdsRecord(record, GDS_OP_PUT_GET);
}

bool TN5250Session::sendGdsRecord(const std::vector<uint8_t>& payload, uint8_t opcode) {
    if (state_ != State::Connected) return false;

    // Build GDS wrapper — 10-byte header per tn5250 reference (telnetstr.c / record.h):
    //   [0-1] total length (big-endian)
    //   [2]   0x12  GDS record type
    //   [3]   0xA0  reserved
    //   [4-5] 0x00  flowtype (TN5250_RECORD_FLOW_DISPLAY = 0x00)
    //   [6]   0x04  variable header length
    //   [7]   0x00  flags (TN5250_RECORD_H_NONE)
    //   [8]   0x00  reserved
    //   [9]   opcode (GDS_OP_PUT_GET=0x03 for input records, GDS_OP_NO_OP=0x00 for query reply)
    uint16_t totalLen = static_cast<uint16_t>(GDS_HEADER_LENGTH + payload.size());
    std::vector<uint8_t> gds;
    gds.reserve(totalLen);
    gds.push_back(static_cast<uint8_t>(totalLen >> 8));
    gds.push_back(static_cast<uint8_t>(totalLen & 0xFF));
    gds.push_back(0x12); // GDS record type
    gds.push_back(0xA0); // reserved
    gds.push_back(0x00); // flowtype hi (TN5250_RECORD_FLOW_DISPLAY)
    gds.push_back(0x00); // flowtype lo
    gds.push_back(0x04); // variable header length
    gds.push_back(0x00); // flags (TN5250_RECORD_H_NONE)
    gds.push_back(0x00); // reserved
    gds.push_back(opcode); // GDS opcode
    gds.insert(gds.end(), payload.begin(), payload.end());

    auto escaped = escapeRecord(gds);
    if (trafficCb_) trafficCb_(true, escaped);
    return transport_.send(escaped);
}

bool TN5250Session::sendATTN() {
    if (!transport_.isConnected()) return false;
    sendRaw({ TN5250_IAC, TN5250_IP });
    return true;
}

// ── Read loop ─────────────────────────────────────────────────────────────────
void TN5250Session::readLoop() {
    uint8_t buf[4096];
    while (transport_.isConnected()) {
        int n = transport_.recv(buf, sizeof(buf));
        if (n <= 0) break;
        if (trafficCb_) trafficCb_(false, { buf, buf + n });
        for (int i = 0; i < n; ++i) {
            processByte(buf[i]);
        }
    }
    state_ = State::Disconnected;
    if (errorCb_) errorCb_("Connection closed");
}

// ── Telnet IAC finite state machine ──────────────────────────────────────────
void TN5250Session::processByte(uint8_t byte) {
    switch (telnetState_) {
    case TelnetState::Normal:
        if (byte == TN5250_IAC) {
            telnetState_ = TelnetState::IacSeen;
        } else {
            currentRecord_.push_back(byte);
            tryDispatchGdsRecord();
        }
        break;

    case TelnetState::IacSeen:
        switch (byte) {
        case TN5250_IAC:
            currentRecord_.push_back(0xFF);
            telnetState_ = TelnetState::Normal;
            break;
        case TN5250_EOR:
            if (!currentRecord_.empty()) {
                if (dataCb_) dataCb_(currentRecord_);
                currentRecord_.clear();
            }
            telnetState_ = TelnetState::Normal;
            break;
        case TN5250_GA:
            // Go-Ahead: if SGA was NOT negotiated, treat as record terminator.
            // If SGA IS active, this should not arrive; ignore it safely.
            if (!currentRecord_.empty()) {
                tryDispatchGdsRecord();  // try length-based first
                if (!currentRecord_.empty()) {
                    if (dataCb_) dataCb_(currentRecord_);
                    currentRecord_.clear();
                }
            }
            telnetState_ = TelnetState::Normal;
            break;
        case TN5250_WILL: telnetState_ = TelnetState::Will; break;
        case TN5250_WONT: telnetState_ = TelnetState::Wont; break;
        case TN5250_DO:   telnetState_ = TelnetState::Do;   break;
        case TN5250_DONT: telnetState_ = TelnetState::Dont; break;
        case TN5250_SB:
            subnegBuf_.clear();
            telnetState_ = TelnetState::Sb;
            break;
        case TN5250_NOP:
            telnetState_ = TelnetState::Normal;
            break;
        default:
            telnetState_ = TelnetState::Normal;
            break;
        }
        break;

    case TelnetState::Will:
        processIacCommand(TN5250_WILL, byte);
        telnetState_ = TelnetState::Normal;
        break;
    case TelnetState::Wont:
        processIacCommand(TN5250_WONT, byte);
        telnetState_ = TelnetState::Normal;
        break;
    case TelnetState::Do:
        processIacCommand(TN5250_DO, byte);
        telnetState_ = TelnetState::Normal;
        break;
    case TelnetState::Dont:
        processIacCommand(TN5250_DONT, byte);
        telnetState_ = TelnetState::Normal;
        break;

    case TelnetState::Sb:
        if (byte == TN5250_IAC) {
            telnetState_ = TelnetState::SbIac;
        } else {
            subnegBuf_.push_back(byte);
        }
        break;
    case TelnetState::SbIac:
        if (byte == TN5250_SE) {
            processSubneg(subnegBuf_);
            subnegBuf_.clear();
            telnetState_ = TelnetState::Normal;
        } else if (byte == TN5250_IAC) {
            subnegBuf_.push_back(TN5250_IAC);
            telnetState_ = TelnetState::Sb;
        } else {
            telnetState_ = TelnetState::Sb;
        }
        break;
    }
}

// ── IAC option commands ───────────────────────────────────────────────────────
void TN5250Session::processIacCommand(uint8_t cmd, uint8_t opt) {
    // Purely reactive negotiation matching the tn5250 reference library:
    //   DO X   → WILL X  (for supported options)
    //   DO X   → WONT X  (for unsupported)
    //   WILL X → DO X    (for supported options)
    //   WILL X → DONT X  (for unsupported)
    //   DONT/WONT: acknowledge by clearing flag, no reply
    // No deduplication — always reply, even if we replied before.
    // (Reference comment: "We should really keep track of states here, but the
    //  code has been like this for some time, and no complaints.")

    switch (opt) {
    case TN5250_OPT_BINARY:
        if (cmd == TN5250_DO) {
            doBinary_ = true;
            sentWillBinary_ = true;
            sendWill(TN5250_OPT_BINARY);
        } else if (cmd == TN5250_WILL) {
            willBinary_ = true;
            sentDoBinary_ = true;
            sendDo(TN5250_OPT_BINARY);
        } else if (cmd == TN5250_DONT) { doBinary_   = false; }
        else if  (cmd == TN5250_WONT)  { willBinary_ = false; }
        break;

    case TN5250_OPT_EOR:
        if (cmd == TN5250_DO) {
            // Server requests EOR framing from us — confirm with WILL EOR.
            // This is the key step pub400.com waits for before sending 5250 data.
            doEOR_ = true;
            sentWillEOR_ = true;
            sendWill(TN5250_OPT_EOR);
        } else if (cmd == TN5250_WILL) {
            willEOR_ = true;
            sentDoEOR_ = true;
            sendDo(TN5250_OPT_EOR);
        } else if (cmd == TN5250_DONT) { doEOR_  = false; }
        else if  (cmd == TN5250_WONT)  { willEOR_ = false; }
        break;

    case TN5250_OPT_TERMINAL_TYPE:
        if (cmd == TN5250_DO) {
            doTermType_ = true;
            sentWillTermType_ = true;
            sendWill(TN5250_OPT_TERMINAL_TYPE);
        }
        break;

    case TN5250_OPT_SGA:
        // RFC 858: Suppress Go-Ahead — agree on both sides for full-duplex.
        if (cmd == TN5250_DO)   { sentWillSGA_ = true; sendWill(TN5250_OPT_SGA); }
        if (cmd == TN5250_WILL) { sentDoSGA_   = true; sendDo  (TN5250_OPT_SGA); }
        break;

    case TN5250_OPT_NEW_ENVIRON:
        // IBM i uses NEW-ENVIRON to request the 5250 workstation/device name.
        if (cmd == TN5250_DO) { sentWillNewEnv_ = true; sendWill(TN5250_OPT_NEW_ENVIRON); }
        break;

    default:
        // Refuse any unsupported option
        if (cmd == TN5250_DO)   sendWont(opt);
        if (cmd == TN5250_WILL) sendDont(opt);
        break;
    }

    tryEnterDataMode();
}

// ── Sub-negotiation ───────────────────────────────────────────────────────────
void TN5250Session::processSubneg(const std::vector<uint8_t>& sb) {
    if (sb.size() < 2) return;

    if (sb[0] == TN5250_OPT_TERMINAL_TYPE && sb[1] == 0x01 /* SEND */) {
        doTermType_ = true;
        sendTerminalType();
        tryEnterDataMode();
        return;
    }

    // RFC 1572 / RFC 2877: IBM i sends SB NEW-ENVIRON SEND to request device name.
    // SEND = 0x01; may be followed by a list of variable names (we ignore them
    // and always respond with DEVNAME).
    if (sb[0] == TN5250_OPT_NEW_ENVIRON && sb[1] == 0x01 /* SEND */) {
        sendNewEnvironIs();
    }
}

void TN5250Session::sendNewEnvironIs() {
    // RFC 1572 NEW-ENVIRON IS response carrying the 5250 workstation device name.
    // Format: IAC SB NEW-ENVIRON IS  USERVAR "DEVNAME" VALUE "X3270001"  IAC SE
    //   IS      = 0x00
    //   USERVAR = 0x03  (IBM-specific variables are USERVARs per RFC 1572)
    //   VALUE   = 0x01
    static const uint8_t IS      = 0x00;
    static const uint8_t USERVAR = 0x03;
    static const uint8_t VALUE   = 0x01;
    static const char kVarName[] = "DEVNAME";
    static const char kDevName[] = "X3270001"; // valid IBM i 8-char workstation name

    std::vector<uint8_t> payload;
    payload.push_back(TN5250_OPT_NEW_ENVIRON);
    payload.push_back(IS);
    payload.push_back(USERVAR);
    for (const char* p = kVarName; *p; ++p) payload.push_back(static_cast<uint8_t>(*p));
    payload.push_back(VALUE);
    for (const char* p = kDevName; *p; ++p) payload.push_back(static_cast<uint8_t>(*p));

    sendSb(payload);
}

void TN5250Session::sendTerminalType() {
    const char* term = terminalTypeName();
    std::vector<uint8_t> payload = { TN5250_OPT_TERMINAL_TYPE, 0x00 /* IS */ };
    for (const char* p = term; *p; ++p)
        payload.push_back(static_cast<uint8_t>(*p));
    sendSb(payload);
    sentTerminalTypeIs_ = true;   // gate: some servers never send DO BINARY/EOR explicitly
}

void TN5250Session::tryEnterDataMode() {
    if (state_ == State::Connected) return;

    // Path 1 (standard IBM i flow):
    //   EOR negotiated in either direction (server sent DO EOR → we replied WILL EOR,
    //   OR server sent WILL EOR → we replied DO EOR) AND terminal type IS was sent.
    //   This is the trigger used by the tn5250 reference library.
    if (sentTerminalTypeIs_ && (willEOR_ || doEOR_)) {
        enterDataMode();
        return;
    }

    // Path 2 (fallback for non-standard servers that skip EOR/BINARY negotiation):
    //   Terminal type IS sent, and no EOR or BINARY option has been offered by
    //   either side.  Enter data mode to avoid blocking forever.
    if (sentTerminalTypeIs_ && !willEOR_ && !doEOR_ && !willBinary_ && !doBinary_) {
        enterDataMode();
    }
}

void TN5250Session::enterDataMode() {
    if (state_ == State::Connected) return;
    state_ = State::Connected;
    if (connectedCb_) connectedCb_();
}

// ── GDS length-based record dispatch ─────────────────────────────────────────
// Some IBM i Telnet servers never negotiate IAC EOR and instead frame 5250
// records using the 2-byte length field in the GDS header.  This method
// dispatches any complete GDS records that have accumulated in currentRecord_,
// so that the data callback fires even without an IAC EOR terminator.
// When EOR *is* negotiated the EOR handler drains the buffer first; this
// becomes a safe no-op (currentRecord_ is empty when IAC EOR fires).
void TN5250Session::tryDispatchGdsRecord() {
    while (currentRecord_.size() >= GDS_HEADER_LENGTH) {
        // Accept both 0x00 (our initial assumption) and 0xA0 (real IBM i) for byte 3
        uint8_t b2 = currentRecord_[2];
        uint8_t b3 = currentRecord_[3];
        if (b2 != GDS_RECORD_TYPE || (b3 != 0x00 && b3 != 0xA0))
            break;
        uint16_t recLen = (static_cast<uint16_t>(currentRecord_[0]) << 8)
                        |  static_cast<uint16_t>(currentRecord_[1]);
        if (recLen < GDS_HEADER_LENGTH || currentRecord_.size() < recLen)
            break;
        std::vector<uint8_t> record(currentRecord_.begin(),
                                    currentRecord_.begin() + recLen);
        currentRecord_.erase(currentRecord_.begin(),
                             currentRecord_.begin() + recLen);
        if (dataCb_) dataCb_(record);
    }
}

// ── Wire helpers ──────────────────────────────────────────────────────────────
void TN5250Session::sendWill(uint8_t opt) { sendRaw({ TN5250_IAC, TN5250_WILL, opt }); }
void TN5250Session::sendWont(uint8_t opt) { sendRaw({ TN5250_IAC, TN5250_WONT, opt }); }
void TN5250Session::sendDo  (uint8_t opt) { sendRaw({ TN5250_IAC, TN5250_DO,   opt }); }
void TN5250Session::sendDont(uint8_t opt) { sendRaw({ TN5250_IAC, TN5250_DONT, opt }); }

void TN5250Session::sendSb(const std::vector<uint8_t>& payload) {
    std::vector<uint8_t> msg;
    msg.reserve(payload.size() + 4);
    msg.push_back(TN5250_IAC);
    msg.push_back(TN5250_SB);
    for (uint8_t b : payload) {
        if (b == TN5250_IAC) msg.push_back(TN5250_IAC);
        msg.push_back(b);
    }
    msg.push_back(TN5250_IAC);
    msg.push_back(TN5250_SE);
    sendRaw(msg);
}

void TN5250Session::sendRaw(const std::vector<uint8_t>& data) {
    if (trafficCb_) trafficCb_(true, data);
    transport_.send(data);
}

std::vector<uint8_t> TN5250Session::escapeRecord(const std::vector<uint8_t>& raw) {
    std::vector<uint8_t> out;
    out.reserve(raw.size() + 4);
    for (uint8_t b : raw) {
        out.push_back(b);
        if (b == TN5250_IAC) out.push_back(TN5250_IAC);
    }
    out.push_back(TN5250_IAC);
    out.push_back(TN5250_EOR);
    return out;
}

} // namespace x3270
