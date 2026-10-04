#include "TN3270Session.h"
#include "ScreenBuffer.h"
#include "EbcdicCodec.h"
#include "DataStreamParser.h"
#include "KeyboardState.h"
#include "ScreenStructuralAnalyzer.h"

#include <iostream>
#include <thread>
#include <memory>
#include <string>
#include <sstream>
#include <map>
#include <algorithm>

// --- Helper Parser MinimalJSON Minimale per Comandi di Input ---
struct AutomationCommand {
    std::string action;                       // "submit", "aid", "type"
    std::map<std::string, std::string> fields; // Map {"USERID": "MYUSER"}
    std::string aid = "ENTER";                 // "ENTER", "PF1".."PF24", "PA1".."PA3", "CLEAR"
};

// Heuristic Lightweight Parser to extract keys/values from the input JSON without heavy dependencies
AutomationCommand parseJsonCommand(const std::string& jsonStr) {
    AutomationCommand cmd;
    
    // Action extraction
    auto actionPos = jsonStr.find("\"action\"");
    if (actionPos != std::string::npos) {
        auto start = jsonStr.find('"', jsonStr.find(':', actionPos) + 1);
        auto end = jsonStr.find('"', start + 1);
        if (start != std::string::npos && end != std::string::npos) {
            cmd.action = jsonStr.substr(start + 1, end - start - 1);
        }
    }

    // AID key extraction
    auto aidPos = jsonStr.find("\"aid\"");
    if (aidPos != std::string::npos) {
        auto start = jsonStr.find('"', jsonStr.find(':', aidPos) + 1);
        auto end = jsonStr.find('"', start + 1);
        if (start != std::string::npos && end != std::string::npos) {
            cmd.aid = jsonStr.substr(start + 1, end - start - 1);
        }
    }

    // "fields" block extraction
    auto fieldsPos = jsonStr.find("\"fields\"");
    if (fieldsPos != std::string::npos) {
        auto openBrace = jsonStr.find('{', fieldsPos);
        auto closeBrace = jsonStr.find('}', openBrace);
        if (openBrace != std::string::npos && closeBrace != std::string::npos) {
            std::string fieldsBlock = jsonStr.substr(openBrace + 1, closeBrace - openBrace - 1);
            std::stringstream ss(fieldsBlock);
            std::string pair;
            
            while (std::getline(ss, pair, ',')) {
                auto colon = pair.find(':');
                if (colon != std::string::npos) {
                    auto kStart = pair.find('"');
                    auto kEnd = pair.find('"', kStart + 1);
                    auto vStart = pair.find('"', colon + 1);
                    auto vEnd = pair.find('"', vStart + 1);
                    
                    if (kStart != std::string::npos && kEnd != std::string::npos &&
                        vStart != std::string::npos && vEnd != std::string::npos) {
                        std::string key = pair.substr(kStart + 1, kEnd - kStart - 1);
                        std::string val = pair.substr(vStart + 1, vEnd - vStart - 1);
                        cmd.fields[key] = val;
                    }
                }
            }
        }
    }

    return cmd;
}

// Utility function to send the appropriate AID key
void executeAIDKey(const std::string& aidStr, x3270::KeyboardState& kbd) {
    std::string aid = aidStr;
    std::transform(aid.begin(), aid.end(), aid.begin(), ::toupper);

    if (aid == "ENTER" || aid == "RETURN") {
        kbd.handleEnter();
    } else if (aid == "CLEAR") {
        kbd.handleClear();
    } else if (aid.rfind("PF", 0) == 0 && aid.length() > 2) {
        int pfNum = std::atoi(aid.substr(2).c_str());
        if (pfNum >= 1 && pfNum <= 24) kbd.handlePF(pfNum);
    } else if (aid.rfind("PA", 0) == 0 && aid.length() > 2) {
        int paNum = std::atoi(aid.substr(2).c_str());
        if (paNum >= 1 && paNum <= 3) kbd.handlePA(paNum);
    } else {
        kbd.handleEnter(); // Default fallback
    }
}

