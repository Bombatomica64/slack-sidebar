// SPDX-License-Identifier: MIT
//
// Slack's Web API, plus the identity and token bookkeeping around it.
//
// Auth: a token read fresh from the keyring on every run and never written
// anywhere else. A user token (xoxp-/xoxc-) is preferred wherever one exists; a
// bot token (xoxb-) works with limits that are Slack's, not ours, and `me`
// reports which kind is in use so the sidebar can say so out loud.
//
// Apps with token rotation enabled issue "xoxe.xoxp-…" access tokens that
// expire in about twelve hours plus a refresh token. When Slack answers
// token_expired the call renews once and retries, under a lock file so two
// concurrent runs rotate the token once rather than racing and invalidating
// each other's copy.

module;

#include <QByteArray>
#include <QDateTime>
#include <QFile>
#include <QJsonObject>
#include <QList>
#include <QString>
#include <QStringList>
#include <QThread>

#include <fcntl.h>
#include <sys/file.h>
#include <unistd.h>

#include <utility>
#include <vector>

export module slack.api;

import slack.util;
import slack.keyring;
import slack.net;

namespace u = slack::util;

export namespace slack::api {

inline constexpr const char* kApiBase = "https://slack.com/api";

enum class TokenKind { None, User, Bot, Unknown };

QString kindName(TokenKind kind) {
    switch (kind) {
    case TokenKind::User: return u::qs("user");
    case TokenKind::Bot: return u::qs("bot");
    case TokenKind::Unknown: return u::qs("unknown");
    case TokenKind::None:
    default: break;
    }
    return u::qs("none");
}

// The xoxb-/xoxp- prefix decides *whose* identity a token carries. Scopes
// describe what it may do; no amount of user scopes turns a bot token into a
// user one, which is the single most common confusion when setting this up.
TokenKind kindOf(const QString& token) {
    if (token.startsWith(QLatin1String("xoxe.xoxp-")))
        return TokenKind::User;
    if (token.startsWith(QLatin1String("xoxe.xoxb-")))
        return TokenKind::Bot;
    if (token.startsWith(QLatin1String("xoxp-")) || token.startsWith(QLatin1String("xoxc-")))
        return TokenKind::User;
    if (token.startsWith(QLatin1String("xoxb-")))
        return TokenKind::Bot;
    return TokenKind::Unknown;
}

bool isRotating(const QString& token) {
    return token.startsWith(QLatin1String("xoxe."));
}

bool isAuthError(const QString& code) {
    static const QStringList dead{
        u::qs("token_expired"), u::qs("token_revoked"),
        u::qs("invalid_auth"), u::qs("account_inactive"),
        u::qs("not_authed")};
    return dead.contains(code);
}

// The whole authenticated session: which token, which identity, which caches.
class Session {
public:
    // preference is "auto", "user" or "bot"; meOverride names the human account
    // when acting as a bot, whose auth.test reports the *app's* id rather than
    // yours - without it your own messages look like a stranger's, they inflate
    // the unread count, and @you never matches.
    Session(QString preference, QString meOverride)
        : preference_(std::move(preference)), meOverride_(std::move(meOverride)) {
        u::ensureDirs();
        haveUserToken_ = kindOf(keyring::lookup(keyring::kUserToken)) == TokenKind::User ||
                         kindOf(keyring::lookup(keyring::kBotToken)) == TokenKind::User;
        haveBotToken_ = kindOf(keyring::lookup(keyring::kUserToken)) == TokenKind::Bot ||
                        kindOf(keyring::lookup(keyring::kBotToken)) == TokenKind::Bot;
        selectToken();
    }

    [[nodiscard]] bool haveUserToken() const { return haveUserToken_; }
    [[nodiscard]] bool haveBotToken() const { return haveBotToken_; }
    [[nodiscard]] TokenKind tokenKind() const { return kind_; }
    [[nodiscard]] bool authDead() const { return authDead_; }
    [[nodiscard]] net::Client& http() { return http_; }

