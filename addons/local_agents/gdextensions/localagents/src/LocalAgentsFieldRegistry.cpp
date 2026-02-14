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

void append_validation_failure(Dictionary &failure, const String &field_name, const String &reason) {
    failure.clear();
    failure["field_name"] = field_name;
    failure["reason"] = reason;
}

constexpr const char *VALIDATION_REASON_COMPONENTS_INVALID = "components_invalid";
constexpr const char *VALIDATION_REASON_FIELD_NAME_MISSING = "field_name_missing";
constexpr const char *VALIDATION_REASON_LAYOUT_INVALID = "layout_invalid";
constexpr const char *VALIDATION_REASON_METADATA_MISSING = "metadata_missing";
constexpr const char *VALIDATION_REASON_METADATA_UNIT_MISSING = "metadata_unit_missing";
constexpr const char *VALIDATION_REASON_METADATA_RANGE_MISSING = "metadata_range_missing";
constexpr const char *VALIDATION_REASON_METADATA_RANGE_MIN_MISSING = "metadata_range_min_missing";
constexpr const char *VALIDATION_REASON_METADATA_RANGE_MAX_MISSING = "metadata_range_max_missing";
constexpr const char *VALIDATION_REASON_METADATA_RANGE_MIN_INVALID = "metadata_range_min_invalid";
constexpr const char *VALIDATION_REASON_METADATA_RANGE_MAX_INVALID = "metadata_range_max_invalid";
constexpr const char *VALIDATION_REASON_METADATA_RANGE_INVERTED = "metadata_range_inverted";
constexpr const char *VALIDATION_REASON_ROLE_TAGS_INVALID = "role_tags_invalid";
constexpr const char *VALIDATION_REASON_CONFIG_ROWS_INVALID = "config_rows_invalid";
constexpr const char *VALIDATION_REASON_SPARSE_CHUNK_SIZE_INVALID = "sparse_chunk_size_invalid";
constexpr const char *VALIDATION_REASON_SPARSE_INVALID = "sparse_invalid";

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

String normalized_field_key(const StringName &field_name) {
    return String(field_name).strip_edges();
}

String normalized_handle_key(const StringName &handle_id) {
    return String(handle_id).strip_edges();
}

String build_deterministic_handle_id(const String &field_name) {
    return String("field::") + field_name;
}

} // namespace

bool LocalAgentsFieldRegistry::register_field(const StringName &field_name, const Dictionary &field_config) {
    const String key = normalized_field_key(field_name);
    if (key.is_empty()) {
        Dictionary failure;
        append_validation_failure(failure, "", VALIDATION_REASON_FIELD_NAME_MISSING);
        Array failures;
        failures.append(failure);
        set_last_configure_status(false, failures, String("register_field"));
        return false;
    }

    Dictionary normalized_field_config;
    Dictionary normalized_schema;
    Dictionary validation_failure;
    if (!normalize_field_entry(key, field_config, normalized_field_config, normalized_schema, validation_failure)) {
        Array failures;
        failures.append(validation_failure);
        set_last_configure_status(false, failures, String("register_field"));
        return false;
    }

    if (!field_configs_.has(key)) {
        registration_order_.append(key);
    }
    field_configs_[key] = normalized_field_config;
    normalized_schema_by_field_[key] = normalized_schema;
    rebuild_normalized_schema_rows();
    refresh_field_handle_mappings();
    Array failures;
    set_last_configure_status(true, failures, String("register_field"));
    return true;
}

Dictionary LocalAgentsFieldRegistry::create_field_handle(const StringName &field_name) {
    Dictionary result;
    const String field_key = normalized_field_key(field_name);
    if (field_key.is_empty()) {
        result["ok"] = false;
        result["error"] = String("invalid_field_name");
        return result;
    }
    if (!normalized_schema_by_field_.has(field_key)) {
        result["ok"] = false;
        result["error"] = String("field_not_registered");
        result["field_name"] = field_key;
        return result;
    }

    if (!handle_by_field_.has(field_key)) {
        const String handle_id = build_deterministic_handle_id(field_key);
        const Dictionary schema_row = static_cast<Dictionary>(normalized_schema_by_field_[field_key]).duplicate(true);
        Dictionary schema_with_handle = schema_row.duplicate(true);
        schema_with_handle["handle_id"] = handle_id;
        schema_with_handle["field_name"] = field_key;

        handle_by_field_[field_key] = handle_id;
        field_by_handle_[handle_id] = field_key;
        normalized_schema_by_handle_[handle_id] = schema_with_handle;
    }

    const String handle_id = handle_by_field_[field_key];
    result["ok"] = true;
    result["field_name"] = field_key;
    result["handle_id"] = handle_id;
    result["schema_row"] = static_cast<Dictionary>(normalized_schema_by_handle_[handle_id]).duplicate(true);
    return result;
}

