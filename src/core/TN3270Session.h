#pragma once
#include <cstdint>
#include <string>
#include <vector>
#include <functional>
#include <memory>
#include "TLSTransport.h"
#include "TerminalModel.h"
#include "ITerminalSession.h"

namespace x3270 {

// ── Telnet constants ──────────────────────────────────────────────────────────
static constexpr uint8_t IAC  = 0xFF;
static constexpr uint8_t DONT = 0xFE;
static constexpr uint8_t DO   = 0xFD;
static constexpr uint8_t WONT = 0xFC;
static constexpr uint8_t WILL = 0xFB;
static constexpr uint8_t SB   = 0xFA;  // Sub-negotiation begin
static constexpr uint8_t SE   = 0xF0;  // Sub-negotiation end
static constexpr uint8_t EOR  = 0xEF;  // End of Record
static constexpr uint8_t IP   = 0xF4;  // Interrupt Process  (ATTN)
static constexpr uint8_t AO   = 0xF5;  // Abort Output       (SYSREQ)
static constexpr uint8_t NOP  = 0xF1;

// Telnet options
static constexpr uint8_t OPT_BINARY        = 0x00;
static constexpr uint8_t OPT_TERMINAL_TYPE = 0x18;
static constexpr uint8_t OPT_EOR           = 0x19;
static constexpr uint8_t OPT_TN3270E       = 0x28;

// TN3270E sub-option codes
static constexpr uint8_t TN3270E_ASSOCIATE   = 0x00;
static constexpr uint8_t TN3270E_CONNECT     = 0x01;
static constexpr uint8_t TN3270E_DEVICE_TYPE = 0x02;
static constexpr uint8_t TN3270E_FUNCTIONS   = 0x03;
static constexpr uint8_t TN3270E_IS          = 0x04;
static constexpr uint8_t TN3270E_REASON      = 0x05;
static constexpr uint8_t TN3270E_REJECT      = 0x06;
static constexpr uint8_t TN3270E_REQUEST     = 0x07;
static constexpr uint8_t TN3270E_SEND        = 0x08;

// TN3270E data types
static constexpr uint8_t DT_3270_DATA  = 0x00;
static constexpr uint8_t DT_RESPONSE   = 0x02;
static constexpr uint8_t DT_BIND_IMAGE = 0x03;
static constexpr uint8_t DT_UNBIND     = 0x04;
static constexpr uint8_t DT_NVT_DATA   = 0x05;

// ── TN3270Session ─────────────────────────────────────────────────────────────
class TN3270Session : public ITerminalSession {
public:
    enum class State {
        Disconnected,
        Connecting,
        NegotiatingTelnet,   // exchanging WILL/DO/WONT/DONT
        NegotiatingTN3270E,  // exchanging TN3270E SBs
        Connected            // 3270 data stream mode
    };

    // Called with each complete 3270 record (IAC EOR stripped, IAC IAC unescaped).
    // For TN3270E mode the 5-byte header is still prepended.
    using DataCallback      = std::function<void(const std::vector<uint8_t>&)>;
    using ConnectedCallback = std::function<void()>;
    using ErrorCallback     = std::function<void(const std::string&)>;
    /// Called with every raw TCP chunk (tx=true → sent, tx=false → received).
    /// Includes all Telnet negotiation bytes as well as 3270 data records.
    using TrafficCallback   = std::function<void(bool tx, const std::vector<uint8_t>&)>;

    TN3270Session();
    ~TN3270Session() override;

    TN3270Session(const TN3270Session&) = delete;
    TN3270Session& operator=(const TN3270Session&) = delete;

    void setDataCallback(DataCallback cb)           override { dataCb_      = std::move(cb); }
    void setConnectedCallback(ConnectedCallback cb) override { connectedCb_ = std::move(cb); }
    void setErrorCallback(ErrorCallback cb)         override { errorCb_     = std::move(cb); }
    void setTrafficCallback(TrafficCallback cb)     override { trafficCb_   = std::move(cb); }

    /// Set the terminal model before calling connect().
    /// Determines the DEVICE-TYPE string sent during TN3270E negotiation.
    void setModel(TerminalModel m) { model_ = m; }

    /// Connect and start Telnet negotiation.  Blocks until negotiation is
    /// complete or an error occurs (intended to be called from a background thread).
    bool connect(const std::string& host, uint16_t port,
                 bool useTLS, bool verifyCert,
                 const std::string& caBundle = {}) override;
                 
    void disconnect() override;
    bool isConnected()    const override { return state_ == State::Connected; }
    bool tn3270eActive()  const { return tn3270eMode_; }
    State state()         const { return state_; }

    void readLoop() override;

    /// Send a 3270 aid record to the host (raw 3270 bytes, before Telnet escaping).
    bool send3270Record(const std::vector<uint8_t>& record);

    /// ITerminalSession::sendRecord — delegates to send3270Record.
    bool sendRecord(const std::vector<uint8_t>& record) override { return send3270Record(record); }

    /// Send Telnet IAC IP (ATTN key).
    bool sendATTN();

private:
    // Telnet IAC FSM
    enum class TelnetState {
        Normal, IacSeen,
        Will, Wont, Do, Dont,
        Sb, SbIac
    };

    void processByte(uint8_t byte);
    void processIacCommand(uint8_t cmd, uint8_t opt);
    void processSubneg(const std::vector<uint8_t>& sb);

    void sendWill(uint8_t opt);
    void sendWont(uint8_t opt);
    void sendDo(uint8_t opt);
    void sendDont(uint8_t opt);
    void sendSb(const std::vector<uint8_t>& payload);
    void sendRaw(const std::vector<uint8_t>& data);

    void handleTN3270eSb(const std::vector<uint8_t>& sb);
    void sendTerminalType();
    void enterDataMode();

    // IAC-escape a 3270 record and append IAC EOR
    static std::vector<uint8_t> escapeRecord(const std::vector<uint8_t>& raw);

    TLSTransport       transport_;
    State              state_       { State::Disconnected };
    TelnetState        telnetState_ { TelnetState::Normal };
    TerminalModel      model_       { TerminalModel::Model2 };

    DataCallback      dataCb_;
    ConnectedCallback connectedCb_;
    ErrorCallback     errorCb_;
    TrafficCallback   trafficCb_;

    // Option negotiation tracking — what the server has agreed to
    bool willBinary_   { false };
    bool doBinary_     { false };
    bool willEOR_      { false };
    bool doEOR_        { false };
    bool willTermType_ { false };
    bool doTermType_   { false };
    bool tn3270eMode_  { false };
    bool tn3270eOffered_ { false };
    uint16_t sendSeqNum_ { 0 };    // TN3270E outbound sequence number

    // Track options WE have already sent (RFC 854: don't retransmit in-flight opts)
    bool sentWillBinary_   { false };
    bool sentDoBinary_     { false };
    bool sentWillEOR_      { false };
    bool sentDoEOR_        { false };
    bool sentWillTermType_ { false };
    bool sentWillTN3270E_  { false };
    bool sentDoTN3270E_    { false };

    // Accumulate current 3270 record
    std::vector<uint8_t> currentRecord_;
    // Accumulate sub-negotiation payload
    std::vector<uint8_t> subnegBuf_;
};

} // namespace x3270
