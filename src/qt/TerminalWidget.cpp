#include "TerminalWidget.h"
#include <QPointer>
#include <QFontDatabase>
#include <QPaintEvent>
#include <QCoreApplication>
#include <QGuiApplication>
#include <QClipboard>
#include <QFile>
#include <QDir>
#include <QSettings>

#include <QMouseEvent>
#include <QRegularExpression>
#include <QMenu>

#include <algorithm>
#include <utility>

TerminalWidget::TerminalWidget(QWidget *parent)
    : QWidget(parent) {
    
    setFocusPolicy(Qt::StrongFocus);

    QPalette pal = palette();
    pal.setColor(QPalette::Window, Qt::black);
    setAutoFillBackground(true);
    setPalette(pal);

    load3270Font();

    m_refreshTimer = new QTimer(this);
    connect(m_refreshTimer, &QTimer::timeout, this, [this]() {
        if (m_screen) update();
    });
    m_refreshTimer->start(33);
}

void TerminalWidget::load3270Font() {
    static QString loadedFamilyName;
    static bool fontAttempted = false;

    if (!fontAttempted) {
        fontAttempted = true;
        QStringList searchPaths = {
            QCoreApplication::applicationDirPath() + "/../Resources/fonts/3270-Regular.otf",
            QCoreApplication::applicationDirPath() + "/fonts/3270-Regular.otf",
            QCoreApplication::applicationDirPath() + "/3270-Regular.otf",
            "./fonts/3270-Regular.otf"
        };

        for (const QString &path : searchPaths) {
            if (QFile::exists(path)) {
                int id = QFontDatabase::addApplicationFont(path);
                if (id != -1) {
                    QStringList families = QFontDatabase::applicationFontFamilies(id);
                    if (!families.isEmpty()) {
                        loadedFamilyName = families.first();
                        break;
                    }
                }
            }
        }
    }

    if (!loadedFamilyName.isEmpty()) {
        m_font = QFont(loadedFamilyName, 15);
    } else {
        m_font = QFont("Menlo", 14);
        if (!m_font.exactMatch()) {
            m_font = QFont("Courier New", 14);
        }
    }

    m_font.setStyleHint(QFont::Monospace);
    m_font.setFixedPitch(true);
    m_font.setStyleStrategy(QFont::PreferAntialias);

    QFontMetrics metrics(m_font);
    m_charWidth = metrics.horizontalAdvance('M');
    if (m_charWidth <= 0) m_charWidth = 10;

    m_charHeight = metrics.height() + 1;
    if (m_charHeight <= 1) m_charHeight = 20;
    m_baseline = metrics.ascent();
}

void TerminalWidget::setScreenBuffer(x3270::ScreenBuffer* screen, x3270::EbcdicCodec* codec, x3270::KeyboardState* kbd) {
    m_screen = screen;
    m_codec = codec;
    m_kbd = kbd;
    update();
}

QSize TerminalWidget::sizeHint() const {
    int cols = (m_screen && m_screen->cols() > 0) ? m_screen->cols() : 80;
    int rows = (m_screen && m_screen->rows() > 0) ? m_screen->rows() : 24;
    return QSize(cols * m_charWidth, (rows + kOIARows) * m_charHeight);
}

void TerminalWidget::setRulerVisible(bool visible) {
    m_showRuler = visible;
    update();
}

void TerminalWidget::toggleRuler() {
    setRulerVisible(!m_showRuler);
}

void TerminalWidget::executeISPFCommand(const QString &command) {
    if (command.isEmpty() || !m_kbd || !m_screen || !m_codec) return;

    QString finalCommand = command.trimmed();

    QSettings settings("DX3270", "CrossPlatform");
    QVariantList fastPaths = settings.value("FastPaths").toList();
    for (const QVariant &var : fastPaths) {
        QVariantMap map = var.toMap();
        QString shortcut = map["cmd"].toString();
        if (shortcut.startsWith("=") && finalCommand == shortcut.mid(1)) {
            finalCommand = shortcut;
            break;
        }
    }

    QStringList tsoCommands = {"TIME", "LISTALC", "LISTDS", "STATUS", "ALLOC", "FREE", "SUBMIT"};
    QString upper = finalCommand.toUpper();
    for (const QString &tso : tsoCommands) {
        if (upper == tso || upper.startsWith(tso + " ")) {
            if (!upper.startsWith("TSO ") && !upper.startsWith("=")) {
                finalCommand = "TSO " + finalCommand;
            }
            break;
        }
    }

    int position = -1;
    int size = m_screen->size();
    uint8_t equals = m_codec->fromAscii('=');
    uint8_t greater = m_codec->fromAscii('>');

    for (int index = 0; index < size - 4; index++) {
        if (m_screen->at(index).ch == equals &&
            m_screen->at(index + 1).ch == equals &&
            m_screen->at(index + 2).ch == equals &&
            m_screen->at(index + 3).ch == greater) {
            position = index + 4;
            if (position < size && m_screen->at(position).isFA) position++;
            break;
        }
    }

    if (position >= 0) {
        m_screen->setCursor(position);
    } else {
        m_kbd->handleHome();
    }

    m_kbd->handleEraseEOF();
    std::string asciiCmd = finalCommand.toStdString();
    for (char ch : asciiCmd) {
        m_kbd->handleChar(static_cast<uint16_t>(ch));
    }
    m_kbd->handleEnter();
    update();
}