    // Per-identity, because a bot and a user token see different conversations
    // and keep different read state; sharing one cache between them would show
    // the wrong list and the wrong badges after a switch.
    [[nodiscard]] QString cursorFile() const { return u::stateDir() + "/cursors-" + kindName(kind_) + ".json"; }
    [[nodiscard]] QString conversationsCache() const { return u::cacheDir() + "/conversations-" + kindName(kind_) + ".json"; }
    [[nodiscard]] QString usersCache() const { return u::cacheDir() + "/users-" + kindName(kind_) + ".json"; }
    [[nodiscard]] QString meCache() const { return u::cacheDir() + "/me-" + kindName(kind_) + ".json"; }

    // The confusing case, spelled out for the header rather than left to fail
    // twelve hours later.
    [[nodiscard]] QString userTokenHint() const {
        const QString stored = keyring::lookup(keyring::kUserToken);
        if (!stored.isEmpty() && isRotating(stored) && keyring::lookup(keyring::kUserRefreshToken).isEmpty()) {
            return u::qs(
                "the stored user token rotates (xoxe.) but no refresh token is saved, so it will "
                "stop working when it expires - sign in again from the account chip");
        }
        if (stored.isEmpty()) {
            return u::qs(
                "no user token stored - sign in with Slack from the account chip");
        }
        if (kindOf(stored) == TokenKind::Bot) {
            return u::qs(
                "the \"user-token\" keyring entry contains a bot token (xoxb-). Configuring User "
                "Token Scopes is not enough: reinstall the app, then copy the separate \"User OAuth "
                "Token\" (xoxp-) from OAuth & Permissions");
        }
        if (kindOf(stored) == TokenKind::Unknown)
            return u::qs("the \"user-token\" keyring entry is not a recognisable Slack token");
        return {};
    }

    // One API call. Retries once on ratelimited or an unreadable response, and
    // once more after renewing a rotating token that Slack has expired.
    QJsonObject call(const QString& verb, const QString& method,
                     const QList<std::pair<QString, QString>>& params = {}) {
        for (int attempt = 1; attempt <= 2; ++attempt) {
            const QJsonObject response = callOnce(verb, method, params);
            const QString error = u::str(response, "error");

            if (error == QLatin1String("ratelimited") && attempt == 1) {
                QThread::msleep(3000);
                continue;
            }
            if (error == QLatin1String("__transport") && attempt == 1) {
                QThread::msleep(2000);
                continue;
            }
            if (isAuthError(error)) {
                if (attempt == 1 && isRotating(token_) && refreshUserToken())
                    continue;
                // Renewal is impossible: the session is genuinely dead. Drop the
                // cached identity so `me` stops cheerfully reporting a signed-in
                // user from day-old data.
                authDead_ = true;
                QFile::remove(meCache());
            }
            return response;
        }
        return {{"ok", false}, {"error", u::qs("no response from ") + method}};
    }

    // Several calls at once, which is what makes polling twenty conversations
    // one round trip's worth of latency instead of twenty.
    std::vector<QJsonObject> callMany(const QString& method,
                                      const std::vector<QList<std::pair<QString, QString>>>& paramSets) {
        std::vector<net::Request> requests;
        requests.reserve(paramSets.size());
        for (const auto& params : paramSets)
            requests.push_back(buildRequest(u::qs("GET"), method, params));

        std::vector<QJsonObject> out;
        out.reserve(paramSets.size());
        for (const net::Response& response : http_.requestMany(requests))
            out.push_back(decode(response, method));

        // A batch that came back expired is worth one renewal and one retry, the
        // same as a single call.
        bool expired = false;
        for (const QJsonObject& object : out)
            expired = expired || isAuthError(u::str(object, "error"));
        if (expired && isRotating(token_) && refreshUserToken()) {
            requests.clear();
            for (const auto& params : paramSets)
                requests.push_back(buildRequest(u::qs("GET"), method, params));
            out.clear();
            for (const net::Response& response : http_.requestMany(requests))
                out.push_back(decode(response, method));
        } else if (expired) {
            authDead_ = true;
            QFile::remove(meCache());
        }
        return out;
    }