// --- MAIN ENGINE ---
int main(int argc, char* argv[]) {
    std::clog << "===========================================" << std::endl;
    std::clog << " DX3270 Headless JSON Automation Engine    " << std::endl;
    std::clog << "===========================================" << std::endl;

    if (argc < 3) {
        std::cout << "{\"error\": \"Usage: dx3270_headless <host> <port> [ssl: 0|1]\"}" << std::endl;
        return 1;
    }

    std::string host = argv[1];
    uint16_t port = static_cast<uint16_t>(std::atoi(argv[2]));
    bool useSSL = (argc >= 4) ? (std::atoi(argv[3]) == 1) : false;

    // 1. Instantiation of C++ components
    auto screen = std::make_shared<x3270::ScreenBuffer>(x3270::TerminalModel::Model2);
    auto codec = std::make_shared<x3270::EbcdicCodec>(x3270::CodePage::CP037);
    auto parser = std::make_shared<x3270::DataStreamParser>(*screen, *codec);
    auto kbd = std::make_shared<x3270::KeyboardState>(*screen, *codec);
    auto session = std::make_shared<x3270::TN3270Session>();

    // Keyboard-socket linkage
    kbd->setSendCallback([session](const std::vector<uint8_t>& record) -> bool {
        return session->sendRecord(record);
    });

    parser->setUnlockCallback([kbd]() { kbd->unlock(); });

    // 2. Euristic Analyzer
    dx3270::ScreenStructuralAnalyzer analyzer(*screen, *codec);

    // Json Emision for each screen structure update
    analyzer.setOnStructureUpdated([](const dx3270::ScreenStructure& structure, const std::string& json) {
        std::string compactJson = json;
        std::replace(compactJson.begin(), compactJson.end(), '\n', ' ');
        std::cout << compactJson << std::endl << std::flush;
    });

    // 3. Network Callback
    session->setDataCallback([parser, &analyzer](const std::vector<uint8_t>& record) {
        const std::vector<uint8_t>* payload = &record;
        std::vector<uint8_t> stripped;
        
        if (record.size() >= 5 && record[0] == 0x00) { // Strip TN3270E Header
            stripped.assign(record.begin() + 5, record.end());
            payload = &stripped;
        }
        
        parser->processRecord(*payload);
        analyzer.analyzeCurrentScreen();
    });

    session->setConnectedCallback([host, port, kbd]() {
        std::clog << "[+] Connected to " << host << ":" << port << std::endl;
        kbd->unlock();
    });

    session->setErrorCallback([](const std::string& err) {
        std::cout << "{\"event\": \"error\", \"message\": \"" << err << "\"}" << std::endl << std::flush;
    });

    // 4. Avvio Connessione
    std::clog << "[*] Connecting to " << host << ":" << port << "..." << std::endl;
    if (!session->connect(host, port, useSSL, false)) {
        return 1;
    }

    // 5. Asynchronous thread listening for JSON commands from STDIN
    std::thread inputThread([&analyzer, &screen, kbd]() {
        std::string jsonLine;
        while (std::getline(std::cin, jsonLine)) {
            if (jsonLine.empty()) continue;

            // Decode the received JSON command
            AutomationCommand cmd = parseJsonCommand(jsonLine);

            // Analyze the current screen to map field names to memory positions
            dx3270::ScreenStructure currentStruct = analyzer.analyzeCurrentScreen();

            // Populate the requested fields in the buffer
            for (const auto& [fieldName, value] : cmd.fields) {
                for (const auto& field : currentStruct.fields) {
                    if (field.name == fieldName && (field.type == dx3270::FieldType::Input || field.type == dx3270::FieldType::Secret)) {
                        // Move the cursor to the beginning of the input field
                        int pos = field.startRow * currentStruct.cols + field.startCol;
                        screen->setCursor(pos);

                        // Delete the previous content (Erase EOF)
                        kbd->handleEraseEOF();

                        // Write the new EBCDIC value   
                        for (char c : value) {
                            kbd->handleChar(static_cast<uint16_t>(c));
                        }
                        break;
                    }
                }
            }

            // Send the AID signal to the mainframe
            executeAIDKey(cmd.aid, *kbd);
        }
    });

    // Blocking network loop
    session->readLoop();

    if (inputThread.joinable()) {
        inputThread.detach();
    }

    return 0;
}