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
 * All Slack access goes through the slack-agent binary, which returns one JSON object per
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
    // Crawl the links Slack did not unfurl for us and show a preview card.
    readonly property bool linkPreviews: setting("linkPreviews", true)
    // Keep every message seen in an encrypted database on this machine.
    readonly property bool archiveMessages: setting("archiveMessages", true)
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

    // Rendering a message is the same work every time until its text changes, and
    // a poll re-delivers the same sixty messages every few seconds. Keyed by the
    // text itself so an edit misses the cache and everything else hits it.
    property var _htmlCache: ({})
    property int _htmlCacheSize: 0

    function _render(list) {
        const colors = root.renderColors;
        const users = root.userMap;
        const me = root.meId;
        const custom = root.customEmoji;
        const cache = root._htmlCache;
        // A conversation is at most a few hundred distinct messages; past that
        // the cache is holding onto scrollback nobody is looking at any more.
        if (root._htmlCacheSize > 2000) {
            root._htmlCache = ({});
            root._htmlCacheSize = 0;
            return _render(list);
        }
        return (list || []).map(m => {
            const out = m;
            const key = m.ts + "\u0001" + (m.edited ? "e" : "") + (m.text || "");
            let hit = cache[key];
            if (hit === undefined) {
                hit = {
                    html: Mrkdwn.format(m.text || "", users, me, colors, custom) + (m.edited ? (' <font color="' + colors.muted + '" size="1">(edited)</font>') : ""),
                    links: root.linkPreviews ? Mrkdwn.extractLinks(m.text || "") : []
                };
                cache[key] = hit;
                root._htmlCacheSize++;
            }
            out.html = hit.html;
            // Slack already unfurled some of these; crawling them again would
            // draw the same card twice.
            out.links = hit.links.filter(url => !root._attachmentCovers(m, url));
            for (const att of (out.attachments || []))
                att.previewText = Mrkdwn.preview(att.text || "", users);
            return out;
        });
    }

    function _attachmentCovers(msg, url) {
        for (const att of (msg.attachments || []))
            if (att.url === url || att.fromUrl === url)
                return true;
        return false;
    }

    // Theme or emoji changes invalidate the cached rich text.
    onRenderColorsChanged: _reRender()
    onCustomEmojiChanged: _reRender()

    function _reRender() {
        root._htmlCache = ({});
        root._htmlCacheSize = 0;
        if (root.activeMessages.length > 0)
            root.activeMessages = _render(root.activeMessages.slice());
        if (root.threadMessages.length > 0)
            root.threadMessages = _render(root.threadMessages.slice());
    }
    property var pollState: ({})            // id -> {unread, mention, latest, cursor}
    property bool listLoading: false
    // True through the whole startup window - before the agent has answered at
    // all, as well as while the list itself is in flight.
    readonly property bool conversationsPending: !agentReady || listLoading
    property bool polling: false

    property string activeId: ""
    property var activeMessages: []
    property string activeReadCursor: ""
    property bool activeLoading: false
    // Slack says there is more history before the oldest message we hold.
    property bool activeHasMore: false
    property bool loadingOlder: false

    property string threadTs: ""
    property var threadMessages: []
    property bool threadLoading: false

    property bool sending: false
    property string sendError: ""

    // ------------------------------------------------------- link previews

    // url -> {url, site, title, description, image, icon}. The agent keeps the
    // real cache on disk; this is only what the visible messages need.
    property var unfurls: ({})
    // Links already asked about, whether or not they produced a card. Without
    // this a page that unfurls to nothing would be re-crawled on every poll.
    property var _unfurlAsked: ({})
    property bool _unfurling: false

    function _wantedLinks() {
        if (!root.linkPreviews)
            return [];
        const out = [];
        const seen = ({});
        const scan = list => {
            for (const msg of (list || [])) {
                for (const url of (msg.links || [])) {
                    if (seen[url] || root._unfurlAsked[url])
                        continue;
                    seen[url] = true;
                    out.push(url);
                }
            }
        };
        scan(root.activeMessages);
        scan(root.threadMessages);
        return out;
    }

    function fetchUnfurls() {
        if (root._unfurling || !root.linkPreviews)
            return;
        // One round at a time, oldest first: the rest come on the next tick of
        // the debounce, so a conversation full of links trickles in rather than
        // forking twenty curls at once.
        const wanted = root._wantedLinks().slice(0, 8);
        if (wanted.length === 0)
            return;
        root._unfurling = true;
        if (!_run(unfurlProc, ["unfurl"].concat(wanted))) {
            root._unfurling = false;
            return;
        }
        // Marked only once the call is really under way, so a refused start
        // does not quietly retire the links it was going to ask about.
        for (const url of wanted)
            root._unfurlAsked[url] = true;
    }

    onActiveMessagesChanged: unfurlDebounce.restart()
    onThreadMessagesChanged: unfurlDebounce.restart()

    Timer {
        id: unfurlDebounce

        // Long enough that opening a conversation and immediately opening a
        // thread inside it is one crawl, not two.
        interval: 350
        onTriggered: root.fetchUnfurls()
    }

    // Conversation ids the user pinned to the watch list, persisted in settings.
    readonly property var pinned: Array.isArray(cfg.pinned) ? cfg.pinned : []

    // The newest unread message already announced, per conversation, keyed by
    // timestamp. It used to be keyed by unread count - "notify when the count
    // goes up" - which quietly stopped working: poll reads the newest 20
    // messages per conversation, so the count saturates at 20, and a
    // conversation left unread for a while reports 20 forever. The count never
    // rises again and the notifications stop, which is exactly what it looked
    // like from the outside.
    property var _notifiedTs: ({})
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

    // The agent is a compiled binary, built into the cache directory rather than
    // into the clone: a plugin directory is somebody's checkout, not a build
    // tree. Everything Slack-related goes through it.
    function cacheDir() {
        const override = Quickshell.env("XDG_CACHE_HOME");
        return (override && override !== "" ? override : Quickshell.env("HOME") + "/.cache") + "/noctalia-slack";
    }

    function agent() {
        return cacheDir() + "/bin/slack-agent";
    }

    // Set once the agent has answered a call. Nothing else runs until it has:
    // a missing binary would otherwise look like a hundred separate failures.
    property bool agentReady: false
    property bool agentBuilding: false

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
            root.lastError = context + ": no output from the Slack helper";
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
        if (proc.running || !root.agentReady)
            return false;
        const base = [root.agent()];
        if (root.tokenPreference !== "auto")
            base.push("--token", root.tokenPreference);
        // A user token already reports the right identity; the override exists
        // only to correct a bot token's, so don't let a stale value leak in.
        if (root.identityUserId !== "" && root.botMode)
            base.push("--me", root.identityUserId);
        if (!root.archiveMessages)
            base.push("--no-archive");
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

    // Full OAuth flow: the agent serves the registered loopback redirect,
    // so the browser hands the code straight back with nothing to copy.
    function signIn() {
        if (root.signingIn)
            return;
        root.signingIn = true;
        root.lastError = "";
        oauthProc.command = [root.agent(), "signin", root.redirectUri];
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
        root.activeHasMore = false;
        root.loadingOlder = false;
        root._activeSig = "";
        root._threadSig = "";
        root.sendError = "";
        loadFromArchive();
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

    // Read from the local archive first. It answers in a millisecond or two, so
    // the transcript is on screen before the network call is out the door - and
    // it is the whole transcript when there is no network at all.
    property string _archiveFor: ""

    function loadFromArchive() {
        if (root.activeId === "" || !root.archiveMessages)
            return;
        root._archiveFor = root.activeId;
        _run(archiveProc, ["archive", root.activeId, String(root.historyLimit)]);
    }

    function loadHistory() {
        if (root.activeId === "" || root.activeNeedsJoin)
            return;
        root.activeLoading = true;
        if (!_run(historyProc, ["history", root.activeId, String(root.historyLimit)]))
            root.activeLoading = false;
    }

    // Page backwards from the oldest message on screen. The open conversation is
    // re-polled every few seconds and that poll only ever returns the newest
    // page, so anything loaded here has to survive it - see _mergeHistory.
    function loadOlder() {
        if (root.activeId === "" || !root.activeHasMore || root.loadingOlder)
            return;
        const messages = root.activeMessages;
        if (messages.length === 0)
            return;
        root.loadingOlder = true;
        const oldest = messages[messages.length - 1].ts;
        if (!_run(olderProc, ["history", root.activeId, String(root.historyLimit), oldest]))
            root.loadingOlder = false;
    }

    // Both arrays are newest-first. The fresh page wins wherever the two
    // overlap, because that is where an edit or a new reaction shows up;
    // everything older than it is kept, which is what stops a poll from
    // throwing away the pages the reader has already scrolled back through.
    function _mergeHistory(fresh) {
        const existing = root.activeMessages || [];
        if (existing.length === 0 || fresh.length === 0)
            return fresh;
        const oldestFresh = parseFloat(fresh[fresh.length - 1].ts);
        const older = existing.filter(m => parseFloat(m.ts) < oldestFresh);
        return older.length === 0 ? fresh : fresh.concat(older);
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
        root._notifiedTs = ({});
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
        root._htmlCache = ({});
        root._htmlCacheSize = 0;

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
        // The first poll of a session describes what was already waiting. That
        // is not news, so it is recorded and not announced.
        const firstPoll = !root._seenFirstPoll;
        root._seenFirstPoll = true;

        const seen = ({});
        for (const id in next) {
            const st = next[id];
            const msg = st.latestUnread;
            const prior = root._notifiedTs[id];

            if (!msg) {
                // Nothing unread: keep what we knew, so an older message can
                // never come back around and announce itself.
                if (prior !== undefined)
                    seen[id] = prior;
                continue;
            }
            seen[id] = msg.ts;

            // Announced regardless of the unread count, which is capped and
            // therefore not a signal. `latestUnread` is the newest genuinely
            // unread message - never your own reply sitting on top of it.
            if (firstPoll || (prior !== undefined && parseFloat(msg.ts) <= parseFloat(prior)))
                continue;
            if (id === root.activeId)
                continue;
            if (root._isMe(msg.user))
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
        root._notifiedTs = seen;
    }

    // ----------------------------------------------------------- startup

    // ------------------------------------------------------------- bootstrap

    // The agent builds itself on first use, through the Makefile shim over
    // CMake. Configuring and building are both no-ops once the binary is
    // current, so probing and building is cheap enough to do at every start and
    // self-healing when the plugin is updated.
    function _startup() {
        root.agentReady = true;
        refreshIdentity();
        refreshList(false);
        refreshEmoji();
        refreshAvatars();
        refreshCredentials();
    }

    function buildAgent() {
        if (root.agentBuilding)
            return;
        root.agentBuilding = true;
        buildProc.command = ["make", "-C", root.pluginDir(), "--no-print-directory", "PREFIX=" + root.cacheDir(), "BUILDDIR=" + root.cacheDir() + "/build", "install"];
        buildProc.running = true;
    }

    Component.onCompleted: probeProc.running = true

    // Any subcommand that needs neither a token nor the network will do; this
    // one only reads the keyring.
    Process {
        id: probeProc
        command: [root.agent(), "credentials"]
        stdout: StdioCollector {}
        stderr: StdioCollector {}
        onExited: (code, status) => {
            if (code === 0)
                root._startup();
            else
                root.buildAgent();
        }
    }

    Process {
        id: buildProc
        stdout: StdioCollector {}
        stderr: StdioCollector {
            onStreamFinished: root._buildLog = String(this.text || "")
        }
        onExited: (code, status) => {
            root.agentBuilding = false;
            if (code === 0) {
                root.lastError = "";
                root._startup();
                return;
            }
            // Naming the two things that actually go wrong beats a build log in
            // a sidebar subtitle.
            root.lastError = "Could not build the Slack helper. It needs make, CMake 3.28+ with Ninja, Qt 6 development headers, libsecret, OpenSSL and SQLCipher, and clang 17+ for C++20 modules. Run `make` in " + root.pluginDir() + " to see why.";
            Logger.e("Slack", "helper build failed: " + root._buildLog.slice(-2000));
        }
    }

    property string _buildLog: ""

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

    // The settings pane stores the Client ID and Secret with its own process, in
    // a component tree that has no handle on this one, so nothing here learns
    // that they arrived. Without this the sign-in entry stays greyed out for the
    // rest of the session in which they were entered - which is exactly the
    // session someone enters them in. A keyring read on panel open is cheap, and
    // opening the sidebar is what you do next to click the thing.
    onPanelVisibleChanged: {
        if (root.panelVisible)
            root.refreshCredentials();
    }

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
                // Users first: mentions inside the rendered text resolve against them.
                root._mergeUsers(res.users);
                const messages = root._mergeHistory(res.messages || []);
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
        id: archiveProc
        stdout: StdioCollector {
            onStreamFinished: {
                const res = root._parse(this.text, "archive");
                if (!res || res.ok !== true || res.fromArchive !== true)
                    return;
                // The network may have answered first, or the reader may have
                // moved on. Either way the archive is the older truth and must
                // not overwrite anything.
                if (root._archiveFor !== root.activeId || root.activeMessages.length > 0)
                    return;
                const messages = res.messages || [];
                if (messages.length === 0)
                    return;
                root._mergeUsers(res.users);
                root.activeMessages = root._render(messages);
                root.activeReadCursor = res.readCursor || root.activeReadCursor;
                // Force the next network result to be applied even if it shapes
                // up identically to what the archive just gave us.
                root._activeSig = "";
            }
        }
        stderr: StdioCollector {}
    }

    Process {
        id: olderProc
        stdout: StdioCollector {
            onStreamFinished: {
                const res = root._parse(this.text, "older messages");
                if (!res || res.ok !== true)
                    return;
                const older = res.messages || [];
                root._mergeUsers(res.users);
                if (older.length > 0) {
                    // Appended, not prepended: the array runs newest-first.
                    root.activeMessages = root.activeMessages.concat(root._render(older));
                    root._activeSig = "";
                }
                // Slack reports whether anything remains before *this* page.
                root.activeHasMore = res.hasMore === true;
            }
        }
        stderr: StdioCollector {}
        onExited: root.loadingOlder = false
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
        id: unfurlProc
        stdout: StdioCollector {
            onStreamFinished: {
                const res = root._parse(this.text, "link previews");
                root._unfurling = false;
                if (!res || res.ok !== true)
                    return;
                const found = res.unfurls || ({});
                let fresh = false;
                for (const url in found) {
                    if (!root.unfurls[url])
                        fresh = true;
                }
                if (fresh)
                    root.unfurls = Object.assign({}, root.unfurls, found);
                // More links than one round could take: come back for them.
                if (root._wantedLinks().length > 0)
                    unfurlDebounce.restart();
            }
        }
        stderr: StdioCollector {}
        onExited: root._unfurling = false
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
