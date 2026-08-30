// SPDX-License-Identifier: MIT
//
// Link-preview metadata, extracted from a fetched HTML page.
//
// A C++20 module rather than a header/source pair. The whole native side is a
// handful of translation units, so the compile-time argument for modules is
// worth nothing here; what they buy is that there is one file per component
// instead of two that have to be kept in step, and that nothing leaks out of it
// except what `export` names.
//
// Kept deliberately importable-without-std-module: `import std;` needs gcc 15
// or libc++'s prebuilt std module, and this plugin has to build on whatever
// compiler the user's distro shipped. The standard library comes in through the
// global module fragment instead.

module;

#include <array>
#include <cstddef>
#include <cstdio>
#include <initializer_list>
#include <ostream>
#include <string>
#include <string_view>
#include <unordered_map>
#include <utility>
#include <vector>

export module slack.html;

export namespace slack::html {
// A <head> that has not produced OpenGraph tags within a megabyte is not going
// to; the cap also bounds what a hostile page can make us allocate.
inline constexpr std::size_t kMaxInput = std::size_t{1} << 20;
inline constexpr std::size_t kTitleMax = 300;
inline constexpr std::size_t kDescMax = 600;

// What a preview card needs, and nothing else. Every field is UTF-8 and may be
// empty; the caller decides whether what is left is worth drawing.
struct Meta {
    std::string url;          // the link as the message wrote it
    std::string finalUrl;     // where the fetch ended up after redirects
    std::string canonical;    // og:url or <link rel=canonical>, else finalUrl
    std::string site;         // og:site_name, else the host
    std::string title;
    std::string description;
    std::string image;        // absolute
    std::string icon;         // absolute, /favicon.ico as the last resort
    std::string kind;         // og:type
};

// Parse a document. `source` is the URL as written, `effective` the one the
// fetch ended on: relative hrefs resolve against the latter, and an empty
// `effective` falls back to `source`.
[[nodiscard]] Meta parse(std::string_view document, std::string_view source, std::string_view effective);

// Write `meta` as one JSON object, newline-terminated.
void write_json(std::ostream& os, const Meta& meta);

// --- pieces, public because they are what the tests actually pin down -------

// Named and numeric HTML entities to UTF-8. Unrecognised references are left
// as written, which is what a browser does with them too.
[[nodiscard]] std::string decode_entities(std::string_view in);

// Runs of whitespace to a single space, with the ends trimmed.
[[nodiscard]] std::string collapse_ws(std::string_view in);

// Cut to at most `max` bytes on a codepoint boundary, marking the cut.
[[nodiscard]] std::string truncate_utf8(std::string s, std::size_t max);

// Replace anything that is not well-formed UTF-8 with U+FFFD. Everything we
// print goes through here, so a page with a broken byte can never produce JSON
// that the caller refuses to parse.
[[nodiscard]] std::string sanitize_utf8(std::string_view in);

// Reinterpret a byte string as windows-1252 (which is also how browsers read a
// page that declares latin-1, or declares nothing).
[[nodiscard]] std::string transcode_cp1252(std::string_view in);

// Resolve `ref` against `base`. Returns empty for anything that is not http(s),
// so a data: or javascript: href can never reach the UI.
[[nodiscard]] std::string resolve_url(std::string_view base, std::string_view ref);

// Hostname of an absolute URL, without userinfo, port, or a leading "www.".
[[nodiscard]] std::string host_of(std::string_view url);
}  // namespace slack::html

