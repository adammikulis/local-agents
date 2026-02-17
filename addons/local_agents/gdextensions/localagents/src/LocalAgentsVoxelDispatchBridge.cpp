#include "LocalAgentsVoxelDispatchBridge.hpp"
#include "helpers/LocalAgentsFractureDebrisEmitter.hpp"
#include "helpers/SimulationCoreDictionaryHelpers.hpp"
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/object.hpp>
#include <godot_cpp/classes/time.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/callable.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/string_name.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include <godot_cpp/variant/vector3.hpp>
#include <algorithm>
#include <cmath>
#include <vector>
using namespace godot;
namespace {
constexpr const char *kDefaultStageName = "voxel_transform_step";
constexpr const char *kDefaultTierId = "native_consolidated_tick";
constexpr int64_t kPulseTimingCap = 64;
Dictionary as_dictionary(const Variant &value) {
    if (value.get_type() == Variant::DICTIONARY) {
        return static_cast<Dictionary>(value);
    }
    return Dictionary();
}
Array as_array(const Variant &value) {
    if (value.get_type() == Variant::ARRAY) {
        return static_cast<Array>(value);
    }
    return Array();
}
String as_string(const Variant &value, const String &fallback = String()) {
    if (value.get_type() == Variant::STRING) {
        return String(value);
    }
    if (value.get_type() == Variant::STRING_NAME) {
        return String(static_cast<StringName>(value));
    }
    return fallback;
}
int64_t as_i64(const Variant &value, int64_t fallback = 0) {
    if (value.get_type() == Variant::INT) {
        return static_cast<int64_t>(value);
    }
    if (value.get_type() == Variant::FLOAT) {
        return static_cast<int64_t>(static_cast<double>(value));
    }
    return fallback;
}
double as_f64(const Variant &value, double fallback = 0.0) {
    if (value.get_type() == Variant::FLOAT) {
        return static_cast<double>(value);
    }
    if (value.get_type() == Variant::INT) {
        return static_cast<int64_t>(value);
    }
    return fallback;
}
bool as_bool(const Variant &value, bool fallback = false) {
    if (value.get_type() == Variant::BOOL) {
        return static_cast<bool>(value);
    }
    if (value.get_type() == Variant::INT) {
        return static_cast<int64_t>(value) != 0;
    }
    return fallback;
}
Object *as_object_ptr(const Variant &value) {
    if (value.get_type() != Variant::OBJECT) {
        return nullptr;
    }
    return value;
}
String normalize_backend(const Dictionary &dispatch) {
    String backend = as_string(dispatch.get("backend_used", String()), String()).strip_edges().to_lower();
    if (backend.is_empty()) {
        const Dictionary voxel_result = as_dictionary(dispatch.get("voxel_result", Dictionary()));
        if (as_bool(voxel_result.get("gpu_dispatched", false), false)) {
            backend = "gpu";
        }
    }
    if (backend.is_empty()) {
        const Dictionary result = as_dictionary(dispatch.get("result", Dictionary()));
        const Dictionary execution = as_dictionary(result.get("execution", Dictionary()));
        if (as_bool(execution.get("gpu_dispatched", false), false)) {
            backend = "gpu";
        }
    }
    if (backend.is_empty() && as_bool(dispatch.get("dispatched", false), false)) {
        backend = "gpu";
    }
    if (backend.findn("gpu") != -1) {
        return "gpu";
    }
    return backend;
}
String resolve_dependency_error(const String &dispatch_reason, const String &dispatch_error) {
    const String reason = dispatch_reason.strip_edges().to_lower();
    const String error = dispatch_error.strip_edges().to_lower();
    static const char *codes[] = {"gpu_required", "gpu_unavailable", "native_required", "native_unavailable"};
    for (const char *code : codes) {
        const String code_string = String(code);
        if (reason == code_string || error == code_string) {
            return code_string;
        }
    }
    return String();
}
Array normalize_contact_rows(const Variant &rows_variant) {
    return local_agents::simulation::helpers::normalize_contact_rows(as_array(rows_variant));
}
Array merge_dispatch_contact_rows(const Array &left_rows, const Array &right_rows) {
    return local_agents::simulation::helpers::merge_and_dedupe_contact_rows(
        left_rows,
        right_rows,
        Array());
}
Array simulation_buffered_contact_rows(Object *simulation_controller);
Array resolve_dispatch_contact_rows(const Dictionary &context, Object *simulation_controller) {
    Array unified_contact_rows;
    static const char *impact_contact_row_keys[] = {
        "dispatch_contact_rows",
        "projectile_contact_rows",
        "debris_contact_rows",
        "fracture_contact_rows",
        "impact_contact_rows",
        "reimpact_contact_rows",
        "re_impact_contact_rows",
    };
    for (const char *key : impact_contact_row_keys) {
        const Array key_rows = normalize_contact_rows(context.get(key, Array()));
        unified_contact_rows = merge_dispatch_contact_rows(unified_contact_rows, key_rows);
    }
    const Array buffered_rows = simulation_buffered_contact_rows(simulation_controller);
    return merge_dispatch_contact_rows(unified_contact_rows, buffered_rows);
}
Array simulation_buffered_contact_rows(Object *simulation_controller) {
    if (simulation_controller == nullptr || !simulation_controller->has_method(StringName("get_physics_contact_snapshot"))) {
        return Array();
    }
    const Variant snapshot_variant = simulation_controller->call("get_physics_contact_snapshot");
    if (snapshot_variant.get_type() != Variant::DICTIONARY) {
        return Array();
    }
    const Dictionary snapshot = snapshot_variant;
    return normalize_contact_rows(snapshot.get("buffered_rows", Array()));
}
int64_t earliest_deadline_frame(const Array &rows) {
    int64_t earliest = -1;
    for (int64_t i = 0; i < rows.size(); i += 1) {
        if (rows[i].get_type() != Variant::DICTIONARY) {
            continue;
        }
        const Dictionary row = rows[i];
        const int64_t deadline = as_i64(row.get("deadline_frame", -1), -1);
        if (deadline < 0) {
            continue;
        }
        if (earliest < 0 || deadline < earliest) {
            earliest = deadline;
        }
    }
    return earliest;
}
void runtime_record_hits_queued(Dictionary &runtime, int64_t hits_count) {
    const int64_t count = std::max<int64_t>(0, hits_count);
    if (count <= 0) {
        return;
    }
    runtime["hits_queued"] = as_i64(runtime.get("hits_queued", 0), 0) + count;
}
void runtime_record_contacts_dispatched(Dictionary &runtime, int64_t contacts_count) {
    const int64_t count = std::max<int64_t>(0, contacts_count);
    if (count <= 0) {
        return;
    }
    runtime["contacts_dispatched"] = as_i64(runtime.get("contacts_dispatched", 0), 0) + count;
}
int64_t count_native_ops(const Dictionary &stage_payload) {
    int64_t count = 0;
    const Array native_ops = as_array(stage_payload.get("native_ops", Array()));
    for (int64_t i = 0; i < native_ops.size(); i += 1) {
        if (native_ops[i].get_type() == Variant::DICTIONARY) {
            count += 1;
        }
    }
    return count;
}
Dictionary normalize_stage_ms(const Dictionary &source) {
    Dictionary out;
    out["stage_a"] = as_f64(source.get("stage_a", 0.0), 0.0);
    out["stage_b"] = as_f64(source.get("stage_b", 0.0), 0.0);
    out["stage_c"] = as_f64(source.get("stage_c", 0.0), 0.0);
    out["stage_d"] = as_f64(source.get("stage_d", 0.0), 0.0);
    return out;
}
Dictionary extract_stage_ms_current(const Dictionary &dispatch, double fallback_duration_ms) {
    Dictionary per_stage;
    Dictionary execution = as_dictionary(dispatch.get("execution", Dictionary()));
    if (execution.is_empty()) {
        const Dictionary result = as_dictionary(dispatch.get("result", Dictionary()));
        execution = as_dictionary(result.get("execution", Dictionary()));
    }
    per_stage = normalize_stage_ms(as_dictionary(execution.get("per_stage_ms", Dictionary())));
    if (per_stage.is_empty()) {
        per_stage = normalize_stage_ms(Dictionary());
    }
    if (as_f64(per_stage.get("stage_c", 0.0), 0.0) <= 0.0) {
        per_stage["stage_c"] = fallback_duration_ms;
    }
    return per_stage;
}
void push_transform_dispatch_metrics(Dictionary &runtime, Object *simulation_controller) {
    if (simulation_controller == nullptr || !simulation_controller->has_method(StringName("set_transform_dispatch_metrics"))) {
        return;
    }
    const Dictionary per_stage_current = normalize_stage_ms(as_dictionary(runtime.get("per_stage_ms_current", Dictionary())));
    const Dictionary per_stage_aggregate = normalize_stage_ms(as_dictionary(runtime.get("per_stage_ms_aggregate", Dictionary())));
    Dictionary payload;
    payload["pulse_count"] = as_i64(runtime.get("pulses_total", 0), 0);
    payload["gpu_dispatch_success_count"] = as_i64(runtime.get("pulses_success", 0), 0);
    payload["gpu_dispatch_failure_count"] = as_i64(runtime.get("pulses_failed", 0), 0);
    payload["per_stage_ms_current"] = per_stage_current;
    payload["per_stage_ms_aggregate"] = per_stage_aggregate;
    simulation_controller->call("set_transform_dispatch_metrics", payload);
}
void runtime_record_pulse(
    Dictionary &runtime,
    Object *simulation_controller,
    int64_t tick,
    const String &tier_id,
    const String &backend_used,
    const String &dispatch_reason,
    double duration_ms,
    bool success,
    const Dictionary &dispatch
) {
    Array pulse_timings = as_array(runtime.get("pulse_timings", Array()));
    Dictionary timing;
    timing["tick"] = tick;
    timing["tier_id"] = tier_id;
    timing["duration_ms"] = duration_ms;
    timing["backend_used"] = backend_used;
    timing["dispatch_reason"] = dispatch_reason;
    timing["success"] = success;
    pulse_timings.append(timing);
    while (pulse_timings.size() > kPulseTimingCap) {
        pulse_timings.remove_at(0);
    }
    runtime["pulse_timings"] = pulse_timings;
    const Dictionary per_stage_current = extract_stage_ms_current(dispatch, duration_ms);
    runtime["per_stage_ms_current"] = per_stage_current;
    Dictionary per_stage_aggregate = normalize_stage_ms(as_dictionary(runtime.get("per_stage_ms_aggregate", Dictionary())));
    per_stage_aggregate["stage_a"] = as_f64(per_stage_aggregate.get("stage_a", 0.0), 0.0) + as_f64(per_stage_current.get("stage_a", 0.0), 0.0);
    per_stage_aggregate["stage_b"] = as_f64(per_stage_aggregate.get("stage_b", 0.0), 0.0) + as_f64(per_stage_current.get("stage_b", 0.0), 0.0);
    per_stage_aggregate["stage_c"] = as_f64(per_stage_aggregate.get("stage_c", 0.0), 0.0) + as_f64(per_stage_current.get("stage_c", 0.0), 0.0);
    per_stage_aggregate["stage_d"] = as_f64(per_stage_aggregate.get("stage_d", 0.0), 0.0) + as_f64(per_stage_current.get("stage_d", 0.0), 0.0);
    runtime["per_stage_ms_aggregate"] = per_stage_aggregate;
    push_transform_dispatch_metrics(runtime, simulation_controller);
}
void runtime_record_success(
    Dictionary &runtime,
    Object *simulation_controller,
    int64_t tick,
    const String &tier_id,
    const String &backend_used,
    const String &dispatch_reason,
    double duration_ms,
    const Dictionary &dispatch
) {
    runtime["pulses_total"] = as_i64(runtime.get("pulses_total", 0), 0) + 1;
    runtime["pulses_success"] = as_i64(runtime.get("pulses_success", 0), 0) + 1;
    runtime["last_backend"] = backend_used;
    runtime["last_dispatch_reason"] = dispatch_reason;
    runtime_record_pulse(runtime, simulation_controller, tick, tier_id, backend_used, dispatch_reason, duration_ms, true, dispatch);
}
void runtime_record_failure(
    Dictionary &runtime,
    Object *simulation_controller,
    int64_t tick,
    const String &tier_id,
    const String &backend_used,
    const String &dispatch_reason,
    double duration_ms,
    bool dependency_error,
    const Dictionary &dispatch
) {
    runtime["pulses_total"] = as_i64(runtime.get("pulses_total", 0), 0) + 1;
    runtime["pulses_failed"] = as_i64(runtime.get("pulses_failed", 0), 0) + 1;
    runtime["last_backend"] = backend_used;
    runtime["last_dispatch_reason"] = dispatch_reason;
    if (dependency_error) {
        runtime["dependency_errors"] = as_i64(runtime.get("dependency_errors", 0), 0) + 1;
    }
    runtime_record_pulse(runtime, simulation_controller, tick, tier_id, backend_used, dispatch_reason, duration_ms, false, dispatch);
}
void runtime_fail_dependency(
    Dictionary &runtime,
    Object *simulation_controller,
    int64_t tick,
    const String &reason,
    const String &tier_id,
    const String &dispatch_reason,
    double duration_ms,
    const Dictionary &dispatch
) {
    runtime["last_error"] = reason;
    runtime["last_error_tick"] = tick;
    runtime_record_failure(runtime, simulation_controller, tick, tier_id, String(), dispatch_reason, duration_ms, true, dispatch);
    UtilityFunctions::push_error(String("GPU_REQUIRED: ") + reason);
}
void collect_nested_dicts(const Dictionary &source, std::vector<Dictionary> &stack, int depth = 0) {
    if (depth > 3) {
        return;
    }
    stack.push_back(source);
    static const char *keys[] = {"voxel_failure_emission", "result_fields", "result", "dispatch", "payload", "execution", "voxel_result", "source"};
    for (const char *key : keys) {
        const Variant nested_variant = source.get(key, Variant());
        if (nested_variant.get_type() == Variant::DICTIONARY) {
            collect_nested_dicts(static_cast<Dictionary>(nested_variant), stack, depth + 1);
        }
    }
}
void collect_native_ops(const Dictionary &source, Array &out, int depth = 0) {
    if (depth > 3) {
        return;
    }
    static const char *op_keys[] = {"native_ops", "op_payloads", "operations", "voxel_ops"};
    for (const char *key : op_keys) {
        const Array rows = as_array(source.get(key, Array()));
        for (int64_t i = 0; i < rows.size(); i += 1) {
            if (rows[i].get_type() == Variant::DICTIONARY) {
                out.append(static_cast<Dictionary>(rows[i]).duplicate(true));
            }
        }
    }
    static const char *nested_keys[] = {"voxel_failure_emission", "result_fields", "result", "dispatch", "payload", "execution", "voxel_result", "source"};
    for (const char *key : nested_keys) {
        const Variant nested_variant = source.get(key, Variant());
        if (nested_variant.get_type() == Variant::DICTIONARY) {
            collect_native_ops(static_cast<Dictionary>(nested_variant), out, depth + 1);
        }
    }
}
Array flatten_native_ops(const Dictionary &source) {
    Array out;
    collect_native_ops(source, out, 0);
    return out;
}
void collect_changed_chunks(const Dictionary &source, Array &out, int depth = 0) {
    if (depth > 3) {
        return;
    }
    const Array rows = as_array(source.get("changed_chunks", Array()));
    for (int64_t i = 0; i < rows.size(); i += 1) {
        const Variant row = rows[i];
        if (row.get_type() == Variant::DICTIONARY) {
            out.append(static_cast<Dictionary>(row).duplicate(true));
        } else if (row.get_type() == Variant::STRING || row.get_type() == Variant::STRING_NAME) {
            const String key = as_string(row, String()).strip_edges();
            if (!key.is_empty()) {
                out.append(key);
            }
        }
    }
    static const char *nested_keys[] = {"voxel_failure_emission", "result_fields", "result", "dispatch", "payload", "execution", "voxel_result", "source"};
    for (const char *key : nested_keys) {
        const Variant nested_variant = source.get(key, Variant());
        if (nested_variant.get_type() == Variant::DICTIONARY) {
            collect_changed_chunks(static_cast<Dictionary>(nested_variant), out, depth + 1);
        }
    }
}
void collect_spawn_entries(const Dictionary &source, Array &out, int depth = 0) {
    if (depth > 3) {
        return;
    }
    const Array rows = as_array(source.get("spawn_entries", Array()));
    for (int64_t i = 0; i < rows.size(); i += 1) {
        if (rows[i].get_type() != Variant::DICTIONARY) {
            continue;
        }
        out.append(static_cast<Dictionary>(rows[i]).duplicate(true));
    }
    static const char *nested_keys[] = {"voxel_failure_emission", "result_fields", "result", "dispatch", "payload", "execution", "voxel_result", "source"};
    for (const char *key : nested_keys) {
        const Variant nested_variant = source.get(key, Variant());
        if (nested_variant.get_type() == Variant::DICTIONARY) {
            collect_spawn_entries(static_cast<Dictionary>(nested_variant), out, depth + 1);
        }
    }
}
Array normalize_changed_chunks(const Array &rows) {
    Dictionary seen;
    std::vector<Dictionary> normalized;
    normalized.reserve(rows.size());
    for (int64_t i = 0; i < rows.size(); i += 1) {
        const Variant row = rows[i];
        Dictionary chunk;
        if (row.get_type() == Variant::DICTIONARY) {
            const Dictionary source = row;
            const int64_t x = as_i64(source.get("x", 0), 0);
            const int64_t y = as_i64(source.get("y", 0), 0);
            const int64_t z = as_i64(source.get("z", source.get("y", 0)), 0);
            chunk["x"] = x;
            chunk["y"] = y;
            chunk["z"] = z;
        } else {
            const String key = as_string(row, String()).strip_edges();
            const PackedStringArray parts = key.split(":");
            if (parts.size() != 2) {
                continue;
            }
            chunk["x"] = String(parts[0]).to_int();
            chunk["y"] = 0;
            chunk["z"] = String(parts[1]).to_int();
        }
        const String dedupe_key = vformat("%d:%d:%d", as_i64(chunk.get("x", 0), 0), as_i64(chunk.get("y", 0), 0), as_i64(chunk.get("z", 0), 0));
        if (as_bool(seen.get(dedupe_key, false), false)) {
            continue;
        }
        seen[dedupe_key] = true;
        normalized.push_back(chunk);
    }
    std::sort(normalized.begin(), normalized.end(), [](const Dictionary &left, const Dictionary &right) {
        const int64_t lx = as_i64(left.get("x", 0), 0);
        const int64_t rx = as_i64(right.get("x", 0), 0);
        if (lx != rx) {
            return lx < rx;
        }
        const int64_t ly = as_i64(left.get("y", 0), 0);
        const int64_t ry = as_i64(right.get("y", 0), 0);
        if (ly != ry) {
            return ly < ry;
        }
        return as_i64(left.get("z", 0), 0) < as_i64(right.get("z", 0), 0);
    });
    Array out;
    for (const Dictionary &chunk : normalized) {
        out.append(chunk);
    }
    return out;
}
Dictionary find_changed_region(const Dictionary &source, int depth = 0) {
    if (depth > 3) {
        return Dictionary();
    }
    const Dictionary region = as_dictionary(source.get("changed_region", Dictionary()));
    if (!region.is_empty() && as_bool(region.get("valid", false), false)) {
        return region.duplicate(true);
    }
    static const char *nested_keys[] = {"voxel_failure_emission", "result_fields", "result", "dispatch", "payload", "execution", "voxel_result", "source"};
    for (const char *key : nested_keys) {
        const Variant nested_variant = source.get(key, Variant());
        if (nested_variant.get_type() != Variant::DICTIONARY) {
            continue;
        }
        const Dictionary nested = find_changed_region(static_cast<Dictionary>(nested_variant), depth + 1);
        if (!nested.is_empty()) {
            return nested;
        }
    }
    return Dictionary();
}
int64_t extract_int_recursive(const Dictionary &source, const String &key, int64_t fallback = 0) {
    std::vector<Dictionary> stack;
    collect_nested_dicts(source, stack, 0);
    int64_t best = fallback;
    for (const Dictionary &entry : stack) {
        if (!entry.has(key)) {
            continue;
        }
        best = std::max(best, as_i64(entry.get(key, 0), 0));
    }
    return best;
}
bool extract_bool_recursive(const Dictionary &source, const String &key) {
    std::vector<Dictionary> stack;
    collect_nested_dicts(source, stack, 0);
    for (const Dictionary &entry : stack) {
        if (!entry.has(key)) {
            continue;
        }
        if (as_bool(entry.get(key, false), false)) {
            return true;
        }
    }
    return false;
}
Dictionary resolve_native_mutation_authority(const Dictionary &dispatch, const Dictionary &stage_payload) {
    const Dictionary explicit_authority = as_dictionary(dispatch.get("native_mutation_authority", Dictionary()));
    if (!explicit_authority.is_empty()) {
        return explicit_authority.duplicate(true);
    }
    Dictionary authority;
    const int64_t ops_changed = extract_int_recursive(dispatch, "ops_changed", 0);
    const bool changed = extract_bool_recursive(dispatch, "changed") || ops_changed > 0;
    if (changed) {
        authority["changed"] = true;
    }
    if (ops_changed > 0) {
        authority["ops_changed"] = ops_changed;
    }
    const Array chunks = normalize_changed_chunks(as_array(stage_payload.get("changed_chunks", Array())));
    if (!chunks.is_empty()) {
        authority["changed_chunks"] = chunks;
    }
    const Dictionary region = as_dictionary(stage_payload.get("changed_region", Dictionary()));
    if (!region.is_empty() && as_bool(region.get("valid", false), false)) {
        authority["changed_region"] = region.duplicate(true);
    }
    if (extract_bool_recursive(dispatch, "mutation_applied")) {
        authority["mutation_applied"] = true;
    }
    return authority;
}
bool authority_reports_changed(const Dictionary &authority, const Dictionary &stage_payload) {
    if (authority.has("changed")) {
        return as_bool(authority.get("changed", false), false);
    }
    if (authority.has("ops_changed")) {
        return as_i64(authority.get("ops_changed", 0), 0) > 0;
    }
    const Array authority_chunks = as_array(authority.get("changed_chunks", Array()));
    if (!authority_chunks.is_empty()) {
        return true;
    }
    const Dictionary authority_region = as_dictionary(authority.get("changed_region", Dictionary()));
    if (!authority_region.is_empty() && as_bool(authority_region.get("valid", false), false)) {
        return true;
    }
    const Array stage_chunks = as_array(stage_payload.get("changed_chunks", Array()));
    if (!stage_chunks.is_empty()) {
        return true;
    }
    const Dictionary stage_region = as_dictionary(stage_payload.get("changed_region", Dictionary()));
    return !stage_region.is_empty() && as_bool(stage_region.get("valid", false), false);
}
String native_no_mutation_error(const Dictionary &dispatch) {
    const String reason = as_string(dispatch.get("dispatch_reason", String()), String()).strip_edges().to_lower();
    if (reason == "gpu_required" || reason == "gpu_unavailable" || reason == "native_required" || reason == "native_unavailable") {
        return reason;
    }
    return "native_voxel_stage_no_mutation";
}
Dictionary build_stage_payload(
    const Dictionary &dispatch,
    const String &backend_used,
    const String &dispatch_reason,
    const Array &dispatch_contact_rows,
    int64_t executed_op_count
) {
    Dictionary stage_payload = as_dictionary(dispatch.get("payload", Dictionary())).duplicate(false);
    const Dictionary raw_result = as_dictionary(dispatch.get("result", Dictionary()));
    if (!raw_result.is_empty()) {
        stage_payload["result"] = raw_result.duplicate(false);
    }
    stage_payload["kernel_pass"] = as_string(dispatch.get("kernel_pass", String()), String());
    stage_payload["backend_used"] = backend_used;
    stage_payload["dispatch_reason"] = dispatch_reason;
    stage_payload["dispatched"] = as_bool(dispatch.get("dispatched", false), false);
    stage_payload["physics_contacts"] = dispatch_contact_rows;
    stage_payload["native_ops"] = flatten_native_ops(dispatch);
    Array raw_chunks;
    collect_changed_chunks(dispatch, raw_chunks, 0);
    stage_payload["changed_chunks"] = normalize_changed_chunks(raw_chunks);
    Array spawn_entries;
    collect_spawn_entries(dispatch, spawn_entries, 0);
    const bool spawn_entries_required = extract_bool_recursive(dispatch, "spawn_entries_required");
    const bool spawn_entries_missing = spawn_entries_required && spawn_entries.is_empty();
    stage_payload["spawn_entries"] = spawn_entries;
    stage_payload["spawn_entries_required"] = spawn_entries_required;
    stage_payload["spawn_entries_status"] = spawn_entries_missing ? String("error_required_missing") : (spawn_entries_required ? String("required") : String("not_required"));
    stage_payload["spawn_entries_warning"] = spawn_entries_missing ? String("spawn_entries_required_missing") : String();
    Dictionary changed_region = find_changed_region(dispatch, 0);
    if (!changed_region.is_empty()) {
        stage_payload["changed_region"] = changed_region;
    }
    const Dictionary authority = resolve_native_mutation_authority(dispatch, stage_payload);
    if (!authority.is_empty()) {
        stage_payload["native_mutation_authority"] = authority.duplicate(true);
        if (authority.has("ops_changed")) {
            stage_payload["_destruction_executed_op_count"] = std::max<int64_t>(0, as_i64(authority.get("ops_changed", 0), 0));
        } else {
            stage_payload["_destruction_executed_op_count"] = std::max<int64_t>(0, executed_op_count);
        }
        if (as_array(authority.get("changed_chunks", Array())).size() > 0) {
            stage_payload["changed_chunks"] = normalize_changed_chunks(as_array(authority.get("changed_chunks", Array())));
        }
        const Dictionary authority_region = as_dictionary(authority.get("changed_region", Dictionary()));
        if (!authority_region.is_empty() && as_bool(authority_region.get("valid", false), false)) {
            stage_payload["changed_region"] = authority_region.duplicate(true);
        }
    } else {
        stage_payload["_destruction_executed_op_count"] = std::max<int64_t>(0, executed_op_count);
    }
    return stage_payload;
}
Dictionary build_native_authoritative_mutation(const Dictionary &dispatch, const Dictionary &stage_payload) {
    const Array changed_chunks = as_array(stage_payload.get("changed_chunks", Array()));
    const Dictionary authority = resolve_native_mutation_authority(dispatch, stage_payload);
    const bool changed = authority_reports_changed(authority, stage_payload);
    Dictionary mutation;
    mutation["ok"] = changed;
    mutation["changed"] = changed;
    mutation["error"] = changed ? String() : native_no_mutation_error(dispatch);
    mutation["tick"] = as_i64(stage_payload.get("tick", -1), -1);
    mutation["changed_tiles"] = Array();
    mutation["changed_chunks"] = changed_chunks.duplicate(true);
    mutation["mutation_path"] = "native_result_authoritative";
    mutation["mutation_path_state"] = changed ? "success" : "failure";
    if (!authority.is_empty()) {
        mutation["native_mutation_authority"] = authority.duplicate(true);
    }
    if (!changed) {
        Array failure_paths;
        failure_paths.append(native_no_mutation_error(dispatch));
        mutation["failure_paths"] = failure_paths;
    }
    return mutation;
}
bool has_native_mutation_signal(const Dictionary &dispatch, const Dictionary &stage_payload) {
    const Array payload_ops = as_array(stage_payload.get("native_ops", Array()));
    if (!payload_ops.is_empty()) {
        return true;
    }
    if (as_i64(stage_payload.get("_destruction_executed_op_count", 0), 0) > 0) {
        return true;
    }
    const Array changed_chunks = as_array(stage_payload.get("changed_chunks", Array()));
    if (!changed_chunks.is_empty()) {
        return true;
    }
    const Dictionary authority = as_dictionary(dispatch.get("native_mutation_authority", Dictionary()));
    if (!authority.is_empty()) {
        if (as_bool(authority.get("changed", false), false)) {
            return true;
        }
        if (as_i64(authority.get("ops_changed", 0), 0) > 0) {
            return true;
        }
        const Array authority_chunks = as_array(authority.get("changed_chunks", Array()));
        if (!authority_chunks.is_empty()) {
            return true;
        }
        if (as_bool(authority.get("mutation_applied", false), false)) {
            return true;
        }
    }
    return false;
}
Dictionary build_mutation_sync_state(Object *simulation_controller, int64_t tick, const Dictionary &mutation) {
    Dictionary state;
    state["tick"] = tick;
    if (simulation_controller != nullptr && simulation_controller->has_method(StringName("current_environment_snapshot"))) {
        state["environment_snapshot"] = mutation.get("environment_snapshot", simulation_controller->call("current_environment_snapshot"));
    } else {
        state["environment_snapshot"] = mutation.get("environment_snapshot", Dictionary());
    }
    if (simulation_controller != nullptr && simulation_controller->has_method(StringName("current_network_state_snapshot"))) {
        state["network_state_snapshot"] = mutation.get("network_state_snapshot", simulation_controller->call("current_network_state_snapshot"));
    } else {
        state["network_state_snapshot"] = mutation.get("network_state_snapshot", Dictionary());
    }
    if (simulation_controller != nullptr && simulation_controller->has_method(StringName("get_atmosphere_state_snapshot"))) {
        state["atmosphere_state_snapshot"] = simulation_controller->call("get_atmosphere_state_snapshot");
    } else {
        state["atmosphere_state_snapshot"] = Dictionary();
    }
    if (simulation_controller != nullptr && simulation_controller->has_method(StringName("get_deformation_state_snapshot"))) {
        state["deformation_state_snapshot"] = simulation_controller->call("get_deformation_state_snapshot");
    } else {
        state["deformation_state_snapshot"] = Dictionary();
    }
    if (simulation_controller != nullptr && simulation_controller->has_method(StringName("get_exposure_state_snapshot"))) {
        state["exposure_state_snapshot"] = simulation_controller->call("get_exposure_state_snapshot");
    } else {
        state["exposure_state_snapshot"] = Dictionary();
    }
    state["transform_changed"] = true;
    state["transform_changed_tiles"] = as_array(mutation.get("changed_tiles", Array())).duplicate(true);
    state["transform_changed_chunks"] = as_array(mutation.get("changed_chunks", Array())).duplicate(true);
    return state;
}
void runtime_record_mutation(Dictionary &runtime, const Dictionary &stage_payload, const Dictionary &mutation, int64_t frame_index) {
    int64_t executed_op_count = std::max<int64_t>(0, as_i64(stage_payload.get("_destruction_executed_op_count", 0), 0));
    if (executed_op_count <= 0) {
        executed_op_count = count_native_ops(stage_payload);
    }
    runtime["ops_applied"] = as_i64(runtime.get("ops_applied", 0), 0) + std::max<int64_t>(0, executed_op_count);
    runtime["changed_chunks"] = as_i64(runtime.get("changed_chunks", 0), 0) + as_array(mutation.get("changed_chunks", Array())).size();
    runtime["changed_tiles"] = as_i64(runtime.get("changed_tiles", 0), 0) + as_array(mutation.get("changed_tiles", Array())).size();
    if (!as_bool(mutation.get("changed", false), false)) {
        const String mutation_error = as_string(mutation.get("error", String()), String()).strip_edges();
        if (!mutation_error.is_empty()) {
            runtime["last_drop_reason"] = mutation_error;
        }
        return;
    }
    const int64_t last_fire_frame = as_i64(runtime.get("_last_successful_fire_frame", -1), -1);
    if (last_fire_frame < 0) {
        return;
    }
    if (as_i64(runtime.get("first_mutation_frames_since_fire", -1), -1) >= 0) {
        return;
    }
    const int64_t resolved_frame = frame_index >= 0 ? frame_index : static_cast<int64_t>(Engine::get_singleton()->get_process_frames());
    runtime["first_mutation_frames_since_fire"] = std::max<int64_t>(0, resolved_frame - last_fire_frame);
}
int64_t runtime_record_destruction_plan(Dictionary &runtime, const Dictionary &dispatch) {
    const int64_t planned_op_count = std::max<int64_t>(0, extract_int_recursive(dispatch, "planned_op_count", 0));
    if (planned_op_count > 0) {
        runtime["plans_planned"] = as_i64(runtime.get("plans_planned", 0), 0) + planned_op_count;
    }
    String drop_reason = as_string(dispatch.get("drop_reason", String()), String()).strip_edges();
    if (drop_reason.is_empty()) {
        const Dictionary result = as_dictionary(dispatch.get("result", Dictionary()));
        drop_reason = as_string(result.get("drop_reason", String()), String()).strip_edges();
    }
    if (!drop_reason.is_empty()) {
        runtime["last_drop_reason"] = drop_reason;
    }
    int64_t executed = std::max<int64_t>(0, extract_int_recursive(dispatch, "executed_op_count", 0));
    executed = std::max<int64_t>(executed, extract_int_recursive(dispatch, "ops_changed", 0));
    return executed;
}
String runtime_backend_for_failure(const Dictionary &runtime, const String &backend_used) {
    const String normalized = backend_used.strip_edges().to_lower();
    if (!normalized.is_empty()) {
        return normalized;
    }
    return as_string(runtime.get("last_backend", String()), String()).strip_edges().to_lower();
}
} // namespace
void LocalAgentsVoxelDispatchBridge::_bind_methods() {
    ClassDB::bind_method(D_METHOD("process_native_voxel_rate", "delta", "context"), &LocalAgentsVoxelDispatchBridge::process_native_voxel_rate);
}
Dictionary LocalAgentsVoxelDispatchBridge::process_native_voxel_rate(double delta, const Dictionary &context) {
    static LocalAgentsFractureDebrisEmitter fracture_debris_emitter;
    Dictionary status;
    status["ok"] = false; status["dispatched"] = false; status["mutation_applied"] = false;
    status["mutation_error"] = String(); status["mutation_path"] = String();
    status["direct_contact_ops_used"] = false; status["direct_contact_ops_count"] = 0; status["contacts_consumed"] = 0;
    const int64_t tick = as_i64(context.get("tick", 0), 0);
    const int64_t frame_index = std::max<int64_t>(0, as_i64(context.get("frame_index", static_cast<int64_t>(Engine::get_singleton()->get_process_frames())), 0));
    Object *simulation_controller = as_object_ptr(context.get("simulation_controller", Variant()));
    Dictionary runtime = as_dictionary(context.get("native_voxel_dispatch_runtime", Dictionary()));
    const Callable sync_callable = context.get("sync_environment_from_state", Callable());
    const Callable mutation_glow_handler = context.get("mutation_glow_handler", Callable());
    String stage_name = as_string(context.get("native_stage_name", String(kDefaultStageName)), String(kDefaultStageName)).strip_edges();
    if (stage_name.is_empty()) {
        stage_name = kDefaultStageName;
    }
    if (simulation_controller == nullptr || !simulation_controller->has_method(StringName("execute_native_voxel_stage"))) {
        runtime_fail_dependency(runtime, simulation_controller, tick, "native voxel dispatch unavailable: execute_native_voxel_stage missing", String(), "missing_dispatch_method", 0.0, Dictionary());
        status["error"] = "missing_dispatch_method";
        status["dependency_error"] = "missing_dispatch_method";
        return status;
    }
    Dictionary view_metrics;
    Object *camera_controller = as_object_ptr(context.get("camera_controller", Variant()));
    if (camera_controller != nullptr && camera_controller->has_method(StringName("native_view_metrics"))) {
        view_metrics = as_dictionary(camera_controller->call("native_view_metrics"));
    }
    const double base_budget = std::clamp(as_f64(view_metrics.get("compute_budget_scale", 1.0), 1.0), 0.05, 1.0);
    const Array dispatch_contact_rows = resolve_dispatch_contact_rows(context, simulation_controller);
    const int64_t queued_contact_count = dispatch_contact_rows.size();
    runtime_record_hits_queued(runtime, queued_contact_count);
    Dictionary orchestration_contract;
    orchestration_contract["pending_contacts"] = queued_contact_count;
    orchestration_contract["expired_contacts"] = 0;
    orchestration_contract["deadline_violations_total"] = 0;
    orchestration_contract["current_frame"] = frame_index;
    orchestration_contract["earliest_deadline_frame"] = earliest_deadline_frame(dispatch_contact_rows);
    Dictionary frame_context;
    frame_context["frame_index"] = frame_index;
    Dictionary tick_payload;
    tick_payload["tick"] = tick;
    tick_payload["delta"] = delta;
    tick_payload["rate_tier"] = String(kDefaultTierId);
    tick_payload["compute_budget_scale"] = base_budget;
    tick_payload["zoom_factor"] = std::clamp(as_f64(view_metrics.get("zoom_factor", 0.0), 0.0), 0.0, 1.0);
    tick_payload["camera_distance"] = std::max(0.0, as_f64(view_metrics.get("camera_distance", 0.0), 0.0));
    tick_payload["uniformity_score"] = std::clamp(as_f64(view_metrics.get("uniformity_score", 0.0), 0.0), 0.0, 1.0);
    tick_payload["physics_contacts"] = dispatch_contact_rows;
    Dictionary native_tick_orchestration;
    native_tick_orchestration["orchestration_contract"] = orchestration_contract.duplicate(true);
    native_tick_orchestration["frame_context"] = frame_context.duplicate(true);
    tick_payload["native_tick_orchestration"] = native_tick_orchestration;
    tick_payload["simulation_tick"] = tick;
    if (as_i64(runtime.get("_last_successful_fire_frame", -1), -1) >= 0 && as_i64(runtime.get("first_mutation_frames_since_fire", -1), -1) < 0) {
        runtime["dispatch_attempts_after_fire"] = as_i64(runtime.get("dispatch_attempts_after_fire", 0), 0) + 1;
    }
    const uint64_t dispatch_start_usec = Time::get_singleton()->get_ticks_usec();
    const Variant dispatch_variant = simulation_controller->call("execute_native_voxel_stage", tick, StringName(stage_name), tick_payload, false);
    const double dispatch_duration_ms = static_cast<double>(std::max<int64_t>(0, static_cast<int64_t>(Time::get_singleton()->get_ticks_usec() - dispatch_start_usec))) / 1000.0;
    String tick_tier_id = kDefaultTierId;
    if (dispatch_variant.get_type() != Variant::DICTIONARY) {
        runtime_record_failure(runtime, simulation_controller, tick, tick_tier_id, String(), "invalid_dispatch_result", dispatch_duration_ms, false, Dictionary());
        status["error"] = "invalid_dispatch_result";
        return status;
    }
    const Dictionary dispatch = dispatch_variant;
    const String backend_used = normalize_backend(dispatch);
    const String dispatch_reason = as_string(dispatch.get("dispatch_reason", String()), String());
    const Dictionary native_tick_contract = as_dictionary(dispatch.get("native_tick_contract", Dictionary()));
    if (native_tick_contract.has("tier_id")) {
        tick_tier_id = as_string(native_tick_contract.get("tier_id", String(kDefaultTierId)), String(kDefaultTierId)).strip_edges();
        if (tick_tier_id.is_empty()) {
            tick_tier_id = kDefaultTierId;
        }
    }
    if (!as_bool(dispatch.get("dispatched", false), false)) {
        const String dependency_error = resolve_dependency_error(dispatch_reason, as_string(dispatch.get("error", String()), String()));
        if (!dependency_error.is_empty()) {
            runtime_fail_dependency(runtime, simulation_controller, tick, "native voxel stage was not dispatched", tick_tier_id, dependency_error, dispatch_duration_ms, dispatch);
            status["error"] = "native_not_dispatched";
            status["dependency_error"] = dependency_error;
            return status;
        }
        if (queued_contact_count > 0) {
            runtime_record_failure(runtime, simulation_controller, tick, tick_tier_id, runtime_backend_for_failure(runtime, backend_used), dispatch_reason, dispatch_duration_ms, false, dispatch);
        }
        status["error"] = dispatch_reason.is_empty() ? String("dispatch_skipped") : dispatch_reason;
        return status;
    }
    if (backend_used.findn("gpu") == -1) {
        runtime_fail_dependency(runtime, simulation_controller, tick, String("native voxel stage backend is not GPU: ") + backend_used, tick_tier_id, dispatch_reason, dispatch_duration_ms, dispatch);
        status["error"] = "backend_not_gpu";
        status["dependency_error"] = dispatch_reason;
        return status;
    }
    runtime_record_success(runtime, simulation_controller, tick, tick_tier_id, backend_used, dispatch_reason, dispatch_duration_ms, dispatch);
    const int64_t native_executed_op_count = runtime_record_destruction_plan(runtime, dispatch);
    Dictionary stage_payload = build_stage_payload(dispatch, backend_used, dispatch_reason, dispatch_contact_rows, native_executed_op_count);
    const bool spawn_entries_required = as_bool(stage_payload.get("spawn_entries_required", false), false);
    const bool spawn_entries_missing = spawn_entries_required && as_array(stage_payload.get("spawn_entries", Array())).is_empty();
    if (spawn_entries_missing) {
        const String missing_error = "spawn_entries_required_missing";
        runtime["last_error"] = missing_error;
        runtime["last_error_tick"] = tick;
        status["dispatched"] = true;
        status["error"] = missing_error;
        status["mutation_error"] = missing_error;
        UtilityFunctions::push_error(String("NATIVE_REQUIRED: ") + missing_error);
        return status;
    }
    const Dictionary mutation_authoritative = build_native_authoritative_mutation(dispatch, stage_payload);
    const bool has_stage_mutation_signal = has_native_mutation_signal(dispatch, stage_payload);
    const bool contact_driven_mutation_required = !dispatch_contact_rows.is_empty();
    const bool can_apply_stage_mutation = !stage_payload.is_empty() && (has_stage_mutation_signal || contact_driven_mutation_required);
    bool mutation_applied = false;
    Dictionary applied_mutation = mutation_authoritative;
    if (can_apply_stage_mutation) {
        if (mutator_.is_null()) {
            mutator_.instantiate();
        }
        if (!mutator_.is_valid()) {
            applied_mutation["changed"] = false;
            applied_mutation["error"] = "native_required";
            applied_mutation["mutation_path"] = "native_mutator_apply";
            applied_mutation["mutation_path_state"] = "failure";
        } else {
            applied_mutation = mutator_->apply_native_voxel_stage_delta(simulation_controller, tick, stage_payload);
            if (as_string(applied_mutation.get("mutation_path", String()), String()).strip_edges().is_empty()) {
                applied_mutation["mutation_path"] = "native_mutator_apply";
            }
        }
        runtime_record_mutation(runtime, stage_payload, applied_mutation, frame_index);
        mutation_applied = as_bool(applied_mutation.get("changed", false), false);
        if (mutation_applied && sync_callable.is_valid()) {
            sync_callable.call(build_mutation_sync_state(simulation_controller, tick, applied_mutation));
        }
    }
    int64_t consumed_contacts = std::max<int64_t>(0, as_i64(native_tick_contract.get("contacts_consumed", 0), 0));
    if (!mutation_applied) {
        consumed_contacts = 0;
    }
    if (consumed_contacts > 0) {
        runtime_record_contacts_dispatched(runtime, consumed_contacts);
    }
    if (mutation_applied) {
        runtime["real_mutations"] = as_i64(runtime.get("real_mutations", 0), 0) + 1;
    }
    if (mutation_applied && mutation_glow_handler.is_valid()) {
        Dictionary glow_payload;
        glow_payload["changed_chunks"] = as_array(stage_payload.get("changed_chunks", Array()));
        glow_payload["changed_region"] = as_dictionary(stage_payload.get("changed_region", Dictionary()));
        mutation_glow_handler.call(glow_payload);
    }
    const int64_t emitted_debris_count = mutation_applied ? fracture_debris_emitter.emit_for_mutation(simulation_controller, tick, stage_payload) : 0;
    runtime["debris_emitted_total"] = as_i64(runtime.get("debris_emitted_total", 0), 0) + std::max<int64_t>(0, emitted_debris_count);
    status["ok"] = !contact_driven_mutation_required || mutation_applied;
    status["dispatched"] = true;
    status["mutation_applied"] = mutation_applied;
    if (!mutation_applied) {
        String mutation_error = as_string(applied_mutation.get("error", String()), String()).strip_edges();
        if (mutation_error.is_empty()) {
            mutation_error = native_no_mutation_error(dispatch);
        }
        String mutation_path = as_string(applied_mutation.get("mutation_path", String()), String()).strip_edges();
        if (mutation_path.is_empty()) {
            mutation_path = "native_mutator_apply";
        }
        status["mutation_error"] = mutation_error;
        status["mutation_path"] = mutation_path;
        status["error"] = mutation_error;
        if (mutation_error == "native_required" || mutation_error == "native_unavailable") {
            status["dependency_error"] = "native_required";
        }
    }
    status["contacts_consumed"] = consumed_contacts;
    status["debris_emitted"] = emitted_debris_count;
    status["backend_used"] = backend_used;
    status["dispatch_reason"] = dispatch_reason;
    status["tier_id"] = tick_tier_id;
    return status;
}
