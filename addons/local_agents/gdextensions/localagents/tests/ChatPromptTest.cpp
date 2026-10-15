#include "RuntimeChatPrompt.hpp"
#include <cstdlib>
#include <iostream>

using namespace local_agents::runtime;

static void require(bool condition, const char *message) {
    if (!condition) {
        std::cerr << message << '\n';
        std::exit(1);
    }
}

int main() {
    std::string prompt, error;
    require(format_chat_prompt("chatml", {{"system", "scene system"}, {"user", "ask once"}},
                               "runtime system", "ask once", prompt, error), "chatml did not render");
    require(prompt == "<|im_start|>system\nscene system<|im_end|>\n"
                      "<|im_start|>user\nask once<|im_end|>\n<|im_start|>assistant\n",
            "prompt duplicates a user turn, overrides the scene system, or loses role tokens");
    require(format_chat_prompt("chatml", {{"user", "first"}, {"assistant", "answer"}},
                               "runtime system", "second", prompt, error), "history did not render");
    require(prompt == "<|im_start|>system\nruntime system<|im_end|>\n"
                      "<|im_start|>user\nfirst<|im_end|>\n"
                      "<|im_start|>assistant\nanswer<|im_end|>\n"
                      "<|im_start|>user\nsecond<|im_end|>\n<|im_start|>assistant\n",
            "history or a new user turn was lost");
    require(!format_chat_prompt(nullptr, {}, "", "hello", prompt, error)
            && error == "chat_template_missing" && prompt.empty(), "missing template silently succeeded");
    require(!format_chat_prompt("unsupported-template", {}, "", "hello", prompt, error)
            && error == "chat_template_unsupported" && prompt.empty(), "unsupported template silently succeeded");
    require(!format_chat_prompt("chatml", {}, "", "", prompt, error)
            && error == "missing_messages" && prompt.empty(), "empty conversation silently succeeded");
    std::cout << "check_chat_prompt: OK\n";
}