namespace slack::html {
namespace {

using std::size_t;
using std::string;
using std::string_view;

[[nodiscard]] constexpr char lower(char c) noexcept {
    return (c >= 'A' && c <= 'Z') ? static_cast<char>(c - 'A' + 'a') : c;
}

[[nodiscard]] constexpr bool is_space(char c) noexcept {
    return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f' || c == '\v';
}

[[nodiscard]] constexpr bool is_name_char(char c) noexcept {
    const char l = lower(c);
    return (l >= 'a' && l <= 'z') || (c >= '0' && c <= '9') || c == '-';
}

[[nodiscard]] bool iequals(string_view a, string_view b) noexcept {
    if (a.size() != b.size())
        return false;
    for (size_t i = 0; i < a.size(); ++i)
        if (lower(a[i]) != lower(b[i]))
            return false;
    return true;
}

[[nodiscard]] string to_lower(string_view s) {
    string out(s);
    for (char& c : out)
        c = lower(c);
    return out;
}

[[nodiscard]] string_view trim(string_view s) noexcept {
    while (!s.empty() && is_space(s.front()))
        s.remove_prefix(1);
    while (!s.empty() && is_space(s.back()))
        s.remove_suffix(1);
    return s;
}

// Case-insensitive find, for the few literal needles we chase ("-->",
// "</script", "</title").
[[nodiscard]] size_t ifind(string_view hay, string_view needle, size_t from) noexcept {
    if (needle.empty() || hay.size() < needle.size())
        return string_view::npos;
    for (size_t i = from; i + needle.size() <= hay.size(); ++i) {
        bool hit = true;
        for (size_t j = 0; j < needle.size(); ++j) {
            if (lower(hay[i + j]) != lower(needle[j])) {
                hit = false;
                break;
            }
        }
        if (hit)
            return i;
    }
    return string_view::npos;
}

void append_utf8(string& out, char32_t cp) {
    if (cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF))
        cp = 0xFFFD;
    const auto byte = [](char32_t v) { return static_cast<char>(static_cast<unsigned char>(v)); };
    if (cp < 0x80) {
        out.push_back(byte(cp));
    } else if (cp < 0x800) {
        out.push_back(byte(0xC0 | (cp >> 6)));
        out.push_back(byte(0x80 | (cp & 0x3F)));
    } else if (cp < 0x10000) {
        out.push_back(byte(0xE0 | (cp >> 12)));
        out.push_back(byte(0x80 | ((cp >> 6) & 0x3F)));
        out.push_back(byte(0x80 | (cp & 0x3F)));
    } else {
        out.push_back(byte(0xF0 | (cp >> 18)));
        out.push_back(byte(0x80 | ((cp >> 12) & 0x3F)));
        out.push_back(byte(0x80 | ((cp >> 6) & 0x3F)));
        out.push_back(byte(0x80 | (cp & 0x3F)));
    }
}

// The eight-bit range where windows-1252 and latin-1 disagree. Pages that
// declare either (or nothing at all, which browsers treat as cp1252) are common
// enough that mojibake in a preview title is worth 32 table entries.
constexpr std::array<char32_t, 32> kCp1252High{
    0x20AC, 0x0081, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021,
    0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x008D, 0x017D, 0x008F,
    0x0090, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
    0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x009D, 0x017E, 0x0178};

const std::unordered_map<string_view, char32_t>& entity_table() {
    static const std::unordered_map<string_view, char32_t> table{
        {"amp", U'&'}, {"lt", U'<'}, {"gt", U'>'}, {"quot", U'"'}, {"apos", U'\''},
        {"nbsp", 0x00A0}, {"copy", 0x00A9}, {"reg", 0x00AE}, {"trade", 0x2122},
        {"hellip", 0x2026}, {"mdash", 0x2014}, {"ndash", 0x2013}, {"lsquo", 0x2018},
        {"rsquo", 0x2019}, {"ldquo", 0x201C}, {"rdquo", 0x201D}, {"bull", 0x2022},
        {"middot", 0x00B7}, {"deg", 0x00B0}, {"plusmn", 0x00B1}, {"times", 0x00D7},
        {"divide", 0x00F7}, {"laquo", 0x00AB}, {"raquo", 0x00BB}, {"euro", 0x20AC},
        {"pound", 0x00A3}, {"yen", 0x00A5}, {"cent", 0x00A2}, {"sect", 0x00A7},
        {"para", 0x00B6}, {"dagger", 0x2020}, {"Dagger", 0x2021}, {"permil", 0x2030},
        {"prime", 0x2032}, {"Prime", 0x2033}, {"larr", 0x2190}, {"uarr", 0x2191},
        {"rarr", 0x2192}, {"darr", 0x2193}, {"harr", 0x2194}, {"hearts", 0x2665},
        {"star", 0x2606}, {"check", 0x2713}, {"cross", 0x2717}, {"infin", 0x221E},
        {"ne", 0x2260}, {"le", 0x2264}, {"ge", 0x2265}, {"frac12", 0x00BD},
        {"frac14", 0x00BC}, {"frac34", 0x00BE}, {"sup2", 0x00B2}, {"sup3", 0x00B3},
        {"agrave", 0x00E0}, {"aacute", 0x00E1}, {"eacute", 0x00E9}, {"egrave", 0x00E8},
        {"iacute", 0x00ED}, {"oacute", 0x00F3}, {"uacute", 0x00FA}, {"ntilde", 0x00F1},
        {"ccedil", 0x00E7}, {"ouml", 0x00F6}, {"auml", 0x00E4}, {"uuml", 0x00FC},
        {"szlig", 0x00DF}, {"aring", 0x00E5}, {"oslash", 0x00F8}, {"aelig", 0x00E6},
        {"shy", 0x00AD}, {"zwj", 0x200D}, {"zwnj", 0x200C}, {"ensp", 0x2002},
        {"emsp", 0x2003}, {"thinsp", 0x2009}};
    return table;
}

// Sanitising comes first, and the order matters: a replacement character is
// three bytes where the byte it replaced was one, so scrubbing after truncating
// pushes the result back over the cap. (The fuzzer found exactly that, in the
// first version of this fix.)
[[nodiscard]] string clean_text(string_view raw, size_t max) {
    return truncate_utf8(collapse_ws(decode_entities(sanitize_utf8(raw))), max);
}

// ------------------------------------------------------------------- urls

struct SplitUrl {
    string scheme;     // "https"
    string authority;  // "example.com:8443"
    string path;       // "/a/b/c"
};

[[nodiscard]] bool has_scheme(string_view url) noexcept {
    if (url.empty())
        return false;
    if (!(lower(url.front()) >= 'a' && lower(url.front()) <= 'z'))
        return false;
    for (size_t i = 0; i < url.size(); ++i) {
        const char c = url[i];
        if (c == ':')
            return i > 0;
        const char l = lower(c);
        if (!((l >= 'a' && l <= 'z') || (c >= '0' && c <= '9') || c == '+' || c == '-' || c == '.'))
            return false;
    }
    return false;
}

[[nodiscard]] SplitUrl split_url(string_view url) {
    SplitUrl out;
    const size_t colon = url.find("://");
    if (colon == string_view::npos)
        return out;
    // Schemes are case-insensitive; everything that compares one downstream -
    // slack.sh's address guard, the QML card's local-vs-remote test - is not.
    // Normalise once, here, rather than making each of them tolerant.
    out.scheme = to_lower(url.substr(0, colon));
    const string_view rest = url.substr(colon + 3);
    const size_t slash = rest.find_first_of("/?#");
    if (slash == string_view::npos) {
        out.authority.assign(rest);
        out.path = "/";
    } else {
        out.authority.assign(rest.substr(0, slash));
        out.path.assign(rest.substr(slash));
    }
    return out;
}

// Squash "." and ".." segments; a preview URL that walks above the root is a
// bug, not a feature.
[[nodiscard]] string normalise_path(string_view path) {
    std::vector<string_view> parts;
    size_t i = 0;
    while (i <= path.size()) {
        const size_t slash = path.find('/', i);
        const string_view seg = path.substr(i, (slash == string_view::npos ? path.size() : slash) - i);
        if (seg == "..") {
            if (!parts.empty())
                parts.pop_back();
        } else if (seg != "." && !seg.empty()) {
            parts.push_back(seg);
        }
        if (slash == string_view::npos)
            break;
        i = slash + 1;
    }
    string out;
    for (const string_view seg : parts) {
        out.push_back('/');
        out.append(seg);
    }
    if (out.empty())
        return "/";
    if (!path.empty() && path.back() == '/' && out.back() != '/')
        out.push_back('/');
    return out;
}

// ------------------------------------------------------------------- parsing

struct Doc {
    std::unordered_map<string, string> meta;       // property/name -> first content seen
    std::vector<std::pair<string, string>> icons;  // (rel, href)
    string title;
    string canonical;
    string base;
    string charset;
};

using Attrs = std::vector<std::pair<string, string>>;

[[nodiscard]] const string* attr(const Attrs& attrs, string_view name) {
    for (const auto& [k, v] : attrs)
        if (k == name)
            return &v;
    return nullptr;
}

// Consumes attributes starting at `i` and leaves `i` just past the closing '>'.
[[nodiscard]] Attrs parse_attrs(string_view b, size_t& i) {
    Attrs out;
    const size_t n = b.size();
    while (i < n) {
        while (i < n && is_space(b[i]))
            ++i;
        if (i >= n)
            break;
        if (b[i] == '>') {
            ++i;
            break;
        }
        if (b[i] == '/') {
            ++i;
            continue;
        }
        size_t s = i;
        while (i < n && !is_space(b[i]) && b[i] != '=' && b[i] != '>')
            ++i;
        string name = to_lower(b.substr(s, i - s));
        const size_t after_name = i;
        while (i < n && is_space(b[i]))
            ++i;
        string value;
        if (i < n && b[i] == '=') {
            ++i;
            while (i < n && is_space(b[i]))
                ++i;
            if (i < n && (b[i] == '"' || b[i] == '\'')) {
                const char q = b[i++];
                s = i;
                while (i < n && b[i] != q)
                    ++i;
                value.assign(b.substr(s, i - s));
                if (i < n)
                    ++i;
            } else {
                s = i;
                while (i < n && !is_space(b[i]) && b[i] != '>')
                    ++i;
                value.assign(b.substr(s, i - s));
            }
        } else {
            // A valueless attribute: the whitespace we skipped belongs to the
            // next one, so hand it back.
            i = after_name;
        }
        if (!name.empty())
            out.emplace_back(std::move(name), std::move(value));
    }
    return out;
}

void parse_html(string_view b, Doc& doc) {
    const size_t n = b.size();
    size_t i = 0;
    bool head_ended = false;

    while (i < n) {
        const size_t lt = b.find('<', i);
        if (lt == string_view::npos)
            break;
        i = lt;

        if (b.compare(i, 4, "<!--") == 0) {
            const size_t end = b.find("-->", i + 4);
            i = (end == string_view::npos) ? n : end + 3;
            continue;
        }
        size_t j = i + 1;
        if (j >= n)
            break;
        if (b[j] == '!' || b[j] == '?') {
            const size_t end = b.find('>', j);
            i = (end == string_view::npos) ? n : end + 1;
            continue;
        }
        const bool closing = b[j] == '/';
        if (closing)
            ++j;
        const size_t name_start = j;
        while (j < n && is_name_char(b[j]))
            ++j;
        if (j == name_start) {
            // A stray '<' in prose. Step over it rather than stalling.
            i = lt + 1;
            continue;
        }
        const string tag = to_lower(b.substr(name_start, j - name_start));

        if (closing) {
            if (tag == "head")
                head_ended = true;
            const size_t end = b.find('>', j);
            i = (end == string_view::npos) ? n : end + 1;
            continue;
        }

        const Attrs attrs = parse_attrs(b, j);
        i = j;

        if (tag == "body") {
            head_ended = true;
            continue;
        }
        if (tag == "script" || tag == "style" || tag == "template") {
            const string close = "</" + tag;
            const size_t end = ifind(b, close, i);
            i = (end == string_view::npos) ? n : end + close.size();
            continue;
        }
        if (tag == "title") {
            const size_t end = ifind(b, "</title", i);
            if (doc.title.empty() && !head_ended) {
                const string_view raw = b.substr(i, (end == string_view::npos ? n : end) - i);
                doc.title = clean_text(raw, kTitleMax);
            }
            i = (end == string_view::npos) ? n : end;
            continue;
        }
        if (tag == "base") {
            if (const string* href = attr(attrs, "href"); href != nullptr && doc.base.empty())
                doc.base = *href;
            continue;
        }
        if (tag == "meta") {
            if (const string* cs = attr(attrs, "charset"); cs != nullptr && doc.charset.empty())
                doc.charset = to_lower(trim(*cs));
            const string* content = attr(attrs, "content");
            const string* equiv = attr(attrs, "http-equiv");
            if (equiv != nullptr && content != nullptr && iequals(*equiv, "content-type") && doc.charset.empty()) {
                const string lowered = to_lower(*content);
                if (const size_t at = lowered.find("charset="); at != string::npos) {
                    const string_view tail = string_view(lowered).substr(at + 8);
                    const size_t end = tail.find_first_of("; \t\"'");
                    doc.charset = string(trim(tail.substr(0, end == string_view::npos ? tail.size() : end)));
                }
            }
            if (content == nullptr)
                continue;
            for (const string_view key : {"property", "name", "itemprop"}) {
                const string* k = attr(attrs, key);
                if (k == nullptr || k->empty())
                    continue;
                doc.meta.try_emplace(to_lower(trim(*k)), *content);
            }
            continue;
        }
        if (tag == "link") {
            const string* rel = attr(attrs, "rel");
            const string* href = attr(attrs, "href");
            if (rel == nullptr || href == nullptr || href->empty())
                continue;
            const string r = to_lower(trim(*rel));
            if (r == "canonical" && doc.canonical.empty())
                doc.canonical = *href;
            else if (r.find("icon") != string::npos)
                doc.icons.emplace_back(r, *href);
            continue;
        }
    }
}

[[nodiscard]] string pick(const Doc& doc, std::initializer_list<string_view> keys) {
    for (const string_view k : keys) {
        const auto it = doc.meta.find(string(k));
        if (it != doc.meta.end() && !trim(it->second).empty())
            return it->second;
    }
    return {};
}

// A page can declare several icons; prefer an explicit rel="icon", otherwise
// take the last, which by convention is the highest resolution.
[[nodiscard]] string pick_icon(const Doc& doc) {
    string best;
    for (const auto& [rel, href] : doc.icons) {
        if (rel == "icon" || rel == "shortcut icon")
            best = href;
    }
    if (best.empty() && !doc.icons.empty())
        best = doc.icons.back().second;
    return best;
}

void json_escape(std::ostream& os, string_view raw) {
    const string safe = sanitize_utf8(raw);
    os << '"';
    for (const char ch : safe) {
        const auto c = static_cast<unsigned char>(ch);
        switch (c) {
        case '"': os << "\\\""; break;
        case '\\': os << "\\\\"; break;
        case '\b': os << "\\b"; break;
        case '\f': os << "\\f"; break;
        case '\n': os << "\\n"; break;
        case '\r': os << "\\r"; break;
        case '\t': os << "\\t"; break;
        default:
            if (c < 0x20) {
                std::array<char, 8> buf{};
                std::snprintf(buf.data(), buf.size(), "\\u%04x", static_cast<unsigned>(c));
                os << buf.data();
            } else {
                os << ch;
            }
        }
    }
    os << '"';
}

void field(std::ostream& os, string_view key, string_view value) {
    os << ',';
    json_escape(os, key);
    os << ':';
    json_escape(os, value);
}

}  // namespace

