#ifndef LOCAL_AGENTS_NETWORK_GRAPH_HPP
#define LOCAL_AGENTS_NETWORK_GRAPH_HPP

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/typed_array.hpp>

#include <mutex>
#include <vector>

struct sqlite3;
struct sqlite3_stmt;

namespace godot {

class NetworkGraph : public RefCounted {
    GDCLASS(NetworkGraph, RefCounted);

public:
    NetworkGraph();
    ~NetworkGraph() override;

    bool open(const String &path);
    void close();
    bool is_open() const;

    int64_t upsert_node(const String &space, const String &label, const Dictionary &data);
    bool update_node_data(int64_t node_id, const Dictionary &data);
    bool remove_node(int64_t node_id);
    Dictionary get_node(int64_t node_id) const;
    TypedArray<Dictionary> list_nodes(const String &space, int64_t limit, int64_t offset) const;
    TypedArray<Dictionary> list_nodes_by_metadata(const String &space, const String &key, const Variant &value,
                                                 int64_t limit, int64_t offset) const;

    int64_t add_edge(int64_t source_id, int64_t target_id, const String &kind, double weight, const Dictionary &data);
    bool remove_edge(int64_t edge_id);
    TypedArray<Dictionary> get_edges(int64_t node_id, int64_t limit) const;

    int64_t add_embedding(int64_t node_id, const PackedFloat32Array &vector, const Dictionary &metadata);
    TypedArray<Dictionary> search_embeddings(const PackedFloat32Array &query, int64_t top_k, int64_t expand, const String &strategy = String("vp_tree")) const;

protected:
    static void _bind_methods();

private:
    struct EmbeddingRecord {
        int64_t id = 0;
        int64_t node_id = 0;
        std::vector<float> values;
        float norm = 0.0f;
        Dictionary metadata;
    };

    struct VPTreeNode {
        int record_index = -1;
        float threshold = 0.0f;
        int left = -1;
        int right = -1;
    };

    bool initialize_schema();
    bool exec_sql(const char *sql) const;
    static String dictionary_to_json(const Dictionary &data);
    static Dictionary json_to_dictionary(const String &json);
    static void bind_variant(sqlite3_stmt *stmt, int index, const Variant &value);

    void load_embeddings();
    double cosine_distance(const std::vector<float> &a, float norm_a, const std::vector<float> &b, float norm_b) const;
    void rebuild_index();
    int build_vp_node(std::vector<int> &indices);
    void search_vp(int node_index, const std::vector<float> &query, float norm_query,
                   int64_t top_k, float &tau,
                   std::vector<std::pair<float, const EmbeddingRecord *>> &results) const;

    void ensure_index() const;

    sqlite3 *db_ = nullptr;
    String db_path_;
    mutable std::mutex mutex_;

    mutable bool index_dirty_ = true;
    mutable std::vector<EmbeddingRecord> embeddings_;
    mutable std::vector<VPTreeNode> vp_nodes_;
    mutable int vp_root_ = -1;
    mutable int embedding_dim_ = 0;
};

} // namespace godot

#endif // LOCAL_AGENTS_NETWORK_GRAPH_HPP
