// SPDX-License-Identifier: MIT
//
// slack-unfurl — turn a fetched HTML page into the handful of fields a link
// preview needs, the way Slack's own unfurler does.
//
//     curl -sL "$url" | slack-unfurl "$url" [final-url]
//
// Prints one JSON object on stdout and always exits 0: the caller treats a
// missing field as "nothing worth showing", never as an error.

#include "html_meta.hpp"

#include <array>
#include <cstddef>
#include <iostream>
#include <string>

namespace {

// Read at most kMaxInput bytes of stdin. Anything past that is markup we would
// not look at anyway, and reading it would let a hostile page decide how much
// memory this process uses.
[[nodiscard]] std::string read_capped_stdin() {
    std::string body;
    std::array<char, std::size_t{1} << 16> chunk{};
    while (body.size() < slack::html::kMaxInput) {
        std::cin.read(chunk.data(), static_cast<std::streamsize>(chunk.size()));
        const auto got = static_cast<std::size_t>(std::cin.gcount());
        if (got == 0)
            break;
        body.append(chunk.data(), got);
    }
    if (body.size() > slack::html::kMaxInput)
        body.resize(slack::html::kMaxInput);
    return body;
}

}  // namespace

int main(int argc, char** argv) {
    std::ios::sync_with_stdio(false);

    const std::string source = argc > 1 ? argv[1] : "";
    // curl reports the URL it ended on after redirects; relative hrefs resolve
    // against that, not against where we started.
    const std::string effective = argc > 2 ? argv[2] : "";

    const std::string body = read_capped_stdin();
    slack::html::write_json(std::cout, slack::html::parse(body, source, effective));
    return 0;
}
