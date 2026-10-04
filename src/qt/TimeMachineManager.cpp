#include "TimeMachineManager.h"
#include <QFile>
#include <QJsonDocument>
#include <QJsonArray>
#include <QJsonObject>
#include <QDateTime>

QJsonObject ScreenSnapshot::toJson() const {
    QJsonObject obj;
    obj["rows"] = rows;
    obj["cols"] = cols;
    obj["cursorRow"] = cursorRow;
    obj["cursorCol"] = cursorCol;
    obj["timestamp"] = timestamp;
    obj["pinned"] = pinned;
    obj["charBuffer"] = QString::fromLatin1(characterBuffer.toBase64());
    obj["attrBuffer"] = QString::fromLatin1(attributeBuffer.toBase64());
    return obj;
}

ScreenSnapshot ScreenSnapshot::fromJson(const QJsonObject &obj) {
    ScreenSnapshot snap;
    snap.rows = obj["rows"].toInt(24);
    snap.cols = obj["cols"].toInt(80);
    snap.cursorRow = obj["cursorRow"].toInt(0);
    snap.cursorCol = obj["cursorCol"].toInt(0);
    snap.timestamp = obj["timestamp"].toVariant().toLongLong();
    snap.pinned = obj["pinned"].toBool(false);
    snap.characterBuffer = QByteArray::fromBase64(obj["charBuffer"].toString().toLatin1());
    snap.attributeBuffer = QByteArray::fromBase64(obj["attrBuffer"].toString().toLatin1());
    return snap;
}

TimeMachineManager& TimeMachineManager::instance() {
    static TimeMachineManager mgr;
    return mgr;
}

void TimeMachineManager::captureSnapshot(int rows, int cols, const ushort *chars, const uint32_t *attrs, int cursorRow, int cursorCol) {
    if (rows <= 0 || cols <= 0 || !chars) return;

    ScreenSnapshot snap;
    snap.rows = rows;
    snap.cols = cols;
    snap.cursorRow = cursorRow;
    snap.cursorCol = cursorCol;
    snap.timestamp = QDateTime::currentMSecsSinceEpoch() / 1000;
    snap.pinned = false;

    snap.characterBuffer = QByteArray(reinterpret_cast<const char*>(chars), rows * cols * sizeof(ushort));
    if (attrs) {
        snap.attributeBuffer = QByteArray(reinterpret_cast<const char*>(attrs), rows * cols * sizeof(uint32_t));
    }

    m_snapshots.append(snap);

    if (m_snapshots.size() > kMaxSnapshots) {
        m_snapshots.removeFirst();
        if (m_baselinePinIndex > 0) m_baselinePinIndex--;
    }
}

void TimeMachineManager::clearHistory() {
    m_snapshots.clear();
    m_baselinePinIndex = -1;
}

const ScreenSnapshot* TimeMachineManager::snapshotAt(int index) const {
    if (index >= 0 && index < m_snapshots.size()) {
        return &m_snapshots[index];
    }
    return nullptr;
}

void TimeMachineManager::togglePinAtIndex(int index) {
    if (index >= 0 && index < m_snapshots.size()) {
        m_snapshots[index].pinned = !m_snapshots[index].pinned;
    }
}

bool TimeMachineManager::isPinnedAtIndex(int index) const {
    if (index >= 0 && index < m_snapshots.size()) {
        return m_snapshots[index].pinned;
    }
    return false;
}

int TimeMachineManager::nextPinnedIndexAfter(int currentIndex) const {
    for (int i = currentIndex + 1; i < m_snapshots.size(); ++i) {
        if (m_snapshots[i].pinned) return i;
    }
    return -1;
}

int TimeMachineManager::prevPinnedIndexBefore(int currentIndex) const {
    for (int i = currentIndex - 1; i >= 0; --i) {
        if (m_snapshots[i].pinned) return i;
    }
    return -1;
}

QList<int> TimeMachineManager::compareSnapshots(const ScreenSnapshot &current, const ScreenSnapshot &baseline) const {
    QList<int> diffMap;
    int totalCells = current.rows * current.cols;
    diffMap.reserve(totalCells);

    const ushort *curChars = reinterpret_cast<const ushort*>(current.characterBuffer.constData());
    const ushort *baseChars = reinterpret_cast<const ushort*>(baseline.characterBuffer.constData());

    int baseTotal = baseline.rows * baseline.cols;

    for (int i = 0; i < totalCells; ++i) {
        if (i < baseTotal && curChars[i] != baseChars[i]) {
            diffMap.append(CellDiffModified);
        } else {
            diffMap.append(CellDiffUnchanged);
        }
    }
    return diffMap;
}

int TimeMachineManager::searchHistory(const QString &query, int startIndex, bool backward) const {
    if (query.isEmpty() || m_snapshots.isEmpty()) return -1;

    int step = backward ? -1 : 1;
    int start = startIndex + step;

    for (int i = start; i >= 0 && i < m_snapshots.size(); i += step) {
        const auto &snap = m_snapshots[i];
        const ushort *chars = reinterpret_cast<const ushort*>(snap.characterBuffer.constData());

        QString screenText = QString::fromUtf16(reinterpret_cast<const char16_t*>(chars), snap.rows * snap.cols);

        if (screenText.contains(query, Qt::CaseInsensitive)) {
            return i;
        }
    }
    return -1;
}

bool TimeMachineManager::exportTrace(const QString &filePath) const {
    QFile file(filePath);
    if (!file.open(QIODevice::WriteOnly)) return false;

    QJsonArray arr;
    for (const auto &snap : m_snapshots) {
        arr.append(snap.toJson());
    }

    QJsonDocument doc(arr);
    file.write(doc.toJson());
    return true;
}

bool TimeMachineManager::importTrace(const QString &filePath) {
    QFile file(filePath);
    if (!file.open(QIODevice::ReadOnly)) return false;

    QByteArray data = file.readAll();
    QJsonDocument doc = QJsonDocument::fromJson(data);
    if (!doc.isArray()) return false;

    m_snapshots.clear();
    QJsonArray arr = doc.array();
    for (const auto &val : arr) {
        m_snapshots.append(ScreenSnapshot::fromJson(val.toObject()));
    }
    return true;
}