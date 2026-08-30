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
#include <QJsonObject>
#include <QString>
#include <QStringList>

#include <cstddef>
#include <iostream>
#include <string_view>

// Includes before imports: see the note in html_meta_test.cpp.
import slack.util;
import slack.net;
import slack.api;
import slack.store;
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

}  // namespace

int main(int argc, char** argv) {
    // QCoreApplication so Qt's types behave as they do in the real process.
    const QCoreApplication app(argc, argv);

    test_crawlable();
    test_token_kinds();
    test_util();
    test_form_encoding();
    test_cursors();

    if (g_failures == 0) {
        std::cout << g_checks << " checks passed\n";
        return 0;
    }
    std::cerr << g_failures << " of " << g_checks << " checks failed\n";
    return 1;
}
