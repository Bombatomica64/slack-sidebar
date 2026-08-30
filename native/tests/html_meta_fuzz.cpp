// SPDX-License-Identifier: MIT
//
// libFuzzer target for the link-preview parser.
//
// The unit tests cover the malformed inputs somebody thought of. This covers
// the ones nobody did, which for a parser whose entire input is chosen by
// whoever owns the page at the other end of a pasted link is the more useful
// half. Built with -fsanitize=fuzzer,address,undefined, so a read past the end
// of the buffer or a signed overflow in the index arithmetic aborts rather than
// quietly producing a wrong title.
//
//   make fuzz                     build it
//   ./build/html_meta_fuzz -max_total_time=60 native/tests/corpus
//
// The assertions below are the parser's contract, not just "did not crash":
// whatever it returns has to be printable as valid JSON, because the QML side
// parses it and a malformed object there means a sidebar with no messages.

#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <sstream>
#include <string>
#include <string_view>

// Includes before import: see the note in html_meta_test.cpp.
import slack.html;

namespace {

void must(bool cond, const char* what) {
    if (!cond) {
        // Abort rather than throw: libFuzzer reports the crashing input, and a
        // thrown exception would just unwind into its handler.
        std::fputs(what, stderr);
        std::fputc('\n', stderr);
        __builtin_trap();
    }
}

}  // namespace

extern "C" int LLVMFuzzerTestOneInput(const std::uint8_t* data, std::size_t size) {
    const std::string_view document(reinterpret_cast<const char*>(data), size);

    // Two different bases, because URL resolution is where the index
    // arithmetic lives and an empty authority takes a different path.
    for (const std::string_view base : {"https://example.com/a/b/page?x=1", "not-a-url"}) {
        const slack::html::Meta meta = slack::html::parse(document, base, "");

        // Every string that leaves the parser is UTF-8, or the JSON it lands in
        // is not parseable by the caller.
        for (const std::string* field : {&meta.canonical, &meta.site, &meta.title,
                                         &meta.description, &meta.image, &meta.icon, &meta.kind}) {
            must(slack::html::sanitize_utf8(*field) == *field, "field is not valid UTF-8");
        }

        // Truncation is a promise about size, and it is the promise most likely
        // to be broken by a codepoint straddling the cut.
        must(meta.title.size() <= slack::html::kTitleMax + 8, "title exceeds its cap");
        must(meta.description.size() <= slack::html::kDescMax + 8, "description exceeds its cap");

        // Nothing but http(s) may reach a card the user can click.
        for (const std::string* url : {&meta.image, &meta.icon}) {
            must(url->empty() || url->starts_with("http://") || url->starts_with("https://"),
                 "a non-http(s) URL escaped resolution");
        }

        std::ostringstream os;
        slack::html::write_json(os, meta);
        const std::string json = os.str();
        must(json.starts_with("{\"ok\":true,"), "json lost its shape");
        must(json.find('\n') == json.size() - 1, "a raw newline escaped into the json body");
    }
    return 0;
}
