#include "NetworkGraph.hpp"

#include <godot_cpp/classes/json.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <sqlite3.h>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <limits>
#include <numeric>

using namespace godot;

namespace {
constexpr float kEpsilon = 1e-8f;

std::vector<float> to_std_vector(const PackedFloat32Array &array) {
    std::vector<float> values;
    values.resize(array.size());
    if (!values.empty()) {
        std::memcpy(values.data(), array.ptr(), values.size() * sizeof(float));
    }
    return values;
}

PackedFloat32Array to_packed_array(const std::vector<float> &values) {
    PackedFloat32Array array;
    array.resize(values.size());
    if (!values.empty()) {
        std::memcpy(array.ptrw(), values.data(), values.size() * sizeof(float));
    }
    return array;
}

float compute_norm(const std::vector<float> &values) {
    float sum = 0.0f;
    for (float v : values) {
        sum += v * v;
    }
    return std::sqrt(std::max(sum, 0.0f));
}

} // namespace

NetworkGraph::NetworkGraph() = default;

NetworkGraph::~NetworkGraph() {
    close();
}

void NetworkGraph::_bind_methods() {
    ClassDB::bind_method(D_METHOD("open", "path"), &NetworkGraph::open);
    ClassDB::bind_method(D_METHOD("close"), &NetworkGraph::close);
    ClassDB::bind_method(D_METHOD("is_open"), &NetworkGraph::is_open);

    ClassDB::bind_method(D_METHOD("upsert_node", "space", "label", "data"), &NetworkGraph::upsert_node, DEFVAL(Dictionary()));
    ClassDB::bind_method(D_METHOD("update_node_data", "node_id", "data"), &NetworkGraph::update_node_data);
    ClassDB::bind_method(D_METHOD("get_node", "node_id"), &NetworkGraph::get_node);
    ClassDB::bind_method(D_METHOD("list_nodes", "space", "limit", "offset"), &NetworkGraph::list_nodes, DEFVAL(100), DEFVAL(0));
    ClassDB::bind_method(D_METHOD("list_nodes_by_metadata", "space", "key", "value", "limit", "offset"),
                        &NetworkGraph::list_nodes_by_metadata, DEFVAL(100), DEFVAL(0));
    ClassDB::bind_method(D_METHOD("remove_node", "node_id"), &NetworkGraph::remove_node);

    ClassDB::bind_method(D_METHOD("add_edge", "source_id", "target_id", "kind", "weight", "data"), &NetworkGraph::add_edge, DEFVAL(String()), DEFVAL(1.0), DEFVAL(Dictionary()));
    ClassDB::bind_method(D_METHOD("remove_edge", "edge_id"), &NetworkGraph::remove_edge);
    ClassDB::bind_method(D_METHOD("get_edges", "node_id", "limit"), &NetworkGraph::get_edges, DEFVAL(32));

    ClassDB::bind_method(D_METHOD("add_embedding", "node_id", "vector", "metadata"), &NetworkGraph::add_embedding, DEFVAL(Dictionary()));
    ClassDB::bind_method(D_METHOD("search_embeddings", "query", "top_k", "expand"), &NetworkGraph::search_embeddings, DEFVAL(8), DEFVAL(32));
}

bool NetworkGraph::open(const String &path) {
    std::scoped_lock lock(mutex_);
    close();

    db_path_ = path;
    int rc = sqlite3_open_v2(path.utf8().get_data(), &db_, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nullptr);
    if (rc != SQLITE_OK) {
        UtilityFunctions::push_error(String("NetworkGraph::open - failed to open ") + path + ": " + sqlite3_errstr(rc));
        close();
        return false;
    }

    exec_sql("PRAGMA foreign_keys = ON;");
    exec_sql("PRAGMA journal_mode = WAL;");
    exec_sql("PRAGMA synchronous = NORMAL;");

    if (!initialize_schema()) {
        close();
        return false;
    }

    load_embeddings();
    index_dirty_ = true;
    return true;
}

