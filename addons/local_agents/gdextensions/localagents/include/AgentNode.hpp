#ifndef LOCAL_AGENTS_AGENT_NODE_HPP
#define LOCAL_AGENTS_AGENT_NODE_HPP

#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/templates/vector.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/typed_array.hpp>
#include <godot_cpp/variant/string.hpp>
#include <string>
#include <vector>

namespace godot {

class AgentNode : public Node {
    GDCLASS(AgentNode, Node);

public:
    AgentNode();
    ~AgentNode() override;

    void _process(double delta) override;

    // Lifecycle
    bool load_model(const String &model_path, const Dictionary &options);
    void unload_model();

    // Conversation helpers
    void add_message(const String &role, const String &content);
    TypedArray<Dictionary> get_history() const;
    void clear_history();

    Dictionary think(const String &prompt, const Dictionary &extra_options);

    bool say(const String &text, const Dictionary &options);
    String listen(const Dictionary &options);

    // Action queue (placeholder for now, ensures API compatibility)
    void enqueue_action(const String &name, const Dictionary &params);

    // Properties
    void set_tick_enabled(bool enabled);
    bool is_tick_enabled() const;

    void set_tick_interval(double seconds);
    double get_tick_interval() const;

    void set_max_actions_per_tick(int actions);
    int get_max_actions_per_tick() const;

    void set_db_path(const String &path);
    String get_db_path() const;

    void set_voice(const String &voice_id);
    String get_voice() const;

    void set_default_model_path(const String &path);
    String get_default_model_path() const;

    void set_runtime_directory(const String &path);
    String get_runtime_directory() const;

protected:
    static void _bind_methods();

private:
    struct Message {
        String role;
        String content;
    };

    bool tick_enabled_ = false;
    double tick_interval_ = 0.0;
    int max_actions_per_tick_ = 4;
    String db_path_;
    String voice_;
    String default_model_path_;
    String runtime_directory_;

    std::vector<Message> history_;
    double tick_accumulator_ = 0.0;
};

} // namespace godot

#endif // LOCAL_AGENTS_AGENT_NODE_HPP
