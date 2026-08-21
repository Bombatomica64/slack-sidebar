import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "Components/Mrkdwn.js" as Mrkdwn

// Quickshell declares Process.exited's exitStatus as the unregistered C++
// enum QProcess::ExitStatus, which qmllint cannot resolve. Runtime is fine.
// qmllint disable signal-handler-parameters

/**
 * Slack plugin state holder.
 *
 * All Slack access goes through slack.sh, which returns one JSON object per
 * call. This file owns the polling cadence, the active conversation, and the
 * unread bookkeeping; the panel is a pure view over these properties.
 */
Item {
    id: root

    property var pluginApi: null
    readonly property var cfg: pluginApi?.pluginSettings || ({})
    readonly property var defaults: pluginApi?.manifest?.metadata?.defaultSettings || ({})

    function setting(key, fallback) {
        return cfg[key] ?? defaults[key] ?? fallback;
    }

    readonly property int pollInterval: setting("pollInterval", 45000)
    readonly property int activePollInterval: setting("activePollInterval", 6000)
    readonly property int syncInterval: setting("syncInterval", 300000)
    readonly property int historyLimit: setting("historyLimit", 60)
    readonly property int maxWatched: setting("maxWatched", 24)
    readonly property bool notifyDms: setting("notifyDms", true)
    readonly property bool notifyMentions: setting("notifyMentions", true)
    readonly property bool markReadOnOpen: setting("markReadOnOpen", true)
    // With a bot token, auth.test reports the app's id rather than yours. Naming
    // your human account here keeps "mine", unread and @mentions correct.
    readonly property string identityUserId: setting("identityUserId", "")
    // auto | user | bot — which stored token to authenticate as.
    readonly property string tokenPreference: setting("tokenPreference", "auto")
    // Must match a Redirect URL registered on the Slack app, and must be a
    // loopback address so the plugin can answer the callback itself.
    readonly property string redirectUri: setting("redirectUri", "https://localhost:3000")
    readonly property string sidePref: setting("side", "right")
    readonly property int panelWidthPref: setting("panelWidth", 460)

    // ---------------------------------------------------------- identity

    property bool connected: false
    property string meId: ""
    property string meName: ""
    property string teamName: ""
    property string teamId: ""
    property string teamUrl: ""
    property string tokenKind: ""
    property string userTokenHint: ""
    property bool signingIn: false
    property real _lastSignInPrompt: 0
    property bool haveClientId: false
    property bool haveClientSecret: false
    property bool haveRefreshToken: false
    readonly property bool canSignIn: haveClientId && haveClientSecret
    property bool haveUserToken: false
    property bool haveBotToken: false
    property string lastError: ""
    property string lastUpdate: ""

    readonly property bool botMode: tokenKind === "bot"

    // ------------------------------------------------------------- data

    property var conversations: []          // [{id, type, name, user, image, topic}]
    property var userMap: ({})              // id -> {name, realName, image}, for mention resolution
    property var customEmoji: ({})          // {emoji: {name: localPath}, aliases: {name: target}}
    property var avatarMap: ({})            // userId -> local avatar file, for notification icons

    // Message text is rendered to rich text here, once, rather than in a delegate
    // binding: re-running the whole mrkdwn pipeline for every row that scrolls
    // into view is what made the transcript flicker and blank out.
    readonly property var renderColors: ({
            link: Color.mSecondary,
            mention: Color.mSecondary,
            mentionSelf: Color.mPrimary,
            code: Color.mTertiary,
            quote: Color.mOnSurfaceVariant,
            monoFamily: Settings.data.ui.fontFixed,
            emojiSize: Math.round(Style.fontSizeL * Style.uiScaleRatio),
            muted: String(Color.mOnSurfaceVariant)
        })

    function _mergeUsers(incoming) {
        if (!incoming)
            return;
        let fresh = false;
        for (const id in incoming) {
            if (!root.userMap[id]) {
                fresh = true;
                break;
            }
        }
        if (fresh)
            root.userMap = Object.assign({}, root.userMap, incoming);
    }

    function _render(list) {
        const colors = root.renderColors;
        const users = root.userMap;
        const me = root.meId;
        const custom = root.customEmoji;
        return (list || []).map(m => {
            const out = m;
            out.html = Mrkdwn.format(m.text || "", users, me, colors, custom) + (m.edited ? (' <font color="' + colors.muted + '" size="1">(edited)</font>') : "");
            return out;
        });
    }

    // Theme or emoji changes invalidate the cached rich text.
    onRenderColorsChanged: _reRender()
    onCustomEmojiChanged: _reRender()

    function _reRender() {
        if (root.activeMessages.length > 0)
            root.activeMessages = _render(root.activeMessages.slice());
        if (root.threadMessages.length > 0)
            root.threadMessages = _render(root.threadMessages.slice());
    }
    property var pollState: ({})            // id -> {unread, mention, latest, cursor}
    property bool listLoading: false
    property bool polling: false

    property string activeId: ""
    property var activeMessages: []
    property string activeReadCursor: ""
    property bool activeLoading: false
    property bool activeHasMore: false

    property string threadTs: ""
    property var threadMessages: []
    property bool threadLoading: false

    property bool sending: false
    property string sendError: ""

    // Conversation ids the user pinned to the watch list, persisted in settings.
    readonly property var pinned: Array.isArray(cfg.pinned) ? cfg.pinned : []

    property var _prevUnread: ({})
    property bool _seenFirstPoll: false

    // Assigning a fresh array to a ListView model rebuilds every delegate, which
    // at a few seconds per poll means visible flicker and a lost scroll position.
    // Most polls return byte-identical data, so compare first and only assign on
    // a real change.
    // Set when a read moves a cursor: any poll already in flight computed its
    // counts from the pre-read cursor file, so its result is stale and one more
    // round is needed once it lands.
    property bool _pollAgain: false
    property string _activeSig: ""
    property string _threadSig: ""

    function _changed(sigProp, value) {
        const sig = JSON.stringify(value);
        if (root[sigProp] === sig)
            return false;
        root[sigProp] = sig;
        return true;
    }

    readonly property int totalUnread: {
        let n = 0;
        for (const id in pollState)
            n += pollState[id].unread || 0;
        return n;
    }

    readonly property int mentionCount: {
        let n = 0;
        for (const id in pollState)
            if (pollState[id].mention)
                n++;
        return n;
    }

    // Resolved from the decorated list so the panel sees pin/unread state too.
    readonly property var activeConversation: {
        for (const c of decorated)
            if (c.id === activeId)
                return c;
        return null;
    }

    // DMs are always watched; channels only when pinned. The open conversation
    // is watched regardless so switching to it starts refreshing immediately.
    readonly property var watchedIds: {
        const out = [];
        const seen = ({});
        const push = id => {
            if (id && !seen[id]) {
                seen[id] = true;
                out.push(id);
            }
        };
        push(activeId);
        for (const id of pinned)
            push(id);
        for (const c of conversations)
            if (c.type === "im" || c.type === "mpim")
                push(c.id);
        return out.slice(0, Math.max(1, maxWatched));
    }

    // Conversation list decorated with unread/pin state, ordered the way the
    // sidebar wants it: mentions, then unread, then pinned, then recency.
    readonly property var decorated: {
        const pins = pinned;
        const state = pollState;
        const list = conversations.map(c => {
            const st = state[c.id] || ({});
            return {
                id: c.id,
                type: c.type,
                name: c.name,
                user: c.user || "",
                image: c.image || "",
                topic: c.topic || "",
                unread: st.unread || 0,
                mention: st.mention === true,
                latest: st.latest || null,
                latestTs: st.latest ? parseFloat(st.latest.ts) : 0,
                pinned: pins.indexOf(c.id) >= 0,
                joined: c.joined !== false,
                error: st.error || ""
            };
        });
        list.sort((a, b) => {
            if (a.mention !== b.mention)
                return a.mention ? -1 : 1;
            if ((a.unread > 0) !== (b.unread > 0))
                return a.unread > 0 ? -1 : 1;
            if (a.pinned !== b.pinned)
                return a.pinned ? -1 : 1;
            if (a.latestTs !== b.latestTs)
                return b.latestTs - a.latestTs;
            return a.name.localeCompare(b.name);
        });
        return list;
    }

    // ---------------------------------------------------------- plumbing

    function pluginDir() {
        return pluginApi?.pluginDir || (Quickshell.env("HOME") + "/.config/noctalia/plugins/slack");
    }

    function helper() {
        return pluginDir() + "/slack.sh";
    }

    // Slack has rejected the credentials and renewing them is not possible, so
    // reopen the sign-in instead of leaving a dead sidebar with a red line.
    function _sessionExpired() {
        if (root.signingIn)
            return;
        if (!root.canSignIn) {
            root.lastError = "Session expired — add the app's Client ID and Secret in the plugin settings, then sign in from the account chip";
            return;
        }
        // Every failing call reports this, so only act once in a while.
        const now = Date.now();
        if (now - root._lastSignInPrompt < 120000)
            return;
        root._lastSignInPrompt = now;
        root.lastError = "Session expired — reopening the Slack sign-in";
        root.signIn();
    }

    function _parse(text, context) {
        const raw = String(text || "").trim();
        if (raw === "") {
            root.lastError = context + ": no output from slack.sh";
            Logger.e("Slack", root.lastError);
            return null;
        }
        try {
            const res = JSON.parse(raw);
            if (res.needsSignIn === true)
                Qt.callLater(root._sessionExpired);
            if (res.ok !== true) {
                root.lastError = res.error || (context + " failed");
                return res;
            }
            root.lastError = "";
            return res;
        } catch (e) {
            root.lastError = context + ": unreadable output";
            Logger.e("Slack", root.lastError + " — " + e + " — " + raw.slice(0, 200));
            return null;
        }
    }

    function _run(proc, args) {
        if (proc.running)
            return false;
        const base = ["bash", root.helper()];
        if (root.tokenPreference !== "auto")
            base.push("--token", root.tokenPreference);
        // A user token already reports the right identity; the override exists
        // only to correct a bot token's, so don't let a stale value leak in.
        if (root.identityUserId !== "" && root.botMode)
            base.push("--me", root.identityUserId);
        proc.command = base.concat(args);
        proc.running = true;
        return true;
    }

    // ----------------------------------------------------------- actions

    function refreshIdentity() {
        _run(meProc, ["me"]);
    }

    function refreshEmoji() {
        _run(emojiProc, ["emoji"]);
    }

    function refreshAvatars() {
        _run(avatarsProc, ["avatars"]);
    }

    function refreshCredentials() {
        _run(credentialsProc, ["credentials"]);
    }

    function storeCredentials(clientId, clientSecret) {
        if (!clientId || !clientSecret)
            return;
        // argv, never a config file — the secret must not land on disk in cleartext.
        _run(storeCredsProc, ["set-credentials", clientId, clientSecret]);
    }

    // Full OAuth flow: oauth-login.py serves the registered loopback redirect,
    // so the browser hands the code straight back with nothing to copy.
    function signIn() {
        if (root.signingIn)
            return;
        root.signingIn = true;
        root.lastError = "";
        oauthProc.command = ["python3", root.pluginDir() + "/oauth-login.py", root.redirectUri];
        oauthProc.running = true;
    }

    function refreshList(force) {
        if (root.listLoading)
            return;
        root.listLoading = true;
        if (!_run(listProc, force ? ["list", "force"] : ["list"]))
            root.listLoading = false;
    }

    function poll() {
        const ids = root.watchedIds;
        if (ids.length === 0 || root.polling)
            return;
        root.polling = true;
        if (!_run(pollProc, ["poll", ids.join(",")]))
            root.polling = false;
    }

    function syncReadState() {
        const ids = root.watchedIds;
        if (ids.length === 0)
            return;
        _run(syncProc, ["sync-read", ids.join(",")]);
    }

    function refreshAll() {
        refreshIdentity();
        refreshList(true);
        poll();
        if (root.activeId !== "")
            loadHistory();
    }

    function openConversation(id) {
        if (id === root.activeId) {
            loadHistory();
            return;
        }
        root.threadTs = "";
        root.threadMessages = [];
        root.activeId = id;
        root.activeMessages = [];
        root._activeSig = "";
        root._threadSig = "";
        root.sendError = "";
        loadHistory();
    }

    function closeConversation() {
        root.activeId = "";
        root.activeMessages = [];
        root.threadTs = "";
        root.threadMessages = [];
        root._activeSig = "";
        root._threadSig = "";
    }

    function loadHistory() {
        if (root.activeId === "" || root.activeNeedsJoin)
            return;
        root.activeLoading = true;
        if (!_run(historyProc, ["history", root.activeId, String(root.historyLimit)]))
            root.activeLoading = false;
    }

    function markActiveRead() {
        if (root.activeId === "" || root.activeMessages.length === 0)
            return;
        const newest = root.activeMessages[0].ts;
        if (newest === undefined || newest === root.activeReadCursor)
            return;
        _markPending = {
            channel: root.activeId,
            ts: newest
        };
        _run(readProc, ["read", root.activeId, newest]);
    }

    property var _markPending: null

    function openThread(ts) {
        if (root.activeId === "" || !ts)
            return;
        if (ts !== root.threadTs) {
            root.threadMessages = [];
            root._threadSig = "";
        }
        root.threadTs = ts;
        root.threadLoading = true;
        if (!_run(repliesProc, ["replies", root.activeId, ts]))
            root.threadLoading = false;
    }

    function closeThread() {
        root.threadTs = "";
        root.threadMessages = [];
        root._threadSig = "";
    }

    function send(text) {
        const body = String(text || "").trim();
        if (body === "" || root.activeId === "" || root.sending)
            return false;
        root.sending = true;
        root.sendError = "";
        const args = ["send", root.activeId, body];
        if (root.threadTs !== "")
            args.push(root.threadTs);
        if (!_run(sendProc, args)) {
            root.sending = false;
            return false;
        }
        return true;
    }

    function toggleReaction(ts, name, mine) {
        if (root.activeId === "" || !ts || !name)
            return;
        _run(reactProc, ["react", root.activeId, ts, name, mine ? "remove" : "add"]);
    }

    // Switching identity invalidates everything on screen: the two tokens see
    // different conversations, different unread state and different "you".
    function switchIdentity(pref) {
        if (!pluginApi || pref === root.tokenPreference)
            return;
        pluginApi.pluginSettings.tokenPreference = pref;
        pluginApi.saveSettings();

        root.conversations = [];
        root.pollState = ({});
        root.userMap = ({});
        root._prevUnread = ({});
        root._seenFirstPoll = false;
        root.activeId = "";
        root.activeMessages = [];
        root.activeReadCursor = "";
        root._activeSig = "";
        root.threadTs = "";
        root.threadMessages = [];
        root._threadSig = "";
        root.lastError = "";
        root.tokenKind = "";
        root.connected = false;

        refreshIdentity();
        refreshList(true);
        refreshEmoji();
    }

    // Label for the account chip in the header.
    readonly property string accountLabel: {
        if (!connected)
            return "Not connected";
        if (meName === "")
            return botMode ? "App" : "Slack";
        return meName;
    }

    // Asking for an identity that is not stored should say why rather than
    // persisting a preference that cannot work.
    function requestIdentity(pref) {
        if (pref === "user" && !root.haveUserToken) {
            root.lastError = root.userTokenHint !== "" ? root.userTokenHint : "no user token stored";
            return;
        }
        if (pref === "bot" && !root.haveBotToken) {
            root.lastError = "no bot token stored";
            return;
        }
        switchIdentity(pref);
    }

    function togglePin(id) {
        if (!pluginApi)
            return;
        const list = Array.isArray(cfg.pinned) ? cfg.pinned.slice() : [];
        const at = list.indexOf(id);
        if (at >= 0)
            list.splice(at, 1);
        else
            list.push(id);
        pluginApi.pluginSettings.pinned = list;
        pluginApi.saveSettings();
        poll();
    }

    // Public channels the caller has not joined are listed for browsing, but
    // conversations.history refuses them, so reading one means joining first.
    readonly property bool activeNeedsJoin: activeConversation ? activeConversation.joined === false : false
    property bool joining: false

    function joinConversation(id) {
        const target = id || root.activeId;
        if (!target || root.joining)
            return;
        root.joining = true;
        if (!_run(joinProc, ["join", target]))
            root.joining = false;
    }

    function openInSlack(id) {
        const target = id || root.activeId;
        if (!target)
            return;
        const url = root.teamId !== "" ? ("slack://channel?team=" + root.teamId + "&id=" + target) : (root.teamUrl + "archives/" + target);
        Quickshell.execDetached(["xdg-open", url]);
    }

    function notify(title, body, iconPath) {
        const args = ["notify-send", "-a", "Slack"];
        if (iconPath)
            // Noctalia prefers the image hint over the app icon, and it wants a
            // real file — hence the mirrored avatars.
            args.push("--hint=string:image-path:" + iconPath);
        else
            args.push("-i", "slack-indicator");
        args.push(title, body);
        Quickshell.execDetached(args);
    }

    function _isMe(userId) {
        if (!userId)
            return false;
        return userId === root.meId || (root.identityUserId !== "" && userId === root.identityUserId);
    }

    function _notifyForPoll(next) {
        if (!root._seenFirstPoll) {
            root._seenFirstPoll = true;
            return;
        }
        for (const id in next) {
            const st = next[id];
            const before = root._prevUnread[id] || 0;
            if ((st.unread || 0) <= before)
                continue;
            if (id === root.activeId)
                continue;
            // Announce the newest genuinely unread message. `latest` can be your
            // own reply sitting on top of it, which is what used to get reported.
            const msg = st.latestUnread;
            if (!msg || root._isMe(msg.user))
                continue;
            let conv = null;
            for (const c of root.conversations)
                if (c.id === id)
                    conv = c;
            const isDm = conv && conv.type === "im";
            const isGroupDm = conv && conv.type === "mpim";
            const wanted = ((isDm || isGroupDm) && root.notifyDms) || (st.mention && root.notifyMentions);
            if (!wanted)
                continue;
            const where = conv ? (isDm ? conv.name : "#" + conv.name) : id;
            // In a 1:1 the title already names the sender.
            const body = isDm ? msg.text : (msg.author + ": " + msg.text);
            root.notify(where, body, root.avatarMap[msg.user] || "");
        }
    }

    // ----------------------------------------------------------- startup

    Component.onCompleted: {
        refreshIdentity();
        refreshList(false);
        refreshEmoji();
        refreshAvatars();
        refreshCredentials();
    }

    onWatchedIdsChanged: pollDebounce.restart()
    onUserMapChanged: avatarDebounce.restart()

    Timer {
        id: avatarDebounce
        interval: 4000
        onTriggered: root.refreshAvatars()
    }

    Timer {
        id: pollDebounce
        interval: 250
        onTriggered: root.poll()
    }

    Timer {
        interval: Math.max(10000, root.pollInterval)
        running: true
        repeat: true
        onTriggered: root.poll()
    }

    readonly property bool panelVisible: (pluginApi?.panelOpenScreen ?? null) !== null

    Timer {
        // Only while the sidebar is on screen — otherwise a conversation left
        // open would keep polling every few seconds forever. When hidden it
        // still gets the ordinary background round.
        interval: Math.max(2000, root.activePollInterval)
        running: root.activeId !== "" && root.panelVisible
        repeat: true
        onTriggered: {
            if (root.threadTs !== "")
                root.openThread(root.threadTs);
            else
                root.loadHistory();
        }
    }

    Timer {
        interval: Math.max(60000, root.syncInterval)
        running: true
        repeat: true
        onTriggered: root.syncReadState()
    }

    // Conversation list is cheap thanks to the on-disk cache; re-ask hourly so
    // newly joined channels and new DMs turn up without a manual refresh.
    Timer {
        interval: 3600000
        running: true
        repeat: true
        onTriggered: root.refreshList(true)
    }

    // --------------------------------------------------------- processes

    Process {
        id: meProc
        stdout: StdioCollector {
            onStreamFinished: {
                const res = root._parse(this.text, "auth");
                if (!res)
                    return;
                root.tokenKind = res.tokenKind || "";
                root.haveUserToken = res.haveUserToken === true;
                root.userTokenHint = res.userTokenHint || "";
                if (res.haveUserToken === true)
                    root.refreshCredentials();
                root.haveBotToken = res.haveBotToken === true;
                root.connected = res.ok === true;
                if (res.ok === true) {
                    root.meId = res.userId || "";
                    root.meName = res.user || "";
                    root.teamName = res.team || "";
                    root.teamId = res.teamId || "";
                    root.teamUrl = res.url || "";
                }
            }
        }
        stderr: StdioCollector {}
    }

    Process {
        id: listProc
        stdout: StdioCollector {
            onStreamFinished: {
                const res = root._parse(this.text, "conversations");
                if (res && Array.isArray(res.conversations)) {
                    root.conversations = res.conversations;
                    if (res.warning)
                        root.lastError = res.warning + " (showing cached list)";
                    // A conversation opened before the list arrived (or just
                    // joined) can only load its history now.
                    if (root.activeId !== "" && root.activeMessages.length === 0)
                        Qt.callLater(root.loadHistory);
                }
            }
        }
        stderr: StdioCollector {}
        onExited: root.listLoading = false
    }

    Process {
        id: pollProc
        stdout: StdioCollector {
            onStreamFinished: {
                const res = root._parse(this.text, "poll");
                if (!res || res.ok !== true)
                    return;
                const next = res.conversations || ({});
                root._notifyForPoll(next);
                const prev = ({});
                for (const id in next)
                    prev[id] = next[id].unread || 0;
                root._prevUnread = prev;
                root.pollState = next;
                root.lastUpdate = new Date().toLocaleTimeString(Qt.locale(), "HH:mm:ss");
            }
        }
        stderr: StdioCollector {}
        onExited: {
            root.polling = false;
            if (root._pollAgain) {
                root._pollAgain = false;
                root.poll();
            }
        }
    }

    Process {
        id: historyProc
        stdout: StdioCollector {
            onStreamFinished: {
                const res = root._parse(this.text, "history");
                if (!res || res.ok !== true)
                    return;
                const messages = res.messages || [];
                // Users first: mentions inside the rendered text resolve against them.
                root._mergeUsers(res.users);
                if (root._changed("_activeSig", messages))
                    root.activeMessages = root._render(messages);
                root.activeReadCursor = res.readCursor || "";
                root.activeHasMore = res.hasMore === true;
                if (root.markReadOnOpen)
                    root.markActiveRead();
            }
        }
        stderr: StdioCollector {}
        onExited: root.activeLoading = false
    }

    Process {
        id: repliesProc
        stdout: StdioCollector {
            onStreamFinished: {
                const res = root._parse(this.text, "thread");
                if (res && res.ok === true) {
                    const messages = res.messages || [];
                    root._mergeUsers(res.users);
                    if (root._changed("_threadSig", messages))
                        root.threadMessages = root._render(messages);
                }
            }
        }
        stderr: StdioCollector {}
        onExited: root.threadLoading = false
    }

    Process {
        id: sendProc
        stdout: StdioCollector {
            onStreamFinished: {
                const res = root._parse(this.text, "send");
                if (!res || res.ok !== true) {
                    root.sendError = root.lastError || "message not sent";
                    return;
                }
                root.sendError = "";
                if (root.threadTs !== "")
                    root.openThread(root.threadTs);
                else
                    root.loadHistory();
                root.poll();
            }
        }
        stderr: StdioCollector {}
        onExited: root.sending = false
    }

    Process {
        id: readProc
        stdout: StdioCollector {
            onStreamFinished: {
                const res = root._parse(this.text, "mark read");
                const pending = root._markPending;
                root._markPending = null;
                if (!res || res.ok !== true || !pending)
                    return;
                // Reflect the new cursor locally so the badge clears without
                // waiting for the next poll round-trip. The entry is created if
                // this conversation had not been polled yet.
                const next = Object.assign({}, root.pollState);
                const entry = next[pending.channel] || ({
                        ok: true,
                        error: "",
                        latest: null
                    });
                next[pending.channel] = {
                    ok: entry.ok !== false,
                    error: entry.error || "",
                    unread: 0,
                    mention: false,
                    cursor: pending.ts,
                    latest: entry.latest || null
                };
                root.pollState = next;
                if (pending.channel === root.activeId)
                    root.activeReadCursor = pending.ts;

                // Re-poll so the authoritative counts come from the new cursor.
                if (root.polling)
                    root._pollAgain = true;
                else
                    root.poll();
            }
        }
        stderr: StdioCollector {}
    }

    Process {
        id: avatarsProc
        stdout: StdioCollector {
            onStreamFinished: {
                const res = root._parse(this.text, "avatars");
                if (res && res.ok === true)
                    root.avatarMap = res.avatars || ({});
            }
        }
        stderr: StdioCollector {}
    }

    Process {
        id: credentialsProc
        stdout: StdioCollector {
            onStreamFinished: {
                const res = root._parse(this.text, "credentials");
                if (res && res.ok === true) {
                    root.haveClientId = res.haveClientId === true;
                    root.haveClientSecret = res.haveClientSecret === true;
                    root.haveRefreshToken = res.haveRefreshToken === true;
                }
            }
        }
        stderr: StdioCollector {}
    }

    Process {
        id: storeCredsProc
        stdout: StdioCollector {
            onStreamFinished: {
                const res = root._parse(this.text, "save credentials");
                if (res && res.ok === true)
                    root.refreshCredentials();
            }
        }
        stderr: StdioCollector {}
    }

    Process {
        id: oauthProc
        stdout: StdioCollector {
            onStreamFinished: {
                const res = root._parse(this.text, "sign in");
                if (!res || res.ok !== true)
                    return;
                root._lastSignInPrompt = 0;
                if (res.rotating && !res.refreshStored)
                    root.lastError = "signed in, but Slack sent no refresh token — this token will expire";
                // Adopt the new identity straight away.
                if (root.tokenPreference === "bot")
                    root.switchIdentity("auto");
                else {
                    root.tokenKind = "";
                    root.refreshIdentity();
                    root.refreshList(true);
                    root.refreshEmoji();
                }
                root.refreshCredentials();
            }
        }
        stderr: StdioCollector {}
        onExited: root.signingIn = false
    }

    Process {
        id: emojiProc
        stdout: StdioCollector {
            onStreamFinished: {
                const res = root._parse(this.text, "emoji");
                if (res && res.ok === true)
                    root.customEmoji = {
                        emoji: res.emoji || ({}),
                        aliases: res.aliases || ({})
                    };
            }
        }
        stderr: StdioCollector {}
    }

    Process {
        id: joinProc
        stdout: StdioCollector {
            onStreamFinished: {
                const res = root._parse(this.text, "join");
                if (res && res.ok === true) {
                    root.refreshList(true);
                    root._activeSig = "";
                    Qt.callLater(root.loadHistory);
                }
            }
        }
        stderr: StdioCollector {}
        onExited: root.joining = false
    }

    Process {
        id: reactProc
        stdout: StdioCollector {
            onStreamFinished: {
                const res = root._parse(this.text, "reaction");
                if (res && res.ok === true)
                    root.loadHistory();
            }
        }
        stderr: StdioCollector {}
    }
}
