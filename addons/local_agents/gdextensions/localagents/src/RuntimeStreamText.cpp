#include "RuntimeStreamText.hpp"
#include <algorithm>
namespace local_agents::runtime {
std::string stream_preview(const std::string &text, const std::vector<std::string> &stops) {
    size_t end = text.size();
    for (const auto &stop : stops) {
        for (size_t n = 1; n <= std::min(stop.size(), text.size()); ++n) {
            if (text.compare(text.size() - n, n, stop, 0, n) == 0) end = std::min(end, text.size() - n);
        }
    }
    size_t position = 0;
    size_t valid = 0;
    while (position < end) {
        unsigned char lead = static_cast<unsigned char>(text[position]);
        size_t bytes = lead < 0x80 ? 1 : (lead & 0xe0) == 0xc0 ? 2 : (lead & 0xf0) == 0xe0 ? 3 : (lead & 0xf8) == 0xf0 ? 4 : 1;
        if (position + bytes > end) break;
        position += bytes;
        valid = position;
    }
    return text.substr(0, valid);
}
}
