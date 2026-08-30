// SPDX-License-Identifier: MIT
//
// The local message archive: an encrypted SQLite database that keeps every
// message this plugin has ever seen.
//
// Append-only, deliberately. Slack hides history past ninety days on a free
// workspace, and a message deleted upstream simply stops appearing in
// conversations.history - so for anything older than that window this file is
// the only copy. Nothing here removes a message; the only destructive operation
// is deleting the file yourself.
//
// Encryption is SQLCipher, transparent at the page level, so nothing readable
// touches the disk - not the message text, not the author, not even SQLite's
// own file header. The key is 32 random bytes generated once and kept in the
// keyring beside the Slack token.
//
// It is emphatically *not* derived from the OAuth token: the agent rewrites
// that token in the keyring every time Slack answers token_expired, which for a
// rotating app is about twice a day, and a key that changed with it would make
// every message written before the rotation permanently unreadable. The keyring
// is already unlocked by the login session, so a stored random key costs the
// reader nothing and survives rotation, re-sign-in and switching identity.

module;

#include <sqlite3.h>

#include <QByteArray>
#include <QCryptographicHash>
#include <QDateTime>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QRandomGenerator>
#include <QString>

#include <utility>

export module slack.archive;

import slack.util;
import slack.keyring;

namespace u = slack::util;

namespace {

// A prepared statement that always gets finalised, however the scope is left.
class Stmt {
public:
    Stmt(sqlite3* db, const char* sql) {
        if (sqlite3_prepare_v2(db, sql, -1, &handle_, nullptr) != SQLITE_OK)
            handle_ = nullptr;
    }
    ~Stmt() {
        if (handle_ != nullptr)
            sqlite3_finalize(handle_);
    }
    Stmt(const Stmt&) = delete;
    Stmt& operator=(const Stmt&) = delete;

    [[nodiscard]] bool ok() const { return handle_ != nullptr; }
    [[nodiscard]] sqlite3_stmt* get() const { return handle_; }

    void bind(int index, const QString& value) {
        const QByteArray utf8 = value.toUtf8();
        sqlite3_bind_text(handle_, index, utf8.constData(), int(utf8.size()), SQLITE_TRANSIENT);
    }
    void bind(int index, qint64 value) { sqlite3_bind_int64(handle_, index, value); }
    void bind(int index, double value) { sqlite3_bind_double(handle_, index, value); }

    [[nodiscard]] bool step() { return sqlite3_step(handle_) == SQLITE_ROW; }
    [[nodiscard]] bool done() { return sqlite3_step(handle_) == SQLITE_DONE; }

    [[nodiscard]] QString text(int column) const {
        const unsigned char* value = sqlite3_column_text(handle_, column);
        return value == nullptr ? QString() : QString::fromUtf8(reinterpret_cast<const char*>(value));
    }

private:
    sqlite3_stmt* handle_ = nullptr;
};

qint64 nowSeconds() {
    return QDateTime::currentSecsSinceEpoch();
}

// What actually distinguishes one version of a message from another, for the
// purpose of keeping revisions. Reactions and reply counts churn constantly and
// are not edits; the text is.
QString revisionDigest(const QJsonObject& message) {
    const QString material = u::str(message, "text") + QChar(0x1F) +
                             (u::boolean(message, "edited") ? u::qs("e") : u::qs("-"));
    return QString::fromLatin1(
        QCryptographicHash::hash(material.toUtf8(), QCryptographicHash::Sha1).toHex());
}

QString compact(const QJsonObject& object) {
    return QString::fromUtf8(QJsonDocument(object).toJson(QJsonDocument::Compact));
}

}  // namespace