QColor TerminalWidget::getCellColor(bool isProtected, bool isIntensified) {
    if (isProtected) return isIntensified ? QColor(217, 217, 217) : QColor(56, 133, 255);
    return isIntensified ? Qt::red : QColor(51, 217, 51);
}

QColor TerminalWidget::colorFor3270Code(uint8_t code) {
    switch (code) {
        case 0xF1: return QColor(56, 133, 255);
        case 0xF2: return QColor(255, 84, 84);
        case 0xF3: return QColor(255, 112, 255);
        case 0xF4: return QColor(51, 217, 51);
        case 0xF5: return QColor(51, 217, 217);
        case 0xF6: return QColor(217, 217, 51);
        case 0xF7: return QColor(217, 217, 217);
        default:   return QColor();
    }
}

void TerminalWidget::paintEvent(QPaintEvent *event) {
    Q_UNUSED(event);

    if (m_isTimeMachineActive) {
        const ScreenSnapshot *snap = TimeMachineManager::instance().snapshotAt(m_currentTimeMachineIndex);
        if (!snap) return;

        QPainter painter(this);
        painter.setRenderHint(QPainter::TextAntialiasing, true);
        painter.setFont(m_font);

        int cols = snap->cols;
        int rows = snap->rows;
        qreal scaleX = static_cast<qreal>(width()) / (cols * m_charWidth);
        qreal scaleY = static_cast<qreal>(height()) / ((rows + kOIARows) * m_charHeight);

        painter.save();
        painter.scale(scaleX, scaleY);

        const ushort *chars = reinterpret_cast<const ushort*>(snap->characterBuffer.constData());
        const uint32_t *attrs = reinterpret_cast<const uint32_t*>(snap->attributeBuffer.constData());

        QList<int> diffMap;
        if (m_isDiffActive) {
            int baseIdx = TimeMachineManager::instance().baselinePinIndex();
            const ScreenSnapshot *baseSnap = (baseIdx >= 0) ? TimeMachineManager::instance().snapshotAt(baseIdx)
                                                             : TimeMachineManager::instance().snapshotAt(m_currentTimeMachineIndex - 1);
            if (baseSnap) {
                diffMap = TimeMachineManager::instance().compareSnapshots(*snap, *baseSnap);
            }
        }

        int r1 = (m_selStart != -1 && m_selEnd != -1) ? std::min(m_selStart / cols, m_selEnd / cols) : -1;
        int r2 = (m_selStart != -1 && m_selEnd != -1) ? std::max(m_selStart / cols, m_selEnd / cols) : -1;
        int c1 = (m_selStart != -1 && m_selEnd != -1) ? std::min(m_selStart % cols, m_selEnd % cols) : -1;
        int c2 = (m_selStart != -1 && m_selEnd != -1) ? std::max(m_selStart % cols, m_selEnd % cols) : -1;

        for (int r = 0; r < rows; ++r) {
            for (int c = 0; c < cols; ++c) {
                int pos = r * cols + c;
                ushort uc = chars[pos];
                int x = c * m_charWidth;
                int y = r * m_charHeight;

                bool isModified = (!diffMap.isEmpty() && diffMap[pos] == CellDiffModified);
                bool isSelected = (m_selStart != -1 && r >= r1 && r <= r2 && c >= c1 && c <= c2);

                QColor fgColor = QColor(51, 217, 51);
                QColor bgColor = Qt::black;

                if (attrs) {
                    uint32_t packed = attrs[pos];
                    uint8_t colorType = (packed >> 16) & 0xFF;
                    uint8_t colorVal = (packed >> 8) & 0xFF;
                    uint8_t activeAttr = packed & 0xFF;

                    if (colorType == 1) {
                        fgColor = colorFor3270Code(colorVal);
                    } else {
                        bool isProtected = (activeAttr & 0x20) != 0;
                        bool isIntensified = (activeAttr & 0x08) != 0;
                        fgColor = getCellColor(isProtected, isIntensified);
                    }
                }

                if (isModified) {
                    bgColor = QColor(115, 51, 0, 200);
                    fgColor = QColor(255, 235, 80);
                }

                if (isSelected) {
                    bgColor = QColor(38, 79, 120);
                    fgColor = Qt::white;
                }

                if (bgColor != Qt::black) painter.fillRect(x, y, m_charWidth, m_charHeight, bgColor);
                if (uc > 0x20) {
                    painter.setPen(fgColor);
                    painter.drawText(x, y + m_baseline, QString(QChar(uc)));
                }
            }
        }

        // --- Disegno del Cursore Storico ---
        if (snap->cursorRow >= 0 && snap->cursorCol >= 0) {
            int cx = snap->cursorCol * m_charWidth; 
            int cy = snap->cursorRow * m_charHeight;
            QRectF cursorRect(cx, cy, m_charWidth, m_charHeight);

            painter.fillRect(cursorRect, QColor(51, 217, 51, 150));

            int pos = snap->cursorRow * snap->cols + snap->cursorCol;
            if (pos < snap->rows * snap->cols) {
                ushort uc = chars[pos];
                if (uc > 0x20) {
                    painter.setPen(Qt::black);
                    painter.drawText(QPointF(cx, cy + m_baseline), QString(QChar(uc)));
                }
            }
        }

        drawOIA(painter, cols * m_charWidth, (rows + kOIARows) * m_charHeight);
        painter.restore();
        return;
    }

    if (!m_screen || !m_codec) return;

    QPainter painter(this);
    painter.setRenderHint(QPainter::TextAntialiasing, true);
    painter.setFont(m_font);

    int cols = std::max(1, m_screen->cols());
    int rows = std::max(1, m_screen->rows());

    int prefWidth = cols * m_charWidth;
    int prefHeight = (rows + kOIARows) * m_charHeight;

    if (prefWidth <= 0 || prefHeight <= 0) return;

    qreal scaleX = static_cast<qreal>(width()) / prefWidth;
    qreal scaleY = static_cast<qreal>(height()) / prefHeight;

    painter.save();
    painter.scale(scaleX, scaleY);

    int r1 = (m_selStart != -1 && m_selEnd != -1) ? std::min(m_selStart / cols, m_selEnd / cols) : -1;
    int r2 = (m_selStart != -1 && m_selEnd != -1) ? std::max(m_selStart / cols, m_selEnd / cols) : -1;
    int c1 = (m_selStart != -1 && m_selEnd != -1) ? std::min(m_selStart % cols, m_selEnd % cols) : -1;
    int c2 = (m_selStart != -1 && m_selEnd != -1) ? std::max(m_selStart % cols, m_selEnd % cols) : -1;

    for (int r = 0; r < rows; ++r) {
        for (int c = 0; c < cols; ++c) {
            int pos = r * cols + c;
            if (pos >= m_screen->size()) continue;

            const auto& cell = m_screen->at(pos);
            if (cell.isNonDisplay() || cell.isFA) continue;

            int x = c * m_charWidth;
            int y = r * m_charHeight;

            QColor fgColor;
            QColor bgColor = Qt::black;

            if (cell.fgColor >= 0xF1 && cell.fgColor <= 0xF7) { 
                fgColor = colorFor3270Code(cell.fgColor);
            } else {
                int faIdx = m_screen->findFieldStart(pos);
                uint8_t activeAttr = (faIdx >= 0) ? m_screen->at(faIdx).attr : cell.attr;
                bool isProtected = (activeAttr & 0x20) != 0;
                bool isIntensified = (activeAttr & 0x08) != 0;
                fgColor = getCellColor(isProtected, isIntensified);
            }

            if (cell.highlight == 0xF2) std::swap(fgColor, bgColor);

            bool isSelected = (m_selStart != -1 && r >= r1 && r <= r2 && c >= c1 && c <= c2);
            if (isSelected) {
                bgColor = QColor(38, 79, 120);
                fgColor = Qt::white;
            }

            if (bgColor != Qt::black) {
                painter.fillRect(x, y, m_charWidth, m_charHeight, bgColor);
            }

            uint16_t uc = m_codec->toUnicode(cell.ch);
            if (uc >= 0x20) {
                painter.setPen(fgColor);
                painter.drawText(x, y + m_baseline, QString(QChar(uc)));
            }

            if (cell.highlight == 0xF4) {
                painter.setPen(fgColor);
                painter.drawLine(x, y + m_charHeight - 1, x + m_charWidth, y + m_charHeight - 1);
            }
        }
    }

    // Cursor
    int cursorPos = m_screen->cursorPos();
    int curR = cursorPos / cols;
    int curC = cursorPos % cols;
    painter.fillRect(curC * m_charWidth, curR * m_charHeight, m_charWidth, m_charHeight, QColor(51, 217, 51, 150));

    // Crosshair Ruler Overlay
    if (m_showRuler) {
        qreal lineX = curC * m_charWidth;
        qreal lineY = (curR + 1) * m_charHeight;
        qreal textWidth = cols * m_charWidth;
        qreal textAreaHeight = rows * m_charHeight;

        QPen rulerPen(QColor(255, 50, 50, 180), 2);
        rulerPen.setCosmetic(true); 
        painter.setPen(rulerPen);

        // Linea Orizzontale
        painter.drawLine(QPointF(0, lineY), QPointF(textWidth, lineY));

        // Linea Verticale
        painter.drawLine(QPointF(lineX, 0), QPointF(lineX, textAreaHeight));
    }

    // Bounding Box per l'area esaminata dal Data Inspector
    if (m_hasInspectedBlock && m_screen) {
        QPen boxPen(Qt::red, 2);
        boxPen.setCosmetic(true);
        painter.setPen(boxPen);

        qreal boxX = m_inspectedMinCol * m_charWidth;
        qreal boxY = m_inspectedMinRow * m_charHeight;
        qreal boxW = (m_inspectedMaxCol - m_inspectedMinCol + 1) * m_charWidth;
        qreal boxH = (m_inspectedMaxRow - m_inspectedMinRow + 1) * m_charHeight;

        painter.drawRect(QRectF(boxX, boxY, boxW, boxH));
    }

    drawOIA(painter, cols * m_charWidth, (rows + kOIARows) * m_charHeight);

    painter.restore();
}