// --------------------------------------------------------------- public API

string transcode_cp1252(string_view in) {
    string out;
    out.reserve(in.size() + in.size() / 4);
    for (const char ch : in) {
        const auto b = static_cast<unsigned char>(ch);
        if (b < 0x80)
            out.push_back(ch);
        else if (b < 0xA0)
            append_utf8(out, kCp1252High[b - 0x80U]);
        else
            append_utf8(out, static_cast<char32_t>(b));
    }
    return out;
}

string sanitize_utf8(string_view in) {
    string out;
    out.reserve(in.size());
    size_t i = 0;
    while (i < in.size()) {
        const auto b0 = static_cast<unsigned char>(in[i]);
        size_t len = 0;
        char32_t cp = 0;
        if (b0 < 0x80) {
            out.push_back(in[i]);
            ++i;
            continue;
        }
        if ((b0 & 0xE0U) == 0xC0U) {
            len = 2;
            cp = b0 & 0x1FU;
        } else if ((b0 & 0xF0U) == 0xE0U) {
            len = 3;
            cp = b0 & 0x0FU;
        } else if ((b0 & 0xF8U) == 0xF0U) {
            len = 4;
            cp = b0 & 0x07U;
        } else {
            append_utf8(out, 0xFFFD);
            ++i;
            continue;
        }
        if (i + len > in.size()) {
            append_utf8(out, 0xFFFD);
            ++i;
            continue;
        }
        bool ok = true;
        for (size_t k = 1; k < len; ++k) {
            const auto bk = static_cast<unsigned char>(in[i + k]);
            if ((bk & 0xC0U) != 0x80U) {
                ok = false;
                break;
            }
            cp = (cp << 6) | (bk & 0x3FU);
        }
        // Reject overlong forms and surrogates as well as truncated sequences:
        // both are how a crafted page smuggles a quote past an escaper.
        const bool overlong = (len == 2 && cp < 0x80) || (len == 3 && cp < 0x800) || (len == 4 && cp < 0x10000);
        if (!ok || overlong || cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF)) {
            append_utf8(out, 0xFFFD);
            ++i;
            continue;
        }
        out.append(in.substr(i, len));
        i += len;
    }
    return out;
}

