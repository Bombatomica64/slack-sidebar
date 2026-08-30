// SPDX-License-Identifier: MIT
//
// The on-disk caches: who people are, what conversations exist, and how far
// through each one you have read.
//
// Read cursors are the only thing here that is not reconstructible from Slack,
// which is why they live in the state directory and everything else lives in
// the cache directory.

module;

#include <QDateTime>
#include <QFile>
#include <QJsonArray>
#include <QJsonObject>
#include <QList>
#include <QString>
#include <QStringList>

#include <utility>
#include <vector>

export module slack.store;

import slack.util;
import slack.api;

namespace u = slack::util;

export namespace slack::store {

// A conversation list changes rarely; an hour is long enough to make opening
// the sidebar instant and short enough that a channel joined on your phone
// turns up without a manual refresh.
inline constexpr qint64 kConversationsTtl = 3600;

// --------------------------------------------------------------- user lookup

QJsonObject usersCache(api::Session& session) {
    return u::readJsonObject(session.usersCache());
}

// Resolve ids to profiles, fetching only the ones not already cached. Returns
// the whole merged map, because every caller wants to look up names in it.
QJsonObject resolveUsers(api::Session& session, const QStringList& ids) {
    QJsonObject cache = usersCache(session);

    QStringList missing;
    for (const QString& id : ids) {
        if (id.isEmpty() || cache.contains(id) || missing.contains(id))
            continue;
        missing << id;
    }
    if (missing.isEmpty())
        return cache;

    // A workspace can have thousands of members and a busy channel can mention
    // a lot of them; sixty per run keeps a cold cache filling over a few polls
    // instead of stalling one.
    if (missing.size() > 60)
        missing = missing.mid(0, 60);

    std::vector<QList<std::pair<QString, QString>>> params;
    params.reserve(static_cast<std::size_t>(missing.size()));
    for (const QString& id : missing)
        params.push_back({{u::qs("user"), id}});

    for (const QJsonObject& response : session.callMany(u::qs("users.info"), params)) {
        if (!u::boolean(response, "ok"))
            continue;
        const QJsonObject user = u::object(response, "user");
        const QString id = u::str(user, "id");
        if (id.isEmpty())
            continue;
        const QJsonObject profile = u::object(user, "profile");
        QString name = u::str(profile, "display_name");
        if (name.isEmpty())
            name = u::str(user, "real_name", u::str(user, "name"));
        QString image = u::str(profile, "image_48");
        if (image.isEmpty())
            image = u::str(profile, "image_72");
        cache[id] = QJsonObject{{"name", name},
                                {"realName", u::str(user, "real_name", u::str(user, "name"))},
                                {"image", image},
                                {"isBot", u::boolean(user, "is_bot")}};
    }
    u::writeJsonAtomic(session.usersCache(), cache);
    return cache;
}

QString userName(const QJsonObject& users, const QString& id, const QString& fallback) {
    const QJsonObject profile = users.value(id).toObject();
    const QString name = u::str(profile, "name");
    return name.isEmpty() ? fallback : name;
}

// ------------------------------------------------------------------- cursors

QJsonObject cursors(api::Session& session) {
    return u::readJsonObject(session.cursorFile());
}

// Cursors only ever move forward: a poll that raced a read must not walk the
// badge back to unread.
void cursorSet(api::Session& session, const QString& channel, const QString& ts) {
    QJsonObject current = cursors(session);
    if (u::ts(u::str(current, channel.toUtf8().constData())) < u::ts(ts)) {
        current[channel] = ts;
        u::writeJsonAtomic(session.cursorFile(), current);
    }
}

QString cursorFor(const QJsonObject& all, const QString& channel) {
    const QJsonValue value = all.value(channel);
    return value.isString() ? value.toString() : QString();
}

// ------------------------------------------------------------- conversations

// One page of users.conversations or conversations.list, appended to `into`.
// Returns the next cursor, empty when the listing is done.
QString fetchPage(api::Session& session, const QString& method,
                         const QList<std::pair<QString, QString>>& base,
                         const QString& cursor, QJsonArray& into, QString* error) {
    QList<std::pair<QString, QString>> params = base;
    if (!cursor.isEmpty())
        params.append({u::qs("cursor"), cursor});
    const QJsonObject response = session.call(u::qs("GET"), method, params);
    if (!u::boolean(response, "ok")) {
        if (error != nullptr)
            *error = u::str(response, "error", method + u::qs(" failed"));
        return {};
    }
    for (const QJsonValue channel : u::array(response, "channels"))
        into.append(channel);
    return u::str(u::object(response, "response_metadata"), "next_cursor");
}

QJsonObject fetchConversations(api::Session& session) {
    QJsonArray joined;
    QString error;
    QString cursor;
    for (int page = 0; page < 4; ++page) {
        cursor = fetchPage(session, u::qs("users.conversations"),
                           {{u::qs("types"), u::qs("public_channel,private_channel,im,mpim")},
                            {u::qs("exclude_archived"), u::qs("true")},
                            {u::qs("limit"), u::qs("200")}},
                           cursor, joined, &error);
        if (!error.isEmpty())
            return {{"ok", false}, {"error", error}};
        if (cursor.isEmpty())
            break;
    }

    // users.conversations only covers what the caller is already in. Public
    // channels are listed separately so the picker can browse the whole
    // workspace; reading one still requires joining it, which is why `joined`
    // is surfaced to the UI rather than hidden.
    QJsonArray publicChannels;
    cursor.clear();
    for (int page = 0; page < 4; ++page) {
        QString ignored;
        cursor = fetchPage(session, u::qs("conversations.list"),
                           {{u::qs("types"), u::qs("public_channel")},
                            {u::qs("exclude_archived"), u::qs("true")},
                            {u::qs("limit"), u::qs("1000")}},
                           cursor, publicChannels, &ignored);
        if (!ignored.isEmpty() || cursor.isEmpty())
            break;
    }

    QStringList joinedIds;
    for (const QJsonValue value : joined)
        joinedIds << u::str(value.toObject(), "id");

    QStringList dmUserIds;
    for (const QJsonValue value : joined) {
        const QJsonObject channel = value.toObject();
        if (u::boolean(channel, "is_im"))
            dmUserIds << u::str(channel, "user");
    }
    const QJsonObject users = resolveUsers(session, dmUserIds);

    struct Row {
        QJsonObject json;
        bool joined;
        bool isChannel;
        QString sortName;
    };
    std::vector<Row> rows;

    const auto append = [&](const QJsonObject& channel, bool isJoined) {
        const bool isIm = u::boolean(channel, "is_im");
        const bool isMpim = u::boolean(channel, "is_mpim");
        const bool isPrivate = u::boolean(channel, "is_private");
        const QString id = u::str(channel, "id");
        const QString user = u::str(channel, "user");

        QString type = u::qs("channel");
        if (isIm)
            type = u::qs("im");
        else if (isMpim)
            type = u::qs("mpim");
        else if (isPrivate)
            type = u::qs("private");

        QString name;
        if (isIm) {
            name = userName(users, user, user.isEmpty() ? u::qs("unknown") : user);
        } else if (isMpim) {
            // Group DM names arrive as "mpdm-ann--bob--carol-1"; Slack shows the
            // members, so unpick it into something a person would recognise.
            QString purpose = u::str(u::object(channel, "purpose"), "value");
            if (!purpose.isEmpty()) {
                name = purpose;
            } else {
                name = u::str(channel, "name", id);
                if (name.startsWith(u::qs("mpdm-")))
                    name.remove(0, 5);
                if (name.endsWith(u::qs("-1")))
                    name.chop(2);
                name.replace(u::qs("--"), u::qs(", "));
            }
        } else {
            name = u::str(channel, "name", id);
        }

        rows.push_back(Row{QJsonObject{{"id", id},
                                       {"type", type},
                                       {"name", name},
                                       {"user", user},
                                       {"image", isIm ? u::str(users.value(user).toObject(), "image") : QString()},
                                       {"topic", u::str(u::object(channel, "topic"), "value")},
                                       {"members", channel.value(u::qs("num_members")).toInt()},
                                       {"joined", isJoined}},
                           isJoined, type == u::qs("channel"), name.toLower()});
    };

    for (const QJsonValue value : joined)
        append(value.toObject(), true);
    for (const QJsonValue value : publicChannels) {
        const QJsonObject channel = value.toObject();
        if (!joinedIds.contains(u::str(channel, "id")))
            append(channel, false);
    }

    // Joined first, DMs before channels, then alphabetical: the order the
    // picker wants before it applies its own unread/pin sorting.
    std::stable_sort(rows.begin(), rows.end(), [](const Row& a, const Row& b) {
        if (a.joined != b.joined)
            return a.joined;
        if (a.isChannel != b.isChannel)
            return !a.isChannel;
        return a.sortName < b.sortName;
    });

    QJsonArray out;
    for (const Row& row : rows)
        out.append(row.json);
    return {{"ok", true}, {"conversations", out}};
}

QJsonObject loadConversations(api::Session& session, bool force) {
    const QString path = session.conversationsCache();
    if (!force && u::fresh(path, kConversationsTtl))
        return u::readJsonObject(path);

    QJsonObject fetched = fetchConversations(session);
    if (u::boolean(fetched, "ok")) {
        u::writeJsonAtomic(path, fetched);
        return fetched;
    }
    // Serving the cached list is fine, but if the reason we could not refresh
    // is that the credentials are dead, say so rather than looking healthy.
    QJsonObject cached = u::readJsonObject(path);
    if (cached.isEmpty())
        return fetched;
    const QString error = u::str(fetched, "error");
    cached[u::qs("stale")] = true;
    cached[u::qs("warning")] = error;
    if (api::isAuthError(error))
        cached[u::qs("needsSignIn")] = true;
    return cached;
}

}  // namespace slack::store
