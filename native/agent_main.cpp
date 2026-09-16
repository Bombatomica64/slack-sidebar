// SPDX-License-Identifier: MIT
//
// slack-agent — everything the sidebar needs from Slack, in one binary.
//
// Replaces the slack.sh + oauth-login.py pair. The interface they defined is
// kept exactly: one subcommand per invocation, one JSON object on stdout, exit
// 0 whatever happened, diagnostics on stderr. The QML side did not change.
//
//   slack-agent [--token user|bot|auto] [--me <userId>] <subcommand> [args...]

#include <QCoreApplication>
#include <QFile>
#include <QJsonObject>
#include <QString>
#include <QStringList>

#include <cstdlib>
#include <iostream>
#include <string_view>

// Includes before imports: gcc does not reconcile a std or Qt header included
// here with the same header pulled in by an imported module's global module
// fragment. See native/html.cppm for the long version.
import slack.util;
import slack.api;
import slack.commands;
import slack.oauth;
import slack.html;

namespace u = slack::util;

namespace {

QJsonObject usage() {
    return {{"ok", false},
            {"error", u::qs("usage: slack-agent [--token user|bot|auto] [--me <userId>] [--no-archive] "
                            "[--identity user|bot] "
                            "{me|list|poll|history [channel] [limit] [before-ts] [since-ts]|replies|send|read|react|join|"
                            "emoji|avatars|"
                            "unfurl|sync-read|users|tokens|credentials|set-credentials|signin|"
                            "archive|archive-revisions|archive-stats|archive-key [hex-to-restore]|"
                            "parse-html|reset}")}};
}

QString argAt(const QStringList& args, int index, const QString& fallback = {}) {
    return index < args.size() ? args.at(index) : fallback;
}

// Read a whole stream with no size cap. Only used by parse-html, which is a
// debugging entry point fed by hand.
QByteArray readStdin() {
    QFile input;
    if (!input.open(stdin, QIODevice::ReadOnly))
        return {};
    return input.readAll();
}

}  // namespace