string decode_entities(string_view in) {
    string out;
    out.reserve(in.size());
    size_t i = 0;
    while (i < in.size()) {
        if (in[i] != '&') {
            out.push_back(in[i++]);
            continue;
        }
        const size_t semi = in.find(';', i + 1);
        // A bare "&", or one whose ";" is implausibly far away, is literal text.
        if (semi == string_view::npos || semi - i > 32) {
            out.push_back(in[i++]);
            continue;
        }
        const string_view body = in.substr(i + 1, semi - i - 1);
        if (body.empty()) {
            out.push_back(in[i++]);
            continue;
        }
        if (body.front() == '#') {
            const bool hex = body.size() > 1 && (body[1] == 'x' || body[1] == 'X');
            const string_view digits = body.substr(hex ? 2 : 1);
            if (digits.empty()) {
                out.push_back(in[i++]);
                continue;
            }
            unsigned long long cp = 0;
            bool valid = true;
            for (const char c : digits) {
                unsigned v = 0;
                if (c >= '0' && c <= '9')
                    v = static_cast<unsigned>(c - '0');
                else if (hex && lower(c) >= 'a' && lower(c) <= 'f')
                    v = static_cast<unsigned>(lower(c) - 'a' + 10);
                else {
                    valid = false;
                    break;
                }
                cp = cp * (hex ? 16U : 10U) + v;
                if (cp > 0x10FFFF) {
                    valid = false;
                    break;
                }
            }
            if (!valid) {
                out.push_back(in[i++]);
                continue;
            }
            // Numeric references in the cp1252 range mean the cp1252 glyph in
            // every browser, so follow suit rather than emitting a control code.
            if (cp >= 0x80 && cp <= 0x9F)
                append_utf8(out, kCp1252High[cp - 0x80U]);
            else
                append_utf8(out, static_cast<char32_t>(cp));
            i = semi + 1;
            continue;
        }
        const auto& table = entity_table();
        if (const auto it = table.find(body); it != table.end()) {
            append_utf8(out, it->second);
            i = semi + 1;
            continue;
        }
        // Named entities are case sensitive apart from the handful of ALL-CAPS
        // legacy spellings (&AMP; &LT;), so retry lowercased before giving up.
        if (const auto it = table.find(to_lower(body)); it != table.end() && body.size() <= 6) {
            append_utf8(out, it->second);
            i = semi + 1;
            continue;
        }
        out.push_back(in[i++]);
    }
    return out;
}