export namespace slack::archive {

// The key lives here. Created on first use; there is no other copy.
inline constexpr const char* kKeyAccount = "archive-key";

// 64 hex characters - SQLCipher's raw-key form, which skips the key derivation
// a passphrase would need. Empty only if the keyring is unavailable.
QString keyHex(bool createIfMissing = true) {
    QString stored = keyring::lookup(kKeyAccount);
    if (!stored.isEmpty() || !createIfMissing)
        return stored;

    QByteArray raw(32, '\0');
    QRandomGenerator::system()->generate(raw.begin(), raw.end());
    stored = QString::fromLatin1(raw.toHex());
    if (!keyring::store(kKeyAccount, u::qs("Slack Archive Key"), stored))
        return {};
    return stored;
}

// One database per identity: a bot and a user see different conversations, and
// mixing them would put messages in an archive their reader cannot explain.
QString databasePath(const QString& identity) {
    // A path rather than an identity name is taken literally, which is how the
    // tests get a database somewhere harmless.
    if (identity.contains('/'))
        return identity;
    return u::stateDir() + u::qs("/archive-") + identity + u::qs(".db");
}

// Put a key back, for an archive restored from a backup after the keyring that
// held its key is gone.
bool adoptKey(const QString& hex) {
    const QString trimmed = hex.trimmed().toLower();
    if (trimmed.size() != 64)
        return false;
    for (const QChar c : trimmed) {
        if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')))
            return false;
    }
    return keyring::store(kKeyAccount, u::qs("Slack Archive Key"), trimmed);
}

class Db {
public:
    // `explicitKey` exists for two reasons that turn out to be the same one:
    // restoring an archive from a key you wrote down after `archive-key`, and
    // testing without a running secret service.
    Db(const QString& identity, bool createIfMissing = true, const QString& explicitKey = {}) {
        const QString key = explicitKey.isEmpty() ? keyHex(createIfMissing) : explicitKey;
        if (key.isEmpty())
            return;
        const QString path = identity.contains('/') ? identity : databasePath(identity);
        const bool existed = QFileInfo::exists(path);
        if (!existed && !createIfMissing)
            return;

        u::ensureDir(u::stateDir());
        if (sqlite3_open(path.toUtf8().constData(), &db_) != SQLITE_OK) {
            close();
            return;
        }
        // Nobody else on the machine needs to read a year of work conversation,
        // encrypted or not.
        QFile::setPermissions(path, QFileDevice::ReadOwner | QFileDevice::WriteOwner);

        // Raw key form: the x'...' spelling means these 32 bytes are the key,
        // rather than a passphrase to stretch.
        if (!exec(u::qs("PRAGMA key = \"x'") + key + u::qs("'\";"))) {
            close();
            return;
        }
        // The first statement to touch a page is what proves the key: a wrong
        // one fails here rather than silently returning nothing.
        if (!exec(u::qs("SELECT count(*) FROM sqlite_master;"))) {
            close();
            return;
        }
        if (!migrate())
            close();
    }

    ~Db() { close(); }
    Db(const Db&) = delete;
    Db& operator=(const Db&) = delete;

    [[nodiscard]] bool ok() const { return db_ != nullptr; }
    [[nodiscard]] sqlite3* handle() const { return db_; }

    bool exec(const QString& sql) {
        if (db_ == nullptr)
            return false;
        char* error = nullptr;
        const int rc = sqlite3_exec(db_, sql.toUtf8().constData(), nullptr, nullptr, &error);
        if (error != nullptr) {
            u::log(u::qs("archive: ") + QString::fromUtf8(error));
            sqlite3_free(error);
        }
        return rc == SQLITE_OK;
    }

private:
    void close() {
        if (db_ != nullptr) {
            sqlite3_close(db_);
            db_ = nullptr;
        }
    }

