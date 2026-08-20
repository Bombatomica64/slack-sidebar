.pragma library

// Slack mrkdwn -> Qt RichText.
//
// Slack escapes only &, < and > inside message text, and uses real angle
// brackets for its own entities (<@U123>, <#C1|name>, <https://x|label>). So the
// order matters: split entities out first, then unescape + HTML-escape the
// remaining prose, then apply inline formatting.

var EMOJI = {
    "smile": "\u{1F604}", "smiley": "\u{1F603}", "grin": "\u{1F601}", "joy": "\u{1F602}",
    "rofl": "\u{1F923}", "sweat_smile": "\u{1F605}", "wink": "\u{1F609}", "blush": "\u{1F60A}",
    "thinking_face": "\u{1F914}", "neutral_face": "\u{1F610}", "expressionless": "\u{1F611}",
    "smirk": "\u{1F60F}", "unamused": "\u{1F612}", "disappointed": "\u{1F61E}",
    "pensive": "\u{1F614}", "confused": "\u{1F615}", "worried": "\u{1F61F}",
    "cry": "\u{1F622}", "sob": "\u{1F62D}", "scream": "\u{1F631}", "flushed": "\u{1F633}",
    "sunglasses": "\u{1F60E}", "sleeping": "\u{1F634}", "nerd_face": "\u{1F913}",
    "exploding_head": "\u{1F92F}", "face_with_monocle": "\u{1F9D0}",
    "shushing_face": "\u{1F92B}", "saluting_face": "\u{1FAE1}",
    "thumbsup": "\u{1F44D}", "+1": "\u{1F44D}", "thumbsdown": "\u{1F44E}", "-1": "\u{1F44E}",
    "ok_hand": "\u{1F44C}", "clap": "\u{1F44F}", "raised_hands": "\u{1F64C}",
    "pray": "\u{1F64F}", "muscle": "\u{1F4AA}", "point_right": "\u{1F449}",
    "point_left": "\u{1F448}", "wave": "\u{1F44B}", "eyes": "\u{1F440}",
    "brain": "\u{1F9E0}", "handshake": "\u{1F91D}", "crossed_fingers": "\u{1F91E}",
    "heart": "❤", "yellow_heart": "\u{1F49B}", "green_heart": "\u{1F49A}",
    "blue_heart": "\u{1F499}", "purple_heart": "\u{1F49C}", "broken_heart": "\u{1F494}",
    "sparkling_heart": "\u{1F496}", "fire": "\u{1F525}", "tada": "\u{1F389}",
    "confetti_ball": "\u{1F38A}", "rocket": "\u{1F680}", "sparkles": "✨",
    "star": "⭐", "star2": "\u{1F31F}", "zap": "⚡", "boom": "\u{1F4A5}",
    "100": "\u{1F4AF}", "bulb": "\u{1F4A1}", "wrench": "\u{1F527}", "hammer": "\u{1F528}",
    "gear": "⚙", "bug": "\u{1F41B}", "skull": "\u{1F480}", "ghost": "\u{1F47B}",
    "alien": "\u{1F47D}", "robot_face": "\u{1F916}", "computer": "\u{1F4BB}",
    "keyboard": "⌨", "white_check_mark": "✅", "heavy_check_mark": "✔",
    "ballot_box_with_check": "☑", "x": "❌", "warning": "⚠",
    "no_entry": "⛔", "no_entry_sign": "\u{1F6AB}", "exclamation": "❗",
    "question": "❓", "bangbang": "‼", "arrow_up": "⬆",
    "arrow_down": "⬇", "arrow_right": "➡", "arrow_left": "⬅",
    "recycle": "♻", "hourglass": "⌛", "hourglass_flowing_sand": "⏳",
    "alarm_clock": "⏰", "calendar": "\u{1F4C5}", "date": "\u{1F4C6}",
    "memo": "\u{1F4DD}", "pencil": "✏", "books": "\u{1F4DA}", "book": "\u{1F4D6}",
    "page_facing_up": "\u{1F4C4}", "clipboard": "\u{1F4CB}", "paperclip": "\u{1F4CE}",
    "link": "\u{1F517}", "lock": "\u{1F512}", "key": "\u{1F511}", "mag": "\u{1F50D}",
    "chart_with_upwards_trend": "\u{1F4C8}", "chart_with_downwards_trend": "\u{1F4C9}",
    "bar_chart": "\u{1F4CA}", "moneybag": "\u{1F4B0}", "dollar": "\u{1F4B5}",
    "credit_card": "\u{1F4B3}", "mailbox": "\u{1F4EC}", "email": "\u{1F4E7}",
    "inbox_tray": "\u{1F4E5}", "outbox_tray": "\u{1F4E4}", "bell": "\u{1F514}",
    "no_bell": "\u{1F515}", "loudspeaker": "\u{1F4E2}", "mega": "\u{1F4E3}",
    "coffee": "☕", "tea": "\u{1F375}", "beer": "\u{1F37A}", "beers": "\u{1F37B}",
    "wine_glass": "\u{1F377}", "pizza": "\u{1F355}", "hamburger": "\u{1F354}",
    "cake": "\u{1F370}", "birthday": "\u{1F382}", "sos": "\u{1F198}", "new": "\u{1F195}",
    "ok": "\u{1F197}", "up": "\u{1F199}", "sunny": "☀", "cloud": "☁",
    "snowflake": "❄", "rainbow": "\u{1F308}", "earth_africa": "\u{1F30D}",
    "moon": "\u{1F319}", "seedling": "\u{1F331}", "palm_tree": "\u{1F334}",
    "cactus": "\u{1F335}", "four_leaf_clover": "\u{1F340}", "dog": "\u{1F436}",
    "cat": "\u{1F431}", "mouse": "\u{1F42D}", "hamster": "\u{1F439}",
    "rabbit": "\u{1F430}", "bear": "\u{1F43B}", "panda_face": "\u{1F43C}",
    "penguin": "\u{1F427}", "owl": "\u{1F989}", "whale": "\u{1F433}",
    "dolphin": "\u{1F42C}", "fish": "\u{1F41F}", "octopus": "\u{1F419}",
    "snail": "\u{1F40C}", "turtle": "\u{1F422}", "snake": "\u{1F40D}",
    "dragon": "\u{1F409}", "unicorn_face": "\u{1F984}", "shrug": "\u{1F937}",
    "man-shrugging": "\u{1F937}", "woman-shrugging": "\u{1F937}",
    "facepalm": "\u{1F926}", "party_parrot": "\u{1F99C}", "frog": "\u{1F438}"
};

