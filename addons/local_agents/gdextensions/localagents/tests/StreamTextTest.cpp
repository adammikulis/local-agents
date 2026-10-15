#include "RuntimeStreamText.hpp"
#include <iostream>
using local_agents::runtime::stream_preview;
int main() {
    if (stream_preview("hello", {}) != "hello") return 1;
    if (stream_preview("hello<EN", {"<END>"}) != "hello") return 1;
    if (stream_preview("hello<END>", {"<END>"}) != "hello") return 1;
    if (stream_preview("hello<EX", {"<END>"}) != "hello<EX") return 1;
    if (stream_preview(std::string("hi \xf0\x9f", 5), {}) != "hi ") return 1;
    if (stream_preview("hi \xf0\x9f\x8c\x8d", {}) != "hi \xf0\x9f\x8c\x8d") return 1;
    if (stream_preview("hi \xc3", {}) != "hi ") return 1;
    if (stream_preview("hi \xc3\xa9", {}) != "hi \xc3\xa9") return 1;
    if (stream_preview("abc", {"bcX", "cY"}) != "a") return 1;
    std::cout << "check_stream_text: OK\n";
}