void TerminalWidget::drawOIA(QPainter &painter, int effectiveWidth, int effectiveHeight) {
    Q_UNUSED(effectiveHeight);
    int rows = m_screen->rows();
    int oiaY = rows * m_charHeight;

    painter.setPen(QColor(100, 100, 100));
    painter.drawLine(0, oiaY, effectiveWidth, oiaY);

    painter.setPen(QColor(150, 150, 150));
    int textY = oiaY + m_baseline + 2;

    QString statusStr = "";
    if (m_kbd) {
        switch (m_kbd->lockReason()) {
            case x3270::KeyboardState::LockReason::None:        statusStr = ""; break;
            case x3270::KeyboardState::LockReason::Connecting:  statusStr = "Connecting..."; break;
            case x3270::KeyboardState::LockReason::System:      statusStr = "X SYS"; break;
            case x3270::KeyboardState::LockReason::OErr:        statusStr = "X OERR"; break;
        }
        if (m_kbd->isInsertMode()) statusStr += " ^";
    }
    painter.drawText(4, textY, statusStr);

    QString versionStr = "DX3270 v1.7.6 build 1 — © 2026 Swen Skalski";
    QFont dimFont = m_font;
    dimFont.setPointSize(std::max(8, m_font.pointSize() - 2));
    painter.setFont(dimFont);
    painter.setPen(QColor(80, 80, 80));
    
    int vWidth = painter.fontMetrics().horizontalAdvance(versionStr);
    int vX = (effectiveWidth - vWidth) / 2;
    painter.drawText(vX, oiaY + m_charHeight + m_baseline, versionStr);

    painter.setFont(m_font);
    painter.setPen(QColor(150, 150, 150));

    int pos = m_screen->cursorPos();
    int cols = m_screen->cols();
    QString cursorInfo = QString("%1/%2")
                            .arg(pos / cols + 1, 3, 10, QChar('0'))
                            .arg(pos % cols + 1, 3, 10, QChar('0'));
    
    int textWidth = painter.fontMetrics().horizontalAdvance(cursorInfo);
    painter.drawText(effectiveWidth - textWidth - 8, textY, cursorInfo);
}

