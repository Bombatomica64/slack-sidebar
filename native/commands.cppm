// SPDX-License-Identifier: MIT
//
// The subcommands. One function per verb, each returning the single JSON object
// the sidebar reads.
//
// Everything here was a jq program in the shell version. The shapes are kept
// byte-for-byte compatible on purpose: the QML side is not part of this change,
// and a field quietly renamed in the port would show up as an empty sidebar
// rather than as a build error.

module;

#include <QAbstractSocket>
#include <QByteArray>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonObject>
#include <QList>
#include <QRegularExpression>
#include <QHostAddress>
#include <QString>
#include <QStringList>
#include <QUrl>

#include <algorithm>
#include <string_view>
#include <utility>
#include <vector>

export module slack.commands;

import slack.util;
import slack.keyring;
import slack.net;
import slack.api;
import slack.store;
import slack.html;

namespace u = slack::util;
namespace net = slack::net;
namespace html = slack::html;

export namespace slack::commands {
// Declared here because the file-local helpers below call it, and defined with
// the rest of the exported surface further down.
bool crawlable(const QString& url);
}  // namespace slack::commands

namespace {

// Subtypes worth showing. Everything else (joins, leaves, topic changes) is
// noise in a sidebar this size.
bool interestingSubtype(const QString& subtype) {
    return subtype.isEmpty() || subtype == u::qs("bot_message") ||
           subtype == u::qs("thread_broadcast") || subtype == u::qs("me_message") ||
           subtype == u::qs("file_share");
}

QString authorOf(const QJsonObject& message, const QJsonObject& users) {
    const QString user = u::str(message, "user");
    if (!user.isEmpty()) {
        const QString name = u::str(users.value(user).toObject(), "name");
        if (!name.isEmpty())
            return name;
        return u::str(message, "username", user);
    }
    const QString username = u::str(message, "username");
    if (!username.isEmpty())
        return username;
    const QString botName = u::str(u::object(message, "bot_profile"), "name");
    return botName.isEmpty() ? u::qs("bot") : botName;
}

bool isMine(const QJsonObject& message, const QStringList& mine) {
    const QString user = u::str(message, "user");
    return !user.isEmpty() && mine.contains(user);
}

QJsonArray shapeReactions(const QJsonObject& message, const QStringList& mine) {
    QJsonArray out;
    for (const QJsonValue value : u::array(message, "reactions")) {
        const QJsonObject reaction = value.toObject();
        bool ours = false;
        for (const QJsonValue who : u::array(reaction, "users"))
            ours = ours || mine.contains(who.toString());
        out.append(QJsonObject{{"name", u::str(reaction, "name")},
                               {"count", reaction.value(u::qs("count")).toInt()},
                               {"mine", ours}});
    }
    return out;
}

QJsonArray shapeFiles(const QJsonObject& message) {
    QJsonArray out;
    for (const QJsonValue value : u::array(message, "files")) {
        const QJsonObject file = value.toObject();
        out.append(QJsonObject{{"name", u::str(file, "name", u::str(file, "title", u::qs("file")))},
                               {"url", u::str(file, "permalink")},
                               {"type", u::str(file, "filetype")}});
    }
    return out;
}

QJsonArray shapeAttachments(const QJsonObject& message) {
    QJsonArray out;
    for (const QJsonValue value : u::array(message, "attachments")) {
        const QJsonObject attachment = value.toObject();
        const QString link = u::str(attachment, "title_link",
                                    u::str(attachment, "original_url", u::str(attachment, "from_url")));
        QString image = u::str(attachment, "image_url");
        if (image.isEmpty())
            image = u::str(attachment, "thumb_url");
        out.append(QJsonObject{
            {"title", u::str(attachment, "title")},
            {"text", u::str(attachment, "text", u::str(attachment, "fallback"))},
            {"url", link},
            {"fromUrl", u::str(attachment, "from_url", u::str(attachment, "original_url"))},
            {"site", u::str(attachment, "service_name")},
            {"siteIcon", u::str(attachment, "service_icon")},
            {"author", u::str(attachment, "author_name")},
            {"image", image},
            {"footer", u::str(attachment, "footer")},
            {"color", u::str(attachment, "color")}});
    }
    return out;
}

// Raw Slack messages into what the UI consumes.
QJsonArray shapeMessages(const QJsonArray& messages, const QJsonObject& users, const QStringList& mine) {
    QJsonArray out;
    for (const QJsonValue value : messages) {
        const QJsonObject message = value.toObject();
        const QString subtype = u::str(message, "subtype");
        if (!interestingSubtype(subtype))
            continue;

        const QString user = u::str(message, "user");
        const QString botId = u::str(message, "bot_id");
        QString image;
        if (!user.isEmpty())
            image = u::str(users.value(user).toObject(), "image");
        else
            image = u::str(u::object(u::object(message, "bot_profile"), "icons"), "image_48");

        QJsonArray replyUsers;
        for (const QJsonValue reply : u::array(message, "reply_users"))
            replyUsers.append(reply);

        out.append(QJsonObject{{"ts", u::str(message, "ts")},
                               {"user", user.isEmpty() ? botId : user},
                               {"author", authorOf(message, users)},
                               {"image", image},
                               {"mine", isMine(message, mine)},
                               {"text", u::str(message, "text")},
                               {"subtype", subtype},
                               {"edited", message.contains(u::qs("edited"))},
                               {"threadTs", u::str(message, "thread_ts")},
                               {"replyCount", message.value(u::qs("reply_count")).toInt()},
                               {"replyUsers", replyUsers},
                               {"isBot", !botId.isEmpty() && user.isEmpty()},
                               {"reactions", shapeReactions(message, mine)},
                               {"files", shapeFiles(message)},
                               {"attachments", shapeAttachments(message)}});
    }
    return out;
}

QStringList collectUserIds(const QJsonArray& messages) {
    QStringList ids;
    for (const QJsonValue value : messages) {
        const QJsonObject message = value.toObject();
        const QString user = u::str(message, "user");
        if (!user.isEmpty() && !ids.contains(user))
            ids << user;
        for (const QJsonValue reaction : u::array(message, "reactions")) {
            for (const QJsonValue who : u::array(reaction.toObject(), "users")) {
                const QString id = who.toString();
                if (!id.isEmpty() && !ids.contains(id))
                    ids << id;
            }
        }
    }
    return ids;
}

QStringList splitIds(const QString& csv) {
    QStringList out;
    for (const QString& part : csv.split(',', Qt::SkipEmptyParts)) {
        const QString id = part.trimmed();
        if (!id.isEmpty() && !out.contains(id))
            out << id;
    }
    return out;
}

// ------------------------------------------------------------ link previews

QString assetExtension(const QString& contentType) {
    const QString type = contentType.toLower();
    if (type.contains(u::qs("png")))
        return u::qs("png");
    if (type.contains(u::qs("jpeg")) || type.contains(u::qs("jpg")))
        return u::qs("jpg");
    if (type.contains(u::qs("gif")))
        return u::qs("gif");
    if (type.contains(u::qs("webp")))
        return u::qs("webp");
    if (type.contains(u::qs("svg")))
        return u::qs("svg");
    if (type.contains(u::qs("avif")))
        return u::qs("avif");
    if (type.contains(u::qs("icon")) || type.contains(u::qs("ico")))
        return u::qs("ico");
    return {};
}

// Mirror an image next to the cards. Qt loads a remote image happily enough,
// but a local file cannot pop in late while the transcript scrolls, and it
// costs nothing on the second read of the same conversation.
QString mirrorAsset(net::Client& http, const QString& url, const QString& directory, qint64 maxBytes) {
    if (url.isEmpty() || !slack::commands::crawlable(url))
        return {};
    QDir().mkpath(directory);
    const QString key = u::hashOf(url);

    const QStringList existing = QDir(directory).entryList({key + u::qs(".*")}, QDir::Files);
    if (!existing.isEmpty())
        return directory + '/' + existing.first();

    net::Request request;
    request.url = url;
    request.maxRedirects = 3;
    request.maxBytes = maxBytes;
    request.timeoutMs = 15000;
    const net::Response response = http.request(request);
    if (!response.transportOk() || response.status >= 400 || response.body.isEmpty())
        return {};
    const QString extension = assetExtension(response.contentType);
    // Not an image: do not hand the UI a web page to draw.
    if (extension.isEmpty())
        return {};

    const QString path = directory + '/' + key + '.' + extension;
    if (!u::writeFileAtomic(path, response.body))
        return {};
    return path;
}

}  // namespace

