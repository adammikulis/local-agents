#pragma once

#include <string>
#include <vector>

namespace local_agents::runtime {
struct ChatMessage {
    std::string role;
    std::string content;
};

bool format_chat_prompt(const char *chat_template, std::vector<ChatMessage> messages,
                        const std::string &system_prompt, const std::string &user_prompt,
                        std::string &formatted, std::string &error);
}