function htmlEscape(s) {
    return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}

// Slack only ever escapes these three, and it does so around its own entities.
function slackUnescape(s) {
    return String(s).replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&amp;/g, "&");
}

/**
 * One :shortcode: -> unicode char, an <img> for a custom workspace emoji, or the
 * original token when we know nothing about it.
 * @param custom {emoji: {name: localPath}, aliases: {name: target}}
 */
function emojiHtml(name, custom, size) {
    var key = String(name).toLowerCase();
    var px = size || 18;

    var std = EMOJI[key];
    if (std !== undefined)
        return std;

    if (custom && custom.emoji && custom.emoji[key])
        return '<img src="file://' + custom.emoji[key] + '" width="' + px + '" height="' + px + '" align="middle">';

    if (custom && custom.aliases && custom.aliases[key]) {
        var target = String(custom.aliases[key]).toLowerCase();
        if (EMOJI[target] !== undefined)
            return EMOJI[target];
        if (custom.emoji && custom.emoji[target])
            return '<img src="file://' + custom.emoji[target] + '" width="' + px + '" height="' + px + '" align="middle">';
    }
    return null;
}

// Unicode-only pass, for contexts that are plain text rather than rich text.
function emojify(s) {
    return s.replace(/:([a-z0-9_+\-']+):(?::skin-tone-\d:)?/gi, function (full, name) {
        var hit = EMOJI[name.toLowerCase()];
        return hit !== undefined ? hit : full;
    });
}

function mono(text, colors) {
    return '<font face="' + colors.monoFamily + '" color="' + colors.code + '">' + text + "</font>";
}

// Inline formatting on already-HTML-escaped prose. Code spans are pulled out
// first so their contents never get re-interpreted as bold/italic.
function inlineFormat(escaped, colors, custom) {
    var spans = [];
    var out = escaped.replace(/`([^`\n]+)`/g, function (full, code) {
        spans.push(code);
        return "%%NCODE" + (spans.length - 1) + "%%";
    });

    out = out.replace(/(^|[\s(>])\*([^*\n]+)\*(?=[\s.,!?:;)]|$)/g, "$1<b>$2</b>");
    out = out.replace(/(^|[\s(>])_([^_\n]+)_(?=[\s.,!?:;)]|$)/g, "$1<i>$2</i>");
    out = out.replace(/(^|[\s(>])~([^~\n]+)~(?=[\s.,!?:;)]|$)/g, "$1<s>$2</s>");

    if (custom) {
        out = out.replace(/:([a-zA-Z0-9_+\-']+):/g, function (full, name) {
            var html = emojiHtml(name, custom, colors.emojiSize);
            return (html !== null && html.indexOf("<img") === 0) ? html : full;
        });
    }

    out = out.replace(/%%NCODE(\d+)%%/g, function (full, index) {
        return mono(spans[parseInt(index, 10)], colors);
    });

    // Blockquote lines, kept cheap: a coloured bar glyph instead of <blockquote>,
    // whose Qt margins look wrong at this size.
    out = out.replace(/(^|\n)&gt;\s?([^\n]*)/g, function (full, lead, body) {
        return lead + '<font color="' + colors.quote + '">▏ ' + body + "</font>";
    });

    return out.replace(/\n/g, "<br/>");
}

function renderEntity(inner, users, meId, colors) {
    var bar = inner.indexOf("|");
    var head = bar >= 0 ? inner.slice(0, bar) : inner;
    var label = bar >= 0 ? inner.slice(bar + 1) : "";

    if (head.charAt(0) === "@") {
        var uid = head.slice(1);
        var profile = users ? users[uid] : null;
        var name = label !== "" ? label : (profile && profile.name ? profile.name : uid);
        var isSelf = uid === meId;
        return '<font color="' + (isSelf ? colors.mentionSelf : colors.mention) + '">'
            + (isSelf ? "<b>@" + htmlEscape(name) + "</b>" : "@" + htmlEscape(name)) + "</font>";
    }
    if (head.charAt(0) === "#") {
        var cname = label !== "" ? label : head.slice(1);
        return '<font color="' + colors.mention + '">#' + htmlEscape(cname) + "</font>";
    }
    if (head.charAt(0) === "!") {
        var special = head.slice(1);
        if (special === "here" || special === "channel" || special === "everyone")
            return '<font color="' + colors.mentionSelf + '"><b>@' + special + "</b></font>";
        return htmlEscape(label !== "" ? label : special);
    }

    var href = head;
    var shown = label !== "" ? label : head.replace(/^https?:\/\//, "").replace(/\/$/, "");
    if (href.indexOf("mailto:") === 0 && label === "")
        shown = href.slice(7);
    return '<a href="' + htmlEscape(href) + '"><font color="' + colors.link + '">' + htmlEscape(emojify(shown)) + "</font></a>";
}

function renderProse(chunk, colors, custom) {
    return inlineFormat(htmlEscape(emojify(slackUnescape(chunk))), colors, custom);
}

function renderFence(chunk, colors) {
    var body = htmlEscape(slackUnescape(chunk)).replace(/^\n/, "").replace(/\n$/, "").replace(/\n/g, "<br/>").replace(/ {2}/g, "&nbsp;&nbsp;");
    return "<br/>" + mono(body, colors) + "<br/>";
}

/**
 * @param text    raw Slack message text
 * @param users   id -> {name} map used to resolve mentions
 * @param meId    own user id, so self-mentions can be highlighted
 * @param colors  {link, mention, mentionSelf, code, quote, monoFamily}
 */
function format(text, users, meId, colors, custom) {
    if (!text)
        return "";

    var result = "";
    var fences = String(text).split("```");

    for (var f = 0; f < fences.length; f++) {
        if (f % 2 === 1) {
            result += renderFence(fences[f], colors);
            continue;
        }
        // Entities never span a fence, so segment inside each prose block.
        var chunk = fences[f];
        var re = /<([^<>\n]*)>/g;
        var last = 0;
        var m;
        while ((m = re.exec(chunk)) !== null) {
            result += renderProse(chunk.slice(last, m.index), colors, custom);
            result += renderEntity(m[1], users, meId, colors);
            last = m.index + m[0].length;
        }
        result += renderProse(chunk.slice(last), colors, custom);
    }
    return result;
}

/** Plain-text flattening for sidebar previews and notifications. */
function preview(text, users) {
    if (!text)
        return "";
    var out = String(text).replace(/```/g, " ");
    out = out.replace(/<([^<>\n]*)>/g, function (full, inner) {
        var bar = inner.indexOf("|");
        var head = bar >= 0 ? inner.slice(0, bar) : inner;
        var label = bar >= 0 ? inner.slice(bar + 1) : "";
        if (head.charAt(0) === "@") {
            var uid = head.slice(1);
            var profile = users ? users[uid] : null;
            return "@" + (label !== "" ? label : (profile && profile.name ? profile.name : uid));
        }
        if (head.charAt(0) === "#")
            return "#" + (label !== "" ? label : head.slice(1));
        if (head.charAt(0) === "!")
            return "@" + head.slice(1);
        return label !== "" ? label : head.replace(/^https?:\/\//, "");
    });
    return emojify(slackUnescape(out)).replace(/[*_~`]/g, "").replace(/\s+/g, " ").trim();
}