void TerminalWidget::captureCurrentScreenSnapshot() {
    if (m_isTimeMachineActive || !m_screen || !m_codec) return;

    int rows = m_screen->rows();
    int cols = m_screen->cols();
    if (rows <= 0 || cols <= 0) return;

    QList<ushort> chars(rows * cols, ' ');
    QList<uint32_t> attrs(rows * cols, 0);

    for (int r = 0; r < rows; ++r) {
        for (int c = 0; c < cols; ++c) {
            int pos = r * cols + c;
            const auto &cell = m_screen->at(pos);
            uint16_t uc = m_codec->toUnicode(cell.ch);
            chars[pos] = (uc >= 0x20) ? uc : ' ';

            uint8_t colorVal = cell.fgColor;
            uint8_t colorType = (colorVal != 0x00) ? 1 : 2;

            int faIdx = m_screen->findFieldStart(pos);
            uint8_t activeAttr = (faIdx >= 0) ? m_screen->at(faIdx).attr : cell.attr;

            attrs[pos] = (static_cast<uint32_t>(colorType) << 16) | (static_cast<uint32_t>(colorVal) << 8) | (activeAttr & 0xFF);
        }
    }

    int curPos = m_screen->cursorPos();
    TimeMachineManager::instance().captureSnapshot(rows, cols, chars.constData(), attrs.constData(), curPos / cols, curPos % cols);
}

