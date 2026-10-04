#include "CommandDockWidget.h"
#include <QScrollArea>
#include <QFrame>
#include <QLabel>
#include <QSettings>
#include <QCompleter>
#include <QJsonDocument>
#include <QJsonArray>
#include <QJsonObject>
#include <QFile>
#include <QCoreApplication>

CommandDockWidget::CommandDockWidget(const QList<DXFastPath> &fastPaths, QWidget *parent)
    : QWidget(parent), m_fastPaths(fastPaths) {
    setFixedHeight(36);
    setStyleSheet(
        "QWidget { background-color: #252526; color: #cccccc; font-size: 11px; }"
        "QLineEdit { background-color: #3c3c3c; color: #ffffff; border: 1px solid #555555; border-radius: 3px; padding: 2px; }"
        "QPushButton { background-color: #333333; color: #ffffff; border: 1px solid #454545; border-radius: 3px; padding: 3px 8px; white-space: nowrap; }"
        "QPushButton:hover { background-color: #444444; }"
        "QPushButton:checked { background-color: #007acc; border-color: #0099ff; color: #ffffff; font-weight: bold; }"
        "QComboBox { background-color: #333333; color: #ffffff; border: 1px solid #454545; border-radius: 3px; padding: 2px; }"
    );

    setupUi();
}

void CommandDockWidget::setupUi() {
    QVBoxLayout *rootLayout = new QVBoxLayout(this);
    rootLayout->setContentsMargins(0, 0, 0, 0);

    QScrollArea *scrollArea = new QScrollArea(this);
    scrollArea->setWidgetResizable(true);
    scrollArea->setFrameShape(QFrame::NoFrame);
    scrollArea->setVerticalScrollBarPolicy(Qt::ScrollBarAlwaysOff);
    scrollArea->setHorizontalScrollBarPolicy(Qt::ScrollBarAlwaysOff);

    QWidget *container = new QWidget(scrollArea);
    QHBoxLayout *mainLayout = new QHBoxLayout(container);
    mainLayout->setContentsMargins(8, 4, 8, 4);
    mainLayout->setSpacing(8);
    mainLayout->setSizeConstraint(QLayout::SetMinAndMaxSize);

    // 1. Group Link
    m_linkGroupCombo = new QComboBox(container);
    m_linkGroupCombo->addItems({"  Only This", "  Group A", "  Group B"});
    m_linkGroupCombo->setMinimumWidth(85);
    mainLayout->addWidget(m_linkGroupCombo);

    connect(m_linkGroupCombo, QOverload<int>::of(&QComboBox::currentIndexChanged), this, [this](int idx) {
        if (idx == 1) m_linkGroup = "GroupA";
        else if (idx == 2) m_linkGroup = "GroupB";
        else m_linkGroup = "";
    });

    QFrame *sep1 = new QFrame(container);
    sep1->setFrameShape(QFrame::VLine);
    sep1->setStyleSheet("color: #444444;");
    mainLayout->addWidget(sep1);

    // 2. Navigation & Fast Paths
    m_fastPathsLayout = new QHBoxLayout();
    m_fastPathsLayout->setSpacing(4);

    QStringList navTitles = {"  Prev", "Next  ", "List  ", "New +"};
    QStringList navCmds = {"SWAP PREV", "SWAP NEXT", "SWAP LIST", "START"};

    for (int i = 0; i < navTitles.size(); ++i) {
        QPushButton *btn = new QPushButton(navTitles[i], container);
        btn->setProperty("cmd", navCmds[i]);
        connect(btn, &QPushButton::clicked, this, &CommandDockWidget::onIspfButtonClicked);
        m_fastPathsLayout->addWidget(btn);
    }

    QFrame *sep2 = new QFrame(container);
    sep2->setFrameShape(QFrame::VLine);
    sep2->setStyleSheet("color: #444444;");
    m_fastPathsLayout->addWidget(sep2);

    loadFastPaths();
    mainLayout->addLayout(m_fastPathsLayout);

    // 3. Campo ISPF
    m_ispfField = new QLineEdit(container);
    m_ispfField->setPlaceholderText("ISPF Cmd...");
    m_ispfField->setMinimumWidth(90);
    mainLayout->addWidget(m_ispfField);

    connect(m_ispfField, &QLineEdit::returnPressed, this, &CommandDockWidget::onIspfReturnPressed);

    // 4. Ruler Button (Pulsante a due stati interattivo)
    m_rulerBtn = new QPushButton("  Ruler", container);
    m_rulerBtn->setCheckable(true);
    m_rulerBtn->setToolTip("Toggle Crosshair Ruler");
    connect(m_rulerBtn, &QPushButton::toggled, this, &CommandDockWidget::toggleRulerRequested);
    mainLayout->addWidget(m_rulerBtn);

    // 5. Time-Machine Button
    m_timeMachineBtn = new QPushButton("  Time-Machine", container);
    m_timeMachineBtn->setToolTip("Toggle Screen History (Cmd+Opt+T)");
    connect(m_timeMachineBtn, &QPushButton::clicked, this, [this]() { emit toggleTimeMachineRequested(); });
    mainLayout->addWidget(m_timeMachineBtn);

    mainLayout->addStretch();

    // 6. Campo SSH/OOB
    QLabel *oobLabel = new QLabel("SSH/OOB:", container);
    m_oobField = new QLineEdit(container);
    m_oobField->setPlaceholderText("TSO / System...");
    m_oobField->setMinimumWidth(200);

    QStringList completions;
    QFile cmdFile(":/commands.json");
    if (!cmdFile.open(QIODevice::ReadOnly)) {
        cmdFile.setFileName(QCoreApplication::applicationDirPath() + "/../Resources/commands.json");
    }
    if (cmdFile.open(QIODevice::ReadOnly)) {
        QJsonDocument doc = QJsonDocument::fromJson(cmdFile.readAll());
        QJsonArray arr = doc.array();
        for (const auto &val : arr) {
            completions.append(val.toObject()["cmd"].toString());
        }
    }
    QCompleter *completer = new QCompleter(completions, this);
    completer->setCaseSensitivity(Qt::CaseInsensitive);
    m_oobField->setCompleter(completer);

    mainLayout->addWidget(oobLabel);
    mainLayout->addWidget(m_oobField);

    connect(m_oobField, &QLineEdit::returnPressed, this, &CommandDockWidget::onOobReturnPressed);

    scrollArea->setWidget(container);
    rootLayout->addWidget(scrollArea);
}

