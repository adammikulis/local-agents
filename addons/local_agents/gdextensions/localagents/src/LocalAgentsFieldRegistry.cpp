#include "LocalAgentsFieldRegistry.hpp"

#include <algorithm>
#include <cmath>

#include <godot_cpp/variant/variant.hpp>

using namespace godot;

namespace local_agents::simulation {

namespace {

bool parse_finite_double(const Variant &value, double &out_value) {
    const Variant::Type type = value.get_type();
    if (type != Variant::INT && type != Variant::FLOAT) {
        return false;
    }
    out_value = static_cast<double>(value);
    return std::isfinite(out_value);
}

bool parse_positive_int64(const Variant &value, int64_t &out_value) {
    const Variant::Type type = value.get_type();
    if (type != Variant::INT) {
        return false;
    }
    out_value = static_cast<int64_t>(value);
    return out_value > 0;
}

String normalized_text(const Variant &value) {
    return String(value).strip_edges();
}

Dictionary dictionary_or_empty(const Variant &value) {
    if (value.get_type() != Variant::DICTIONARY) {
        return Dictionary();
    }
    return static_cast<Dictionary>(value);
}

Array to_string_array(const PackedStringArray &values) {
    Array out;
    out.resize(values.size());
    for (int64_t i = 0; i < values.size(); i += 1) {
        out[i] = values[i];
    }
    return out;
}

} // namespace

bool LocalAgentsFieldRegistry::register_field(const StringName &field_name, const Dictionary &field_config) {
    if (field_name.is_empty()) {
        return false;
    }

    const String key = String(field_name);
    Dictionary normalized_field_config;
    Dictionary normalized_schema;
    if (!normalize_field_entry(key, field_config, normalized_field_config, normalized_schema)) {
        return false;
    }

    if (!field_configs_.has(key)) {
        registration_order_.append(key);
    }
    field_configs_[key] = normalized_field_config;
    normalized_schema_by_field_[key] = normalized_schema;
    rebuild_normalized_schema_rows();
    return true;
}

bool LocalAgentsFieldRegistry::configure(const Dictionary &config) {
    Array config_rows;
    if (!collect_config_rows(config, config_rows)) {
        return false;
    }

    Dictionary next_field_configs = field_configs_.duplicate(true);
    Dictionary next_schema_by_field = normalized_schema_by_field_.duplicate(true);
    Array next_registration_order = registration_order_.duplicate(true);
    const bool replace_registry_state = !config_rows.is_empty();
    if (replace_registry_state) {
        next_field_configs.clear();
        next_schema_by_field.clear();
        next_registration_order.clear();
    }

    for (int64_t index = 0; index < config_rows.size(); index += 1) {
        const Variant row_variant = config_rows[index];
        if (row_variant.get_type() != Variant::DICTIONARY) {
            return false;
        }
        const Dictionary row = row_variant;
        const String field_name = normalized_text(row.get("field_name", String()));
        if (field_name.is_empty()) {
            return false;
        }

        Dictionary normalized_field_config;
        Dictionary normalized_schema;
        if (!normalize_field_entry(field_name, row, normalized_field_config, normalized_schema)) {
            return false;
        }

        if (!next_field_configs.has(field_name)) {
            next_registration_order.append(field_name);
        }
        next_field_configs[field_name] = normalized_field_config;
        next_schema_by_field[field_name] = normalized_schema;
    }

    field_configs_ = next_field_configs;
    normalized_schema_by_field_ = next_schema_by_field;
    registration_order_ = next_registration_order;
    rebuild_normalized_schema_rows();
    config_ = config.duplicate(true);
    return true;
}

void LocalAgentsFieldRegistry::clear() {
    config_.clear();
    field_configs_.clear();
    normalized_schema_by_field_.clear();
    normalized_schema_rows_.clear();
    registration_order_.clear();
}

Dictionary LocalAgentsFieldRegistry::get_debug_snapshot() const {
    Dictionary snapshot;
    snapshot["component"] = String("FieldRegistry");
    snapshot["field_count"] = field_configs_.size();
    snapshot["config"] = config_.duplicate(true);
    snapshot["registration_order"] = registration_order_.duplicate(true);
    snapshot["fields"] = field_configs_.duplicate(true);
    snapshot["normalized_schema_by_field"] = normalized_schema_by_field_.duplicate(true);
    snapshot["normalized_schema_rows"] = normalized_schema_rows_.duplicate(true);
    return snapshot;
}

bool LocalAgentsFieldRegistry::normalize_field_entry(
    const String &field_name,
    const Dictionary &field_config,
    Dictionary &normalized_field_config,
    Dictionary &normalized_schema
) const {
    normalized_field_config = field_config.duplicate(true);
    normalized_field_config["field_name"] = field_name;

    const Dictionary metadata = dictionary_or_empty(field_config.get("metadata", Dictionary()));
    const String units = normalized_text(field_config.has("units") ? field_config["units"] : metadata.get("units", String()));
    normalized_field_config["units"] = units;

    int64_t components = 1;
    if (field_config.has("components")) {
        if (!parse_positive_int64(field_config["components"], components)) {
            return false;
        }
    } else if (field_config.has("component_count")) {
        if (!parse_positive_int64(field_config["component_count"], components)) {
            return false;
        }
    } else if (metadata.has("components")) {
        if (!parse_positive_int64(metadata["components"], components)) {
            return false;
        }
    }
    normalized_field_config["components"] = components;

    String layout = normalized_text(field_config.get("layout", String("soa"))).to_lower();
    if (layout.is_empty()) {
        layout = String("soa");
    }
    if (layout != String("soa")) {
        return false;
    }
    normalized_field_config["layout"] = layout;

    bool has_min = false;
    bool has_max = false;
    double min_value = 0.0;
    double max_value = 0.0;
    if (field_config.has("min")) {
        if (!parse_finite_double(field_config["min"], min_value)) {
            return false;
        }
        has_min = true;
    } else if (field_config.has("clamp_min")) {
        if (!parse_finite_double(field_config["clamp_min"], min_value)) {
            return false;
        }
        has_min = true;
    }
    if (field_config.has("max")) {
        if (!parse_finite_double(field_config["max"], max_value)) {
            return false;
        }
        has_max = true;
    } else if (field_config.has("clamp_max")) {
        if (!parse_finite_double(field_config["clamp_max"], max_value)) {
            return false;
        }
        has_max = true;
    }
    if (has_min && has_max && min_value > max_value) {
        std::swap(min_value, max_value);
    }
    if (has_min) {
        normalized_field_config["min"] = min_value;
    }
    if (has_max) {
        normalized_field_config["max"] = max_value;
    }

    const Dictionary sparse_config = field_config.has("sparse")
                                         ? dictionary_or_empty(field_config["sparse"])
                                         : dictionary_or_empty(metadata.get("sparse", Dictionary()));
    const bool has_sparse = !sparse_config.is_empty() || field_config.has("chunk_size") ||
                            field_config.has("deterministic_ordering_key");
    bool sparse_enabled = false;
    if (has_sparse) {
        sparse_enabled = true;
        if (sparse_config.has("enabled")) {
            sparse_enabled = static_cast<bool>(sparse_config["enabled"]);
        }
    }
    int64_t sparse_chunk_size = 0;
    if (sparse_config.has("chunk_size")) {
        if (!parse_positive_int64(sparse_config["chunk_size"], sparse_chunk_size)) {
            return false;
        }
    } else if (field_config.has("chunk_size")) {
        if (!parse_positive_int64(field_config["chunk_size"], sparse_chunk_size)) {
            return false;
        }
    }
    if (sparse_enabled && sparse_chunk_size == 0) {
        sparse_chunk_size = 64;
    }

    String ordering_key = normalized_text(
        sparse_config.has("deterministic_ordering_key")
            ? sparse_config["deterministic_ordering_key"]
            : field_config.get("deterministic_ordering_key", sparse_config.get("ordering_key", String())));
    if (sparse_enabled && ordering_key.is_empty()) {
        ordering_key = String("entity_id");
    }
    if (!ordering_key.is_empty()) {
        normalized_field_config["deterministic_ordering_key"] = ordering_key;
    }

    Dictionary normalized_sparse;
    normalized_sparse["enabled"] = sparse_enabled;
    if (sparse_chunk_size > 0) {
        normalized_sparse["chunk_size"] = sparse_chunk_size;
    }
    if (!ordering_key.is_empty()) {
        normalized_sparse["deterministic_ordering_key"] = ordering_key;
    }
    normalized_field_config["sparse"] = normalized_sparse;

    const Variant role_tags_variant =
        field_config.has("role_tags")
            ? field_config["role_tags"]
            : (field_config.has("roles") ? field_config["roles"] : metadata.get("role_tags", Array()));
    PackedStringArray role_tags;
    if (role_tags_variant.get_type() == Variant::PACKED_STRING_ARRAY) {
        role_tags = role_tags_variant;
    } else if (role_tags_variant.get_type() == Variant::ARRAY) {
        const Array tags_array = role_tags_variant;
        for (int64_t i = 0; i < tags_array.size(); i += 1) {
            const String tag = normalized_text(tags_array[i]).to_lower();
            if (tag.is_empty() || role_tags.has(tag)) {
                continue;
            }
            role_tags.append(tag);
        }
    } else {
        return false;
    }
    normalized_field_config["role_tags"] = to_string_array(role_tags);

    normalized_schema.clear();
    normalized_schema["field_name"] = field_name;
    normalized_schema["units"] = units;
    normalized_schema["components"] = components;
    normalized_schema["layout"] = layout;
    normalized_schema["has_min"] = has_min;
    normalized_schema["has_max"] = has_max;
    if (has_min) {
        normalized_schema["min"] = min_value;
    }
    if (has_max) {
        normalized_schema["max"] = max_value;
    }
    normalized_schema["sparse"] = normalized_sparse;
    normalized_schema["role_tags"] = to_string_array(role_tags);
    return true;
}

bool LocalAgentsFieldRegistry::collect_config_rows(const Dictionary &config, Array &rows) const {
    rows.clear();

    if (config.has("fields")) {
        const Variant fields_variant = config["fields"];
        if (fields_variant.get_type() == Variant::DICTIONARY) {
            const Dictionary fields_dict = fields_variant;
            const Array keys = fields_dict.keys();
            for (int64_t i = 0; i < keys.size(); i += 1) {
                const String field_name = normalized_text(keys[i]);
                if (field_name.is_empty()) {
                    return false;
                }
                const Variant row_variant = fields_dict[keys[i]];
                if (row_variant.get_type() != Variant::DICTIONARY) {
                    return false;
                }
                Dictionary row = static_cast<Dictionary>(row_variant).duplicate(true);
                row["field_name"] = field_name;
                rows.append(row);
            }
        } else if (fields_variant.get_type() == Variant::ARRAY) {
            const Array fields_rows = fields_variant;
            for (int64_t i = 0; i < fields_rows.size(); i += 1) {
                if (fields_rows[i].get_type() != Variant::DICTIONARY) {
                    return false;
                }
                Dictionary row = static_cast<Dictionary>(fields_rows[i]).duplicate(true);
                String field_name = normalized_text(row.get("field_name", row.get("name", row.get("channel_id", String()))));
                if (field_name.is_empty()) {
                    return false;
                }
                row["field_name"] = field_name;
                rows.append(row);
            }
        } else {
            return false;
        }
    }

    if (config.has("channels")) {
        const Variant channels_variant = config["channels"];
        if (channels_variant.get_type() != Variant::ARRAY) {
            return false;
        }
        const Array channels = channels_variant;
        for (int64_t i = 0; i < channels.size(); i += 1) {
            if (channels[i].get_type() != Variant::DICTIONARY) {
                return false;
            }
            Dictionary row = static_cast<Dictionary>(channels[i]).duplicate(true);
            String field_name = normalized_text(row.get("field_name", row.get("channel_id", row.get("name", String()))));
            if (field_name.is_empty()) {
                return false;
            }
            if (row.has("component_count") && !row.has("components")) {
                row["components"] = row["component_count"];
            }
            if (row.has("clamp_min") && !row.has("min")) {
                row["min"] = row["clamp_min"];
            }
            if (row.has("clamp_max") && !row.has("max")) {
                row["max"] = row["clamp_max"];
            }
            row["field_name"] = field_name;
            rows.append(row);
        }
    }

    return true;
}

void LocalAgentsFieldRegistry::rebuild_normalized_schema_rows() {
    normalized_schema_rows_.clear();
    for (int64_t i = 0; i < registration_order_.size(); i += 1) {
        const String field_name = registration_order_[i];
        if (!normalized_schema_by_field_.has(field_name)) {
            continue;
        }
        normalized_schema_rows_.append(normalized_schema_by_field_[field_name]);
    }
}

} // namespace local_agents::simulation