void TerminalWidget::toggleTimeMachine() {
    if (m_isTimeMachineActive) {
        onTimeMachineReturnToLive();
        return;
    }

    captureCurrentScreenSnapshot();

    int count = TimeMachineManager::instance().snapshotCount();
    if (count == 0) return;

    m_isTimeMachineActive = true;
    m_currentTimeMachineIndex = count - 1;

    if (!m_timeMachineHUD) {
        m_timeMachineHUD = new TimeMachineHUDWidget(this);

        connect(m_timeMachineHUD, &TimeMachineHUDWidget::snapshotSelected, this, &TerminalWidget::onTimeMachineSnapshotSelected);
        connect(m_timeMachineHUD, &TimeMachineHUDWidget::diffToggled, this, &TerminalWidget::onTimeMachineDiffToggled);
        connect(m_timeMachineHUD, &TimeMachineHUDWidget::returnToLiveRequested, this, &TerminalWidget::onTimeMachineReturnToLive);
        connect(m_timeMachineHUD, &TimeMachineHUDWidget::searchRequested, this, &TerminalWidget::onTimeMachineSearchRequested);

        connect(m_timeMachineHUD, &TimeMachineHUDWidget::pinToggled, this, [this]() {
            TimeMachineManager::instance().togglePinAtIndex(m_currentTimeMachineIndex);
            if (const auto *snap = TimeMachineManager::instance().snapshotAt(m_currentTimeMachineIndex)) {
                m_timeMachineHUD->updateHUD(TimeMachineManager::instance().snapshotCount(),
                                            m_currentTimeMachineIndex,
                                            snap->timestamp,
                                            m_isDiffActive);
            }
        });

        connect(m_timeMachineHUD, &TimeMachineHUDWidget::jumpToPinRequested, this, [this](bool forward) {
            int target = forward ? TimeMachineManager::instance().nextPinnedIndexAfter(m_currentTimeMachineIndex)
                                 : TimeMachineManager::instance().prevPinnedIndexBefore(m_currentTimeMachineIndex);
            
            if (target != -1) {
                onTimeMachineSnapshotSelected(target);
            }
        });
    }

    m_timeMachineHUD->show();
    m_timeMachineHUD->raise();

    if (const auto *snap = TimeMachineManager::instance().snapshotAt(m_currentTimeMachineIndex)) {
        m_timeMachineHUD->updateHUD(count, m_currentTimeMachineIndex, snap->timestamp, m_isDiffActive);
    }

    updateHUDPosition();
    update();
}

void TerminalWidget::updateHUDPosition() {
    if (m_timeMachineHUD && m_timeMachineHUD->isVisible()) {
        int maxWidth = std::max(100, width() - 20);
        
        int idealW = m_timeMachineHUD->idealWidth();
        int actualWidth = std::min(maxWidth, idealW);

        m_timeMachineHUD->setFixedSize(actualWidth, 42);

        int hudX = (width() - actualWidth) / 2;
        int hudY = height() - 42 - 40;
        m_timeMachineHUD->move(std::max(10, hudX), std::max(10, hudY));
        m_timeMachineHUD->raise();
    }
}

void TerminalWidget::resizeEvent(QResizeEvent *event) {
    QWidget::resizeEvent(event);
    updateHUDPosition();
}

void TerminalWidget::onTimeMachineSnapshotSelected(int index) {
    m_currentTimeMachineIndex = index;
    const auto *snap = TimeMachineManager::instance().snapshotAt(index);
    if (snap && m_timeMachineHUD) {
        m_timeMachineHUD->updateHUD(TimeMachineManager::instance().snapshotCount(), index, snap->timestamp, m_isDiffActive);
    }
    update();
}

void TerminalWidget::onTimeMachineDiffToggled(bool enabled) {
    m_isDiffActive = enabled;
    if (enabled && TimeMachineManager::instance().isPinnedAtIndex(m_currentTimeMachineIndex)) {
        TimeMachineManager::instance().setBaselinePinIndex(m_currentTimeMachineIndex);
    } else if (!enabled) {
        TimeMachineManager::instance().setBaselinePinIndex(-1);
    }
    onTimeMachineSnapshotSelected(m_currentTimeMachineIndex);
}

void TerminalWidget::onTimeMachineReturnToLive() {
    m_isTimeMachineActive = false;
    m_isDiffActive = false;
    if (m_timeMachineHUD) m_timeMachineHUD->hide();
    update();
}

void TerminalWidget::onTimeMachineSearchRequested(const QString &query, bool backward) {
    int result = TimeMachineManager::instance().searchHistory(query, m_currentTimeMachineIndex, backward);
    if (result != -1) {
        onTimeMachineSnapshotSelected(result);
    }
}

// Manteniamo questa firma di convenienza che reindirizza al nuovo calcolo
int TerminalWidget::offsetForPosition(const QPoint &pos) const {
    return offsetForPoint(pos);
}

int TerminalWidget::offsetForPoint(const QPoint &pt) const {
    if (!m_screen) return -1;

    int cols = std::max(1, m_screen->cols());
    int rows = std::max(1, m_screen->rows());

    int prefWidth = cols * m_charWidth;
    int prefHeight = (rows + kOIARows) * m_charHeight;

    if (prefWidth <= 0 || prefHeight <= 0) return -1;

    qreal scaleX = static_cast<qreal>(width()) / prefWidth;
    qreal scaleY = static_cast<qreal>(height()) / prefHeight;

    qreal realX = pt.x() / scaleX;
    qreal realY = pt.y() / scaleY;

    int col = static_cast<int>(realX / m_charWidth);
    int row = static_cast<int>(realY / m_charHeight);

    if (col < 0 || col >= cols || row < 0 || row >= rows) {
        return -1;
    }

    return (row * cols) + col;
}