export namespace slack::commands {
// Only public http(s) may be crawled. A colleague pasting
// http://127.0.0.1:8080/shutdown must not make this machine visit it, and the
// same goes for cloud metadata endpoints and anything on the LAN. This checks
// the address as written; it is not a defence against a public hostname that
// resolves to a private one.
// Exported so the tests can reach it. Everything else in this module needs a
// Slack token or the network; this is pure, and it is the piece most worth
// pinning down.
bool crawlable(const QString& url) {
    const QUrl parsed(url);
    const QString scheme = parsed.scheme();
    if (scheme != u::qs("http") && scheme != u::qs("https"))
        return false;
    const QString host = parsed.host().toLower();
    if (host.isEmpty())
        return false;

    static const QStringList badSuffixes{u::qs(".localhost"), u::qs(".local"), u::qs(".internal"),
                                         u::qs(".home.arpa"), u::qs(".onion")};
    if (host == u::qs("localhost"))
        return false;
    for (const QString& suffix : badSuffixes) {
        if (host.endsWith(suffix))
            return false;
    }

    const QHostAddress address(host);
    if (!address.isNull()) {
        // A literal address: judge it directly rather than by prefix matching.
        if (address.isLoopback() || address.isLinkLocal() || address.isSiteLocal() ||
            address.isMulticast() || address.isBroadcast() || address.isNull())
            return false;
        if (address.protocol() == QAbstractSocket::IPv4Protocol) {
            const quint32 v4 = address.toIPv4Address();
            // Written as base address and prefix length rather than by hand:
            // the hand-rolled version of this had 172.16/12 and 100.64/10 wrong
            // and let both through, which the tests caught.
            struct Range {
                quint32 base;
                int prefix;
            };
            static constexpr Range kPrivate[]{
                {0x00000000u, 8},   // 0.0.0.0/8, "this network"
                {0x0A000000u, 8},   // 10/8
                {0x64400000u, 10},  // 100.64/10, carrier-grade NAT
                {0x7F000000u, 8},   // 127/8, loopback
                {0xA9FE0000u, 16},  // 169.254/16, link-local
                {0xAC100000u, 12},  // 172.16/12
                {0xC0A80000u, 16},  // 192.168/16
                {0xE0000000u, 4},   // 224/4, multicast
                {0xF0000000u, 4},   // 240/4, reserved
            };
            for (const Range& range : kPrivate) {
                const quint32 mask = range.prefix == 0
                                         ? 0u
                                         : ~((quint32{1} << (32 - range.prefix)) - 1);
                if ((v4 & mask) == range.base)
                    return false;
            }
        }
        return true;
    }
    // A name with no dot is a LAN hostname, not something on the public internet.
    return host.contains('.');
}


QString unfurlDir() { return u::cacheDir() + u::qs("/unfurl"); }
QString unfurlAssetsDir() { return u::cacheDir() + u::qs("/unfurl-img"); }
QString emojiDir() { return u::cacheDir() + u::qs("/emoji-img"); }
QString avatarDir() { return u::cacheDir() + u::qs("/avatars"); }

// A good page keeps for a week; a 404 or a timeout is retried in six hours, so
// a flaky host recovers but a dead link is not re-fetched on every poll.
inline constexpr qint64 kUnfurlTtl = 604800;
inline constexpr qint64 kUnfurlFailTtl = 21600;
inline constexpr qint64 kAssetMaxBytes = 4000000;

// ----------------------------------------------------------------- identity

QJsonObject me(api::Session& session) {
    QJsonObject identity = session.me();
    if (!u::boolean(identity, "ok"))
        identity[u::qs("needsSignIn")] = session.authDead() || u::boolean(identity, "needsSignIn");
    return identity;
}

QJsonObject tokens(api::Session& session) {
    return {{"ok", true},
            {"haveUserToken", session.haveUserToken()},
            {"haveBotToken", session.haveBotToken()},
            {"active", api::kindName(session.tokenKind())}};
}

QJsonObject credentials() {
    return {{"ok", true},
            {"haveClientId", !keyring::lookup(keyring::kClientId).isEmpty()},
            {"haveClientSecret", !keyring::lookup(keyring::kClientSecret).isEmpty()},
            {"haveRefreshToken", !keyring::lookup(keyring::kUserRefreshToken).isEmpty()}};
}

QJsonObject setCredentials(const QString& clientId, const QString& clientSecret) {
    if (clientId.isEmpty() || clientSecret.isEmpty())
        return {{"ok", false}, {"error", u::qs("usage: slack-agent set-credentials <client-id> <client-secret>")}};
    keyring::store(keyring::kClientId, u::qs("Slack App Client ID"), clientId);
    keyring::store(keyring::kClientSecret, u::qs("Slack App Client Secret"), clientSecret);
    return {{"ok", true}};
}

// ------------------------------------------------------------ conversations

QJsonObject list(api::Session& session, bool force) {
    return store::loadConversations(session, force);
}

QJsonObject join(api::Session& session, const QString& channel) {
    const QJsonObject response =
        session.call(u::qs("POST"), u::qs("conversations.join"), {{u::qs("channel"), channel}});
    if (!u::boolean(response, "ok")) {
        const QString error = u::str(response, "error", u::qs("conversations.join failed"));
        return {{"ok", false}, {"error", error}, {"needsSignIn", api::isAuthError(error)}};
    }
    QFile::remove(session.conversationsCache());
    return {{"ok", true}};
}

// ---------------------------------------------------------------- messages

QJsonObject history(api::Session& session, const QString& channel, int limit) {
    const QJsonObject response =
        session.call(u::qs("GET"), u::qs("conversations.history"),
                     {{u::qs("channel"), channel},
                      {u::qs("limit"), QString::number(limit)},
                      {u::qs("inclusive"), u::qs("true")}});
    if (!u::boolean(response, "ok")) {
        const QString error = u::str(response, "error", u::qs("conversations.history failed"));
        return {{"ok", false}, {"error", error}, {"needsSignIn", api::isAuthError(error)}};
    }
    const QJsonArray raw = u::array(response, "messages");
    const QJsonObject users = store::resolveUsers(session, collectUserIds(raw));
    return {{"ok", true},
            {"messages", shapeMessages(raw, users, session.mineIds())},
            {"users", users},
            {"readCursor", store::cursorFor(store::cursors(session), channel)},
            {"hasMore", u::boolean(response, "has_more")}};
}

QJsonObject replies(api::Session& session, const QString& channel, const QString& thread) {
    const QJsonObject response = session.call(u::qs("GET"), u::qs("conversations.replies"),
                                              {{u::qs("channel"), channel},
                                               {u::qs("ts"), thread},
                                               {u::qs("limit"), u::qs("100")}});
    if (!u::boolean(response, "ok")) {
        const QString error = u::str(response, "error", u::qs("conversations.replies failed"));
        return {{"ok", false}, {"error", error}, {"needsSignIn", api::isAuthError(error)}};
    }
    const QJsonArray raw = u::array(response, "messages");
    const QJsonObject users = store::resolveUsers(session, collectUserIds(raw));
    QJsonArray shaped = shapeMessages(raw, users, session.mineIds());

    // The transcript wants newest first, the same as conversations.history.
    std::vector<QJsonObject> rows;
    rows.reserve(static_cast<std::size_t>(shaped.size()));
    for (const QJsonValue value : shaped)
        rows.push_back(value.toObject());
    std::sort(rows.begin(), rows.end(), [](const QJsonObject& a, const QJsonObject& b) {
        return u::ts(u::str(a, "ts")) > u::ts(u::str(b, "ts"));
    });
    QJsonArray ordered;
    for (const QJsonObject& row : rows)
        ordered.append(row);

    return {{"ok", true}, {"messages", ordered}, {"users", users}};
}

QJsonObject send(api::Session& session, const QString& channel, const QString& text,
                        const QString& thread) {
    QList<std::pair<QString, QString>> params{{u::qs("channel"), channel},
                                              {u::qs("text"), text},
                                              {u::qs("unfurl_links"), u::qs("true")},
                                              {u::qs("unfurl_media"), u::qs("true")}};
    if (!thread.isEmpty())
        params.append({u::qs("thread_ts"), thread});

    const QJsonObject response = session.call(u::qs("POST"), u::qs("chat.postMessage"), params);
    if (!u::boolean(response, "ok")) {
        const QString error = u::str(response, "error", u::qs("chat.postMessage failed"));
        return {{"ok", false}, {"error", error}, {"needsSignIn", api::isAuthError(error)}};
    }
    const QString ts = u::str(response, "ts");
    // Your own message is read by definition; moving the cursor here stops it
    // counting against you until the next poll.
    store::cursorSet(session, channel, ts);
    return {{"ok", true}, {"ts", ts}};
}

QJsonObject markRead(api::Session& session, const QString& channel, const QString& ts) {
    store::cursorSet(session, channel, ts);
    const QJsonObject response = session.call(u::qs("POST"), u::qs("conversations.mark"),
                                              {{u::qs("channel"), channel}, {u::qs("ts"), ts}});
    // Pushing the cursor back to Slack is optional - it needs a write scope the
    // token may not have - so a failure here is reported, not fatal: the local
    // cursor has already moved and the badge is already right.
    return {{"ok", true},
            {"marked", u::boolean(response, "ok")},
            {"markError", u::str(response, "error")}};
}

QJsonObject react(api::Session& session, const QString& channel, const QString& ts,
                         const QString& name, bool remove) {
    const QJsonObject response =
        session.call(u::qs("POST"), remove ? u::qs("reactions.remove") : u::qs("reactions.add"),
                     {{u::qs("channel"), channel}, {u::qs("timestamp"), ts}, {u::qs("name"), name}});
    if (!u::boolean(response, "ok")) {
        const QString error = u::str(response, "error", u::qs("reaction failed"));
        return {{"ok", false}, {"error", error}, {"needsSignIn", api::isAuthError(error)}};
    }
    return {{"ok", true}};
}

// -------------------------------------------------------------------- poll

QJsonObject poll(api::Session& session, const QString& idsCsv) {
    const QStringList ids = splitIds(idsCsv);
    if (ids.isEmpty())
        return {{"ok", true}, {"conversations", QJsonObject{}}};

    std::vector<QList<std::pair<QString, QString>>> params;
    params.reserve(static_cast<std::size_t>(ids.size()));
    for (const QString& id : ids)
        params.push_back({{u::qs("channel"), id}, {u::qs("limit"), u::qs("20")}});

    const std::vector<QJsonObject> responses = session.callMany(u::qs("conversations.history"), params);

    QStringList userIds;
    for (const QJsonObject& response : responses) {
        for (const QString& id : collectUserIds(u::array(response, "messages"))) {
            if (!userIds.contains(id))
                userIds << id;
        }
    }
    const QJsonObject users = store::resolveUsers(session, userIds);
    const QJsonObject cursors = store::cursors(session);
    const QStringList mine = session.mineIds();
    const QString meId = session.meId();

    // Matches @you, @here, @channel and @everyone in Slack's entity form.
    const QRegularExpression mentionPattern(
        u::qs("<@") + QRegularExpression::escape(meId) + u::qs(">|<!here>|<!channel>|<!everyone>"));

    QJsonObject conversations;
    bool needsSignIn = false;

    for (int i = 0; i < ids.size(); ++i) {
        const QJsonObject& response = responses[static_cast<std::size_t>(i)];
        const QString id = ids[i];
        const QString error = u::str(response, "error");
        needsSignIn = needsSignIn || api::isAuthError(error);

        const QString cursor = store::cursorFor(cursors, id);
        const double cursorTs = u::ts(cursor);

        QJsonArray unread;
        QJsonObject latest;
        bool haveLatest = false;
        bool mention = false;

        for (const QJsonValue value : u::array(response, "messages")) {
            const QJsonObject message = value.toObject();
            if (!haveLatest && interestingSubtype(u::str(message, "subtype"))) {
                latest = message;
                haveLatest = true;
            }
            if (u::ts(u::str(message, "ts")) <= cursorTs)
                continue;
            if (isMine(message, mine))
                continue;
            unread.append(message);
            mention = mention || u::str(message, "text").contains(mentionPattern);
        }

        QJsonValue latestValue = QJsonValue::Null;
        if (haveLatest) {
            latestValue = QJsonObject{{"ts", u::str(latest, "ts")},
                                      {"author", authorOf(latest, users)},
                                      {"mine", isMine(latest, mine)},
                                      {"text", u::flatten(u::str(latest, "text"))}};
        }

        // The newest genuinely unread message. `latest` can be your own reply
        // sitting on top of it, which must never be what a notification says.
        QJsonValue latestUnread = QJsonValue::Null;
        if (!unread.isEmpty()) {
            const QJsonObject first = unread.first().toObject();
            latestUnread = QJsonObject{{"ts", u::str(first, "ts")},
                                       {"user", u::str(first, "user")},
                                       {"author", authorOf(first, users)},
                                       {"text", u::flatten(u::str(first, "text"))}};
        }

        conversations[id] = QJsonObject{{"ok", u::boolean(response, "ok")},
                                        {"error", error},
                                        {"unread", unread.size()},
                                        {"mention", mention},
                                        {"cursor", cursor},
                                        {"latest", latestValue},
                                        {"latestUnread", latestUnread}};
    }

    return {{"ok", true}, {"me", meId}, {"needsSignIn", needsSignIn}, {"conversations", conversations}};
}

// Reconcile local cursors with Slack's own read state, so reading a channel on
// your phone clears the badge here too.
QJsonObject syncRead(api::Session& session, const QString& idsCsv) {
    const QStringList ids = splitIds(idsCsv);
    if (ids.isEmpty())
        return {{"ok", true}, {"cursors", QJsonObject{}}};

    std::vector<QList<std::pair<QString, QString>>> params;
    params.reserve(static_cast<std::size_t>(ids.size()));
    for (const QString& id : ids)
        params.push_back({{u::qs("channel"), id}});

    QJsonObject merged = store::cursors(session);
    for (const QJsonObject& response : session.callMany(u::qs("conversations.info"), params)) {
        if (!u::boolean(response, "ok"))
            continue;
        const QJsonObject channel = u::object(response, "channel");
        const QString id = u::str(channel, "id");
        const QString lastRead = u::str(channel, "last_read");
        if (id.isEmpty() || lastRead.isEmpty())
            continue;
        if (u::ts(store::cursorFor(merged, id)) < u::ts(lastRead))
            merged[id] = lastRead;
    }
    u::writeJsonAtomic(session.cursorFile(), merged);
    return {{"ok", true}, {"cursors", merged}};
}

// -------------------------------------------------------- mirrored assets

QJsonObject avatars(api::Session& session) {
    const QJsonObject users = store::usersCache(session);
    QDir().mkpath(avatarDir());

    net::Client http;
    std::vector<net::Request> requests;
    QStringList targets;
    QJsonObject map;

    for (auto it = users.begin(); it != users.end(); ++it) {
        const QString image = u::str(it.value().toObject(), "image");
        if (image.isEmpty())
            continue;
        // Slack's avatar URLs end in the extension; keep it so the file is
        // recognisable, and default to png when it is something odd.
        QString extension = QFileInfo(QUrl(image).path()).suffix().toLower();
        static const QStringList known{u::qs("png"), u::qs("gif"), u::qs("jpg"), u::qs("jpeg"), u::qs("webp")};
        if (!known.contains(extension))
            extension = u::qs("png");
        const QString path = avatarDir() + '/' + it.key() + '.' + extension;
        map[it.key()] = path;
        if (QFileInfo::exists(path))
            continue;
        // Two hundred is more faces than any sidebar shows in a session; the cap
        // stops a first run on a large workspace becoming a download storm.
        if (requests.size() >= 200)
            continue;
        net::Request request;
        request.url = image;
        request.maxRedirects = 2;
        request.maxBytes = kAssetMaxBytes;
        request.timeoutMs = 15000;
        requests.push_back(request);
        targets << path;
    }

    const std::vector<net::Response> responses = http.requestMany(requests);
    for (std::size_t i = 0; i < responses.size(); ++i) {
        const net::Response& response = responses[i];
        if (response.transportOk() && response.status < 400 && !response.body.isEmpty())
            u::writeFileAtomic(targets[static_cast<int>(i)], response.body);
    }
    return {{"ok", true}, {"avatars", map}};
}

QJsonObject emoji(api::Session& session) {
    const QString cachePath = u::cacheDir() + u::qs("/emoji-") + api::kindName(session.tokenKind()) + u::qs(".json");
    QJsonObject raw;
    if (u::fresh(cachePath, 86400)) {
        raw = u::readJsonObject(cachePath);
    } else {
        const QJsonObject response = session.call(u::qs("GET"), u::qs("emoji.list"));
        if (!u::boolean(response, "ok")) {
            // Custom emoji are a nicety; failing to list them must not make the
            // sidebar look broken.
            return {{"ok", true}, {"emoji", QJsonObject{}}, {"aliases", QJsonObject{}}};
        }
        raw = u::object(response, "emoji");
        u::writeJsonAtomic(cachePath, raw);
    }

    QDir().mkpath(emojiDir());
    net::Client http;
    QJsonObject direct;
    QJsonObject aliases;
    std::vector<net::Request> requests;
    QStringList targets;

    for (auto it = raw.begin(); it != raw.end(); ++it) {
        const QString value = it.value().toString();
        if (value.startsWith(u::qs("alias:"))) {
            aliases[it.key()] = value.mid(6);
            continue;
        }
        QString extension = QFileInfo(QUrl(value).path()).suffix().toLower();
        static const QStringList known{u::qs("png"), u::qs("gif"), u::qs("jpg"), u::qs("jpeg"), u::qs("webp")};
        if (!known.contains(extension))
            extension = u::qs("png");
        const QString path = emojiDir() + '/' + it.key() + '.' + extension;
        direct[it.key()] = path;
        if (QFileInfo::exists(path) || requests.size() >= 400)
            continue;
        net::Request request;
        request.url = value;
        request.maxRedirects = 2;
        request.maxBytes = kAssetMaxBytes;
        request.timeoutMs = 15000;
        requests.push_back(request);
        targets << path;
    }

    const std::vector<net::Response> responses = http.requestMany(requests);
    for (std::size_t i = 0; i < responses.size(); ++i) {
        const net::Response& response = responses[i];
        if (response.transportOk() && response.status < 400 && !response.body.isEmpty())
            u::writeFileAtomic(targets[static_cast<int>(i)], response.body);
    }
    return {{"ok", true}, {"emoji", direct}, {"aliases", aliases}};
}

// ------------------------------------------------------------ link previews

QJsonObject unfurl(const QStringList& urlsIn) {
    QDir().mkpath(unfurlDir());
    QDir().mkpath(unfurlAssetsDir());

    QStringList urls;
    for (const QString& url : urlsIn) {
        if (!url.isEmpty() && !urls.contains(url))
            urls << url;
    }
    // Slack unfurls a handful of links per message, not a hundred; the cap is
    // what stops one pasted wall of text from spawning a crawl storm.
    if (urls.size() > 24)
        urls = urls.mid(0, 24);
    if (urls.isEmpty())
        return {{"ok", true}, {"unfurls", QJsonObject{}}};

    net::Client http;
    QStringList wanted;
    for (const QString& url : urls) {
        const QString path = unfurlDir() + '/' + u::hashOf(url) + u::qs(".json");
        if (QFileInfo::exists(path)) {
            const bool good = u::boolean(u::readJsonObject(path), "ok");
            if (u::fresh(path, good ? kUnfurlTtl : kUnfurlFailTtl))
                continue;
        }
        wanted << url;
    }

    if (!wanted.isEmpty()) {
        std::vector<net::Request> requests;
        QStringList fetchable;
        for (const QString& url : wanted) {
            if (!crawlable(url)) {
                u::writeJsonAtomic(unfurlDir() + '/' + u::hashOf(url) + u::qs(".json"),
                                   {{"ok", false}, {"url", url}, {"error", u::qs("not crawlable")}});
                continue;
            }
            net::Request request;
            request.url = url;
            request.maxRedirects = 4;
            request.maxBytes = 8000000;
            request.timeoutMs = 12000;
            request.headers.append({QByteArrayLiteral("User-Agent"),
                                    QByteArrayLiteral("Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
                                                      "(KHTML, like Gecko) Chrome/125.0 Safari/537.36")});
            request.headers.append({QByteArrayLiteral("Accept"),
                                    QByteArrayLiteral("text/html,application/xhtml+xml;q=0.9,*/*;q=0.5")});
            request.headers.append({QByteArrayLiteral("Accept-Language"), QByteArrayLiteral("en;q=0.9")});
            requests.push_back(request);
            fetchable << url;
        }

        const std::vector<net::Response> responses = http.requestMany(requests);
        for (std::size_t i = 0; i < responses.size(); ++i) {
            const QString url = fetchable[static_cast<int>(i)];
            const net::Response& response = responses[i];
            const QString path = unfurlDir() + '/' + u::hashOf(url) + u::qs(".json");

            if (!response.transportOk() || response.status >= 400) {
                u::writeJsonAtomic(path, {{"ok", false},
                                          {"url", url},
                                          {"error", u::qs("http ") + QString::number(response.status)}});
                continue;
            }

            const QString contentType = response.contentType.toLower();
            if (contentType.startsWith(u::qs("image/"))) {
                // A bare image link: Slack shows the picture, and so do we.
                const QString local = mirrorAsset(http, response.finalUrl, unfurlAssetsDir(), kAssetMaxBytes);
                u::writeJsonAtomic(path, {{"ok", true},
                                          {"url", url},
                                          {"canonical", response.finalUrl},
                                          {"site", html::host_of(response.finalUrl.toStdString()).c_str()},
                                          {"title", QString()},
                                          {"description", QString()},
                                          {"imageFile", local},
                                          {"iconFile", QString()},
                                          {"kind", u::qs("image")}});
                continue;
            }
            if (!contentType.contains(u::qs("html")) && !contentType.isEmpty()) {
                u::writeJsonAtomic(path, {{"ok", false},
                                          {"url", url},
                                          {"error", u::qs("not a page: ") + contentType}});
                continue;
            }

            const html::Meta meta = html::parse(
                std::string_view(response.body.constData(), static_cast<std::size_t>(response.body.size())),
                url.toStdString(), response.finalUrl.toStdString());
            const QString image = QString::fromStdString(meta.image);
            const QString icon = QString::fromStdString(meta.icon);
            u::writeJsonAtomic(path,
                               {{"ok", true},
                                {"url", url},
                                {"canonical", QString::fromStdString(meta.canonical)},
                                {"site", QString::fromStdString(meta.site)},
                                {"title", QString::fromStdString(meta.title)},
                                {"description", QString::fromStdString(meta.description)},
                                {"imageFile", mirrorAsset(http, image, unfurlAssetsDir(), kAssetMaxBytes)},
                                {"iconFile", mirrorAsset(http, icon, unfurlAssetsDir(), kAssetMaxBytes)},
                                {"kind", QString::fromStdString(meta.kind)}});
        }
    }

    QJsonObject out;
    for (const QString& url : urls) {
        const QJsonObject card = u::readJsonObject(unfurlDir() + '/' + u::hashOf(url) + u::qs(".json"));
        if (!u::boolean(card, "ok"))
            continue;
        // A card with nothing to show is not worth a slot in the transcript.
        if (u::str(card, "title").isEmpty() && u::str(card, "description").isEmpty() &&
            u::str(card, "imageFile").isEmpty())
            continue;
        out[url] = QJsonObject{{"url", u::str(card, "canonical", url)},
                               {"site", u::str(card, "site")},
                               {"title", u::str(card, "title")},
                               {"description", u::str(card, "description")},
                               {"image", u::str(card, "imageFile")},
                               {"icon", u::str(card, "iconFile")},
                               {"kind", u::str(card, "kind")}};
    }
    return {{"ok", true}, {"unfurls", out}};
}

// ------------------------------------------------------------------- misc

QJsonObject users(api::Session& session) {
    return {{"ok", true}, {"users", store::usersCache(session)}};
}

QJsonObject reset(api::Session& session) {
    QFile::remove(session.conversationsCache());
    QFile::remove(session.usersCache());
    QFile::remove(session.meCache());
    QDir(unfurlDir()).removeRecursively();
    return {{"ok", true}};
}

}  // namespace slack::commands