void CommandDockWidget::loadFastPaths() {
    QList<DXFastPath> pathsToLoad = m_fastPaths;
    
    // IL FALLBACK SALVAGENTE ESATTO
    if (pathsToLoad.isEmpty()) {
        pathsToLoad = {
            {"=3.4", "=3.4"}, {"=3.2", "=3.2"}, 
            {"SDSF", "=S;ST"}, {"LOG", "=S;LOG"}, {"TIME", "/D T"}
        };
    }
    
    // Attenzione a usare il parent corretto (es. m_container o container) in cui inserisci i bottoni
    // Recupera il container padre dal layout, oppure rendi m_container globale. 
    // Assumendo che m_fastPathsLayout sia già associato alla UI:
    for (const auto &fp : pathsToLoad) {
        QPushButton *btn = new QPushButton(fp.title, this); 
        btn->setProperty("cmd", fp.cmd);
        connect(btn, &QPushButton::clicked, this, &CommandDockWidget::onIspfButtonClicked);
        m_fastPathsLayout->addWidget(btn);
    }
}

void CommandDockWidget::onIspfButtonClicked() {
    QPushButton *btn = qobject_cast<QPushButton*>(sender());
    if (btn) {
        QString cmd = btn->property("cmd").toString();
        emit ispfCommandRequested(cmd, m_linkGroup);
    }
}

void CommandDockWidget::onIspfReturnPressed() {
    QString text = m_ispfField->text().trimmed();
    if (!text.isEmpty()) {
        emit ispfCommandRequested(text, m_linkGroup);
        m_ispfField->clear();
    }
}

void CommandDockWidget::onOobReturnPressed() {
    QString text = m_oobField->text().trimmed();
    if (!text.isEmpty()) {
        emit oobCommandRequested(text, m_linkGroup);
        m_oobField->clear();
    }
}