    // auth.test, cached for a day: it is the same answer every time until the
    // identity changes, and every subcommand needs it.
    QJsonObject me() {
        if (u::fresh(meCache(), 86400)) {
            const QJsonObject cached = u::readJsonObject(meCache());
            if (u::str(cached, "tokenKind") == kindName(kind_))
                return cached;
        }
        const QJsonObject response = call(u::qs("GET"), u::qs("auth.test"));
        if (!u::boolean(response, "ok")) {
            const QString error = u::str(response, "error", u::qs("auth.test failed"));
            return {{"ok", false},
                    {"error", error},
                    {"needsSignIn", isAuthError(error)},
                    {"tokenKind", kindName(kind_)},
                    {"haveUserToken", haveUserToken_},
                    {"haveBotToken", haveBotToken_}};
        }
        const QJsonObject identity{
            {"ok", true},
            {"userId", u::str(response, "user_id")},
            {"user", u::str(response, "user")},
            {"team", u::str(response, "team")},
            {"teamId", u::str(response, "team_id")},
            {"url", u::str(response, "url")},
            {"tokenKind", kindName(kind_)},
            {"haveUserToken", haveUserToken_},
            {"haveBotToken", haveBotToken_},
            {"userTokenHint", userTokenHint()}};
        u::writeJsonAtomic(meCache(), identity);
        return identity;
    }

    // The identity to attribute messages and mentions to.
    QString meId() {
        if (!meOverride_.isEmpty())
            return meOverride_;
        return u::str(me(), "userId");
    }

    // Everything that counts as "you": the override and the token's own
    // identity, so messages this app posted on your behalf are not shown as
    // somebody else's.
    QStringList mineIds() {
        QStringList out;
        if (!meOverride_.isEmpty())
            out << meOverride_;
        const QString own = u::str(me(), "userId");
        if (!own.isEmpty() && !out.contains(own))
            out << own;
        return out;
    }

private:
    void selectToken() {
        const auto pick = [this](TokenKind want) {
            for (const char* account : {keyring::kUserToken, keyring::kBotToken}) {
                const QString candidate = keyring::lookup(account);
                if (!candidate.isEmpty() && kindOf(candidate) == want) {
                    token_ = candidate;
                    kind_ = want;
                    return true;
                }
            }
            return false;
        };

        if (preference_ == QLatin1String("user")) {
            if (!pick(TokenKind::User))
                u::fail(userTokenHint());
        } else if (preference_ == QLatin1String("bot")) {
            if (!pick(TokenKind::Bot))
                u::fail(u::qs("no bot token (xoxb-) in keyring"));
        } else if (!pick(TokenKind::User)) {
            pick(TokenKind::Bot);
        }

        if (token_.isEmpty()) {
            // Nothing recognisable; fall back to whatever is stored so the error
            // can name it.
            for (const char* account : {keyring::kUserToken, keyring::kBotToken}) {
                token_ = keyring::lookup(account);
                if (!token_.isEmpty()) {
                    kind_ = kindOf(token_);
                    break;
                }
            }
        }
        if (token_.isEmpty()) {
            u::fail(u::qs("no Slack token in keyring - sign in with Slack from the "
                                   "account chip in the sidebar"),
                    true);
        }
        migrateLegacyCaches();
    }

    // One-time carry-over from the layout before the caches were split per
    // identity.
    void migrateLegacyCaches() const {
        const std::pair<QString, QString> pairs[] = {
            {u::stateDir() + "/cursors.json", cursorFile()},
            {u::cacheDir() + "/users.json", usersCache()}};
        for (const auto& [legacy, current] : pairs) {
            if (QFile::exists(legacy) && !QFile::exists(current))
                QFile::copy(legacy, current);
        }
    }

