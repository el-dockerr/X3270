#pragma once

#include <QDialog>
#include <QTextEdit>
#include <QPushButton>
#include <QByteArray>
#include <QString>

class DataInspectorDialog : public QDialog {
    Q_OBJECT

public:
    explicit DataInspectorDialog(const QByteArray &rawBytes, const QString &decodedText,
                                 const QByteArray &verticalHex = QByteArray(),
                                 const QString &verticalDecodedText = QString(),
                                 QWidget *parent = nullptr);

signals:
    void addressJumpRequested(const QString &address);

private:
    void setupUi();
    void decodeData();
    void analyzeBytes(const uint8_t *bytes, int len, QString &outText);
    QString decodeComp3(const uint8_t *bytes, int len);
    QByteArray parseHexString(const QString &str);

    QByteArray m_rawBytes;
    QString m_decodedString;
    QByteArray m_verticalHex;
    QString m_verticalDecodedString;

    QTextEdit *m_textView;
    QPushButton *m_jumpBtn{nullptr};
};