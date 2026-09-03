// SPDX-License-Identifier: MIT
//
// Paths, files and the JSON conventions every subcommand shares.
//
// The contract inherited from the shell version and kept deliberately: every
// subcommand prints exactly one JSON object on stdout and exits 0. Errors are
// {"ok":false,"error":"..."} so the QML side never has to care about exit codes
// or stderr, and a crash is the only thing that can produce no output at all.

module;

#include <QByteArray>
#include <QCryptographicHash>
#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonValue>
#include <QSaveFile>
#include <QStandardPaths>
#include <QString>
#include <QTextStream>

#include <cstdio>
#include <cstdlib>

export module slack.util;

export namespace slack::util {

// ------------------------------------------------------------------- output

// Print one JSON object and nothing else. Every exit path goes through here or
// through fail(). Not named `emit`: Qt defines that as a macro, and the build
// turns those off with QT_NO_KEYWORDS precisely so names like this stay usable.
void emitJson(const QJsonObject& object) {
    QTextStream out(stdout);
    out << QString::fromUtf8(QJsonDocument(object).toJson(QJsonDocument::Compact)) << '\n';
    out.flush();
}

// Progress and diagnostics go to stderr, where the QML side ignores them.
void log(const QString& message) {
    QTextStream err(stderr);
    err << message << '\n';
    err.flush();
}

[[noreturn]] inline void fail(const QString& message, bool needsSignIn = false) {
    emitJson({{"ok", false}, {"error", message}, {"needsSignIn", needsSignIn}});
    std::exit(0);
}

// QStringLiteral expands to a call to QtPrivate::qMakeStringPrivate, which Qt
// declares `static` - a TU-local entity. A module interface may not expose one
// in the definition of an inline function, and clang enforces that as soon as
// the module imports anything, so QStringLiteral compiles in a leaf module and
// stops compiling the moment that module gains an import. Rather than leave a
// landmine, nothing here uses it: every string constant is built through this.
//
// The cost is a heap allocation per constant, in a process that makes a handful
// of HTTP requests and exits.
[[nodiscard]] QString qs(const char* text) {
    return QString::fromUtf8(text);
}

// --------------------------------------------------------------------- paths

QString envOr(const char* name, const QString& fallback) {
    const QByteArray value = qgetenv(name);
    return value.isEmpty() ? fallback : QString::fromLocal8Bit(value);
}

QString homeDir() {
    return envOr("HOME", QStandardPaths::writableLocation(QStandardPaths::HomeLocation));
}

// State is what would be painful to lose (read cursors); cache is what can be
// rebuilt from Slack (conversation lists, avatars, link previews). Existing
// Noctalia installations used the old directory name. Prefer it only when the
// shell-neutral directory does not exist yet, so upgrading keeps read cursors
// without making a new DMS/end-4/Caelestia install host-specific.
QString dataDir(const QString& base) {
    const QString current = base + "/slack-sidebar";
    const QString legacy = base + "/noctalia-slack";
    if (!QFileInfo::exists(current) && QFileInfo::exists(legacy))
        return legacy;
    return current;
}

QString stateDir() {
    return dataDir(envOr("XDG_STATE_HOME", homeDir() + "/.local/state"));
}

QString cacheDir() {
    return dataDir(envOr("XDG_CACHE_HOME", homeDir() + "/.cache"));
}

void ensureDir(const QString& path) {
    QDir().mkpath(path);
    // These hold read state and mirrored avatars for one person; nobody else on
    // the machine needs to see them.
    QFile::setPermissions(path, QFileDevice::ReadOwner | QFileDevice::WriteOwner | QFileDevice::ExeOwner);
}

void ensureDirs() {
    ensureDir(stateDir());
    ensureDir(cacheDir());
}

// --------------------------------------------------------------------- files

QByteArray readFile(const QString& path) {
    QFile file(path);
    if (!file.open(QIODevice::ReadOnly))
        return {};
    return file.readAll();
}

// Write through a temporary and rename, so a reader never sees half a file and
// a crash mid-write cannot destroy the previous contents.
bool writeFileAtomic(const QString& path, const QByteArray& data) {
    QSaveFile file(path);
    if (!file.open(QIODevice::WriteOnly))
        return false;
    if (file.write(data) != data.size())
        return false;
    return file.commit();
}

bool fresh(const QString& path, qint64 ttlSeconds) {
    const QFileInfo info(path);
    if (!info.exists() || info.size() == 0)
        return false;
    return info.lastModified().secsTo(QDateTime::currentDateTime()) < ttlSeconds;
}

QString hashOf(const QString& text) {
    return QString::fromLatin1(
        QCryptographicHash::hash(text.toUtf8(), QCryptographicHash::Sha1).toHex());
}

// ---------------------------------------------------------------------- json

QJsonObject parseObject(const QByteArray& bytes, bool* ok = nullptr) {
    QJsonParseError error{};
    const QJsonDocument document = QJsonDocument::fromJson(bytes, &error);
    const bool good = error.error == QJsonParseError::NoError && document.isObject();
    if (ok != nullptr)
        *ok = good;
    return good ? document.object() : QJsonObject{};
}

QJsonObject readJsonObject(const QString& path) {
    return parseObject(readFile(path));
}

bool writeJsonAtomic(const QString& path, const QJsonObject& object) {
    return writeFileAtomic(path, QJsonDocument(object).toJson(QJsonDocument::Compact));
}

QString str(const QJsonObject& object, const char* key, const QString& fallback = {}) {
    const QJsonValue value = object.value(QLatin1String(key));
    return value.isString() ? value.toString() : fallback;
}

bool boolean(const QJsonObject& object, const char* key, bool fallback = false) {
    const QJsonValue value = object.value(QLatin1String(key));
    return value.isBool() ? value.toBool() : fallback;
}

QJsonArray array(const QJsonObject& object, const char* key) {
    return object.value(QLatin1String(key)).toArray();
}

QJsonObject object(const QJsonObject& parent, const char* key) {
    return parent.value(QLatin1String(key)).toObject();
}

// Slack timestamps are strings holding a decimal ("1787123637.474259") and are
// compared numerically everywhere. Parsing to double is exact enough: the
// integer part is ten digits and the fraction six, well inside the 53 bits of a
// double's mantissa.
double ts(const QString& value) {
    bool ok = false;
    const double parsed = value.toDouble(&ok);
    return ok ? parsed : 0.0;
}

// Message previews are one line in a sidebar, not a document.
QString flatten(const QString& text, int limit = 140) {
    QString out = text.simplified();
    if (out.size() > limit)
        out.truncate(limit);
    return out;
}

}  // namespace slack::util