void NetworkGraph::close() {
    std::scoped_lock lock(mutex_);
    if (db_) {
        sqlite3_close(db_);
        db_ = nullptr;
    }
    embeddings_.clear();
    vp_nodes_.clear();
    vp_root_ = -1;
    embedding_dim_ = 0;
    index_dirty_ = true;
}

bool NetworkGraph::is_open() const {
    std::scoped_lock lock(mutex_);
    return db_ != nullptr;
}

bool NetworkGraph::initialize_schema() {
    const char *schema_sql = R"SQL(
CREATE TABLE IF NOT EXISTS nodes (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    space TEXT NOT NULL,
    label TEXT,
    data TEXT,
    created_at INTEGER NOT NULL DEFAULT (strftime('%s','now')),
    UNIQUE(space, label)
);

CREATE TABLE IF NOT EXISTS edges (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    source_id INTEGER NOT NULL,
    target_id INTEGER NOT NULL,
    kind TEXT,
    weight REAL NOT NULL DEFAULT 1.0,
    data TEXT,
    created_at INTEGER NOT NULL DEFAULT (strftime('%s','now')),
    FOREIGN KEY(source_id) REFERENCES nodes(id) ON DELETE CASCADE,
    FOREIGN KEY(target_id) REFERENCES nodes(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_edges_source ON edges(source_id);
CREATE INDEX IF NOT EXISTS idx_edges_target ON edges(target_id);

CREATE TABLE IF NOT EXISTS embeddings (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    node_id INTEGER NOT NULL,
    dim INTEGER NOT NULL,
    norm REAL NOT NULL,
    vector BLOB NOT NULL,
    metadata TEXT,
    created_at INTEGER NOT NULL DEFAULT (strftime('%s','now')),
    FOREIGN KEY(node_id) REFERENCES nodes(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_embeddings_node ON embeddings(node_id);
)SQL";

    return exec_sql(schema_sql);
}

bool NetworkGraph::exec_sql(const char *sql) const {
    char *err_msg = nullptr;
    int rc = sqlite3_exec(db_, sql, nullptr, nullptr, &err_msg);
    if (rc != SQLITE_OK) {
        UtilityFunctions::push_error(String("NetworkGraph::exec_sql - ") + sqlite3_errmsg(db_));
        if (err_msg) {
            sqlite3_free(err_msg);
        }
        return false;
    }
    if (err_msg) {
        sqlite3_free(err_msg);
    }
    return true;
}

void NetworkGraph::load_embeddings() {
    embeddings_.clear();
    embedding_dim_ = 0;

    const char *sql = "SELECT id, node_id, dim, norm, vector, COALESCE(metadata, '{}') FROM embeddings ORDER BY id ASC";
    sqlite3_stmt *stmt = nullptr;
    if (sqlite3_prepare_v2(db_, sql, -1, &stmt, nullptr) != SQLITE_OK) {
        UtilityFunctions::push_error(String("NetworkGraph::load_embeddings prepare - ") + sqlite3_errmsg(db_));
        return;
    }

    while (sqlite3_step(stmt) == SQLITE_ROW) {
        EmbeddingRecord record;
        record.id = sqlite3_column_int64(stmt, 0);
        record.node_id = sqlite3_column_int64(stmt, 1);
        int dim = sqlite3_column_int(stmt, 2);
        record.norm = static_cast<float>(sqlite3_column_double(stmt, 3));
        const void *blob = sqlite3_column_blob(stmt, 4);
        int bytes = sqlite3_column_bytes(stmt, 4);
        if (!blob || bytes != dim * static_cast<int>(sizeof(float))) {
            continue;
        }
        record.values.resize(dim);
        std::memcpy(record.values.data(), blob, bytes);
        if (record.norm < kEpsilon) {
            record.norm = compute_norm(record.values);
        }
        if (embedding_dim_ == 0) {
            embedding_dim_ = dim;
        }
        if (sqlite3_column_type(stmt, 5) != SQLITE_NULL) {
            record.metadata = json_to_dictionary(String((const char *)sqlite3_column_text(stmt, 5)));
        }
        embeddings_.push_back(record);
    }

    sqlite3_finalize(stmt);
    index_dirty_ = true;
}

String NetworkGraph::dictionary_to_json(const Dictionary &data) {
    if (data.is_empty()) {
        return String();
    }
    return JSON::stringify(data, String(), false, true);
}

Dictionary NetworkGraph::json_to_dictionary(const String &json) {
    if (json.is_empty()) {
        return Dictionary();
    }
    Variant parsed = JSON::parse_string(json);
    if (parsed.get_type() == Variant::DICTIONARY) {
        return parsed;
    }
    return Dictionary();
}

void NetworkGraph::bind_variant(sqlite3_stmt *stmt, int index, const Variant &value) {
    switch (value.get_type()) {
        case Variant::INT:
            sqlite3_bind_int64(stmt, index, (int64_t)value);
            break;
        case Variant::FLOAT:
            sqlite3_bind_double(stmt, index, (double)value);
            break;
        case Variant::BOOL:
            sqlite3_bind_int(stmt, index, (bool)value ? 1 : 0);
            break;
        case Variant::STRING: {
            String text = value;
            sqlite3_bind_text(stmt, index, text.utf8().get_data(), -1, SQLITE_TRANSIENT);
        } break;
        default:
            sqlite3_bind_null(stmt, index);
            break;
    }
}

int64_t NetworkGraph::upsert_node(const String &space, const String &label, const Dictionary &data) {
    std::scoped_lock lock(mutex_);
    if (!db_) {
        UtilityFunctions::push_error("NetworkGraph::upsert_node - database closed");
        return -1;
    }

    const char *sql = R"SQL(
INSERT INTO nodes(space, label, data) VALUES(?1, ?2, json(?3))
ON CONFLICT(space, label) DO UPDATE SET data = COALESCE(json(?3), nodes.data)
RETURNING id;
)SQL";

    sqlite3_stmt *stmt = nullptr;
    if (sqlite3_prepare_v2(db_, sql, -1, &stmt, nullptr) != SQLITE_OK) {
        UtilityFunctions::push_error(String("NetworkGraph::upsert_node prepare - ") + sqlite3_errmsg(db_));
        return -1;
    }

    sqlite3_bind_text(stmt, 1, space.utf8().get_data(), -1, SQLITE_TRANSIENT);
    if (label.is_empty()) {
        sqlite3_bind_null(stmt, 2);
    } else {
        sqlite3_bind_text(stmt, 2, label.utf8().get_data(), -1, SQLITE_TRANSIENT);
    }
    String json = dictionary_to_json(data);
    if (json.is_empty()) {
        sqlite3_bind_null(stmt, 3);
    } else {
        sqlite3_bind_text(stmt, 3, json.utf8().get_data(), -1, SQLITE_TRANSIENT);
    }

    int64_t node_id = -1;
    if (sqlite3_step(stmt) == SQLITE_ROW) {
        node_id = sqlite3_column_int64(stmt, 0);
    }
    sqlite3_finalize(stmt);
    return node_id;
}

bool NetworkGraph::update_node_data(int64_t node_id, const Dictionary &data) {
    std::scoped_lock lock(mutex_);
    if (!db_) {
        return false;
    }

    const char *sql = "UPDATE nodes SET data = json(?1) WHERE id = ?2";
    sqlite3_stmt *stmt = nullptr;
    if (sqlite3_prepare_v2(db_, sql, -1, &stmt, nullptr) != SQLITE_OK) {
        UtilityFunctions::push_error(String("NetworkGraph::update_node_data prepare - ") + sqlite3_errmsg(db_));
        return false;
    }

    String json = dictionary_to_json(data);
    if (json.is_empty()) {
        sqlite3_bind_null(stmt, 1);
    } else {
        sqlite3_bind_text(stmt, 1, json.utf8().get_data(), -1, SQLITE_TRANSIENT);
    }
    sqlite3_bind_int64(stmt, 2, node_id);

    bool ok = sqlite3_step(stmt) == SQLITE_DONE;
    sqlite3_finalize(stmt);
    return ok && sqlite3_changes(db_) > 0;
}

bool NetworkGraph::remove_node(int64_t node_id) {
    std::scoped_lock lock(mutex_);
    if (!db_) {
        return false;
    }

    const char *sql = "DELETE FROM nodes WHERE id = ?1";
    sqlite3_stmt *stmt = nullptr;
    if (sqlite3_prepare_v2(db_, sql, -1, &stmt, nullptr) != SQLITE_OK) {
        UtilityFunctions::push_error(String("NetworkGraph::remove_node prepare - ") + sqlite3_errmsg(db_));
        return false;
    }

    sqlite3_bind_int64(stmt, 1, node_id);
    bool ok = sqlite3_step(stmt) == SQLITE_DONE;
    sqlite3_finalize(stmt);
    if (ok) {
        auto it = std::remove_if(embeddings_.begin(), embeddings_.end(), [node_id](const EmbeddingRecord &rec) {
            return rec.node_id == node_id;
        });
        if (it != embeddings_.end()) {
            embeddings_.erase(it, embeddings_.end());
            index_dirty_ = true;
        }
    }
    return ok && sqlite3_changes(db_) > 0;
}

Dictionary NetworkGraph::get_node(int64_t node_id) const {
    std::scoped_lock lock(mutex_);
    Dictionary result;
    if (!db_) {
        return result;
    }

    const char *sql = "SELECT id, space, label, COALESCE(data, '{}'), created_at FROM nodes WHERE id = ?1";
    sqlite3_stmt *stmt = nullptr;
    if (sqlite3_prepare_v2(db_, sql, -1, &stmt, nullptr) != SQLITE_OK) {
        UtilityFunctions::push_error(String("NetworkGraph::get_node prepare - ") + sqlite3_errmsg(db_));
        return result;
    }
    sqlite3_bind_int64(stmt, 1, node_id);

    if (sqlite3_step(stmt) == SQLITE_ROW) {
        result["id"] = sqlite3_column_int64(stmt, 0);
        result["space"] = String((const char *)sqlite3_column_text(stmt, 1));
        if (sqlite3_column_type(stmt, 2) != SQLITE_NULL) {
            result["label"] = String((const char *)sqlite3_column_text(stmt, 2));
        }
        String json = String((const char *)sqlite3_column_text(stmt, 3));
        result["data"] = json_to_dictionary(json);
        result["created_at"] = sqlite3_column_int64(stmt, 4);
    }
    sqlite3_finalize(stmt);
    return result;
}

TypedArray<Dictionary> NetworkGraph::list_nodes(const String &space, int64_t limit, int64_t offset) const {
    std::scoped_lock lock(mutex_);
    TypedArray<Dictionary> rows;
    if (!db_) {
        return rows;
    }

    const char *sql = R"SQL(
SELECT id, space, label, COALESCE(data, '{}'), created_at
FROM nodes
WHERE (?1 = '' OR space = ?1)
ORDER BY created_at DESC
LIMIT ?2 OFFSET ?3;
)SQL";

    sqlite3_stmt *stmt = nullptr;
    if (sqlite3_prepare_v2(db_, sql, -1, &stmt, nullptr) != SQLITE_OK) {
        UtilityFunctions::push_error(String("NetworkGraph::list_nodes prepare - ") + sqlite3_errmsg(db_));
        return rows;
    }

    sqlite3_bind_text(stmt, 1, space.utf8().get_data(), -1, SQLITE_TRANSIENT);
    sqlite3_bind_int64(stmt, 2, limit);
    sqlite3_bind_int64(stmt, 3, offset);

    while (sqlite3_step(stmt) == SQLITE_ROW) {
        Dictionary row;
        row["id"] = sqlite3_column_int64(stmt, 0);
        row["space"] = String((const char *)sqlite3_column_text(stmt, 1));
        if (sqlite3_column_type(stmt, 2) != SQLITE_NULL) {
            row["label"] = String((const char *)sqlite3_column_text(stmt, 2));
        }
        String json = String((const char *)sqlite3_column_text(stmt, 3));
        row["data"] = json_to_dictionary(json);
        row["created_at"] = sqlite3_column_int64(stmt, 4);
        rows.push_back(row);
    }
    sqlite3_finalize(stmt);
    return rows;
}

TypedArray<Dictionary> NetworkGraph::list_nodes_by_metadata(const String &space, const String &key, const Variant &value,
                                                           int64_t limit, int64_t offset) const {
    std::scoped_lock lock(mutex_);
    TypedArray<Dictionary> rows;
    if (!db_) {
        return rows;
    }

    String json_path = String("$.") + key;
    const char *sql = R"SQL(
SELECT id, space, label, COALESCE(data, '{}'), created_at
FROM nodes
WHERE (?1 = '' OR space = ?1)
  AND json_extract(COALESCE(data, '{}'), ?2) = ?3
ORDER BY created_at DESC
LIMIT ?4 OFFSET ?5;
)SQL";

    sqlite3_stmt *stmt = nullptr;
    if (sqlite3_prepare_v2(db_, sql, -1, &stmt, nullptr) != SQLITE_OK) {
        UtilityFunctions::push_error(String("NetworkGraph::list_nodes_by_metadata prepare - ") + sqlite3_errmsg(db_));
        return rows;
    }

    sqlite3_bind_text(stmt, 1, space.utf8().get_data(), -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 2, json_path.utf8().get_data(), -1, SQLITE_TRANSIENT);
    bind_variant(stmt, 3, value);
    sqlite3_bind_int64(stmt, 4, limit);
    sqlite3_bind_int64(stmt, 5, offset);

    while (sqlite3_step(stmt) == SQLITE_ROW) {
        Dictionary row;
        row["id"] = sqlite3_column_int64(stmt, 0);
        row["space"] = String((const char *)sqlite3_column_text(stmt, 1));
        if (sqlite3_column_type(stmt, 2) != SQLITE_NULL) {
            row["label"] = String((const char *)sqlite3_column_text(stmt, 2));
        }
        String json = String((const char *)sqlite3_column_text(stmt, 3));
        row["data"] = json_to_dictionary(json);
        row["created_at"] = sqlite3_column_int64(stmt, 4);
        rows.push_back(row);
    }

    sqlite3_finalize(stmt);
    return rows;
}