    [[nodiscard]] net::Request buildRequest(const QString& verb, const QString& method,
                                            const QList<std::pair<QString, QString>>& params) const {
        net::Request request;
        request.headers.append({QByteArrayLiteral("Authorization"), ("Bearer " + token_).toUtf8()});
        if (verb == QLatin1String("POST")) {
            request.method = u::qs("POST");
            request.url = QString::fromLatin1(kApiBase) + "/" + method;
            request.body = net::formEncode(params);
            request.contentType = u::qs("application/x-www-form-urlencoded; charset=utf-8");
        } else {
            request.url = net::appendQuery(QString::fromLatin1(kApiBase) + "/" + method, params);
        }
        return request;
    }

    [[nodiscard]] static QJsonObject decode(const net::Response& response, const QString& method) {
        if (!response.transportOk())
            return {{"ok", false}, {"error", u::qs("__transport")}, {"method", method}};
        bool parsed = false;
        const QJsonObject object = u::parseObject(response.body, &parsed);
        if (!parsed)
            return {{"ok", false}, {"error", u::qs("__transport")}, {"method", method}};
        return object;
    }

    QJsonObject callOnce(const QString& verb, const QString& method,
                         const QList<std::pair<QString, QString>>& params) {
        return decode(http_.request(buildRequest(verb, method, params)), method);
    }

    // Renew a rotating token. Under flock, because two runs hitting an expired
    // token at the same time would each spend the one-shot refresh token and
    // one of them would lose.
    bool refreshUserToken() {
        const QString started = token_;
        const int lock = ::open((u::stateDir() + "/refresh.lock").toLocal8Bit().constData(),
                                O_CREAT | O_RDWR | O_CLOEXEC, 0600);
        if (lock >= 0)
            ::flock(lock, LOCK_EX);

        // Another process may have rotated it while we waited for the lock.
        const QString current = keyring::lookup(keyring::kUserToken);
        if (current != started && !current.isEmpty()) {
            token_ = current;
            if (lock >= 0) {
                ::flock(lock, LOCK_UN);
                ::close(lock);
            }
            return true;
        }

        const bool renewed = doRefresh();
        if (lock >= 0) {
            ::flock(lock, LOCK_UN);
            ::close(lock);
        }
        if (!renewed)
            return false;
        const QString fresh = keyring::lookup(keyring::kUserToken);
        if (fresh.isEmpty() || fresh == started)
            return false;
        token_ = fresh;
        return true;
    }

    bool doRefresh() {
        const QString refresh = keyring::lookup(keyring::kUserRefreshToken);
        const QString clientId = keyring::lookup(keyring::kClientId);
        const QString clientSecret = keyring::lookup(keyring::kClientSecret);
        if (refresh.isEmpty() || clientId.isEmpty() || clientSecret.isEmpty())
            return false;

        net::Request request;
        request.method = u::qs("POST");
        request.url = QString::fromLatin1(kApiBase) + "/oauth.v2.access";
        request.contentType = u::qs("application/x-www-form-urlencoded; charset=utf-8");
        request.body = net::formEncode({{u::qs("grant_type"), u::qs("refresh_token")},
                                        {u::qs("refresh_token"), refresh},
                                        {u::qs("client_id"), clientId},
                                        {u::qs("client_secret"), clientSecret}});
        const QJsonObject response = decode(http_.request(request), u::qs("oauth.v2.access"));
        if (!u::boolean(response, "ok"))
            return false;

        // Rotation responses put the new pair either at the top level or under
        // authed_user, depending on which token type was refreshed.
        const QJsonObject authed = u::object(response, "authed_user");
        const QString access = u::str(response, "access_token", u::str(authed, "access_token"));
        const QString newRefresh = u::str(response, "refresh_token", u::str(authed, "refresh_token"));
        if (access.isEmpty())
            return false;

        keyring::store(keyring::kUserToken, u::qs("Slack User Token"), access);
        if (!newRefresh.isEmpty())
            keyring::store(keyring::kUserRefreshToken, u::qs("Slack User Refresh Token"), newRefresh);
        return true;
    }

    QString preference_;
    QString meOverride_;
    QString token_;
    TokenKind kind_ = TokenKind::None;
    bool haveUserToken_ = false;
    bool haveBotToken_ = false;
    bool authDead_ = false;
    net::Client http_;
};

}  // namespace slack::api
