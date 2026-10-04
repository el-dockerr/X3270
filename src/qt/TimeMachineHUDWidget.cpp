#include "TimeMachineHUDWidget.h"
#include "TimeMachineManager.h"
#include <QHBoxLayout>
#include <QVBoxLayout>
#include <QScrollArea>
#include <QDateTime>
#include <QGuiApplication>
#include <QPainter>
#include <QPainterPath>
#include <QPaintEvent>

TimeMachineHUDWidget::TimeMachineHUDWidget(QWidget *parent)
    : QWidget(parent) {

    setFixedHeight(42);
    setAttribute(Qt::WA_StyledBackground, true);
    
    setStyleSheet(
        "QPushButton { background-color: rgba(255, 255, 255, 25); color: #ffffff; border: 1px solid rgba(255, 255, 255, 40); border-radius: 4px; padding: 2px 8px; font-size: 11px; font-weight: 500; }"
        "QPushButton:hover { background-color: #007acc; border-color: #0099ff; color: #ffffff; }"
        "QPushButton:checked { background-color: #e67e22; border-color: #d35400; color: #ffffff; font-weight: bold; }"
        "QSlider::groove:horizontal { height: 4px; background: rgba(255, 255, 255, 40); border-radius: 2px; }"
        "QSlider::handle:horizontal { background: #007acc; width: 14px; margin: -5px 0; border-radius: 7px; border: 1px solid #ffffff; }"
        "QLineEdit { background-color: rgba(0, 0, 0, 180); color: #ffffff; border: 1px solid rgba(255, 255, 255, 50); border-radius: 4px; padding: 2px 6px; font-size: 11px; }"
        "QLabel { color: #ffffff; font-family: monospace; font-size: 11px; font-weight: bold; }"
        "QScrollArea { background: transparent; border: none; }"
    );

    setupUi();
}

void TimeMachineHUDWidget::setupUi() {
    QVBoxLayout *mainLayout = new QVBoxLayout(this);
    mainLayout->setContentsMargins(0, 0, 0, 0);

    QScrollArea *scrollArea = new QScrollArea(this);
    scrollArea->setWidgetResizable(true);
    scrollArea->setFrameShape(QFrame::NoFrame);
    scrollArea->setVerticalScrollBarPolicy(Qt::ScrollBarAlwaysOff);
    scrollArea->setHorizontalScrollBarPolicy(Qt::ScrollBarAlwaysOff);
    scrollArea->setStyleSheet("background: transparent; border: none;");

    QWidget *container = new QWidget(scrollArea);
    container->setObjectName("hudContainer");
    container->setStyleSheet("background: transparent;");

    m_container = new QWidget(scrollArea);
    m_container->setObjectName("hudContainer");
    m_container->setStyleSheet("background: transparent;");

    QHBoxLayout *layout = new QHBoxLayout(m_container);
    layout->setContentsMargins(12, 5, 12, 5);
    layout->setSpacing(6);

    m_slider = new QSlider(Qt::Horizontal, container);
    m_slider->setMinimum(0);
    m_slider->setMaximum(1);
    m_slider->setFixedWidth(130);

    m_infoLabel = new QLabel("--:--:-- (#0/0)", container);
    m_infoLabel->setAlignment(Qt::AlignCenter);

    m_prevPinBtn = new QPushButton("|<", container);
    m_prevPinBtn->setToolTip("Jump to Previous PIN");
    m_pinBtn = new QPushButton("PIN", container);
    m_pinBtn->setCheckable(true);
    m_pinBtn->setToolTip("Bookmark Current Frame");
    m_nextPinBtn = new QPushButton(">|", container);
    m_nextPinBtn->setToolTip("Jump to Next PIN");

    m_exportBtn = new QPushButton("Export", container);
    m_importBtn = new QPushButton("Import", container);

    m_searchField = new QLineEdit(container);
    m_searchField->setPlaceholderText("Search...");
    m_searchField->setFixedWidth(95);

    m_diffBtn = new QPushButton("DIFF", container);
    m_diffBtn->setCheckable(true);

    m_liveBtn = new QPushButton("LIVE >>", container);
    m_liveBtn->setStyleSheet("QPushButton { background-color: #27ae60; font-weight: bold; border-color: #2ecc71; color: #ffffff; } QPushButton:hover { background-color: #2ecc71; }");

    layout->addWidget(m_prevBtn);
    layout->addWidget(m_nextBtn);
    layout->addWidget(m_slider);
    layout->addWidget(m_infoLabel);
    layout->addWidget(m_prevPinBtn);
    layout->addWidget(m_pinBtn);
    layout->addWidget(m_nextPinBtn);
    layout->addWidget(m_exportBtn);
    layout->addWidget(m_importBtn);
    layout->addWidget(m_searchField);
    layout->addWidget(m_diffBtn);
    layout->addWidget(m_liveBtn);

    scrollArea->setWidget(m_container);
    mainLayout->addWidget(scrollArea);

    connect(m_slider, &QSlider::valueChanged, this, &TimeMachineHUDWidget::onSliderValueChanged);
    connect(m_prevBtn, &QPushButton::clicked, this, [this]() {
        if (m_slider->value() > 0) m_slider->setValue(m_slider->value() - 1);
    });
    connect(m_nextBtn, &QPushButton::clicked, this, [this]() {
        if (m_slider->value() < m_slider->maximum()) m_slider->setValue(m_slider->value() + 1);
    });

    connect(m_pinBtn, &QPushButton::clicked, this, [this]() { emit pinToggled(); });
    connect(m_prevPinBtn, &QPushButton::clicked, this, [this]() { emit jumpToPinRequested(false); });
    connect(m_nextPinBtn, &QPushButton::clicked, this, [this]() { emit jumpToPinRequested(true); });

    connect(m_exportBtn, &QPushButton::clicked, this, [this]() { emit exportRequested(); });
    connect(m_importBtn, &QPushButton::clicked, this, [this]() { emit importRequested(); });

    connect(m_searchField, &QLineEdit::returnPressed, this, &TimeMachineHUDWidget::onSearchReturnPressed);

    connect(m_diffBtn, &QPushButton::toggled, this, [this](bool checked) {
        m_isDiffActive = checked;
        emit diffToggled(checked);
    });

    connect(m_liveBtn, &QPushButton::clicked, this, [this]() { emit returnToLiveRequested(); });
}

