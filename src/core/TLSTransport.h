#pragma once
#include <string>
#include <cstdint>
#include <functional>
#include <openssl/ssl.h>

namespace x3270 {

/// Low-level transport: wraps a TCP socket with optional OpenSSL TLS.
/// Thread-safe for one reader and one writer running concurrently.
class TLSTransport {
public:
    TLSTransport();
    ~TLSTransport();

    // Non-copyable
    TLSTransport(const TLSTransport&) = delete;
    TLSTransport& operator=(const TLSTransport&) = delete;

    /// Connect to host:port.  If useTLS=true the TLS handshake is performed
    /// immediately after the TCP connection (implicit TLS, not STARTTLS).
    /// caBundle: optional path to a PEM CA bundle; empty = use system defaults.
    /// Returns true on success; on failure errorMsg is populated.
    bool connect(const std::string& host, uint16_t port,
                 bool useTLS, 
                 bool verifyCert,
                 const std::string& caBundle,
                 std::string& errorMsg);

    void disconnect();
    bool isConnected() const { return connected_; }

    /// Send bytes.  Returns false if the connection dropped.
    bool send(const uint8_t* data, size_t len);
    bool send(const std::vector<uint8_t>& data);

    /// Blocking read up to bufLen bytes into buf.
    /// Returns number of bytes read, 0 on clean close, -1 on error.
    int recv(uint8_t* buf, size_t bufLen);

private:
    void initOpenSSL();

    int         sock_      { -1 };
    bool        connected_ { false };
    bool        useTLS_    { false };
    SSL_CTX*    ctx_       { nullptr };
    SSL*        ssl_       { nullptr };
};

} // namespace x3270
