#ifndef LOCAL_AGENTS_AGENT_RUNTIME_HPP
#define LOCAL_AGENTS_AGENT_RUNTIME_HPP

#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/templates/vector.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/typed_array.hpp>
#include <godot_cpp/variant/string.hpp>

#include <llama.h>

#include <memory>
#include <mutex>
#include <string>
#include <vector>

#include <common/chat.h>

struct llama_model;
struct llama_context;
struct llama_sampler;

namespace godot {

class AgentRuntime : public Node {
    GDCLASS(AgentRuntime, Node);

public:
    AgentRuntime();
    ~AgentRuntime() override;

    static AgentRuntime *get_singleton();

    bool load_model(const String &model_path, const Dictionary &options);
    void unload_model();
    bool is_model_loaded() const;

    Dictionary generate(const Dictionary &request);
    PackedFloat32Array embed_text(const String &text, const Dictionary &options = Dictionary());

    Dictionary download_model(const Dictionary &request);

    void set_default_model_path(const String &path);
    String get_default_model_path() const;

    void set_runtime_directory(const String &path);
    String get_runtime_directory() const;

    void set_system_prompt(const String &prompt);
    String get_system_prompt() const;

protected:
    static void _bind_methods();
    void _notification(int what);

private:
    Dictionary run_inference_locked(const Dictionary &request);
    bool ensure_sampler_locked(const Dictionary &options);
    std::vector<common_chat_msg> build_messages_from_history(const TypedArray<Dictionary> &history, const String &user_prompt, const Dictionary &options) const;
    bool ensure_chat_templates_locked(const Dictionary &options);
    void reset_chat_state_locked();
    std::string token_to_string(llama_token token) const;
    bool load_model_locked(const String &path, const Dictionary &options, bool store_defaults);
    void unload_model_locked();

    static AgentRuntime *singleton_;

    mutable std::mutex mutex_;

    llama_model *model_ = nullptr;
    llama_context *context_ = nullptr;
    std::unique_ptr<llama_sampler, void(*)(llama_sampler*)> sampler_;

    String default_model_path_;
    String runtime_directory_;
    String system_prompt_;
    Dictionary default_options_;

    common_chat_templates_ptr chat_templates_;
    bool chat_use_jinja_ = true;
    String chat_template_override_;

    std::string pending_grammar_;
    bool pending_grammar_lazy_ = false;
    std::vector<common_grammar_trigger> pending_grammar_triggers_;
    std::vector<std::string> pending_additional_stops_;

    String loaded_model_name_;
};

} // namespace godot

#endif // LOCAL_AGENTS_AGENT_RUNTIME_HPP