void TerminalWidget::mousePressEvent(QMouseEvent *event) {
    // Ignora i clic con tasto non sinistro (per evitare reset accidentali)
    if (event->button() != Qt::LeftButton) {
        QWidget::mousePressEvent(event);
        return;
    }

    int offset = offsetForPoint(event->pos());
    if (offset < 0) {
        m_selStart = m_selEnd = -1;
        m_hasInspectedBlock = false;
        update();
        return;
    }

    // --- OPTION/ALT + CLICK = Data Inspector ---
    if ((event->modifiers() & Qt::AltModifier) && !m_isTimeMachineActive) {
        bool insideSelection = false;
        
        if (m_selStart >= 0 && m_selEnd >= 0 && m_screen) {
            int cols = m_screen->cols();
            int r1 = m_selStart / cols, c1 = m_selStart % cols;
            int r2 = m_selEnd / cols, c2 = m_selEnd % cols;
            int minR = std::min(r1, r2), maxR = std::max(r1, r2);
            int minC = std::min(c1, c2), maxC = std::max(c1, c2);
            int clickR = offset / cols, clickC = offset % cols;
            
            insideSelection = (clickR >= minR && clickR <= maxR && clickC >= minC && clickC <= maxC);
        }
        
        if (!insideSelection) {
            if (m_screen) m_screen->setCursor(offset);
            m_selStart = offset;
            m_selEnd = offset;
            update();
        }
        
        showDataInspectorAtOffset(offset, event->globalPosition().toPoint());
        return;
    }

    // --- Click Normale (Selezione Base) ---
    if (!m_isTimeMachineActive && m_screen) {
        m_screen->setCursor(offset);
    }
    
    m_selStart = offset;
    m_selEnd = offset;
    m_hasInspectedBlock = false;
    update();
}

void TerminalWidget::mouseMoveEvent(QMouseEvent *event) {
    // Aggiorna la selezione solo se il tasto sinistro è attualmente premuto
    if (event->buttons() & Qt::LeftButton) {
        if (m_selStart == -1) return;
        
        int offset = offsetForPoint(event->pos());
        if (offset >= 0 && offset != m_selEnd) {
            m_selEnd = offset;
            update();
        }
    } else {
        QWidget::mouseMoveEvent(event);
    }
}

void TerminalWidget::mouseReleaseEvent(QMouseEvent *event) {
    Q_UNUSED(event);
    // Non è strettamente necessario resettare variabili se ci basiamo sui flag dei buttons nel Move,
    // ma manteniamo il metodo per eventuale estendibilità futura.
}

void TerminalWidget::showDataInspector(int offset) {
    // (Metodo di retrocompatibilità mantenuto - reindirizza al nuovo se chiamato dal codice legacy)
    showDataInspectorAtOffset(offset, QCursor::pos());
}

void TerminalWidget::copyToClipboard() {
    if (m_selStart == -1 || m_selEnd == -1) return;

    int cols = (m_screen && m_screen->cols() > 0) ? m_screen->cols() : 80;
    int r1 = std::min(m_selStart / cols, m_selEnd / cols);
    int r2 = std::max(m_selStart / cols, m_selEnd / cols);
    int c1 = std::min(m_selStart % cols, m_selEnd % cols);
    int c2 = std::max(m_selStart % cols, m_selEnd % cols);

    QString text = "";

    if (m_isTimeMachineActive) {
        const ScreenSnapshot *snap = TimeMachineManager::instance().snapshotAt(m_currentTimeMachineIndex);
        if (!snap) return;
        const ushort *chars = reinterpret_cast<const ushort*>(snap->characterBuffer.constData());

        for (int r = r1; r <= r2; ++r) {
            for (int c = c1; c <= c2; ++c) {
                int pos = r * snap->cols + c;
                ushort uc = chars[pos];
                text += (uc >= 0x20) ? QChar(uc) : ' ';
            }
            if (r < r2) text += "\n";
        }
    } else if (m_screen && m_codec) {
        for (int r = r1; r <= r2; ++r) {
            for (int c = c1; c <= c2; ++c) {
                int pos = r * cols + c;
                const auto &cell = m_screen->at(pos);
                if (cell.isFA || cell.isNonDisplay() || cell.ch == 0x00) {
                    text += " ";
                } else {
                    uint16_t uc = m_codec->toUnicode(cell.ch);
                    text += (uc >= 0x20) ? QChar(uc) : ' ';
                }
            }
            if (r < r2) text += "\n";
        }
    }

    QGuiApplication::clipboard()->setText(text);
}