void TimeMachineHUDWidget::paintEvent(QPaintEvent *event) {
    Q_UNUSED(event);
    QPainter painter(this);
    painter.setRenderHint(QPainter::Antialiasing, true);

    QRectF r = rect().adjusted(1, 1, -1, -1);
    QPainterPath path;
    path.addRoundedRect(r, 10, 10);

    // Sfondo traslucido scuro
    painter.fillPath(path, QColor(20, 20, 25, 235));

    // Bordo semi-trasparente
    painter.setPen(QPen(QColor(255, 255, 255, 70), 1.5));
    painter.drawPath(path);
}

void TimeMachineHUDWidget::onSliderValueChanged(int value) {
    emit snapshotSelected(value);
}

void TimeMachineHUDWidget::onSearchReturnPressed() {
    bool shiftPressed = QGuiApplication::keyboardModifiers().testFlag(Qt::ShiftModifier);
    emit searchRequested(m_searchField->text().trimmed(), !shiftPressed);
}

void TimeMachineHUDWidget::updateHUD(int count, int currentIndex, qint64 timestamp, bool isDiffActive) {
    if (count <= 0) return;

    m_slider->blockSignals(true);
    m_slider->setMaximum(count - 1);
    m_slider->setValue(currentIndex);
    m_slider->blockSignals(false);

    QString timeStr = QDateTime::fromMSecsSinceEpoch(timestamp * 1000).toString("HH:mm:ss");
    int baselineIdx = TimeMachineManager::instance().baselinePinIndex();

    if (isDiffActive) {
        if (baselineIdx >= 0) {
            m_infoLabel->setText(QString("%1 (DIFF #%2 vs PIN #%3)").arg(timeStr).arg(currentIndex + 1).arg(baselineIdx + 1));
        } else if (currentIndex > 0) {
            m_infoLabel->setText(QString("%1 (DIFF #%2 vs #%3)").arg(timeStr).arg(currentIndex + 1).arg(currentIndex));
        }
        m_infoLabel->setStyleSheet("color: #f39c12; font-weight: bold;");
    } else {
        m_infoLabel->setText(QString("%1 (#%2/%3)").arg(timeStr).arg(currentIndex + 1).arg(count));
        m_infoLabel->setStyleSheet("color: #ffffff; font-weight: bold;");
    }

    bool isPinned = TimeMachineManager::instance().isPinnedAtIndex(currentIndex);
    m_pinBtn->blockSignals(true);
    m_pinBtn->setChecked(isPinned);
    m_pinBtn->setText(isPinned ? "PINNED" : "PIN");
    m_pinBtn->blockSignals(false);

    adjustSize();
}

int TimeMachineHUDWidget::idealWidth() const {
    if (m_container) {
        // Restituisce la larghezza perfetta richiesta dai pulsanti
        return m_container->sizeHint().width();
    }
    return 800;
}