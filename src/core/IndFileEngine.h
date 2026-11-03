#pragma once

#include <string>
#include <vector>
#include <functional>
#include <fstream>
#include <cstdint>
#include "EbcdicCodec.h"

namespace x3270 {

enum class IndFileDirection { Get, Put };
enum class IndFileMode { Ascii, Binary };
enum class IndFileState { 
    Idle, 
    AwaitingHostSync, // Il comando è stato inviato, aspettiamo che l'host avvii il transfer
    Transferring,     // Trasferimento dei blocchi dati in corso
    Complete,         // Trasferimento completato con successo
    Error             // Errore durante il trasferimento
};

class IndFileEngine {
public:
    // Callback per comunicare con l'esterno senza dipendere dalla sessione specifica
    using SendDataCallback = std::function<bool(const std::vector<uint8_t>&)>;
    using ProgressCallback = std::function<void(size_t bytesTransferred)>;
    using CompletionCallback = std::function<void(bool success, const std::string& message)>;

    explicit IndFileEngine(EbcdicCodec& codec);
    ~IndFileEngine();

    void setCallbacks(SendDataCallback sendCb, ProgressCallback progCb, CompletionCallback compCb);

    // Avvia un trasferimento aprendo i file locali e preparando la macchina a stati
    bool startTransfer(IndFileDirection dir, 
                       IndFileMode mode, 
                       const std::string& hostFile, 
                       const std::string& localFilePath);

    // Forza l'interruzione di un trasferimento in corso
    void abortTransfer();

    // Intercettore di rete. 
    // Ritorna 'true' se il record appartiene al protocollo IND$FILE (e non va mostrato a schermo).
    bool processHostData(const std::vector<uint8_t>& record);

    IndFileState state() const { return state_; }
    bool isActive() const { return state_ == IndFileState::AwaitingHostSync || state_ == IndFileState::Transferring; }

private:
    EbcdicCodec& codec_;
    IndFileState state_{IndFileState::Idle};
    IndFileDirection direction_{IndFileDirection::Get};
    IndFileMode mode_{IndFileMode::Ascii};
    
    std::string localFilePath_;
    std::fstream fileStream_;
    size_t bytesTransferred_{0};

    SendDataCallback sendCb_;
    ProgressCallback progCb_;
    CompletionCallback compCb_;

    void finishTransfer(bool success, const std::string& message);
    void sendAcknowledge();
    
    void processGetChunk(const std::vector<uint8_t>& record);
    void processPutChunk(const std::vector<uint8_t>& record);
};

} // namespace x3270