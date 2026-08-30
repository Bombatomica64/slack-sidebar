// SPDX-License-Identifier: MIT
//
// Link-preview metadata, extracted from a fetched HTML page.
//
// Split out of the command-line front end so the parts that face hostile input
// can be unit-tested directly rather than through a subprocess.

#ifndef SLACK_SIDEBAR_HTML_META_HPP
#define SLACK_SIDEBAR_HTML_META_HPP

#include <cstddef>
#include <iosfwd>
#include <string>
#include <string_view>

namespace slack::html {

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

#endif  // SLACK_SIDEBAR_HTML_META_HPP