int main(int argc, char** argv) {
    QCoreApplication app(argc, argv);

    QStringList args = QCoreApplication::arguments();
    if (!args.isEmpty())
        args.removeFirst();

    // A bot token's auth.test reports the *app's* user id, not yours, which
    // would make your own messages look like someone else's and stop @you from
    // matching. `--me <id>` names the human account so "mine", unread and
    // mentions stay right.
    QString tokenPreference = u::qs("auto");
    QString meOverride;
    // Names which archive to read without needing a session. The archive
    // outlives the token that filled it - leaving a workspace ends your Slack
    // access, and that is precisely when the local copy matters most.
    QString identity;
    while (!args.isEmpty() && args.first().startsWith(u::qs("--"))) {
        const QString flag = args.takeFirst();
        if (flag == u::qs("--token") && !args.isEmpty())
            tokenPreference = args.takeFirst();
        else if (flag == u::qs("--me") && !args.isEmpty())
            meOverride = args.takeFirst();
        else if (flag == u::qs("--no-archive"))
            slack::commands::setArchiveEnabled(false);
        else if (flag == u::qs("--identity") && !args.isEmpty())
            identity = args.takeFirst();
        // An unknown flag is dropped rather than fatal: the QML side and this
        // binary are versioned together but not always updated together.
    }

    if (args.isEmpty()) {
        u::emitJson(usage());
        return 0;
    }
    const QString verb = args.takeFirst();

    // Two subcommands work without a token, and must: one of them is how you
    // get a token in the first place.
    if (verb == u::qs("signin")) {
        u::ensureDirs();
        const QString redirect = argAt(args, 0, u::qs("https://localhost:3000"));
        const int timeout = u::envOr("SLACK_OAUTH_TIMEOUT", u::qs("180")).toInt();
        u::emitJson(slack::oauth::signIn(redirect, timeout > 0 ? timeout : 180));
        return 0;
    }
    // The archive key must be reachable when nothing else is. Losing the keyring
    // is the scenario it exists for, and needing a working Slack token to read
    // your own decryption key would be exactly backwards.
    if (verb == u::qs("archive-key")) {
        u::emitJson(args.isEmpty() ? slack::commands::archiveKey()
                                   : slack::commands::archiveAdoptKey(argAt(args, 0)));
        return 0;
    }
    // Likewise reading the archive, when an identity is named outright.
    if (!identity.isEmpty()) {
        if (verb == u::qs("archive")) {
            u::emitJson(slack::commands::archiveHistory(identity, argAt(args, 0),
                                                        argAt(args, 1, u::qs("50")).toInt(),
                                                        argAt(args, 2), {}, {}));
            return 0;
        }
        if (verb == u::qs("archive-revisions")) {
            u::emitJson(slack::commands::archiveRevisions(identity, argAt(args, 0), argAt(args, 1)));
            return 0;
        }
        if (verb == u::qs("archive-stats")) {
            u::emitJson(slack::commands::archiveStats(identity));
            return 0;
        }
    }
    if (verb == u::qs("credentials")) {
        u::emitJson(slack::commands::credentials());
        return 0;
    }
    if (verb == u::qs("set-credentials")) {
        u::emitJson(slack::commands::setCredentials(argAt(args, 0), argAt(args, 1)));
        return 0;
    }
    if (verb == u::qs("parse-html")) {
        // curl -sL "$url" | slack-agent parse-html "$url" [final-url]
        const QByteArray body = readStdin();
        slack::html::write_json(
            std::cout,
            slack::html::parse(std::string_view(body.constData(), static_cast<std::size_t>(body.size())),
                               argAt(args, 0).toStdString(), argAt(args, 1).toStdString()));
        return 0;
    }
    if (verb == u::qs("unfurl")) {
        // Link previews are about pages on the open internet, not about Slack,
        // so they need no token either.
        u::ensureDirs();
        u::emitJson(slack::commands::unfurl(args));
        return 0;
    }

    // Everything below needs an identity. The constructor fails loudly (and
    // exits 0 with an {ok:false}) when there is no usable token.
    slack::api::Session session(tokenPreference, meOverride);

    QJsonObject result;
    if (verb == u::qs("me"))
        result = slack::commands::me(session);
    else if (verb == u::qs("list"))
        result = slack::commands::list(session, argAt(args, 0) == u::qs("force"));
    else if (verb == u::qs("poll"))
        result = slack::commands::poll(session, argAt(args, 0));
    else if (verb == u::qs("history"))
        result = slack::commands::history(session, argAt(args, 0), argAt(args, 1, u::qs("50")).toInt(),
                                          argAt(args, 2), argAt(args, 3));
    else if (verb == u::qs("replies"))
        result = slack::commands::replies(session, argAt(args, 0), argAt(args, 1));
    else if (verb == u::qs("send"))
        result = slack::commands::send(session, argAt(args, 0), argAt(args, 1), argAt(args, 2));
    else if (verb == u::qs("read"))
        result = slack::commands::markRead(session, argAt(args, 0), argAt(args, 1));
    else if (verb == u::qs("react"))
        result = slack::commands::react(session, argAt(args, 0), argAt(args, 1), argAt(args, 2),
                                        argAt(args, 3) == u::qs("remove"));
    else if (verb == u::qs("join"))
        result = slack::commands::join(session, argAt(args, 0));
    else if (verb == u::qs("emoji"))
        result = slack::commands::emoji(session);
    else if (verb == u::qs("avatars"))
        result = slack::commands::avatars(session);
    else if (verb == u::qs("sync-read"))
        result = slack::commands::syncRead(session, argAt(args, 0));
    else if (verb == u::qs("users"))
        result = slack::commands::users(session);
    else if (verb == u::qs("tokens"))
        result = slack::commands::tokens(session);
    else if (verb == u::qs("archive"))
        result = slack::commands::archiveHistory(
            slack::api::kindName(session.tokenKind()), argAt(args, 0),
            argAt(args, 1, u::qs("50")).toInt(), argAt(args, 2),
            slack::commands::users(session).value(u::qs("users")).toObject(),
            slack::commands::readCursorFor(session, argAt(args, 0)));
    else if (verb == u::qs("archive-revisions"))
        result = slack::commands::archiveRevisions(slack::api::kindName(session.tokenKind()),
                                                   argAt(args, 0), argAt(args, 1));
    else if (verb == u::qs("archive-stats"))
        result = slack::commands::archiveStats(slack::api::kindName(session.tokenKind()));
    else if (verb == u::qs("reset"))
        result = slack::commands::reset(session);
    else
        result = usage();

    // Any call may have discovered the session is dead; say so once, here,
    // rather than in every subcommand.
    if (session.authDead() && !u::boolean(result, "needsSignIn"))
        result[u::qs("needsSignIn")] = true;

    u::emitJson(result);
    return 0;
}
