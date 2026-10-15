#include "RuntimeChatPrompt.hpp"
#include <llama.h>
#include <algorithm>
#include <limits>

namespace local_agents::runtime {
bool format_chat_prompt(const char *chat_template, std::vector<ChatMessage> messages,
                        const std::string &system_prompt, const std::string &user_prompt,
                        std::string &formatted, std::string &error) {
    formatted.clear();
    error.clear();
    if (!chat_template || !*chat_template) {
        error = "chat_template_missing";
        return false;
    }
    bool has_system = std::any_of(messages.begin(), messages.end(), [](const ChatMessage &message) {
        return message.role == "system";
    });
    if (!has_system && !system_prompt.empty()) {
        messages.insert(messages.begin(), {"system", system_prompt});
    }
    if (!user_prompt.empty() && (messages.empty() || messages.back().role != "user"
                                || messages.back().content != user_prompt)) {
        messages.push_back({"user", user_prompt});
    }
    if (messages.empty()) {
        error = "missing_messages";
        return false;
    }
    std::vector<llama_chat_message> chat;
    chat.reserve(messages.size());
    for (const auto &message : messages) {
        chat.push_back({message.role.c_str(), message.content.c_str()});
    }
    int32_t length = llama_chat_apply_template(chat_template, chat.data(), chat.size(), true, nullptr, 0);
    if (length <= 0 || length == std::numeric_limits<int32_t>::max()) {
        error = "chat_template_unsupported";
        return false;
    }
    formatted.resize(static_cast<size_t>(length) + 1);
    int32_t written = llama_chat_apply_template(chat_template, chat.data(), chat.size(), true,
                                               formatted.data(), static_cast<int32_t>(formatted.size()));
    if (written != length) {
        formatted.clear();
        error = "chat_template_render_failed";
        return false;
    }
    formatted.resize(length);
    return true;
}
}