int64_t NetworkGraph::add_edge(int64_t source_id, int64_t target_id, const String &kind, double weight, const Dictionary &data) {
    std::scoped_lock lock(mutex_);
    if (!db_) {
        return -1;
    }

    const char *sql = R"SQL(
INSERT INTO edges(source_id, target_id, kind, weight, data) VALUES(?1, ?2, ?3, ?4, json(?5));
)SQL";

    sqlite3_stmt *stmt = nullptr;
    if (sqlite3_prepare_v2(db_, sql, -1, &stmt, nullptr) != SQLITE_OK) {
        UtilityFunctions::push_error(String("NetworkGraph::add_edge prepare - ") + sqlite3_errmsg(db_));
        return -1;
    }

    sqlite3_bind_int64(stmt, 1, source_id);
    sqlite3_bind_int64(stmt, 2, target_id);
    if (kind.is_empty()) {
        sqlite3_bind_null(stmt, 3);
    } else {
        sqlite3_bind_text(stmt, 3, kind.utf8().get_data(), -1, SQLITE_TRANSIENT);
    }
    sqlite3_bind_double(stmt, 4, weight);
    String json = dictionary_to_json(data);
    if (json.is_empty()) {
        sqlite3_bind_null(stmt, 5);
    } else {
        sqlite3_bind_text(stmt, 5, json.utf8().get_data(), -1, SQLITE_TRANSIENT);
    }

    int64_t edge_id = -1;
    if (sqlite3_step(stmt) == SQLITE_DONE) {
        edge_id = sqlite3_last_insert_rowid(db_);
    }
    sqlite3_finalize(stmt);
    return edge_id;
}