string collapse_ws(string_view in) {
    string out;
    out.reserve(in.size());
    bool pending = false;
    for (const char c : in) {
        if (is_space(c)) {
            pending = !out.empty();
            continue;
        }
        if (pending) {
            out.push_back(' ');
            pending = false;
        }
        out.push_back(c);
    }
    return out;
}

string truncate_utf8(string s, size_t max) {
    if (s.size() <= max)
        return s;
    size_t cut = max;
    while (cut > 0 && (static_cast<unsigned char>(s[cut]) & 0xC0U) == 0x80U)
        --cut;
    // Prefer breaking at the last space in the tail we are about to drop.
    if (const size_t space = s.rfind(' ', cut); space != string::npos && space + 24 >= cut)
        cut = space;
    s.resize(cut);
    while (!s.empty() && is_space(s.back()))
        s.pop_back();
    s += "…";
    return s;
}

string resolve_url(string_view base, string_view ref_in) {
    const string_view ref = trim(ref_in);
    if (ref.empty())
        return {};
    // A control character (a NUL especially) is not something RFC 3986 admits,
    // and each consumer downstream mangles it differently - a NUL truncates the
    // argv element handed to xdg-open. Refuse rather than guess. Found by the
    // fuzzer.
    for (const char c : ref) {
        const auto byte = static_cast<unsigned char>(c);
        if (byte < 0x20 || byte == 0x7F)
            return {};
    }
    if (ref.starts_with("data:") || ref.starts_with("javascript:") || ref.starts_with("about:"))
        return {};
    if (ref.starts_with("//")) {
        const SplitUrl b = split_url(base);
        return (b.scheme.empty() ? string("https") : b.scheme) + ":" + string(ref);
    }
    if (has_scheme(ref)) {
        // Only http(s) ends up in a card, and the authority is required too:
        // "https:nonsense" has a scheme we accept and is still not something
        // any fetcher or xdg-open can do anything with. Checking the scheme
        // alone let those through (found by the fuzzer).
        const string lowered = to_lower(ref);
        const size_t scheme_len = lowered.starts_with("https://") ? 8 : (lowered.starts_with("http://") ? 7 : 0);
        if (scheme_len == 0)
            return {};
        // Keep the lowercased scheme, keep the rest of the URL exactly as the
        // page wrote it: paths and queries are case-sensitive.
        return lowered.substr(0, scheme_len) + string(ref.substr(scheme_len));
    }
    const SplitUrl b = split_url(base);
    if (b.authority.empty())
        return {};
    const string origin = b.scheme + "://" + b.authority;
    if (ref.front() == '#' || ref.front() == '?')
        return string(base) + string(ref);
    if (ref.front() == '/')
        return origin + normalise_path(ref);
    string dir = b.path;
    const size_t slash = dir.rfind('/');
    dir = (slash == string::npos) ? "/" : dir.substr(0, slash + 1);
    return origin + normalise_path(dir + string(ref));
}

