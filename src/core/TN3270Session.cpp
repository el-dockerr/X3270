#include "TN3270Session.h"
#include <cstring>
#include <stdexcept>

namespace x3270 {

TN3270Session::TN3270Session() = default;
TN3270Session::~TN3270Session() { disconnect(); }

// ── Public interface ──────────────────────────────────────────────────────────
bool TN3270Session::connect(const std::string& host, uint16_t port,
                            bool useTLS, bool verifyCert, const std::string& caBundle) {
    std::string errMsg;
    if (!transport_.connect(host, port, useTLS, verifyCert, caBundle, errMsg)) {
        state_ = State::Disconnected;
        if (errorCb_) errorCb_(errMsg);
        return false;
    }
    state_ = State::NegotiatingTelnet;

    // Reset all negotiation state for this (re)connection
    willBinary_ = doBinary_ = willEOR_ = doEOR_ = false;
    willTermType_ = doTermType_ = tn3270eMode_ = tn3270eOffered_ = false;
    sentWillBinary_ = sentDoBinary_ = sentWillEOR_ = sentDoEOR_ = sentWillTermType_ = false;
    sentWillTN3270E_ = sentDoTN3270E_ = false;

    // RFC 2355: offer TN3270E (both directions simultaneously) and hint at
    // terminal-type capability.  We deliberately do NOT proactively offer
    // BINARY or EOR here: servers like z/VM interpret a proactive WILL BINARY
    // as a request for NVT-binary mode and immediately respond DONT BINARY,
    // permanently locking the session into NVT before the terminal type is
    // even known.  BINARY/EOR are negotiated reactively once the server has
    // seen our terminal type and decides to enable 3270 block mode.
    sendWill(OPT_TN3270E);        sentWillTN3270E_ = true;
    sendDo(OPT_TN3270E);          sentDoTN3270E_   = true;
    sendWill(OPT_TERMINAL_TYPE);  sentWillTermType_ = true;

    return true;
}

void TN3270Session::disconnect() {
    state_ = State::Disconnected;
    transport_.disconnect();
}

bool TN3270Session::send3270Record(const std::vector<uint8_t>& record) {
    if (state_ != State::Connected) return false;

    std::vector<uint8_t> payload;
    if (tn3270eMode_) {
        // TN3270E: prepend 5-byte header [data-type, request, response, seq_hi, seq_lo]
        uint16_t seq = sendSeqNum_++;
        payload = { DT_3270_DATA, 0x00, 0x00,
                    static_cast<uint8_t>(seq >> 8),
                    static_cast<uint8_t>(seq & 0xFF) };
        payload.insert(payload.end(), record.begin(), record.end());
    } else {
        payload = record;
    }
    auto escaped = escapeRecord(payload);
    if (trafficCb_) trafficCb_(true, escaped);
    return transport_.send(escaped);
}

bool TN3270Session::sendATTN() {
    if (!transport_.isConnected()) return false;
    const std::vector<uint8_t> attn = { IAC, IP };
    return transport_.send(attn);
}

// ── Read loop ─────────────────────────────────────────────────────────────────
void TN3270Session::readLoop() {
    uint8_t buf[4096];
    while (transport_.isConnected()) {
        int n = transport_.recv(buf, sizeof(buf));
        if (n <= 0) break;
        if (trafficCb_) trafficCb_(false, {buf, buf + n});
        for (int i = 0; i < n; ++i) {
            processByte(buf[i]);
        }
    }
    state_ = State::Disconnected;
    if (errorCb_) errorCb_("Connection closed");
}

// ── Telnet IAC finite state machine ──────────────────────────────────────────
void TN3270Session::processByte(uint8_t byte) {
    switch (telnetState_) {
    case TelnetState::Normal:
        if (byte == IAC) {
            telnetState_ = TelnetState::IacSeen;
        } else {
            // Normal data byte (inside record or NVT)
            currentRecord_.push_back(byte);
        }
        break;

    case TelnetState::IacSeen:
        switch (byte) {
        case IAC:
            // Escaped IAC — literal 0xFF in data stream
            currentRecord_.push_back(0xFF);
            telnetState_ = TelnetState::Normal;
            break;
        case EOR:
            // End of Record — deliver accumulated record
            if (!currentRecord_.empty()) {
                if (dataCb_) dataCb_(currentRecord_);
                currentRecord_.clear();
            }
            telnetState_ = TelnetState::Normal;
            break;
        case WILL: telnetState_ = TelnetState::Will;  break;
        case WONT: telnetState_ = TelnetState::Wont;  break;
        case DO:   telnetState_ = TelnetState::Do;    break;
        case DONT: telnetState_ = TelnetState::Dont;  break;
        case SB:
            subnegBuf_.clear();
            telnetState_ = TelnetState::Sb;
            break;
        case NOP:
            telnetState_ = TelnetState::Normal;
            break;
        default:
            // Ignore other IAC commands
            telnetState_ = TelnetState::Normal;
            break;
        }
        break;

    case TelnetState::Will:
        processIacCommand(WILL, byte);
        telnetState_ = TelnetState::Normal;
        break;
    case TelnetState::Wont:
        processIacCommand(WONT, byte);
        telnetState_ = TelnetState::Normal;
        break;
    case TelnetState::Do:
        processIacCommand(DO, byte);
        telnetState_ = TelnetState::Normal;
        break;
    case TelnetState::Dont:
        processIacCommand(DONT, byte);
        telnetState_ = TelnetState::Normal;
        break;

    case TelnetState::Sb:
        if (byte == IAC) {
            telnetState_ = TelnetState::SbIac;
        } else {
            subnegBuf_.push_back(byte);
        }
        break;
    case TelnetState::SbIac:
        if (byte == SE) {
            processSubneg(subnegBuf_);
            subnegBuf_.clear();
            telnetState_ = TelnetState::Normal;
        } else if (byte == IAC) {
            subnegBuf_.push_back(IAC); // escaped IAC inside SB
            telnetState_ = TelnetState::Sb;
        } else {
            telnetState_ = TelnetState::Sb;
        }
        break;
    }
}

// ── IAC option commands ───────────────────────────────────────────────────────
void TN3270Session::processIacCommand(uint8_t cmd, uint8_t opt) {
    switch (opt) {
    case OPT_BINARY:
        if (cmd == DO) {
            doBinary_ = true;
            // Only respond if we haven't already sent WILL BINARY (e.g. in connect())
            if (!sentWillBinary_) { sentWillBinary_ = true; sendWill(OPT_BINARY); }
        } else if (cmd == WILL) {
            willBinary_ = true;
            if (!sentDoBinary_)   { sentDoBinary_   = true; sendDo(OPT_BINARY); }
        } else if (cmd == DONT) { doBinary_ = false; }
        else if (cmd == WONT) { willBinary_ = false; }
        break;

    case OPT_EOR:
        if (cmd == DO) {
            doEOR_ = true;
            if (!sentWillEOR_) { sentWillEOR_ = true; sendWill(OPT_EOR); }
        } else if (cmd == WILL) {
            willEOR_ = true;
            if (!sentDoEOR_)   { sentDoEOR_   = true; sendDo(OPT_EOR); }
        } else if (cmd == DONT) { doEOR_ = false; }
        else if (cmd == WONT) { willEOR_ = false; }
        break;

    case OPT_TERMINAL_TYPE:
        if (cmd == DO) {
            doTermType_ = true;
            if (!sentWillTermType_) { sentWillTermType_ = true; sendWill(OPT_TERMINAL_TYPE); }
        } else if (cmd == WILL) {
            // Server wants to know our type — it will SB TERMINAL-TYPE SEND
            willTermType_ = true;
        }
        break;

    case OPT_TN3270E:
        if ((cmd == DO || cmd == WILL) && !tn3270eOffered_) {
            // Server confirmed (DO) or offered (WILL) TN3270E — start sub-negotiation.
            // Guard against duplicate WILL/DO in case we already sent one in connect().
            tn3270eOffered_ = true;
            if (cmd == WILL && !sentDoTN3270E_)   { sentDoTN3270E_   = true; sendDo(OPT_TN3270E); }
            if (cmd == DO   && !sentWillTN3270E_) { sentWillTN3270E_ = true; sendWill(OPT_TN3270E); }
            state_ = State::NegotiatingTN3270E;
            std::vector<uint8_t> payload = {
                OPT_TN3270E,
                TN3270E_DEVICE_TYPE, TN3270E_REQUEST
            };
            const char* dtype = modelTypeName(model_);
            for (const char* p = dtype; *p; ++p)
                payload.push_back(static_cast<uint8_t>(*p));
            sendSb(payload);
        } else if (cmd == WONT || cmd == DONT) {
            // Server rejected TN3270E — fall back to traditional TN3270
            tn3270eOffered_ = false;
        }
        break;

    default:
        // Reject unknown options
        if (cmd == DO)   sendWont(opt);
        if (cmd == WILL) sendDont(opt);
        break;
    }

    // Check if traditional TN3270 negotiation is complete.
    // Only require the server→client DO options; WILL BINARY/WILL EOR may not be
    // sent by all servers (e.g. z/VM) but binary data still arrives correctly.
    if (!tn3270eOffered_ && !tn3270eMode_) {
        if (doBinary_ && doEOR_ && doTermType_) {
            enterDataMode();
        }
    }
}

// ── Sub-negotiation ───────────────────────────────────────────────────────────
void TN3270Session::processSubneg(const std::vector<uint8_t>& sb) {
    if (sb.empty()) return;

    uint8_t opt = sb[0];

    if (opt == OPT_TERMINAL_TYPE && sb.size() >= 2 && sb[1] == 0x01 /* SEND */) {
        // SEND subneg is the server asking for our terminal type — treat it as
        // evidence of effective DO TERMINAL-TYPE even if that IAC was not sent.
        doTermType_ = true;
        sendTerminalType();
        // If classic negotiation is otherwise complete, enter data mode now.
        if (!tn3270eOffered_ && !tn3270eMode_ && doBinary_ && doEOR_) {
            enterDataMode();
        }
    } else if (opt == OPT_TN3270E) {
        handleTN3270eSb(sb);
    }
}

void TN3270Session::handleTN3270eSb(const std::vector<uint8_t>& sb) {
    if (sb.size() < 2) return;
    // sb[0] == OPT_TN3270E, sb[1] == function code
    uint8_t func = sb[1];

    if (func == TN3270E_DEVICE_TYPE && sb.size() >= 3) {
        uint8_t sub = sb[2];
        if (sub == TN3270E_IS) {
            // Server confirmed device type — now negotiate functions
            std::vector<uint8_t> payload = {
                OPT_TN3270E,
                TN3270E_FUNCTIONS, TN3270E_REQUEST
                // No special functions for Phase 1
            };
            sendSb(payload);
        } else if (sub == TN3270E_REJECT) {
            // Server rejected our device type — fall back to classic TN3270
            tn3270eOffered_ = false;
            tn3270eMode_    = false;
            if (doBinary_ && doEOR_ && doTermType_) {
                enterDataMode();
            }
            // If classic options not yet fully negotiated, enterDataMode()
            // will be triggered from processIacCommand when the last DO arrives.
        }
    } else if (func == TN3270E_FUNCTIONS && sb.size() >= 3) {
        uint8_t sub = sb[2];
        if (sub == TN3270E_IS) {
            // Functions agreed — we are in TN3270E mode
            tn3270eMode_ = true;
            enterDataMode();
        } else if (sub == TN3270E_REJECT) {
            // Server rejected function set — fall back to classic TN3270
            tn3270eOffered_ = false;
            tn3270eMode_ = false;
            if (doBinary_ && doEOR_ && doTermType_) {
                enterDataMode();
            }
        }
    }
}

void TN3270Session::sendTerminalType() {
    const char* term = modelTypeName(model_);
    std::vector<uint8_t> payload = { OPT_TERMINAL_TYPE, 0x00 /* IS */ };
    for (const char* p = term; *p; ++p)
        payload.push_back(static_cast<uint8_t>(*p));
    sendSb(payload);
}

void TN3270Session::enterDataMode() {
    if (state_ == State::Connected) return;
    state_ = State::Connected;
    if (connectedCb_) connectedCb_();
}

// ── Wire helpers ──────────────────────────────────────────────────────────────
void TN3270Session::sendWill(uint8_t opt) {
    sendRaw({ IAC, WILL, opt });
}
void TN3270Session::sendWont(uint8_t opt) {
    sendRaw({ IAC, WONT, opt });
}
void TN3270Session::sendDo(uint8_t opt) {
    sendRaw({ IAC, DO, opt });
}
void TN3270Session::sendDont(uint8_t opt) {
    sendRaw({ IAC, DONT, opt });
}

void TN3270Session::sendSb(const std::vector<uint8_t>& payload) {
    std::vector<uint8_t> msg;
    msg.reserve(payload.size() + 4);
    msg.push_back(IAC);
    msg.push_back(SB);
    for (uint8_t b : payload) {
        if (b == IAC) msg.push_back(IAC); // escape
        msg.push_back(b);
    }
    msg.push_back(IAC);
    msg.push_back(SE);
    sendRaw(msg);
}

void TN3270Session::sendRaw(const std::vector<uint8_t>& data) {
    if (trafficCb_) trafficCb_(true, data);
    transport_.send(data);
}

// ── Record encoding ───────────────────────────────────────────────────────────
std::vector<uint8_t> TN3270Session::escapeRecord(const std::vector<uint8_t>& raw) {
    std::vector<uint8_t> out;
    out.reserve(raw.size() + 4);
    for (uint8_t b : raw) {
        out.push_back(b);
        if (b == IAC) out.push_back(IAC); // double 0xFF
    }
    out.push_back(IAC);
    out.push_back(EOR);
    return out;
}

} // namespace x3270
