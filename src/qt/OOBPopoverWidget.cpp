#include "OOBPopoverWidget.h"
#include <QVBoxLayout>
#include <QHBoxLayout>
#include <QPushButton>
#include <QClipboard>
#include <QApplication>

OOBPopoverWidget::OOBPopoverWidget(const QString &title, const QString &content, QWidget *parent)
    : QDialog(parent) {

    setWindowTitle("OOB Result");
    resize(560, 320);
    setStyleSheet("QDialog { background-color: #1e1e1e; color: #cccccc; }");

    QVBoxLayout *mainLayout = new QVBoxLayout(this);
    mainLayout->setContentsMargins(0, 0, 0, 0);

    // Header
    QWidget *header = new QWidget(this);
    header->setFixedHeight(36);
    header->setStyleSheet("background-color: #2d2d2d;");

    QHBoxLayout *headerLayout = new QHBoxLayout(header);
    headerLayout->setContentsMargins(12, 0, 12, 0);

    m_titleLabel = new QLabel(title, header);
    m_titleLabel->setStyleSheet("font-weight: bold; color: #ffffff;");

    QPushButton *copyBtn = new QPushButton("Copy", header);
    copyBtn->setFixedWidth(60);
    copyBtn->setStyleSheet("QPushButton { background-color: #007acc; color: white; border: none; border-radius: 3px; padding: 4px; }");

    connect(copyBtn, &QPushButton::clicked, this, [this]() {
        QApplication::clipboard()->setText(m_textView->toPlainText());
    });

    headerLayout->addWidget(m_titleLabel);
    headerLayout->addStretch();
    headerLayout->addWidget(copyBtn);

    mainLayout->addWidget(header);

    // Output Text Area
    m_textView = new QTextEdit(this);
    m_textView->setReadOnly(true);
    m_textView->setFont(QFont("Menlo", 11));
    m_textView->setStyleSheet("QTextEdit { background-color: #121212; color: #dcdcdc; border: none; padding: 8px; }");
    m_textView->setPlainText(content);

    mainLayout->addWidget(m_textView);
}