string host_of(string_view url) {
    string authority = to_lower(split_url(url).authority);
    if (const size_t at = authority.find('@'); at != string::npos)
        authority.erase(0, at + 1);
    if (const size_t colon = authority.find(':'); colon != string::npos)
        authority.erase(colon);
    if (authority.starts_with("www."))
        authority.erase(0, 4);
    return authority;
}

Meta parse(string_view document, string_view source, string_view effective) {
    const string effective_url = effective.empty() ? string(source) : string(effective);

    Doc doc;
    parse_html(document, doc);

    // Re-parse when the page turns out not to be UTF-8: transcoding first would
    // mean guessing before we have read the declaration.
    string converted;
    if (!doc.charset.empty() && doc.charset != "utf-8" && doc.charset != "utf8") {
        if (doc.charset == "iso-8859-1" || doc.charset == "latin1" || doc.charset == "latin-1" ||
            doc.charset == "windows-1252" || doc.charset == "cp1252" || doc.charset == "iso8859-1") {
            converted = transcode_cp1252(document);
            doc = Doc{};
            parse_html(converted, doc);
        }
    }

    Meta meta;
    meta.url = string(source);
    meta.finalUrl = effective_url;

    const string canonical_raw = pick(doc, {"og:url"});
    meta.canonical = resolve_url(effective_url, canonical_raw.empty() ? doc.canonical : canonical_raw);
    if (meta.canonical.empty())
        meta.canonical = effective_url;

    const string base = doc.base.empty() ? effective_url : resolve_url(effective_url, doc.base);

    meta.title = clean_text(pick(doc, {"og:title", "twitter:title", "title"}), kTitleMax);
    if (meta.title.empty())
        meta.title = doc.title;

    meta.description = clean_text(pick(doc, {"og:description", "twitter:description", "description"}), kDescMax);

    meta.image = resolve_url(base, pick(doc, {"og:image:secure_url", "og:image:url", "og:image",
                                              "twitter:image", "twitter:image:src", "image"}));

    meta.icon = resolve_url(base, pick_icon(doc));
    if (meta.icon.empty())
        meta.icon = resolve_url(effective_url, "/favicon.ico");

    meta.site = clean_text(pick(doc, {"og:site_name", "application-name", "twitter:site"}), 80);
    if (meta.site.empty() || meta.site.front() == '@')
        meta.site = host_of(meta.canonical);

    meta.kind = clean_text(pick(doc, {"og:type"}), 40);

    // A backstop over everything on the way out, rather than trusting each
    // field's own path to have done it. A page that declares a charset we do not
    // transcode (or a plausible-looking one that is a lie) leaves raw non-UTF-8
    // bytes in the markup, and they otherwise travel all the way into Meta:
    // write_json scrubs what it prints, but a caller that uses these fields
    // in-process rather than through the JSON gets the bad bytes. Found by the
    // fuzzer, on a page declaring "ISO-885<0x96>9-1".
    //
    // For anything that came through clean_text this is now a no-op; it is the
    // URLs, built straight from attribute bytes, that still need it.
    for (string* field : {&meta.url, &meta.finalUrl, &meta.canonical, &meta.site,
                          &meta.title, &meta.description, &meta.image, &meta.icon, &meta.kind}) {
        if (const string clean = sanitize_utf8(*field); clean != *field)
            *field = clean;
    }
    return meta;
}

void write_json(std::ostream& os, const Meta& meta) {
    os << R"({"ok":true)";
    field(os, "url", meta.url);
    field(os, "finalUrl", meta.finalUrl);
    field(os, "canonical", meta.canonical);
    field(os, "site", meta.site);
    field(os, "title", meta.title);
    field(os, "description", meta.description);
    field(os, "image", meta.image);
    field(os, "icon", meta.icon);
    field(os, "kind", meta.kind);
    os << "}\n";
}
}  // namespace slack::html
