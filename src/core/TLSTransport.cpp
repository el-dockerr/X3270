#include "TLSTransport.h"

#include <sys/socket.h>
#include <sys/types.h>
#include <netdb.h>
#include <unistd.h>
#include <fcntl.h>
#include <cerrno>
#include <cstring>
#include <vector>
#include <stdexcept>
#include <mutex>

#include <openssl/err.h>
#include <openssl/x509v3.h>

namespace x3270 {

// ── OpenSSL one-time initialisation ──────────────────────────────────────────
static std::once_flag g_sslInitFlag;
static void opensslInit() {
    SSL_library_init();
    SSL_load_error_strings();
    OpenSSL_add_all_algorithms();
}

// ── Helpers ──────────────────────────────────────────────────────────────────
static std::string sslLastError() {
    char buf[256];
    unsigned long err = ERR_get_error();
    if (err == 0) return "unknown SSL error";
    ERR_error_string_n(err, buf, sizeof(buf));
    return std::string(buf);
}

static int tcpConnect(const std::string& host, uint16_t port, std::string& errorMsg) {
    struct addrinfo hints{};
    hints.ai_family   = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;

    std::string portStr = std::to_string(port);
    struct addrinfo* res = nullptr;
    int rc = ::getaddrinfo(host.c_str(), portStr.c_str(), &hints, &res);
    if (rc != 0) {
        errorMsg = std::string("DNS lookup failed: ") + gai_strerror(rc);
        return -1;
    }

    int sock = -1;
    for (struct addrinfo* p = res; p != nullptr; p = p->ai_next) {
        sock = ::socket(p->ai_family, p->ai_socktype, p->ai_protocol);
        if (sock < 0) continue;
        if (::connect(sock, p->ai_addr, p->ai_addrlen) == 0) break;
        ::close(sock);
        sock = -1;
    }
    ::freeaddrinfo(res);

    if (sock < 0) {
        errorMsg = std::string("TCP connect failed: ") + strerror(errno);
        return -1;
    }
    return sock;
}

// ── TLSTransport ─────────────────────────────────────────────────────────────
TLSTransport::TLSTransport() {
    std::call_once(g_sslInitFlag, opensslInit);
}

TLSTransport::~TLSTransport() {
    disconnect();
}

bool TLSTransport::connect(const std::string& host, uint16_t port,
                           bool useTLS,
                           bool verifyCert,
                           const std::string& caBundle,
                           std::string& errorMsg) {
    disconnect();

    sock_ = tcpConnect(host, port, errorMsg);
    if (sock_ < 0) return false;

    useTLS_ = useTLS;

    if (useTLS_) {
        ctx_ = SSL_CTX_new(TLS_client_method());
        if (!ctx_) {
            errorMsg = "SSL_CTX_new failed: " + sslLastError();
            ::close(sock_); sock_ = -1;
            return false;
        }

        // Certificate verification
        if (verifyCert) {
            SSL_CTX_set_verify(ctx_, SSL_VERIFY_PEER, nullptr);
        } else {
        // Disable certificate verification (equivalent to the -noverifycert flag)
            SSL_CTX_set_verify(ctx_, SSL_VERIFY_NONE, nullptr);
        }

        if (!caBundle.empty()) {
            if (SSL_CTX_load_verify_locations(ctx_, caBundle.c_str(), nullptr) != 1) {
                errorMsg = "Failed to load CA bundle: " + sslLastError();
                SSL_CTX_free(ctx_); ctx_ = nullptr;
                ::close(sock_); sock_ = -1;
                return false;
            }
        } else {
            // Use macOS system certificates
            SSL_CTX_set_default_verify_paths(ctx_);
        }

        // Minimum TLS 1.2
        SSL_CTX_set_min_proto_version(ctx_, TLS1_2_VERSION);

        ssl_ = SSL_new(ctx_);
        if (!ssl_) {
            errorMsg = "SSL_new failed: " + sslLastError();
            SSL_CTX_free(ctx_); ctx_ = nullptr;
            ::close(sock_); sock_ = -1;
            return false;
        }

        SSL_set_fd(ssl_, sock_);
        // SNI
        SSL_set_tlsext_host_name(ssl_, host.c_str());
        // Hostname verification
        SSL_set_hostflags(ssl_, X509_CHECK_FLAG_NO_PARTIAL_WILDCARDS);
        if (!SSL_set1_host(ssl_, host.c_str())) {
            errorMsg = "SSL_set1_host failed";
            SSL_free(ssl_); ssl_ = nullptr;
            SSL_CTX_free(ctx_); ctx_ = nullptr;
            ::close(sock_); sock_ = -1;
            return false;
        }

        if (SSL_connect(ssl_) != 1) {
            errorMsg = "TLS handshake failed: " + sslLastError();
            SSL_free(ssl_); ssl_ = nullptr;
            SSL_CTX_free(ctx_); ctx_ = nullptr;
            ::close(sock_); sock_ = -1;
            return false;
        }
    }

    connected_ = true;
    return true;
}

void TLSTransport::disconnect() {
    connected_ = false;
    if (ssl_) {
        SSL_shutdown(ssl_);
        SSL_free(ssl_);
        ssl_ = nullptr;
    }
    if (ctx_) {
        SSL_CTX_free(ctx_);
        ctx_ = nullptr;
    }
    if (sock_ >= 0) {
        ::close(sock_);
        sock_ = -1;
    }
}

bool TLSTransport::send(const uint8_t* data, size_t len) {
    if (!connected_) return false;

    size_t sent = 0;
    while (sent < len) {
        int n;
        if (useTLS_) {
            n = SSL_write(ssl_, data + sent, static_cast<int>(len - sent));
            if (n <= 0) { connected_ = false; return false; }
        } else {
            n = static_cast<int>(::write(sock_, data + sent, len - sent));
            if (n <= 0) { connected_ = false; return false; }
        }
        sent += static_cast<size_t>(n);
    }
    return true;
}

bool TLSTransport::send(const std::vector<uint8_t>& data) {
    return send(data.data(), data.size());
}

int TLSTransport::recv(uint8_t* buf, size_t bufLen) {
    if (!connected_) return -1;

    int n;
    if (useTLS_) {
        n = SSL_read(ssl_, buf, static_cast<int>(bufLen));
        if (n <= 0) {
            int err = SSL_get_error(ssl_, n);
            if (err == SSL_ERROR_ZERO_RETURN) return 0; // clean close
            connected_ = false;
            return -1;
        }
    } else {
        n = static_cast<int>(::read(sock_, buf, bufLen));
        if (n == 0) return 0;
        if (n < 0) { connected_ = false; return -1; }
    }
    return n;
}

} // namespace x3270