bool NetworkGraph::remove_edge(int64_t edge_id) {
    std::scoped_lock lock(mutex_);
    if (!db_) {
        return false;
    }

    const char *sql = "DELETE FROM edges WHERE id = ?1";
    sqlite3_stmt *stmt = nullptr;
    if (sqlite3_prepare_v2(db_, sql, -1, &stmt, nullptr) != SQLITE_OK) {
        UtilityFunctions::push_error(String("NetworkGraph::remove_edge prepare - ") + sqlite3_errmsg(db_));
        return false;
    }
    sqlite3_bind_int64(stmt, 1, edge_id);

    bool ok = sqlite3_step(stmt) == SQLITE_DONE;
    sqlite3_finalize(stmt);
    return ok && sqlite3_changes(db_) > 0;
}

TypedArray<Dictionary> NetworkGraph::get_edges(int64_t node_id, int64_t limit) const {
    std::scoped_lock lock(mutex_);
    TypedArray<Dictionary> rows;
    if (!db_) {
        return rows;
    }

    const char *sql = R"SQL(
SELECT id, source_id, target_id, kind, weight, COALESCE(data, '{}'), created_at
FROM edges
WHERE source_id = ?1 OR target_id = ?1
ORDER BY created_at DESC
LIMIT ?2;
)SQL";

    sqlite3_stmt *stmt = nullptr;
    if (sqlite3_prepare_v2(db_, sql, -1, &stmt, nullptr) != SQLITE_OK) {
        UtilityFunctions::push_error(String("NetworkGraph::get_edges prepare - ") + sqlite3_errmsg(db_));
        return rows;
    }

    sqlite3_bind_int64(stmt, 1, node_id);
    sqlite3_bind_int64(stmt, 2, limit);

    while (sqlite3_step(stmt) == SQLITE_ROW) {
        Dictionary row;
        row["id"] = sqlite3_column_int64(stmt, 0);
        row["source_id"] = sqlite3_column_int64(stmt, 1);
        row["target_id"] = sqlite3_column_int64(stmt, 2);
        if (sqlite3_column_type(stmt, 3) != SQLITE_NULL) {
            row["kind"] = String((const char *)sqlite3_column_text(stmt, 3));
        }
        row["weight"] = sqlite3_column_double(stmt, 4);
        String json = String((const char *)sqlite3_column_text(stmt, 5));
        row["data"] = json_to_dictionary(json);
        row["created_at"] = sqlite3_column_int64(stmt, 6);
        rows.push_back(row);
    }
    sqlite3_finalize(stmt);
    return rows;
}

