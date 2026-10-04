#include "DataInspectorDialog.h"
#include <QVBoxLayout>
#include <QHBoxLayout>
#include <QLabel>
#include <QCoreApplication>
#include <QFile>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonArray>
#include <QDateTime>
#include <QTimeZone>
#include <QRegularExpression>
#include <cmath>

DataInspectorDialog::DataInspectorDialog(const QByteArray &rawBytes, const QString &decodedText,
                                           const QByteArray &verticalHex, const QString &verticalDecodedText,
                                           QWidget *parent)
    : QDialog(parent), m_rawBytes(rawBytes), m_decodedString(decodedText),
      m_verticalHex(verticalHex), m_verticalDecodedString(verticalDecodedText) {

    setWindowTitle("Mainframe Data Inspector");
    resize(520, 480);
    setStyleSheet("QDialog { background-color: #1e1e1e; color: #dcdcdc; }");

    setupUi();
    decodeData();
}

void DataInspectorDialog::setupUi() {
    QVBoxLayout *mainLayout = new QVBoxLayout(this);
    mainLayout->setContentsMargins(10, 10, 10, 10);
    mainLayout->setSpacing(10);

    m_textView = new QTextEdit(this);
    m_textView->setReadOnly(true);
    m_textView->setFont(QFont("Menlo", 11));
    m_textView->setStyleSheet("QTextEdit { background-color: #121212; color: #00ff66; border: 1px solid #333333; font-family: monospace; }");

    mainLayout->addWidget(m_textView);

    // Rilevamento indirizzo esadecimale IPCS (Pointer Hopper)
    QString cleanStr = m_decodedString.trimmed();
    static QRegularExpression ptrRegex("^[0-9A-Fa-f]{8}$|^[0-9A-Fa-f]{16}$");
    if (!cleanStr.isEmpty() && ptrRegex.match(cleanStr).hasMatch()) {
        m_jumpBtn = new QPushButton(QString("Jump to Address (L %1)").arg(cleanStr.toUpper()), this);
        m_jumpBtn->setStyleSheet("QPushButton { background-color: #007acc; color: white; font-weight: bold; border-radius: 4px; padding: 6px; }"
                                 "QPushButton:hover { background-color: #0099ff; }");
        connect(m_jumpBtn, &QPushButton::clicked, this, [this, cleanStr]() {
            emit addressJumpRequested(cleanStr.toUpper());
            accept();
        });
        mainLayout->addWidget(m_jumpBtn);
    }
}

void DataInspectorDialog::decodeData() {
    if (m_rawBytes.isEmpty() && m_decodedString.isEmpty()) return;

    QString outText;

    // 1. ISPF VERTICAL HEX
    if (!m_verticalHex.isEmpty()) {
        outText += "=== ISPF VERTICAL HEX ===\n";
        analyzeBytes(reinterpret_cast<const uint8_t*>(m_verticalHex.constData()), m_verticalHex.size(), outText);
        outText += QString("EBCDIC : %1\n\n").arg(m_verticalDecodedString);
    }

    // 2. PARSED SCREEN TEXT
    QByteArray parsedHex = parseHexString(m_decodedString);
    if (!parsedHex.isEmpty()) {
        outText += "=== PARSED SCREEN TEXT (HEX) ===\n";
        analyzeBytes(reinterpret_cast<const uint8_t*>(parsedHex.constData()), parsedHex.size(), outText);
        outText += "\n";
    }

    // 3. RAW TERMINAL BUFFER
    outText += "=== RAW TERMINAL BUFFER ===\n";
    analyzeBytes(reinterpret_cast<const uint8_t*>(m_rawBytes.constData()), m_rawBytes.size(), outText);
    outText += QString("EBCDIC : %1\n").arg(m_decodedString);

    m_textView->setPlainText(outText);
}