void TerminalWidget::pasteFromClipboard() {
    if (!m_kbd) return;

    QString text = QGuiApplication::clipboard()->text();
    if (text.isEmpty()) return;

    int startCol = m_screen ? (m_screen->cursorPos() % m_screen->cols()) : 0;
    int cols = m_screen ? m_screen->cols() : 80;
    int rows = m_screen ? m_screen->rows() : 24;

    for (int i = 0; i < text.length(); ++i) {
        QChar c = text.at(i);
        if (c == '\r') continue;

        if (c == '\n') {
            if (m_screen) {
                int curRow = m_screen->cursorPos() / cols;
                int nextRow = curRow + 1;
                if (nextRow < rows) {
                    m_screen->setCursor(nextRow * cols + startCol);
                } else {
                    break;
                }
            }
        } else {
            m_kbd->handleChar(c.unicode());
        }
    }
    update();
}

void TerminalWidget::keyPressEvent(QKeyEvent *event) {
    int key = event->key();
    Qt::KeyboardModifiers mods = event->modifiers();

    // 1. Copia-Incolla
    if ((mods & Qt::ControlModifier || mods & Qt::MetaModifier) && key == Qt::Key_C) {
        copyToClipboard();
        return;
    }
    if ((mods & Qt::ControlModifier || mods & Qt::MetaModifier) && key == Qt::Key_V) {
        pasteFromClipboard();
        return;
    }

    // 2. Time-Machine
    if ((mods & Qt::ControlModifier || mods & Qt::AltModifier) && key == Qt::Key_T) {
        toggleTimeMachine();
        return;
    }

    // 3. Toggle Insert Mode
    if ((mods & Qt::ControlModifier || mods & Qt::MetaModifier) && key == Qt::Key_I) {
        if (m_kbd) {
            m_kbd->toggleInsert();
            update();
        }
        return;
    }

    if (!m_kbd) {
        QWidget::keyPressEvent(event);
        return;
    }

    bool handled = false;

    // 4. Reset / Clear
    if (key == Qt::Key_Escape) {
        if (mods & Qt::AltModifier) {
            handled = m_kbd->handleClear(); 
        } else {
            handled = m_kbd->handleReset(); 
        }
    }
    // 5. Tasti PA1, PA2, PA3 
    else if (mods & Qt::AltModifier && key >= Qt::Key_1 && key <= Qt::Key_3) {
        handled = m_kbd->handlePA(key - Qt::Key_0);
    }
    // 6. Erase EOF 
    else if (mods & Qt::AltModifier && key == Qt::Key_Delete) {
        handled = m_kbd->handleEraseEOF();
    }
    // 7. Erase Input 
    else if (mods & Qt::AltModifier && key == Qt::Key_E) {
        handled = m_kbd->handleEraseInput();
    }
    // 8. Invio
    else if (key == Qt::Key_Return || key == Qt::Key_Enter) {
        handled = m_kbd->handleEnter();
    }
    // 9. Tab / BackTab
    else if (key == Qt::Key_Tab) {
        bool backward = (mods & Qt::ShiftModifier) || (mods & Qt::AltModifier);
        handled = m_kbd->handleTab(backward);
    }
    // 10. Modifica Testo e Cursore
    else if (key == Qt::Key_Backspace) {
        handled = m_kbd->handleBackspace();
    } else if (key == Qt::Key_Delete) {
        handled = m_kbd->handleDelete();
    } else if (key == Qt::Key_Home) {
        handled = m_kbd->handleHome();
    } else if (key == Qt::Key_Up) {
        handled = m_kbd->handleCursorUp();
    } else if (key == Qt::Key_Down) {
        handled = m_kbd->handleCursorDown();
    } else if (key == Qt::Key_Left) {
        handled = m_kbd->handleCursorLeft();
    } else if (key == Qt::Key_Right) {
        handled = m_kbd->handleCursorRight();
    }
    // 11. Tasti Funzione PF1-PF24 
    else if (key >= Qt::Key_F1 && key <= Qt::Key_F12) {
        int pfNum = key - Qt::Key_F1 + 1;
        if (mods & Qt::ShiftModifier) pfNum += 12;
        handled = m_kbd->handlePF(pfNum);
    }
    // 12. Caratteri EBCDIC stampabili
    else if (!event->text().isEmpty()) {
        QChar c = event->text().at(0);
        if (c.unicode() >= 0x20 && c.unicode() != 0x7F) {
            handled = m_kbd->handleChar(c.unicode());
        }
    }

    if (handled) {
        update();
    } else {
        QWidget::keyPressEvent(event);
    }
}

