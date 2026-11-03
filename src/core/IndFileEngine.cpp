#include "IndFileEngine.h"
#include <iostream>

namespace x3270 {

static constexpr uint8_t CMD_WSF      = 0xF3; // Write Structured Field
static constexpr uint8_t SF_TYPE_FT   = 0xD0; // File Transfer Structured Field

static constexpr uint8_t FT_SUB_INIT  = 0x00;
static constexpr uint8_t FT_SUB_DATA  = 0x01;
static constexpr uint8_t FT_SUB_ACK   = 0x02;
static constexpr uint8_t FT_SUB_EOF   = 0x03;
static constexpr uint8_t FT_SUB_ERR   = 0x04;

IndFileEngine::IndFileEngine(EbcdicCodec& codec) : codec_(codec) {}

IndFileEngine::~IndFileEngine() {
    if (fileStream_.is_open()) {
        fileStream_.close();
    }
}

void IndFileEngine::setCallbacks(SendDataCallback sendCb, ProgressCallback progCb, CompletionCallback compCb) {
    sendCb_ = std::move(sendCb);
    progCb_ = std::move(progCb);
    compCb_ = std::move(compCb);
}

bool IndFileEngine::startTransfer(IndFileDirection dir, IndFileMode mode, const std::string& hostFile, const std::string& localFilePath) {
    if (isActive()) {
        return false;
    }

    direction_ = dir;
    mode_ = mode;
    localFilePath_ = localFilePath;
    bytesTransferred_ = 0;

    std::ios_base::openmode fileMode = (direction_ == IndFileDirection::Get) 
                                     ? (std::ios::out | std::ios::trunc) 
                                     : (std::ios::in);
                                     
    if (mode_ == IndFileMode::Binary) {
        fileMode |= std::ios::binary;
    }

    fileStream_.open(localFilePath_, fileMode);
    if (!fileStream_.is_open()) {
        if (compCb_) compCb_(false, "Failed to open local file: " + localFilePath_);
        return false;
    }

    state_ = IndFileState::AwaitingHostSync;
    return true;
}

void IndFileEngine::abortTransfer() {
    if (!isActive()) return;
    finishTransfer(false, "Transfer aborted by user.");
}

void IndFileEngine::finishTransfer(bool success, const std::string& message) {
    if (fileStream_.is_open()) {
        fileStream_.close();
    }
    state_ = success ? IndFileState::Complete : IndFileState::Error;
    if (compCb_) compCb_(success, message);
    state_ = IndFileState::Idle;
}

bool IndFileEngine::processHostData(const std::vector<uint8_t>& record) {
    if (!isActive() || record.empty()) return false;

    size_t offset = 0;
    if (record[0] == CMD_WSF) { // 0xF3
        offset = 1;
    }

    while (offset + 3 <= record.size()) {
        uint16_t sfLen = (static_cast<uint16_t>(record[offset]) << 8) | record[offset + 1];
        if (sfLen < 3 || offset + sfLen > record.size()) break;

        uint8_t sfType = record[offset + 2];

        // ---------------------------------------------------------------------
        // 1. READ PARTITION QUERY (0x40) - Handshake
        // ---------------------------------------------------------------------
        if (sfType == 0x40 && state_ == IndFileState::AwaitingHostSync) {
            // Risposta Query Reply matematicamente esatta per z/OS IND$FILE
            std::vector<uint8_t> queryReply = {
                0x88, // AID Structured Field

                // Summary Query Reply (0x81 0x80) -> Lunghezza: 11 byte (0x00 0x0B)
                0x00, 0x0B, 
                0x81, 0x80, 
                0x80, 0x81, 0x84, 0x86, 0x87, 0xA6, 0xD0,

                // Usable Area Query Reply (0x81 0x81) -> Lunghezza: 19 byte (0x00 0x13)
                0x00, 0x13, 
                0x81, 0x81, 
                0x01,       
                0x00, 0x80, // Larghezza (128)
                0x00, 0x2B, // Altezza (43)
                0x01,       
                0x00, 0x0A, 0x00, 0x14, 
                0x00, 0x50, 0x00, 0x2B, // Schermo 80x43

                // File Transfer Query Reply (0x81 0xD0) -> Lunghezza: 10 byte (0x00 0x0A)
                0x00, 0x0A, 
                0x81, 0xD0, 
                0x01, 0x00, // Version 1.0
                0x00, 0x01, // Type: 3270 FT
                0x01, 0x01  // Buffers
            };

            if (sendCb_) sendCb_(queryReply);
            return true; // Pacchetto consumato
        }

        // ---------------------------------------------------------------------
        // 2. STREAM DATI IND$FILE (0xD0)
        // ---------------------------------------------------------------------
        if (sfType == SF_TYPE_FT) {
            uint8_t subtype = record[offset + 3];
            state_ = IndFileState::Transferring;

            std::vector<uint8_t> payload(
                record.begin() + offset + 4, 
                record.begin() + offset + sfLen
            );

            switch (subtype) {
            case FT_SUB_INIT:
                sendAcknowledge();
                break;

            case FT_SUB_DATA:
                if (direction_ == IndFileDirection::Get) {
                    processGetChunk(payload);
                }
                break;

            case FT_SUB_EOF:
                finishTransfer(true, "File transfer completed successfully.");
                return true;

            case FT_SUB_ERR:
                finishTransfer(false, "Host reported file transfer error.");
                return true;

            default:
                break;
            }

            return true; // Pacchetto consumato
        }

        offset += sfLen;
    }

    return false;
}

void IndFileEngine::processGetChunk(const std::vector<uint8_t>& payload) {
    if (!fileStream_.is_open() || payload.size() <= 2) return;

    // Saltiamo i primi 2 byte di flag dell'header del blocco dati 3270
    const uint8_t* dataPtr = payload.data() + 2;
    size_t dataLen = payload.size() - 2;

    if (mode_ == IndFileMode::Binary) {
        fileStream_.write(reinterpret_cast<const char*>(dataPtr), dataLen);
        bytesTransferred_ += dataLen;
    } else {
        std::string asciiChunk;
        asciiChunk.reserve(dataLen);

        for (size_t i = 0; i < dataLen; ++i) {
            uint8_t ebcdicByte = dataPtr[i];
            uint16_t unicode = codec_.toUnicode(ebcdicByte);
            if (unicode >= 0x20 || unicode == '\n' || unicode == '\r' || unicode == '\t') {
                asciiChunk.push_back(static_cast<char>(unicode));
            } else if (unicode == 0x00 || ebcdicByte == 0x40) {
                asciiChunk.push_back(' ');
            }
        }

        fileStream_.write(asciiChunk.data(), asciiChunk.size());
        bytesTransferred_ += asciiChunk.size();
    }

    if (progCb_) {
        progCb_(bytesTransferred_);
    }

    sendAcknowledge();
}

void IndFileEngine::processPutChunk(const std::vector<uint8_t>& payload) {
    // Stub per upload (PUT)
}

void IndFileEngine::sendAcknowledge() {
    if (!sendCb_) return;

    std::vector<uint8_t> ackPacket = {
        0x88,       // AID Structured Field
        0x00, 0x05, // Lunghezza dello SF (5 byte)
        SF_TYPE_FT, // 0xD0 (File Transfer)
        FT_SUB_ACK  // 0x02 (Acknowledge)
    };

    sendCb_(ackPacket);
}

} // namespace x3270