int64_t NetworkGraph::add_embedding(int64_t node_id, const PackedFloat32Array &vector, const Dictionary &metadata) {
    std::scoped_lock lock(mutex_);
    if (!db_) {
        UtilityFunctions::push_error("NetworkGraph::add_embedding - database closed");
        return -1;
    }

    if (vector.is_empty()) {
        UtilityFunctions::push_error("NetworkGraph::add_embedding - vector empty");
        return -1;
    }

    std::vector<float> values = to_std_vector(vector);
    float norm = compute_norm(values);
    if (norm < kEpsilon) {
        UtilityFunctions::push_error("NetworkGraph::add_embedding - zero norm vector");
        return -1;
    }

    if (embedding_dim_ == 0) {
        embedding_dim_ = vector.size();
    } else if (embedding_dim_ != vector.size()) {
        UtilityFunctions::push_error("NetworkGraph::add_embedding - inconsistent dimensions");
        return -1;
    }

    const char *sql = R"SQL(
INSERT INTO embeddings(node_id, dim, norm, vector, metadata) VALUES(?1, ?2, ?3, ?4, json(?5));
)SQL";

    sqlite3_stmt *stmt = nullptr;
    if (sqlite3_prepare_v2(db_, sql, -1, &stmt, nullptr) != SQLITE_OK) {
        UtilityFunctions::push_error(String("NetworkGraph::add_embedding prepare - ") + sqlite3_errmsg(db_));
        return -1;
    }

    sqlite3_bind_int64(stmt, 1, node_id);
    sqlite3_bind_int(stmt, 2, vector.size());
    sqlite3_bind_double(stmt, 3, norm);
    sqlite3_bind_blob(stmt, 4, values.data(), static_cast<int>(values.size() * sizeof(float)), SQLITE_TRANSIENT);
    String json = dictionary_to_json(metadata);
    if (json.is_empty()) {
        sqlite3_bind_null(stmt, 5);
    } else {
        sqlite3_bind_text(stmt, 5, json.utf8().get_data(), -1, SQLITE_TRANSIENT);
    }

    int64_t embedding_id = -1;
    if (sqlite3_step(stmt) == SQLITE_DONE) {
        embedding_id = sqlite3_last_insert_rowid(db_);
        EmbeddingRecord record;
        record.id = embedding_id;
        record.node_id = node_id;
        record.values = std::move(values);
        record.norm = norm;
        record.metadata = metadata.duplicate(true);
        embeddings_.push_back(record);
        index_dirty_ = true;
    }
    sqlite3_finalize(stmt);
    return embedding_id;
}