    bool migrate() {
        // `ts` is Slack's own timestamp and is unique per channel, so it is the
        // natural key; ts_num exists only because ordering a decimal string is
        // a trap waiting for the day Slack's format changes width.
        return exec(u::qs(R"(
            PRAGMA journal_mode = WAL;
            CREATE TABLE IF NOT EXISTS messages(
              channel    TEXT    NOT NULL,
              ts         TEXT    NOT NULL,
              ts_num     REAL    NOT NULL,
              user       TEXT,
              author     TEXT,
              text       TEXT,
              thread_ts  TEXT,
              subtype    TEXT,
              edited     INTEGER NOT NULL DEFAULT 0,
              json       TEXT    NOT NULL,
              digest     TEXT    NOT NULL,
              first_seen INTEGER NOT NULL,
              last_seen  INTEGER NOT NULL,
              PRIMARY KEY(channel, ts)
            );
            CREATE INDEX IF NOT EXISTS messages_by_time ON messages(channel, ts_num DESC);
            CREATE INDEX IF NOT EXISTS messages_by_thread ON messages(channel, thread_ts);

            -- Messages on Slack are mutable: people edit them, and an archive
            -- that overwrote the previous text would quietly lose what was
            -- actually said at the time. Superseded versions land here.
            CREATE TABLE IF NOT EXISTS revisions(
              channel       TEXT    NOT NULL,
              ts            TEXT    NOT NULL,
              superseded_at INTEGER NOT NULL,
              json          TEXT    NOT NULL,
              digest        TEXT    NOT NULL
            );
            CREATE INDEX IF NOT EXISTS revisions_by_message ON revisions(channel, ts);

            CREATE TABLE IF NOT EXISTS conversations(
              id   TEXT PRIMARY KEY,
              type TEXT,
              name TEXT,
              seen INTEGER NOT NULL
            );
        )"));
    }

    sqlite3* db_ = nullptr;
};

struct IngestResult {
    int added = 0;
    int revised = 0;
    int unchanged = 0;
};

// Upsert a page of shaped messages. Nothing is ever deleted; a message whose
// text changed keeps its previous version in `revisions`.
IngestResult ingest(Db& db, const QString& channel, const QJsonArray& messages) {
    IngestResult result;
    if (!db.ok() || messages.isEmpty() || channel.isEmpty())
        return result;

    db.exec(u::qs("BEGIN IMMEDIATE;"));
    const qint64 now = nowSeconds();

    for (const QJsonValue value : messages) {
        const QJsonObject message = value.toObject();
        const QString ts = u::str(message, "ts");
        if (ts.isEmpty())
            continue;
        const QString json = compact(message);
        const QString digest = revisionDigest(message);

        QString priorDigest;
        QString priorJson;
        bool exists = false;
        {
            Stmt find(db.handle(), "SELECT digest, json FROM messages WHERE channel = ?1 AND ts = ?2;");
            if (!find.ok())
                continue;
            find.bind(1, channel);
            find.bind(2, ts);
            if (find.step()) {
                exists = true;
                priorDigest = find.text(0);
                priorJson = find.text(1);
            }
        }

        if (exists && priorDigest == digest) {
            // Same text: reactions or a reply count may have moved, which is
            // worth storing but is not a new version of what was said.
            Stmt touch(db.handle(),
                       "UPDATE messages SET json = ?3, last_seen = ?4 WHERE channel = ?1 AND ts = ?2;");
            if (touch.ok()) {
                touch.bind(1, channel);
                touch.bind(2, ts);
                touch.bind(3, json);
                touch.bind(4, now);
                (void)touch.done();
            }
            ++result.unchanged;
            continue;
        }

        if (exists) {
            Stmt keep(db.handle(),
                      "INSERT INTO revisions(channel, ts, superseded_at, json, digest) "
                      "VALUES(?1, ?2, ?3, ?4, ?5);");
            if (keep.ok()) {
                keep.bind(1, channel);
                keep.bind(2, ts);
                keep.bind(3, now);
                keep.bind(4, priorJson);
                keep.bind(5, priorDigest);
                (void)keep.done();
            }
        }

        Stmt put(db.handle(),
                 "INSERT INTO messages(channel, ts, ts_num, user, author, text, thread_ts, subtype,"
                 "                     edited, json, digest, first_seen, last_seen) "
                 "VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?12) "
                 "ON CONFLICT(channel, ts) DO UPDATE SET "
                 "  user = ?4, author = ?5, text = ?6, thread_ts = ?7, subtype = ?8, edited = ?9,"
                 "  json = ?10, digest = ?11, last_seen = ?12;");
        if (!put.ok())
            continue;
        put.bind(1, channel);
        put.bind(2, ts);
        put.bind(3, u::ts(ts));
        put.bind(4, u::str(message, "user"));
        put.bind(5, u::str(message, "author"));
        put.bind(6, u::str(message, "text"));
        put.bind(7, u::str(message, "threadTs"));
        put.bind(8, u::str(message, "subtype"));
        put.bind(9, qint64(u::boolean(message, "edited") ? 1 : 0));
        put.bind(10, json);
        put.bind(11, digest);
        put.bind(12, now);
        (void)put.done();

        if (exists)
            ++result.revised;
        else
            ++result.added;
    }

    db.exec(u::qs("COMMIT;"));
    return result;
}

void rememberConversations(Db& db, const QJsonArray& conversations) {
    if (!db.ok() || conversations.isEmpty())
        return;
    db.exec(u::qs("BEGIN IMMEDIATE;"));
    const qint64 now = nowSeconds();
    for (const QJsonValue value : conversations) {
        const QJsonObject conversation = value.toObject();
        Stmt put(db.handle(),
                 "INSERT INTO conversations(id, type, name, seen) VALUES(?1, ?2, ?3, ?4) "
                 "ON CONFLICT(id) DO UPDATE SET type = ?2, name = ?3, seen = ?4;");
        if (!put.ok())
            continue;
        put.bind(1, u::str(conversation, "id"));
        put.bind(2, u::str(conversation, "type"));
        put.bind(3, u::str(conversation, "name"));
        put.bind(4, now);
        (void)put.done();
    }
    db.exec(u::qs("COMMIT;"));
}

// Newest first, the same order and shape conversations.history returns, so the
// UI cannot tell the difference between this and the network.
QJsonArray readHistory(Db& db, const QString& channel, int limit, const QString& before) {
    QJsonArray out;
    if (!db.ok() || channel.isEmpty())
        return out;

    const char* sql = before.isEmpty()
                          ? "SELECT json FROM messages WHERE channel = ?1 "
                            "ORDER BY ts_num DESC LIMIT ?3;"
                          : "SELECT json FROM messages WHERE channel = ?1 AND ts_num < ?2 "
                            "ORDER BY ts_num DESC LIMIT ?3;";
    Stmt read(db.handle(), sql);
    if (!read.ok())
        return out;
    read.bind(1, channel);
    read.bind(2, u::ts(before));
    read.bind(3, qint64(limit > 0 ? limit : 50));
    while (read.step())
        out.append(u::parseObject(read.text(0).toUtf8()));
    return out;
}

// Every superseded version of one message, oldest first - what the text used to
// say before somebody edited it.
QJsonArray readRevisions(Db& db, const QString& channel, const QString& ts) {
    QJsonArray out;
    if (!db.ok())
        return out;
    Stmt read(db.handle(),
              "SELECT json FROM revisions WHERE channel = ?1 AND ts = ?2 ORDER BY superseded_at ASC;");
    if (!read.ok())
        return out;
    read.bind(1, channel);
    read.bind(2, ts);
    while (read.step())
        out.append(u::parseObject(read.text(0).toUtf8()));
    return out;
}

QJsonObject stats(Db& db) {
    if (!db.ok()) {
        // Either nothing has been archived yet, or the key is not available -
        // both look the same from here, and neither is an error worth alarming
        // anyone about.
        return {{"ok", true},
                {"messages", 0},
                {"revisions", 0},
                {"conversations", 0},
                {"conversationDetail", QJsonArray{}},
                {"note", u::qs("no archive on disk yet, or its key is not in the keyring")}};
    }

    const auto count = [&db](const char* sql) -> qint64 {
        Stmt read(db.handle(), sql);
        if (!read.ok() || !read.step())
            return 0;
        return sqlite3_column_int64(read.get(), 0);
    };

    QJsonArray perConversation;
    {
        Stmt read(db.handle(),
                  "SELECT m.channel, COALESCE(c.name, m.channel), COUNT(*), MIN(m.ts), MAX(m.ts) "
                  "FROM messages m LEFT JOIN conversations c ON c.id = m.channel "
                  "GROUP BY m.channel ORDER BY COUNT(*) DESC LIMIT 50;");
        while (read.ok() && read.step()) {
            perConversation.append(QJsonObject{{"id", read.text(0)},
                                               {"name", read.text(1)},
                                               {"messages", sqlite3_column_int64(read.get(), 2)},
                                               {"oldest", read.text(3)},
                                               {"newest", read.text(4)}});
        }
    }
    return {{"ok", true},
            {"messages", count("SELECT COUNT(*) FROM messages;")},
            {"revisions", count("SELECT COUNT(*) FROM revisions;")},
            {"conversations", count("SELECT COUNT(DISTINCT channel) FROM messages;")},
            {"conversationDetail", perConversation}};
}

}  // namespace slack::archive
