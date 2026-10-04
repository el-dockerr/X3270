#pragma once

#include <QDialog>
#include <QTextEdit>
#include <QLabel>

class OOBPopoverWidget : public QDialog {
    Q_OBJECT

public:
    explicit OOBPopoverWidget(const QString &title, const QString &content, QWidget *parent = nullptr);

private:
    QTextEdit *m_textView;
    QLabel *m_titleLabel;
};