TypedArray<Dictionary> NetworkGraph::search_embeddings(const PackedFloat32Array &query, int64_t top_k, int64_t expand) const {
    std::scoped_lock lock(mutex_);
    TypedArray<Dictionary> results;
    if (!db_ || query.is_empty() || embeddings_.empty()) {
        return results;
    }

    expand = std::max<int64_t>(expand, 1);
    top_k = std::max<int64_t>(top_k, 1);

    std::vector<float> needle = to_std_vector(query);
    if (embedding_dim_ != static_cast<int>(needle.size())) {
        UtilityFunctions::push_error("NetworkGraph::search_embeddings - dimension mismatch");
        return results;
    }

    float norm = compute_norm(needle);
    if (norm < kEpsilon) {
        UtilityFunctions::push_error("NetworkGraph::search_embeddings - zero norm query");
        return results;
    }

    ensure_index();

    int64_t search_width = std::max(top_k, expand);
    std::vector<std::pair<float, const EmbeddingRecord *>> matches;
    matches.reserve(static_cast<size_t>(search_width));
    float tau = std::numeric_limits<float>::infinity();
    search_vp(vp_root_, needle, norm, search_width, tau, matches);
    std::sort(matches.begin(), matches.end(), [](const auto &a, const auto &b) {
        return a.first < b.first;
    });

    if (matches.size() > static_cast<size_t>(top_k)) {
        matches.resize(static_cast<size_t>(top_k));
    }

    for (const auto &entry : matches) {
        Dictionary row;
        row["embedding_id"] = entry.second->id;
        row["node_id"] = entry.second->node_id;
        row["distance"] = entry.first;
        row["similarity"] = 1.0 - entry.first;
        row["metadata"] = entry.second->metadata.duplicate(true);
        results.push_back(row);
    }
    return results;
}

