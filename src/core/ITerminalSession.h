#pragma once
#include <cstdint>
#include <string>
#include <vector>
#include <functional>

namespace x3270 {

/// Protocol-agnostic interface for a Telnet-based terminal session.
/// Implemented by TN3270Session and TN5250Session.
class ITerminalSession {
public:
    using DataCallback      = std::function<void(const std::vector<uint8_t>&)>;
    using ConnectedCallback = std::function<void()>;
    using ErrorCallback     = std::function<void(const std::string&)>;
    /// tx=true → bytes were sent, tx=false → bytes were received (raw TCP).
    using TrafficCallback   = std::function<void(bool tx, const std::vector<uint8_t>&)>;

    virtual ~ITerminalSession() = default;

    virtual void setDataCallback(DataCallback cb)           = 0;
    virtual void setConnectedCallback(ConnectedCallback cb) = 0;
    virtual void setErrorCallback(ErrorCallback cb)         = 0;
    virtual void setTrafficCallback(TrafficCallback cb)     = 0;

    /// Establish the connection and run Telnet negotiation.
    /// Returns true when the session enters data-exchange mode.
    /// Intended to be called from a background thread.
    virtual bool connect(const std::string& host, uint16_t port,
                         bool useTLS, bool verifyCert, const std::string& caBundle = {}) = 0;
    virtual void disconnect() = 0;
    virtual bool isConnected() const = 0;

    /// Send a raw application-layer record.
    /// For TN3270: raw 3270 bytes (Telnet escaping and EOR are handled internally).
    /// For TN5250: raw 5250 input record bytes (GDS header added internally).
    virtual bool sendRecord(const std::vector<uint8_t>& record) = 0;

    /// Block reading from the socket, delivering records via DataCallback.
    /// Returns when the connection is closed.  Call from a dedicated thread.
    virtual void readLoop() = 0;
};

} // namespace x3270
