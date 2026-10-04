#pragma once

#include <QWidget>
#include <QPainter>
#include <QTimer>
#include <QKeyEvent>
#include <QMouseEvent>
#include <QResizeEvent>
#include <QFont>
#include <QColor>
#include <QStringList>

#include "TimeMachineHUDWidget.h"
#include "TimeMachineManager.h"
#include "DataInspectorDialog.h"

#include "../core/ScreenBuffer.h"
#include "../core/EbcdicCodec.h"
#include "../core/KeyboardState.h"

class TerminalWidget : public QWidget {
    Q_OBJECT

public:
    explicit TerminalWidget(QWidget *parent = nullptr);
    ~TerminalWidget() override = default;

    void setScreenBuffer(x3270::ScreenBuffer* screen, x3270::EbcdicCodec* codec, x3270::KeyboardState* kbd);
    QSize sizeHint() const override;

    void executeISPFCommand(const QString &command);
    QColor getCellColor(bool isProtected, bool isIntensified);
    QColor colorFor3270Code(uint8_t code);

    void setRulerVisible(bool visible);
    void toggleRuler();
    bool isRulerVisible() const { return m_showRuler; }

    void toggleTimeMachine();
    void captureCurrentScreenSnapshot();
    bool isTimeMachineActive() const { return m_isTimeMachineActive; }

    void copyToClipboard();
    void pasteFromClipboard();

protected:
    void paintEvent(QPaintEvent *event) override;
    void keyPressEvent(QKeyEvent *event) override;
    void mousePressEvent(QMouseEvent *event) override;
    void mouseMoveEvent(QMouseEvent *event) override;
    void mouseReleaseEvent(QMouseEvent *event) override;
    void resizeEvent(QResizeEvent *event) override;

private slots:
    void onTimeMachineSnapshotSelected(int index);
    void onTimeMachineDiffToggled(bool enabled);
    void onTimeMachineReturnToLive();
    void onTimeMachineSearchRequested(const QString &query, bool backward);

private:
    void load3270Font();
    void drawOIA(QPainter &painter, int effectiveWidth, int effectiveHeight);
    int offsetForPosition(const QPoint &pos) const;
    void updateHUDPosition();

    void showDataInspector(int offset);

    x3270::ScreenBuffer *m_screen{nullptr};
    x3270::EbcdicCodec *m_codec{nullptr};
    x3270::KeyboardState *m_kbd{nullptr};

    QFont m_font;
    int m_charWidth{10};
    int m_charHeight{20};
    int m_baseline{15};
    static constexpr int kOIARows = 2;

    bool m_showRuler{false};
    int m_selStart{-1};
    int m_selEnd{-1};
    bool m_isSelecting{false};

    QTimer *m_refreshTimer{nullptr};

    TimeMachineHUDWidget *m_timeMachineHUD{nullptr};
    bool m_isTimeMachineActive{false};
    bool m_isDiffActive{false};
    int m_currentTimeMachineIndex{0};

    void showDataInspectorAtOffset(int offset, const QPoint &globalPos);
    int offsetForPoint(const QPoint &pt) const;

    bool m_hasInspectedBlock{false};
    int m_inspectedMinRow{0};
    int m_inspectedMaxRow{0};
    int m_inspectedMinCol{0};
    int m_inspectedMaxCol{0};
};