double NetworkGraph::cosine_distance(const std::vector<float> &a, float norm_a, const std::vector<float> &b, float norm_b) const {
    float dot = 0.0f;
    const size_t n = a.size();
    for (size_t i = 0; i < n; ++i) {
        dot += a[i] * b[i];
    }
    float denom = std::max(norm_a * norm_b, kEpsilon);
    float cosine = dot / denom;
    cosine = std::max(-1.0f, std::min(1.0f, cosine));
    return 1.0f - cosine;
}

void NetworkGraph::rebuild_index() {
    vp_nodes_.clear();
    vp_root_ = -1;
    if (embeddings_.empty()) {
        index_dirty_ = false;
        return;
    }

    std::vector<int> indices(embeddings_.size());
    std::iota(indices.begin(), indices.end(), 0);
    vp_root_ = build_vp_node(indices);
    index_dirty_ = false;
}

int NetworkGraph::build_vp_node(std::vector<int> &indices) {
    if (indices.empty()) {
        return -1;
    }

    int node_idx = static_cast<int>(vp_nodes_.size());
    vp_nodes_.push_back(VPTreeNode());
    VPTreeNode &node = vp_nodes_.back();

    node.record_index = indices.back();
    indices.pop_back();

    if (indices.empty()) {
        node.threshold = 0.0f;
        node.left = -1;
        node.right = -1;
        return node_idx;
    }

    EmbeddingRecord &vp = embeddings_[node.record_index];

    std::vector<std::pair<float, int>> distances;
    distances.reserve(indices.size());
    for (int idx : indices) {
        EmbeddingRecord &cand = embeddings_[idx];
        float dist = static_cast<float>(cosine_distance(vp.values, vp.norm, cand.values, cand.norm));
        distances.emplace_back(dist, idx);
    }

    size_t median = distances.size() / 2;
    std::nth_element(distances.begin(), distances.begin() + median, distances.end(),
                     [](const auto &a, const auto &b) { return a.first < b.first; });
    node.threshold = distances[median].first;

    std::vector<int> left_indices;
    std::vector<int> right_indices;
    left_indices.reserve(distances.size());
    right_indices.reserve(distances.size());

    for (const auto &pair : distances) {
        if (pair.first <= node.threshold) {
            left_indices.push_back(pair.second);
        } else {
            right_indices.push_back(pair.second);
        }
    }

    node.left = build_vp_node(left_indices);
    node.right = build_vp_node(right_indices);
    return node_idx;
}