Dictionary LocalAgentsFieldRegistry::resolve_field_handle(const StringName &handle_id) const {
    Dictionary result;
    const String handle_key = normalized_handle_key(handle_id);
    if (handle_key.is_empty()) {
        result["ok"] = false;
        result["error"] = String("invalid_handle_id");
        return result;
    }
    if (!field_by_handle_.has(handle_key) || !normalized_schema_by_handle_.has(handle_key)) {
        result["ok"] = false;
        result["error"] = String("field_handle_not_found");
        result["handle_id"] = handle_key;
        return result;
    }

    result["ok"] = true;
    result["handle_id"] = handle_key;
    result["field_name"] = field_by_handle_[handle_key];
    result["schema_row"] = static_cast<Dictionary>(normalized_schema_by_handle_[handle_key]).duplicate(true);
    return result;
}

Dictionary LocalAgentsFieldRegistry::list_field_handles_snapshot() const {
    Dictionary snapshot;
    snapshot["ok"] = true;
    snapshot["handle_count"] = field_by_handle_.size();
    snapshot["handles_by_field"] = handle_by_field_.duplicate(true);
    snapshot["fields_by_handle"] = field_by_handle_.duplicate(true);
    snapshot["normalized_schema_by_handle"] = normalized_schema_by_handle_.duplicate(true);
    return snapshot;
}

