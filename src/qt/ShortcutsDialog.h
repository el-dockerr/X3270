#pragma once
#include <QDialog>
#include <QTableWidget>

class ShortcutsDialog : public QDialog {
    Q_OBJECT
public:
    explicit ShortcutsDialog(QWidget *parent = nullptr);
private:
    void addSection(const QString &title);
    void addShortcut(const QString &keys, const QString &desc);
    QTableWidget *m_table;
};