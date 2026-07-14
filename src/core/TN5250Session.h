#pragma once
#include "ITerminalSession.h"
#include "TLSTransport.h"
#include "TerminalModel.h"
#include <cstdint>
#include <string>
#include <vector>
#include <functional>

namespace x3270 {

// ── Telnet constants (shared with TN3270, redeclared for clarity) ─────────────
static constexpr uint8_t TN5250_IAC  = 0xFF;
static constexpr uint8_t TN5250_DONT = 0xFE;
static constexpr uint8_t TN5250_DO   = 0xFD;
static constexpr uint8_t TN5250_WONT = 0xFC;
static constexpr uint8_t TN5250_WILL = 0xFB;
static constexpr uint8_t TN5250_SB   = 0xFA;
static constexpr uint8_t TN5250_SE   = 0xF0;
static constexpr uint8_t TN5250_EOR  = 0xEF;
static constexpr uint8_t TN5250_NOP  = 0xF1;
static constexpr uint8_t TN5250_GA   = 0xF9; ///< Go-Ahead — treat as record terminator if SGA not active
static constexpr uint8_t TN5250_IP   = 0xF4;

static constexpr uint8_t TN5250_OPT_BINARY        = 0x00;
static constexpr uint8_t TN5250_OPT_SGA           = 0x03; ///< Suppress Go-Ahead (RFC 858)
static constexpr uint8_t TN5250_OPT_TERMINAL_TYPE = 0x18;
static constexpr uint8_t TN5250_OPT_EOR           = 0x19;
static constexpr uint8_t TN5250_OPT_NEW_ENVIRON   = 0x27; ///< RFC 1572 — IBM i uses this to obtain device name

// ── 5250 GDS record structure (host → client) ─────────────────────────────────
// Offset 0-1: total length including header (big-endian)
// Offset 2:   record type (0x12 = GDS)
// Offset 3:   reserved (0x00)
// Offset 4:   opcode
// Offset 5:   reserved (0x00)
// Offset 6+:  data

static constexpr uint8_t GDS_RECORD_TYPE    = 0x12;
static constexpr uint8_t GDS_HEADER_LENGTH  = 10; // 2-byte len + 0x12 + 0xA0 + flowtype(2) + varHdrLen + flags + reserved + opcode

// Host→client opcodes
static constexpr uint8_t OP_SAVE_SCREEN        = 0x01;
static constexpr uint8_t OP_RESTORE_SCREEN     = 0x02;
static constexpr uint8_t OP_WTD                = 0x11; ///< Write To Display
static constexpr uint8_t OP_CLEAR_UNIT_ALT     = 0x20;
static constexpr uint8_t OP_WRITE_ERROR_CODE   = 0x21;
static constexpr uint8_t OP_CLEAR_UNIT         = 0x40;

// Client→host GDS opcodes (TN5250_RECORD_OPCODE_*)
static constexpr uint8_t GDS_OP_NO_OP      = 0x00; ///< e.g. Query reply
static constexpr uint8_t GDS_OP_INVITE     = 0x01;
static constexpr uint8_t GDS_OP_OUTPUT_ONLY= 0x02;
static constexpr uint8_t GDS_OP_PUT_GET    = 0x03; ///< Normal AID input record
static constexpr uint8_t GDS_OP_READ_IMMED = 0x06;

// ── TN5250Session ─────────────────────────────────────────────────────────────
class TN5250Session : public ITerminalSession {
public:
    enum class State {
        Disconnected,
        Connecting,
        NegotiatingTelnet,
        Connected,
    };

    TN5250Session();
    ~TN5250Session() override;

    TN5250Session(const TN5250Session&) = delete;
    TN5250Session& operator=(const TN5250Session&) = delete;

    void setDataCallback(DataCallback cb)           override { dataCb_      = std::move(cb); }
    void setConnectedCallback(ConnectedCallback cb) override { connectedCb_ = std::move(cb); }
    void setErrorCallback(ErrorCallback cb)         override { errorCb_     = std::move(cb); }
    void setTrafficCallback(TrafficCallback cb)     override { trafficCb_   = std::move(cb); }

    /// Terminal model determines the advertised terminal-type string.
    void setModel(TerminalModel m) { model_ = m; }

    bool connect(const std::string& host, uint16_t port,
                 bool useTLS, bool verifyCert,
                 const std::string& caBundle = {}) override;

    void disconnect() override;
    bool isConnected() const override { return state_ == State::Connected; }

    /// Send a raw 5250 input record (GDS header is added here; uses PUT_GET opcode).
    bool sendRecord(const std::vector<uint8_t>& record) override;

    /// Send a raw 5250 record with an explicit GDS opcode.
    bool sendGdsRecord(const std::vector<uint8_t>& payload, uint8_t opcode);

    /// Send Telnet IAC IP (Attention / system request).
    bool sendATTN();

    void readLoop() override;

private:
    enum class TelnetState {
        Normal, IacSeen,
        Will, Wont, Do, Dont,
        Sb, SbIac,
    };

    TLSTransport       transport_;
    State              state_       { State::Disconnected };
    TelnetState        telnetState_ { TelnetState::Normal };
    TerminalModel      model_       { TerminalModel::Model2 };

    DataCallback      dataCb_;
    ConnectedCallback connectedCb_;
    ErrorCallback     errorCb_;
    TrafficCallback   trafficCb_;

    bool willBinary_      { false };
    bool doBinary_        { false };
    bool willEOR_         { false };
    bool doEOR_           { false };
    bool doTermType_      { false };

    bool sentWillBinary_   { false };
    bool sentDoBinary_     { false };
    bool sentWillEOR_      { false };
    bool sentDoEOR_        { false };
    bool sentWillTermType_ { false };
    bool sentTerminalTypeIs_{ false }; ///< true once SB TERMINAL-TYPE IS was sent
    bool sentWillSGA_      { false }; ///< RFC 2877 SHOULD: both sides suppress go-ahead
    bool sentDoSGA_        { false };
    bool sentWillNewEnv_   { false }; ///< true once WILL NEW-ENVIRON has been sent

    std::vector<uint8_t> currentRecord_;
    std::vector<uint8_t> subnegBuf_;

    void processByte(uint8_t byte);
    void processIacCommand(uint8_t cmd, uint8_t opt);
    void processSubneg(const std::vector<uint8_t>& sb);
    void sendTerminalType();
    void enterDataMode();
    void tryEnterDataMode();
    void tryDispatchGdsRecord(); ///< length-based GDS dispatch for EOR-less servers
    void sendNewEnvironIs();     ///< RFC 1572 response: SB NEW-ENVIRON IS DEVNAME VALUE <name> SE

    void sendWill(uint8_t opt);
    void sendWont(uint8_t opt);
    void sendDo(uint8_t opt);
    void sendDont(uint8_t opt);
    void sendSb(const std::vector<uint8_t>& payload);
    void sendRaw(const std::vector<uint8_t>& data);

    std::vector<uint8_t> escapeRecord(const std::vector<uint8_t>& raw);

    /// IBM terminal-type string for TN5250 negotiation.
    const char* terminalTypeName() const;
};

} // namespace x3270