bool LocalAgentsFieldRegistry::configure(const Dictionary &config) {
    Array config_rows;
    if (!collect_config_rows(config, config_rows)) {
        Array failures;
        Dictionary failure;
        append_validation_failure(failure, "", VALIDATION_REASON_CONFIG_ROWS_INVALID);
        failures.append(failure);
        set_last_configure_status(false, failures, String("configure"));
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
            Array failures;
            Dictionary failure;
            append_validation_failure(failure, "", VALIDATION_REASON_CONFIG_ROWS_INVALID);
            failures.append(failure);
            set_last_configure_status(false, failures, String("configure"));
            return false;
        }
        const Dictionary row = row_variant;
        const String field_name = normalized_text(row.get("field_name", String()));
        if (field_name.is_empty()) {
            Array failures;
            Dictionary failure;
            append_validation_failure(failure, "", VALIDATION_REASON_FIELD_NAME_MISSING);
            failures.append(failure);
            set_last_configure_status(false, failures, String("configure"));
            return false;
        }

        Dictionary normalized_field_config;
        Dictionary normalized_schema;
        Dictionary validation_failure;
        if (!normalize_field_entry(field_name, row, normalized_field_config, normalized_schema, validation_failure)) {
            Array failures;
            failures.append(validation_failure);
            set_last_configure_status(false, failures, String("configure"));
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
    refresh_field_handle_mappings();
    config_ = config.duplicate(true);
    Array failures;
    set_last_configure_status(true, failures, String("configure"));
    return true;
}

void LocalAgentsFieldRegistry::clear() {
    config_.clear();
    field_configs_.clear();
    normalized_schema_by_field_.clear();
    normalized_schema_rows_.clear();
    registration_order_.clear();
    handle_by_field_.clear();
    field_by_handle_.clear();
    normalized_schema_by_handle_.clear();
    last_configure_status_.clear();
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
    snapshot["handles_by_field"] = handle_by_field_.duplicate(true);
    snapshot["fields_by_handle"] = field_by_handle_.duplicate(true);
    snapshot["normalized_schema_by_handle"] = normalized_schema_by_handle_.duplicate(true);
    snapshot["configure_status"] = last_configure_status_.duplicate(true);
    return snapshot;
}

void LocalAgentsFieldRegistry::set_last_configure_status(
    const bool ok,
    const Array &failures,
    const String &operation
) {
    last_configure_status_.clear();
    last_configure_status_["ok"] = ok;
    last_configure_status_["operation"] = operation;
    last_configure_status_["failures"] = failures.duplicate(true);
}

bool LocalAgentsFieldRegistry::normalize_field_entry(
    const String &field_name,
    const Dictionary &field_config,
    Dictionary &normalized_field_config,
    Dictionary &normalized_schema,
    Dictionary &validation_failure
) const {
    append_validation_failure(validation_failure, field_name, String());

    normalized_field_config = field_config.duplicate(true);
    normalized_field_config["field_name"] = field_name;

    const Dictionary metadata = dictionary_or_empty(field_config.get("metadata", Dictionary()));
    if (metadata.is_empty()) {
        append_validation_failure(validation_failure, field_name, VALIDATION_REASON_METADATA_MISSING);
        return false;
    }
    const String units = normalized_text(metadata.get("unit", String()));
    if (units.is_empty()) {
        append_validation_failure(validation_failure, field_name, VALIDATION_REASON_METADATA_UNIT_MISSING);
        return false;
    }
    normalized_field_config["units"] = units;

    int64_t components = 1;
    if (field_config.has("components")) {
        if (!parse_positive_int64(field_config["components"], components)) {
            append_validation_failure(validation_failure, field_name, VALIDATION_REASON_COMPONENTS_INVALID);
            return false;
        }
    } else if (field_config.has("component_count")) {
        if (!parse_positive_int64(field_config["component_count"], components)) {
            append_validation_failure(validation_failure, field_name, VALIDATION_REASON_COMPONENTS_INVALID);
            return false;
        }
    } else if (metadata.has("components")) {
        if (!parse_positive_int64(metadata["components"], components)) {
            append_validation_failure(validation_failure, field_name, VALIDATION_REASON_COMPONENTS_INVALID);
            return false;
        }
    }
    normalized_field_config["components"] = components;

    String layout = normalized_text(field_config.get("layout", String("soa"))).to_lower();
    if (layout.is_empty()) {
        layout = String("soa");
    }
    if (layout != String("soa")) {
        append_validation_failure(validation_failure, field_name, VALIDATION_REASON_LAYOUT_INVALID);
        return false;
    }
    normalized_field_config["layout"] = layout;

    double min_value = 0.0;
    double max_value = 0.0;
    const Dictionary range = dictionary_or_empty(metadata.get("range", Dictionary()));
    if (!metadata.has("range") || range.is_empty()) {
        append_validation_failure(validation_failure, field_name, VALIDATION_REASON_METADATA_RANGE_MISSING);
        return false;
    }
    if (!range.has("min")) {
        append_validation_failure(validation_failure, field_name, VALIDATION_REASON_METADATA_RANGE_MIN_MISSING);
        return false;
    }
    if (!range.has("max")) {
        append_validation_failure(validation_failure, field_name, VALIDATION_REASON_METADATA_RANGE_MAX_MISSING);
        return false;
    }
    if (!parse_finite_double(range.get("min", 0.0), min_value)) {
        append_validation_failure(validation_failure, field_name, VALIDATION_REASON_METADATA_RANGE_MIN_INVALID);
        return false;
    }
    if (!parse_finite_double(range.get("max", 0.0), max_value)) {
        append_validation_failure(validation_failure, field_name, VALIDATION_REASON_METADATA_RANGE_MAX_INVALID);
        return false;
    }
    if (min_value > max_value) {
        append_validation_failure(validation_failure, field_name, VALIDATION_REASON_METADATA_RANGE_INVERTED);
        return false;
    }
    normalized_field_config["min"] = min_value;
    normalized_field_config["max"] = max_value;

    if (field_config.has("sparse") && field_config["sparse"].get_type() != Variant::DICTIONARY) {
        append_validation_failure(validation_failure, field_name, VALIDATION_REASON_SPARSE_INVALID);
        return false;
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
            append_validation_failure(validation_failure, field_name, VALIDATION_REASON_SPARSE_CHUNK_SIZE_INVALID);
            return false;
        }
    } else if (field_config.has("chunk_size")) {
        if (!parse_positive_int64(field_config["chunk_size"], sparse_chunk_size)) {
            append_validation_failure(validation_failure, field_name, VALIDATION_REASON_SPARSE_CHUNK_SIZE_INVALID);
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
        append_validation_failure(validation_failure, field_name, VALIDATION_REASON_ROLE_TAGS_INVALID);
        return false;
    }
    normalized_field_config["role_tags"] = to_string_array(role_tags);

    normalized_schema.clear();
    normalized_schema["field_name"] = field_name;
    normalized_schema["units"] = units;
    normalized_schema["components"] = components;
    normalized_schema["layout"] = layout;
    normalized_schema["has_min"] = true;
    normalized_schema["has_max"] = true;
    normalized_schema["min"] = min_value;
    normalized_schema["max"] = max_value;
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

void LocalAgentsFieldRegistry::refresh_field_handle_mappings() {
    Dictionary next_handle_by_field;
    Dictionary next_field_by_handle;
    Dictionary next_schema_by_handle;
    const Array field_names = normalized_schema_by_field_.keys();
    for (int64_t i = 0; i < field_names.size(); i += 1) {
        const String field_name = normalized_text(field_names[i]);
        if (field_name.is_empty()) {
            continue;
        }
        const String handle_id = build_deterministic_handle_id(field_name);
        const Dictionary schema_row = static_cast<Dictionary>(normalized_schema_by_field_[field_name]).duplicate(true);
        Dictionary schema_with_handle = schema_row.duplicate(true);
        schema_with_handle["handle_id"] = handle_id;
        schema_with_handle["field_name"] = field_name;

        next_handle_by_field[field_name] = handle_id;
        next_field_by_handle[handle_id] = field_name;
        next_schema_by_handle[handle_id] = schema_with_handle;
    }
    handle_by_field_ = next_handle_by_field;
    field_by_handle_ = next_field_by_handle;
    normalized_schema_by_handle_ = next_schema_by_handle;
}

} // namespace local_agents::simulation