void DataInspectorDialog::analyzeBytes(const uint8_t *bytes, int len, QString &outText) {
    if (len <= 0) return;

    // HEX
    outText += "HEX    : ";
    for (int i = 0; i < len; ++i) {
        outText += QString("%1 ").arg(bytes[i], 2, 16, QChar('0')).toUpper();
    }
    outText += "\n";

    // BINARY (primi 4 byte)
    outText += "BIN    : ";
    int binLen = std::min(len, 4);
    for (int i = 0; i < binLen; ++i) {
        uint8_t b = bytes[i];
        for (int j = 7; j >= 0; --j) {
            outText += QString::number((b >> j) & 1);
        }
        if (i < binLen - 1) outText += " ";
    }
    outText += "\n";

    // ASCII
    outText += "ASCII  : ";
    for (int i = 0; i < len; ++i) {
        outText += (bytes[i] >= 0x20 && bytes[i] <= 0x7E) ? QChar(bytes[i]) : '.';
    }
    outText += "\n";

    // --- ASN.1 Detection (PKCS#7, Certificati) ---
    bool foundAsn = false;
    for (int i = 0; i < len - 2; ++i) {
        // ASN.1 SEQUENCE
        if (bytes[i] == 0x30 && (bytes[i+1] == 0x81 || bytes[i+1] == 0x82)) {
            outText += "FOUND  : ASN.1 SEQUENCE (Long/Multi-byte length)\n";
            foundAsn = true;
        }
        // ASN.1 OID (PKCS#7 Data)
        if (bytes[i] == 0x06 && bytes[i+1] == 0x09 && i + 10 < len) {
            if (bytes[i+2]==0x2A && bytes[i+3]==0x86 && bytes[i+4]==0x48 &&
                bytes[i+5]==0x86 && bytes[i+6]==0xF7 && bytes[i+7]==0x0D &&
                bytes[i+8]==0x01 && bytes[i+9]==0x07 && bytes[i+10]==0x01) {
                outText += "FOUND  : ASN.1 OID: PKCS#7 Data\n";
                foundAsn = true;
            }
        }
    }
    if (foundAsn) outText += "\n";

    outText += "-------------------------------------------------\n";

    // Decodificatori interi COMP / COMP-4
    if (len >= 2) {
        int16_t hw = static_cast<int16_t>((static_cast<uint16_t>(bytes[0]) << 8) | bytes[1]);
        outText += QString("COMP-H : %1\n").arg(hw);
    }

    if (len >= 4) {
        uint32_t ufw = (static_cast<uint32_t>(bytes[0]) << 24) | (static_cast<uint32_t>(bytes[1]) << 16) |
                       (static_cast<uint32_t>(bytes[2]) << 8) | static_cast<uint32_t>(bytes[3]);
        int32_t fw = static_cast<int32_t>(ufw);
        outText += QString("COMP-F : %1\n").arg(fw);

        // PTR-31 (z/OS 31-bit pointer)
        uint32_t ptr31 = ufw & 0x7FFFFFFF;
        outText += QString("PTR-31 : 0x%1\n").arg(ptr31, 8, 16, QChar('0')).toUpper();

        // HFP (IBM Hexadecimal Floating Point Short)
        int sign = (ufw >> 31) & 1;
        int exp = (ufw >> 24) & 0x7F;
        uint32_t frac = ufw & 0x00FFFFFF;
        double hfp_short = (1.0 - 2.0 * sign) * (static_cast<double>(frac) / 16777216.0) * std::pow(16.0, exp - 64);
        outText += QString("HFP(S) : %1\n").arg(hfp_short, 0, 'g', 10);
    }

    if (len >= 8) {
        uint64_t dw = 0;
        for (int i = 0; i < 8; ++i) dw = (dw << 8) | bytes[i];
        outText += QString("COMP-D : %1\n").arg(static_cast<long long>(dw));

        // HFP (IBM Hexadecimal Floating Point Long)
        int sign = (dw >> 63) & 1;
        int exp = (dw >> 56) & 0x7F;
        uint64_t frac = dw & 0x00FFFFFFFFFFFFFFULL;
        double hfp_long = (1.0 - 2.0 * sign) * (static_cast<double>(frac) / 72057594037927936.0) * std::pow(16.0, exp - 64);
        outText += QString("HFP(L) : %1\n").arg(hfp_long, 0, 'g', 15);

        // STCK Timestamp
        uint64_t micros = dw >> 12;
        uint64_t epochOffset = 2208988800ULL * 1000000ULL;
        if (micros > epochOffset) {
            qint64 unixTime = (micros - epochOffset) / 1000000ULL;
            QDateTime dt = QDateTime::fromSecsSinceEpoch(unixTime, QTimeZone::utc());
            outText += QString("STCK   : %1 UTC\n").arg(dt.toString("yyyy-MM-dd HH:mm:ss.zzz"));
        }
    }

    // COMP-3 (COBOL Packed Decimal)
    outText += QString("COMP-3 : %1\n").arg(decodeComp3(bytes, std::min(len, 32)));

    // --- VSAM CONTROL INTERVAL (CIDF) ---
    if (len >= 4) {
        uint16_t offset = (bytes[0] << 8) | bytes[1];
        uint16_t freeSpc = (bytes[2] << 8) | bytes[3];
        outText += "=== VSAM CONTROL INTERVAL (CIDF) ===\n";
        outText += QString("Free Space Offset : %1 bytes (0x%2)\n")
                    .arg(offset)
                    .arg(QString::number(offset, 16).rightJustified(4, '0').toUpper());
        outText += QString("Free Space Length : %1 bytes (0x%2)\n")
                    .arg(freeSpc)
                    .arg(QString::number(freeSpc, 16).rightJustified(4, '0').toUpper());
    }
}

QString DataInspectorDialog::decodeComp3(const uint8_t *bytes, int len) {
    QString numStr = "";
    bool valid = true;

    for (int i = 0; i < len; ++i) {
        uint8_t b = bytes[i];
        uint8_t high = (b & 0xF0) >> 4;
        uint8_t low  = (b & 0x0F);

        if (i < len - 1) {
            if (high > 9 || low > 9) { valid = false; break; }
            numStr += QString("%1%2").arg(high).arg(low);
        } else {
            if (high > 9) { valid = false; break; }
            numStr += QString::number(high);
            if (low == 0xC || low == 0xA || low == 0xE || low == 0xF) {
                numStr.prepend("+");
            } else if (low == 0xD || low == 0xB) {
                numStr.prepend("-");
            } else {
                valid = false;
            }
        }
    }
    return valid ? numStr : "Invalid";
}

QByteArray DataInspectorDialog::parseHexString(const QString &str) {
    QString cleanStr = str.simplified().remove(' ').toUpper();
    QByteArray data;
    for (int i = 0; i < cleanStr.length() - 1; i += 2) {
        bool ok = false;
        uint8_t byte = cleanStr.mid(i, 2).toUInt(&ok, 16);
        if (ok) data.append(static_cast<char>(byte));
        else break;
    }
    return data;
}