void NetworkGraph::ensure_index() const {
    if (!index_dirty_) {
        return;
    }
    const_cast<NetworkGraph *>(this)->rebuild_index();
}

void NetworkGraph::search_vp(int node_index, const std::vector<float> &query, float norm_query,
                            int64_t top_k, float &tau,
                            std::vector<std::pair<float, const EmbeddingRecord *>> &results) const {
    if (node_index < 0) {
        return;
    }

    const VPTreeNode &node = vp_nodes_[node_index];
    const EmbeddingRecord &record = embeddings_[node.record_index];

    float dist = static_cast<float>(cosine_distance(query, norm_query, record.values, record.norm));
    if (results.size() < static_cast<size_t>(top_k)) {
        results.emplace_back(dist, &record);
        if (results.size() == static_cast<size_t>(top_k)) {
            auto it = std::max_element(results.begin(), results.end(), [](const auto &a, const auto &b) {
                return a.first < b.first;
            });
            tau = it->first;
        }
    } else if (dist < tau) {
        auto it = std::max_element(results.begin(), results.end(), [](const auto &a, const auto &b) {
            return a.first < b.first;
        });
        *it = {dist, &record};
        tau = std::max_element(results.begin(), results.end(), [](const auto &a, const auto &b) {
            return a.first < b.first;
        })->first;
    }

    if (node.left < 0 && node.right < 0) {
        return;
    }

    if (dist < node.threshold) {
        if (node.left >= 0) {
            search_vp(node.left, query, norm_query, top_k, tau, results);
        }
        if (node.right >= 0 && dist + tau >= node.threshold) {
            search_vp(node.right, query, norm_query, top_k, tau, results);
        }
    } else {
        if (node.right >= 0) {
            search_vp(node.right, query, norm_query, top_k, tau, results);
        }
        if (node.left >= 0 && dist - tau <= node.threshold) {
            search_vp(node.left, query, norm_query, top_k, tau, results);
        }
    }
}
