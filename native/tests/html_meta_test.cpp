// SPDX-License-Identifier: MIT
//
// Unit tests for the link-preview parser.
//
// Hand-rolled rather than gtest: one more build dependency for a plugin that
// people install by cloning is a worse trade than forty lines of assert. Run
// under -fsanitize=address,undefined in CI, which is where most of the value
// of testing a parser on hostile input actually comes from.

#include "../html_meta.hpp"

#include <cstddef>
#include <iostream>
#include <sstream>
#include <string>
#include <string_view>

namespace {

int g_failures = 0;
int g_checks = 0;

void expect_eq(std::string_view got, std::string_view want, std::string_view what) {
    ++g_checks;
    if (got == want)
        return;
    ++g_failures;
    std::cerr << "FAIL " << what << "\n  want: [" << want << "]\n  got:  [" << got << "]\n";
}

// A string made of nothing but U+FFFD, which is what sanitising a wholly
// malformed sequence has to leave behind.
[[nodiscard]] bool is_all_replacement(std::string_view s) {
    if (s.empty() || s.size() % 3 != 0)
        return false;
    for (std::size_t i = 0; i < s.size(); i += 3)
        if (s.substr(i, 3) != "\xef\xbf\xbd")
            return false;
    return true;
}

void expect_true(bool cond, std::string_view what) {
    ++g_checks;
    if (cond)
        return;
    ++g_failures;
    std::cerr << "FAIL " << what << "\n";
}

using slack::html::Meta;

Meta parse(std::string_view doc, std::string_view url = "https://example.com/a/b/page?x=1") {
    return slack::html::parse(doc, url, "");
}

// --------------------------------------------------------------------- utf8

void test_sanitize_utf8() {
    using slack::html::sanitize_utf8;
    expect_eq(sanitize_utf8("plain ascii"), "plain ascii", "sanitize: ascii passes through");
    expect_eq(sanitize_utf8("caf\xc3\xa9"), "caf\xc3\xa9", "sanitize: valid two-byte sequence kept");
    expect_eq(sanitize_utf8("\xff\xfe"), "\xef\xbf\xbd\xef\xbf\xbd", "sanitize: lone invalid bytes replaced");
    expect_eq(sanitize_utf8("\xc3"), "\xef\xbf\xbd", "sanitize: truncated sequence replaced");
    expect_eq(sanitize_utf8("\xf0\x9f\x98\x80"), "\xf0\x9f\x98\x80", "sanitize: four-byte emoji kept");

    // The guarantee is "nothing invalid survives", not a particular number of
    // replacement characters: a rejected sequence resumes at the byte after the
    // one that failed, so C0 80 comes back as two U+FFFD rather than one. That
    // is also what WHATWG's decoder does with a lead byte outside C2..DF, and
    // counting them here would pin down an implementation detail instead of the
    // property that matters.
    //
    // C0 80 is an overlong NUL, the classic way to smuggle a byte past a naive
    // escaper; ED A0 80 is the surrogate U+D800. Neither is legal UTF-8.
    for (const std::string_view bad : {"\xc0\x80", "\xed\xa0\x80", "\xff",
                                       "\xe2\x82", "\xf0\x9f\x98", "\xf5\x80\x80\x80"}) {
        const std::string clean = sanitize_utf8(bad);
        expect_true(is_all_replacement(clean), "sanitize: nothing survives from a malformed sequence");
        expect_eq(sanitize_utf8(clean), clean, "sanitize: is idempotent");
    }

    // A bad lead byte followed by ordinary ASCII: the lead is replaced and the
    // ASCII is kept, rather than the pair being swallowed together.
    expect_eq(sanitize_utf8("\xc3" "("), "\xef\xbf\xbd" "(", "sanitize: ASCII after a bad lead byte survives");

    // Valid text either side of a bad byte has to come through untouched.
    // Split literals: a hex escape swallows every following hex digit, so
    // "\xffb" would be one out-of-range escape rather than a byte and a 'b'.
    expect_eq(sanitize_utf8("a\xff" "b"), "a\xef\xbf\xbd" "b", "sanitize: keeps the good bytes around a bad one");
}

void test_entities() {
    using slack::html::decode_entities;
    expect_eq(decode_entities("a &amp; b"), "a & b", "entities: named");
    expect_eq(decode_entities("&lt;tag&gt;"), "<tag>", "entities: angle brackets");
    expect_eq(decode_entities("&#65;&#x42;"), "AB", "entities: decimal and hex numeric");
    expect_eq(decode_entities("&#x1F600;"), "\xf0\x9f\x98\x80", "entities: astral numeric");
    expect_eq(decode_entities("&hellip;"), "\xe2\x80\xa6", "entities: hellip");
    // Browsers map numeric references in the C1 range to cp1252 glyphs.
    expect_eq(decode_entities("&#147;"), "\xe2\x80\x9c", "entities: C1 numeric maps to cp1252");
    expect_eq(decode_entities("100% &notathing; ok"), "100% &notathing; ok", "entities: unknown left alone");
    expect_eq(decode_entities("a & b"), "a & b", "entities: bare ampersand left alone");
    expect_eq(decode_entities("&"), "&", "entities: trailing ampersand");
    expect_eq(decode_entities("&#;"), "&#;", "entities: empty numeric left alone");
    expect_eq(decode_entities("&#x110000;"), "&#x110000;", "entities: out-of-range numeric left alone");
}

void test_collapse_and_truncate() {
    using slack::html::collapse_ws;
    using slack::html::truncate_utf8;
    expect_eq(collapse_ws("  a \n\t b  "), "a b", "collapse: runs and ends");
    expect_eq(collapse_ws(""), "", "collapse: empty");
    expect_eq(collapse_ws("   "), "", "collapse: all whitespace");

    expect_eq(truncate_utf8("short", 100), "short", "truncate: under the cap is untouched");
    // Cutting mid-sequence would emit half a character; the cut has to move back
    // to a boundary. "é" is two bytes, so a cap of 4 lands inside the third one.
    const std::string accents = "\xc3\xa9\xc3\xa9\xc3\xa9";
    const std::string cut = truncate_utf8(accents, 5);
    expect_eq(slack::html::sanitize_utf8(cut), cut, "truncate: result is still valid UTF-8");
    expect_true(cut.size() <= 5 + 3, "truncate: result respects the cap plus the ellipsis");
}

void test_urls() {
    using slack::html::host_of;
    using slack::html::resolve_url;
    const std::string base = "https://example.com/a/b/page?x=1";
    expect_eq(resolve_url(base, "/img.png"), "https://example.com/img.png", "url: absolute path");
    expect_eq(resolve_url(base, "img.png"), "https://example.com/a/b/img.png", "url: relative path");
    expect_eq(resolve_url(base, "../img.png"), "https://example.com/a/img.png", "url: parent segment");
    expect_eq(resolve_url(base, "../../../../img.png"), "https://example.com/img.png", "url: cannot climb above root");
    expect_eq(resolve_url(base, "//cdn.example.com/x.png"), "https://cdn.example.com/x.png", "url: scheme-relative");
    expect_eq(resolve_url(base, "https://other.test/y"), "https://other.test/y", "url: already absolute");
    expect_eq(resolve_url(base, "  /spaced.png  "), "https://example.com/spaced.png", "url: trimmed");
    // Anything that is not http(s) must not reach a card the user can click.
    expect_eq(resolve_url(base, "javascript:alert(1)"), "", "url: javascript rejected");
    expect_eq(resolve_url(base, "data:image/png;base64,AAAA"), "", "url: data rejected");
    expect_eq(resolve_url(base, "ftp://example.com/x"), "", "url: ftp rejected");
    expect_eq(resolve_url(base, ""), "", "url: empty");

    expect_eq(host_of("https://www.example.com:8443/x"), "example.com", "host: strips www and port");
    expect_eq(host_of("http://user:pw@example.org/x"), "example.org", "host: strips userinfo");
    expect_eq(host_of("not a url"), "", "host: garbage yields nothing");
}

// -------------------------------------------------------------------- pages

void test_opengraph() {
    const Meta m = parse(R"(<!DOCTYPE html>
<html><head>
<meta charset="utf-8">
<title>Fallback &amp; Title</title>
<meta property="og:title" content="Real   Title &hellip;">
<meta property="og:description" content="Two
lines">
<meta property="og:site_name" content="Example Co">
<meta property=og:image content=/img/preview.png>
<link rel="canonical" href="https://example.com/final/page">
<link rel=icon href="../favicon.png">
</head><body></body></html>)");
    expect_eq(m.title, "Real Title \xe2\x80\xa6", "og: title wins over <title>, whitespace collapsed");
    expect_eq(m.description, "Two lines", "og: description newline collapsed");
    expect_eq(m.site, "Example Co", "og: site name");
    expect_eq(m.image, "https://example.com/img/preview.png", "og: unquoted attribute, path resolved");
    expect_eq(m.canonical, "https://example.com/final/page", "og: canonical link");
    expect_eq(m.icon, "https://example.com/a/favicon.png", "og: icon resolved relative to the document");
}

void test_comments_and_scripts_are_skipped() {
    const Meta m = parse(R"(<html><head>
<!-- <meta property="og:title" content="COMMENTED OUT"> -->
<script>var s = "<meta property='og:title' content='IN SCRIPT'>";</script>
<style>body::after{content:"<title>IN STYLE</title>"}</style>
<meta property="og:title" content="Real">
</head></html>)");
    expect_eq(m.title, "Real", "skip: commented-out and scripted meta ignored");
}

void test_title_fallbacks() {
    expect_eq(parse("<html><head><title>Just A Title</title></head></html>").title,
              "Just A Title", "fallback: <title> when there is no og:title");
    expect_eq(parse("<html><head><meta name=\"twitter:title\" content=\"Tw\"></head></html>").title,
              "Tw", "fallback: twitter:title");
    // A <title> inside <body> (an inline SVG, say) is not the document title.
    expect_eq(parse("<html><head></head><body><title>Body</title></body></html>").title,
              "", "fallback: <title> after <body> ignored");
    expect_eq(parse("<html><head></head></html>").site, "example.com",
              "fallback: site name falls back to the host");
}

void test_charset() {
    // "Café" in latin-1, declared as such: parsed twice, the second time
    // transcoded, so the title comes out as UTF-8 rather than mojibake.
    const Meta m = parse("<html><head>"
                         "<meta http-equiv=\"Content-Type\" content=\"text/html; charset=ISO-8859-1\">"
                         "<title>Caf\xe9</title></head></html>");
    expect_eq(m.title, "Caf\xc3\xa9", "charset: latin-1 page transcoded");
    expect_eq(slack::html::sanitize_utf8(m.title), m.title, "charset: result is valid UTF-8");
}

void test_malformed_input_terminates() {
    // None of these should hang, crash, or read out of bounds. Under the
    // sanitizers in CI that is a real assertion, not a formality.
    expect_true(parse("").title.empty(), "malformed: empty document");
    expect_true(parse("<").title.empty(), "malformed: lone angle bracket");
    expect_true(parse("<!--").title.empty(), "malformed: unterminated comment");
    expect_true(parse("<html><head><meta property=\"og:title\" content=\"unclosed").title == "unclosed",
                "malformed: unterminated tag still yields its attribute");
    expect_true(parse("<script>").title.empty(), "malformed: unterminated script");
    expect_true(parse("<title>").title.empty(), "malformed: unterminated title");
    expect_true(parse("<meta charset=>").title.empty(), "malformed: empty attribute value");
    expect_true(parse("<a b c d e f>").title.empty(), "malformed: valueless attributes");
    expect_true(parse(std::string(4096, '<')).title.empty(), "malformed: nothing but angle brackets");
    expect_true(parse(std::string(4096, '\xff')).title.empty(), "malformed: nothing but invalid bytes");
}

void test_json_is_wellformed() {
    Meta m;
    m.url = "https://x.test/";
    m.title = "quote \" backslash \\ newline \n tab \t control \x01";
    m.description = "bad byte \xff here";
    std::ostringstream os;
    slack::html::write_json(os, m);
    const std::string out = os.str();
    expect_true(out.starts_with(R"({"ok":true,)"), "json: starts with ok");
    expect_true(out.ends_with("}\n"), "json: one object, newline terminated");
    expect_true(out.find(R"(\")") != std::string::npos, "json: quote escaped");
    expect_true(out.find(R"(\u0001)") != std::string::npos, "json: control character escaped");
    expect_true(out.find('\n') == out.size() - 1, "json: no raw newline in the body");
    expect_true(out.find("\xff") == std::string::npos, "json: invalid byte scrubbed");
}

}  // namespace

int main() {
    test_sanitize_utf8();
    test_entities();
    test_collapse_and_truncate();
    test_urls();
    test_opengraph();
    test_comments_and_scripts_are_skipped();
    test_title_fallbacks();
    test_charset();
    test_malformed_input_terminates();
    test_json_is_wellformed();

    if (g_failures == 0) {
        std::cout << g_checks << " checks passed\n";
        return 0;
    }
    std::cerr << g_failures << " of " << g_checks << " checks failed\n";
    return 1;
}
