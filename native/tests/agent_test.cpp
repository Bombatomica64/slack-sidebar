// SPDX-License-Identifier: MIT
//
// Unit tests for the agent's pure logic.
//
// Most of the agent needs a Slack token, a keyring or the network, and none of
// that belongs in a unit test. What is left is small but includes the piece
// most worth pinning down: the address guard that decides whether this machine
// fetches a URL somebody pasted into a Slack message. That guard was ported
// from shell to C++ with no test covering the C++ version, which is exactly the
// gap `make coverage` exists to make visible.

#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QJsonArray>
#include <QJsonObject>
#include <QString>
#include <QStringList>

#include <cstddef>
#include <iostream>
#include <string>
#include <string_view>

// Includes before imports: see the note in html_meta_test.cpp.
import slack.util;
import slack.net;
import slack.api;
import slack.store;
import slack.archive;
import slack.commands;

namespace {

int g_failures = 0;
int g_checks = 0;

void expect(bool cond, std::string_view what) {
    ++g_checks;
    if (cond)
        return;
    ++g_failures;
    std::cerr << "FAIL " << what << "\n";
}

void expect_eq(const QString& got, const QString& want, std::string_view what) {
    ++g_checks;
    if (got == want)
        return;
    ++g_failures;
    std::cerr << "FAIL " << what << "\n  want: [" << want.toStdString()
              << "]\n  got:  [" << got.toStdString() << "]\n";
}

// ------------------------------------------------------------ address guard

void test_crawlable() {
    using slack::commands::crawlable;
    const auto qs = slack::util::qs;

    // What a link preview is actually for.
    for (const char* allowed : {"https://example.com/x",
                                "http://example.com/",
                                "https://sub.example.co.uk/a?b=c",
                                "https://ExAmPle.COM/x",
                                "https://example.com:8443/x",
                                "https://93.184.216.34/x"}) {
        expect(crawlable(qs(allowed)), std::string("crawlable: allows ") + allowed);
    }

    // A colleague pasting any of these must not make this machine visit it.
    for (const char* blocked : {// loopback, in every spelling
                                "http://127.0.0.1:8080/a",
                                "http://127.1.2.3/a",
                                "https://localhost/a",
                                "http://user:pw@127.0.0.1/x",
                                "https://[::1]/x",
                                // link-local, including cloud metadata
                                "http://169.254.169.254/latest/meta-data",
                                "https://metadata.google.internal/x",
                                "http://instance-data/latest",
                                // private ranges
                                "https://10.0.0.5/x",
                                "https://172.16.0.1/x",
                                "https://172.20.3.4/x",
                                "https://172.31.255.254/x",
                                "https://192.168.1.1/",
                                "https://100.64.2.3/y",
                                "https://0.0.0.0/x",
                                // names that are not the public internet
                                "https://foo.internal/x",
                                "https://ec2.internal/",
                                "https://printer.local/x",
                                "https://host.home.arpa/x",
                                "https://something.onion/x",
                                "https://bare-hostname/x",
                                // not http at all
                                "file:///etc/passwd",
                                "javascript:alert(1)",
                                "data:text/html,<b>x</b>",
                                "ftp://example.com/x",
                                "",
                                "not a url"}) {
        expect(!crawlable(qs(blocked)), std::string("crawlable: refuses ") + blocked);
    }

    // 172.16/12 is the range that is easy to get wrong by prefix matching:
    // 172.15 and 172.32 are public, everything between is not.
    expect(crawlable(qs("https://172.15.0.1/x")), "crawlable: 172.15 is public");
    expect(crawlable(qs("https://172.32.0.1/x")), "crawlable: 172.32 is public");
    // Likewise 100.64/10 (carrier-grade NAT): 100.63 and 100.128 are public.
    expect(crawlable(qs("https://100.63.0.1/x")), "crawlable: 100.63 is public");
    expect(crawlable(qs("https://100.128.0.1/x")), "crawlable: 100.128 is public");
}

// ------------------------------------------------------------------ tokens

void test_token_kinds() {
    using namespace slack::api;
    const auto qs = slack::util::qs;

    expect(kindOf(qs("xoxp-123")) == TokenKind::User, "token: xoxp is a user token");
    expect(kindOf(qs("xoxc-123")) == TokenKind::User, "token: xoxc is a user token");
    expect(kindOf(qs("xoxb-123")) == TokenKind::Bot, "token: xoxb is a bot token");
    // Rotating tokens carry the same identity under an xoxe. prefix. Configuring
    // user scopes never turns a bot token into a user one, which is the single
    // most common setup mistake.
    expect(kindOf(qs("xoxe.xoxp-123")) == TokenKind::User, "token: rotating user token");
    expect(kindOf(qs("xoxe.xoxb-123")) == TokenKind::Bot, "token: rotating bot token");
    expect(kindOf(qs("nonsense")) == TokenKind::Unknown, "token: anything else is unknown");
    expect(kindOf(qs("")) == TokenKind::Unknown, "token: empty is unknown");

    expect(isRotating(qs("xoxe.xoxp-1")), "token: xoxe. rotates");
    expect(!isRotating(qs("xoxp-1")), "token: xoxp does not rotate");

    for (const char* dead : {"token_expired", "token_revoked", "invalid_auth",
                             "account_inactive", "not_authed"}) {
        expect(isAuthError(slack::util::qs(dead)), std::string("auth: ") + dead + " is fatal");
    }
    expect(!isAuthError(qs("ratelimited")), "auth: ratelimited is not an auth error");
    expect(!isAuthError(qs("channel_not_found")), "auth: channel_not_found is not an auth error");
    expect(!isAuthError(qs("")), "auth: no error is not an auth error");
}

// ------------------------------------------------------------------- values

void test_util() {
    using namespace slack::util;

    // Slack timestamps are decimal strings compared numerically everywhere.
    expect(ts(qs("1787123637.474259")) > ts(qs("1787123637.474258")), "ts: orders by fraction");
    expect(ts(qs("")) == 0.0, "ts: empty is zero");
    expect(ts(qs("not a number")) == 0.0, "ts: garbage is zero");

    expect_eq(flatten(qs("  a\n\n b  \t c ")), qs("a b c"), "flatten: collapses whitespace");
    expect_eq(flatten(qs("abcdef"), 3), qs("abc"), "flatten: respects the cap");

    expect_eq(hashOf(qs("https://example.com/")), hashOf(qs("https://example.com/")),
              "hash: is stable");
    expect(hashOf(qs("a")) != hashOf(qs("b")), "hash: distinguishes inputs");
    expect(hashOf(qs("a")).size() == 40, "hash: is a sha1 hex digest");

    bool ok = false;
    const QJsonObject parsed = parseObject(QByteArrayLiteral(R"({"ok":true,"n":3})"), &ok);
    expect(ok, "json: parses an object");
    expect(boolean(parsed, "ok"), "json: reads a bool");
    parseObject(QByteArrayLiteral("not json"), &ok);
    expect(!ok, "json: rejects garbage");
    parseObject(QByteArrayLiteral("[1,2]"), &ok);
    expect(!ok, "json: rejects a non-object");

    expect_eq(str(parsed, "missing", qs("fallback")), qs("fallback"), "json: falls back");
}

void test_form_encoding() {
    using slack::net::appendQuery;
    using slack::net::formEncode;
    const auto qs = slack::util::qs;

    // Message text goes through here verbatim, so nothing may be interpolated.
    const QByteArray body = formEncode({{qs("text"), qs("a&b=c d")}, {qs("channel"), qs("C1")}});
    expect(!body.contains("a&b=c d"), "form: encodes the separators in a value");
    expect(body.contains("channel=C1"), "form: keeps ordinary values readable");

    expect_eq(appendQuery(qs("https://x.test/m"), {}), qs("https://x.test/m"),
              "query: no fields means no change");
    expect(appendQuery(qs("https://x.test/m"), {{qs("a"), qs("1")}}).contains('?'),
           "query: first field opens the query string");
    expect(appendQuery(qs("https://x.test/m?z=0"), {{qs("a"), qs("1")}}).contains('&'),
           "query: a second field appends");
}

void test_cursors() {
    const auto qs = slack::util::qs;
    const QJsonObject cursors{{"C1", "1787123637.474259"}, {"C2", QJsonValue(7)}};
    expect_eq(slack::store::cursorFor(cursors, qs("C1")), qs("1787123637.474259"),
              "cursor: reads a stored value");
    expect_eq(slack::store::cursorFor(cursors, qs("C2")), QString(),
              "cursor: a non-string is no cursor");
    expect_eq(slack::store::cursorFor(cursors, qs("nope")), QString(),
              "cursor: an unknown channel has none");
}

// -------------------------------------------------------- history paging

// One raw message as `conversations.history` hands it over: only the subtype
// and the timestamp matter to the paging decision.
QJsonObject raw(const char* ts, const char* subtype) {
    const auto qs = slack::util::qs;
    QJsonObject out{{"ts", qs(ts)}, {"user", qs("UBOB")}, {"text", qs("hi")}};
    if (subtype[0] != '\0')
        out.insert(qs("subtype"), qs(subtype));
    return out;
}

void test_history_paging() {
    using slack::commands::interestingSubtype;
    using slack::commands::nextHistoryPage;
    const auto qs = slack::util::qs;

    // What the sidebar renders, and what it drops.
    for (const char* shown : {"", "bot_message", "thread_broadcast", "me_message", "file_share"})
        expect(interestingSubtype(qs(shown)), std::string("subtype: renders ") + shown);
    for (const char* noise : {"channel_join", "channel_leave", "channel_topic",
                              "channel_purpose", "channel_name"})
        expect(!interestingSubtype(qs(noise)), std::string("subtype: drops ") + noise);

    // The bug: a whole page of joins and leaves shapes down to nothing, so the
    // transcript came back empty with `hasMore: true` and stayed empty. The
    // page has to be continued from its oldest entry.
    const QJsonArray joinsOnly{raw("1781162867.584519", "channel_join"),
                               raw("1779879184.496049", "channel_leave"),
                               raw("1778071692.270579", "channel_join")};
    expect_eq(nextHistoryPage(joinsOnly, true), qs("1778071692.270579"),
              "paging: a page of nothing but joins continues from its oldest entry");

    // One renderable message anywhere in the page is enough to stop.
    const QJsonArray mixed{raw("1781162867.584519", "channel_join"),
                           raw("1779879184.496049", ""),
                           raw("1778071692.270579", "channel_join")};
    expect(nextHistoryPage(mixed, false).isEmpty(),
           "paging: a page with a real message needs no continuation");
    expect(nextHistoryPage(mixed, true).isEmpty(),
           "paging: and not even when Slack says there is more");

    // Nothing older to ask for: `has_more` false, or no page at all. Either
    // would otherwise be a request for the same page forever.
    expect(nextHistoryPage(joinsOnly, false).isEmpty(),
           "paging: joins-only stops when Slack has nothing older");
    expect(nextHistoryPage(QJsonArray{}, true).isEmpty(), "paging: an empty page stops");
    expect(nextHistoryPage(QJsonArray{raw("", "channel_join")}, true).isEmpty(),
           "paging: a page whose oldest entry has no timestamp stops");
}

// ------------------------------------------------------------------ archive

// A key the tests own, so none of this needs a running secret service. The real
// one is 32 random bytes from the keyring.
const QString& testKey() {
    static const QString key = slack::util::qs(
        "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff");
    return key;
}

QString scratchDb(const char* name) {
    const QString dir = QDir::tempPath() + slack::util::qs("/slack-archive-test");
    QDir().mkpath(dir);
    const QString path = dir + '/' + slack::util::qs(name) + slack::util::qs(".db");
    QFile::remove(path);
    QFile::remove(path + slack::util::qs("-wal"));
    QFile::remove(path + slack::util::qs("-shm"));
    return path;
}

QJsonObject message(const char* ts, const char* text, bool edited = false) {
    const auto qs = slack::util::qs;
    return QJsonObject{{"ts", qs(ts)},
                       {"user", qs("UBOB")},
                       {"author", qs("bob")},
                       {"text", qs(text)},
                       {"edited", edited},
                       {"reactions", QJsonArray{}}};
}

void test_archive() {
    using namespace slack::archive;
    const auto qs = slack::util::qs;
    const QString path = scratchDb("basic");

    {
        Db db(path, true, testKey());
        expect(db.ok(), "archive: opens with an explicit key");

        // A first page lands whole.
        const IngestResult first = ingest(db, qs("C1"),
                                          QJsonArray{message("1780000003.0001", "three"),
                                                     message("1780000002.0001", "two"),
                                                     message("1780000001.0001", "one")});
        expect(first.added == 3 && first.revised == 0, "archive: a first page is all new");

        // Re-fetching the same page must not duplicate or revise it.
        const IngestResult again = ingest(db, qs("C1"),
                                          QJsonArray{message("1780000003.0001", "three"),
                                                     message("1780000002.0001", "two")});
        expect(again.added == 0 && again.revised == 0 && again.unchanged == 2,
               "archive: re-fetching the same messages changes nothing");

        // Reactions churn on every poll and are not edits.
        QJsonObject reacted = message("1780000002.0001", "two");
        reacted[qs("reactions")] = QJsonArray{QJsonObject{{"name", qs("tada")}, {"count", 1}}};
        const IngestResult churn = ingest(db, qs("C1"), QJsonArray{reacted});
        expect(churn.revised == 0 && churn.unchanged == 1,
               "archive: a new reaction is stored without making a revision");

        // An actual edit is what a revision is for.
        const IngestResult edit =
            ingest(db, qs("C1"), QJsonArray{message("1780000002.0001", "two, corrected", true)});
        expect(edit.revised == 1 && edit.added == 0, "archive: an edit makes a revision");

        const QJsonArray history = readHistory(db, qs("C1"), 10, {});
        expect(history.size() == 3, "archive: reads back every message once");
        expect(slack::util::str(history.first().toObject(), "ts") == qs("1780000003.0001"),
               "archive: newest first, the way history returns");
        expect(slack::util::str(history.at(1).toObject(), "text") == qs("two, corrected"),
               "archive: the current version is the edited one");

        const QJsonArray revisions = readRevisions(db, qs("C1"), qs("1780000002.0001"));
        expect(revisions.size() == 1, "archive: one superseded version kept");
        expect(slack::util::str(revisions.first().toObject(), "text") == qs("two"),
               "archive: and it is what the message used to say");

        // Paging back, the same contract `history` has.
        const QJsonArray older = readHistory(db, qs("C1"), 10, qs("1780000002.0001"));
        expect(older.size() == 1 && slack::util::str(older.first().toObject(), "ts") == qs("1780000001.0001"),
               "archive: before-ts pages backwards, exclusive");

        expect(readHistory(db, qs("C-unknown"), 10, {}).isEmpty(),
               "archive: an unknown conversation is empty, not an error");
    }

    // The whole point: none of that is readable on disk.
    {
        QFile file(path);
        expect(file.open(QIODevice::ReadOnly), "archive: the file exists");
        const QByteArray bytes = file.readAll();
        expect(!bytes.contains("two, corrected"), "archive: message text is not on disk");
        expect(!bytes.contains("bob"), "archive: author names are not on disk");
        expect(!bytes.startsWith("SQLite format"), "archive: not even the SQLite header is on disk");
    }

    // A wrong key opens nothing.
    {
        Db wrong(path, false,
                 qs("ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"));
        expect(!wrong.ok(), "archive: the wrong key does not open it");
    }

    // Reopening with the right key finds everything still there.
    {
        Db db(path, false, testKey());
        expect(db.ok(), "archive: reopens with the right key");
        expect(readHistory(db, qs("C1"), 10, {}).size() == 3, "archive: survives a reopen");
        const QJsonObject counts = stats(db);
        expect(counts.value(qs("messages")).toInt() == 3, "archive: stats count the messages");
        expect(counts.value(qs("revisions")).toInt() == 1, "archive: stats count the revisions");
    }

    // Opening a database that does not exist, without permission to create it,
    // is the "nothing archived yet" case and must not be an error.
    {
        Db absent(scratchDb("absent"), false, testKey());
        expect(!absent.ok(), "archive: a missing database with createIfMissing off stays closed");
        expect(readHistory(absent, qs("C1"), 10, {}).isEmpty(), "archive: and reads as empty");
    }
}

}  // namespace

int main(int argc, char** argv) {
    // QCoreApplication so Qt's types behave as they do in the real process.
    const QCoreApplication app(argc, argv);

    test_crawlable();
    test_token_kinds();
    test_util();
    test_form_encoding();
    test_cursors();
    test_history_paging();
    test_archive();

    if (g_failures == 0) {
        std::cout << g_checks << " checks passed\n";
        return 0;
    }
    std::cerr << g_failures << " of " << g_checks << " checks failed\n";
    return 1;
}