void TerminalWidget::showDataInspectorAtOffset(int offset, const QPoint &globalPos) {
    if (!m_screen || !m_codec) return;
    
    QByteArray rawBytes;
    QString decodedText;
    QByteArray verticalHexBytes;
    QString verticalDecodedText;
    
    int cols = m_screen->cols();
    int maxScreenSize = m_screen->rows() * cols;
    int minRow, maxRow, minCol, maxCol;
    
    bool isBlockSelection = (m_selStart >= 0 && m_selEnd > m_selStart && offset >= m_selStart && offset <= m_selEnd);
    
    if (isBlockSelection) {
        int r1 = m_selStart / cols, c1 = m_selStart % cols;
        int r2 = m_selEnd / cols, c2 = m_selEnd % cols;
        minRow = std::min(r1, r2); maxRow = std::max(r1, r2);
        minCol = std::min(c1, c2); maxCol = std::max(c1, c2);
    } else {
        // Smart Word Extraction
        minRow = offset / cols;
        maxRow = minRow;
        int clickCol = offset % cols;
        
        minCol = clickCol;
        while (minCol > 0 && m_screen->at(minRow * cols + (minCol - 1)).ch > 0x40) minCol--;
        
        maxCol = clickCol;
        while (maxCol < cols - 1 && m_screen->at(minRow * cols + (maxCol + 1)).ch > 0x40) maxCol++;
    }
    
    // Limiti di sicurezza
    if (maxRow - minRow > 50) maxRow = minRow + 50;
    if (maxCol > cols - 1) maxCol = cols - 1;
    
    m_hasInspectedBlock = true;
    m_inspectedMinRow = minRow; m_inspectedMaxRow = maxRow;
    m_inspectedMinCol = minCol; m_inspectedMaxCol = maxCol;
    update();
    
    auto hexCharToInt = [](uint16_t c) -> int {
        if (c >= '0' && c <= '9') return c - '0';
        if (c >= 'A' && c <= 'F') return c - 'A' + 10;
        if (c >= 'a' && c <= 'f') return c - 'a' + 10;
        return -1;
    };
    
    for (int r = minRow; r <= maxRow; r++) {
        bool canCheckVertical = (!isBlockSelection) || (r == maxRow - 1);
        
        for (int c = minCol; c <= maxCol; c++) {
            int pos = r * cols + c;
            if (pos >= maxScreenSize) continue;
            
            uint8_t byte = m_screen->at(pos).ch;
            rawBytes.append(static_cast<char>(byte));
            
            uint16_t uc = m_codec->toUnicode(byte);
            decodedText.append(uc >= 0x20 ? QChar(uc) : QChar('.'));
            
            if (canCheckVertical) {
                int posBottom = pos + cols;
                if (posBottom < maxScreenSize) {
                    uint16_t uTop = m_codec->toUnicode(m_screen->at(pos).ch);
                    uint16_t uBot = m_codec->toUnicode(m_screen->at(posBottom).ch);
                    int hTop = hexCharToInt(uTop);
                    int hBot = hexCharToInt(uBot);
                    
                    if (hTop >= 0 && hBot >= 0) {
                        uint8_t vByte = static_cast<uint8_t>((hTop << 4) | hBot);
                        verticalHexBytes.append(static_cast<char>(vByte));
                        uint16_t vUc = m_codec->toUnicode(vByte);
                        verticalDecodedText.append(vUc >= 0x20 ? QChar(vUc) : QChar('.'));
                    } else {
                        verticalHexBytes.append(static_cast<char>(0x00));
                        verticalDecodedText.append('.');
                    }
                }
            }
        }
    }
    
    bool hasValidVerticalHex = false;
    for (char c : verticalHexBytes) {
        if (c != 0x00) {
            hasValidVerticalHex = true;
            break;
        }
    }

    if (hasValidVerticalHex && isBlockSelection) {
        rawBytes = verticalHexBytes;
        decodedText = verticalDecodedText;
    }

    QString cleanToken = decodedText.trimmed().remove(' ').remove('.');
    QRegularExpression ptrRegex("^[0-9A-Fa-f]{8}$|^[0-9A-Fa-f]{16}$");
    bool isPointer = (!cleanToken.isEmpty() && ptrRegex.match(cleanToken).hasMatch());

    if (isPointer) {
        QMenu *jumpMenu = new QMenu(this);
        QAction *jumpAction = jumpMenu->addAction(QString("Jump to (L %1)").arg(cleanToken.toUpper()));
        connect(jumpAction, &QAction::triggered, this, [this, cleanToken]() {
            executeISPFCommand(QString("L %1").arg(cleanToken.toUpper()));
        });
        
        connect(jumpMenu, &QMenu::aboutToHide, this, [this, jumpMenu]() {
            m_hasInspectedBlock = false;
            update();
            jumpMenu->deleteLater();
        });
        
        jumpMenu->popup(globalPos);
        
    } else {
        static QPointer<DataInspectorDialog> inspectorDialog;
        
        if (inspectorDialog) {
            inspectorDialog->close();
            inspectorDialog->deleteLater();
        }
        
        inspectorDialog = new DataInspectorDialog(rawBytes, decodedText, verticalHexBytes, verticalDecodedText, nullptr);
        
        inspectorDialog->setModal(false);
        inspectorDialog->setAttribute(Qt::WA_DeleteOnClose, true);
        inspectorDialog->setWindowFlags(Qt::Window | Qt::WindowStaysOnTopHint);
        
        inspectorDialog->show();
        inspectorDialog->raise();
        inspectorDialog->activateWindow();
    }
}