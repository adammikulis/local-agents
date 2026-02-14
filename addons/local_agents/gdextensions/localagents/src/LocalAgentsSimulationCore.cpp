#include "LocalAgentsSimulationCore.hpp"

#include "LocalAgentsComputeManager.hpp"
#include "LocalAgentsFieldRegistry.hpp"
#include "LocalAgentsQueryService.hpp"
#include "LocalAgentsScheduler.hpp"
#include "LocalAgentsSimProfiler.hpp"
#include "SimulationFailureEmissionPlanner.hpp"
#include "VoxelEditEngine.hpp"

#include <algorithm>
#include <set>
#include <cmath>
#include <cstdint>

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/array.hpp>

using namespace godot;
using namespace local_agents::simulation;

namespace {
double get_numeric_dictionary_value(const Dictionary &row, const StringName &key);

constexpr int64_t kDefaultPhysicsContactCapacity = 256;
constexpr double kImpactSignalGainMin = 1.0e-7;
constexpr double kImpactSignalDefaultScale = 1.0e-5;
constexpr double kWatchSignalDefault = 2.2;
constexpr double kActiveSignalDefault = 4.0;
constexpr double kMaxFractureRadius = 12.0;
constexpr double kDefaultFractureRadiusBase = 1.0;
constexpr double kDefaultFractureRadiusGain = 0.5;
constexpr double kDefaultFractureValueSoftness = 2.4;
constexpr double kDefaultFractureValueCap = 0.95;

struct ImpactFractureProfile {
    double impact_signal_gain = kImpactSignalDefaultScale;
    double watch_signal_threshold = kWatchSignalDefault;
    double active_signal_threshold = kActiveSignalDefault;
    double fracture_radius_base = kDefaultFractureRadiusBase;
    double fracture_radius_gain = kDefaultFractureRadiusGain;
    double fracture_radius_max = kMaxFractureRadius;
    double fracture_value_softness = kDefaultFractureValueSoftness;
    double fracture_value_cap = kDefaultFractureValueCap;
};

double contact_impulse_from_row(const Dictionary &row) {
    const double contact_impulse = get_numeric_dictionary_value(row, StringName("contact_impulse"));
    if (contact_impulse != 0.0) {
        return contact_impulse;
    }
    return get_numeric_dictionary_value(row, StringName("impulse"));
}

int64_t increment_stage_counter(Dictionary &counters, const StringName &stage_name) {
    const String stage_key = String(stage_name);
    int64_t count = 0;
    if (counters.has(stage_key)) {
        count = static_cast<int64_t>(counters[stage_key]);
    }
    count += 1;
    counters[stage_key] = count;
    return count;
}

Dictionary build_stage_dispatch_counters(
    int64_t domain_dispatch_count,
    int64_t stage_dispatch_count
) {
    Dictionary counters;
    counters["domain_dispatch_count"] = domain_dispatch_count;
    counters["stage_dispatch_count"] = stage_dispatch_count;
    return counters;
}

double get_numeric_dictionary_value(const Dictionary &row, const StringName &key) {
    if (!row.has(key)) {
        return 0.0;
    }
    const Variant value = row[key];
    switch (value.get_type()) {
        case Variant::INT:
            return static_cast<double>(static_cast<int64_t>(value));
        case Variant::FLOAT:
            return static_cast<double>(value);
        default:
            return 0.0;
    }
}

bool extract_reference_from_dictionary(const Dictionary &payload, String &out_ref) {
    if (payload.has("schema_row")) {
        const Variant schema_variant = payload.get("schema_row", Dictionary());
        if (schema_variant.get_type() == Variant::DICTIONARY) {
            const Dictionary schema = schema_variant;
            if (extract_reference_from_dictionary(schema, out_ref)) {
                return true;
            }
        }
    }
    if (payload.has("handle_id")) {
        out_ref = String(payload.get("handle_id", String()));
        return true;
    }
    if (payload.has("field_name")) {
        out_ref = String(payload.get("field_name", String()));
        return true;
    }
    if (payload.has("name")) {
        out_ref = String(payload.get("name", String()));
        return true;
    }
    if (payload.has("id")) {
        out_ref = String(payload.get("id", String()));
        return true;
    }
    if (payload.has("handle")) {
        const Variant handle_candidate = payload.get("handle", String());
        if (handle_candidate.get_type() == Variant::STRING || handle_candidate.get_type() == Variant::STRING_NAME) {
            out_ref = String(handle_candidate);
            return true;
        }
    }
    return false;
}

Dictionary normalize_contact_row(const Variant &raw_row) {
    Dictionary normalized;
    if (raw_row.get_type() != Variant::DICTIONARY) {
        return normalized;
    }

    const Dictionary source = raw_row;
    normalized["body_a"] = source.get("body_a", StringName());
    normalized["body_b"] = source.get("body_b", StringName());
    normalized["shape_a"] = static_cast<int64_t>(source.get("shape_a", static_cast<int64_t>(-1)));
    normalized["shape_b"] = static_cast<int64_t>(source.get("shape_b", static_cast<int64_t>(-1)));
    const double normalized_impulse = contact_impulse_from_row(source);
    normalized["contact_impulse"] = normalized_impulse;
    normalized["impulse"] = normalized_impulse;
    const double body_velocity = get_numeric_dictionary_value(source, StringName("body_velocity"));
    const double obstacle_velocity = get_numeric_dictionary_value(source, StringName("obstacle_velocity"));
    const double row_velocity = std::fabs(get_numeric_dictionary_value(source, StringName("contact_velocity")));
    const double legacy_relative_speed = std::fabs(get_numeric_dictionary_value(source, StringName("relative_speed")));
    const double relative_speed = std::fmax(
        0.0,
        std::fmax(std::fmax(row_velocity, legacy_relative_speed), std::fabs(body_velocity - obstacle_velocity))
    );
    normalized["relative_speed"] = relative_speed;
    const Variant contact_point = source.get("contact_point", Dictionary());
    const Variant contact_normal = source.get("contact_normal", source.get("normal", Dictionary()));
    normalized["contact_point"] = contact_point;
    normalized["contact_normal"] = contact_normal;
    normalized["normal"] = contact_normal;
    normalized["frame"] = static_cast<int64_t>(source.get("frame", static_cast<int64_t>(0)));
    normalized["body_mass"] = get_numeric_dictionary_value(source, StringName("body_mass"));
    normalized["collider_mass"] = get_numeric_dictionary_value(source, StringName("collider_mass"));
    return normalized;
}

Array collect_input_field_handles(
    const Dictionary &frame_inputs,
    IFieldRegistry *registry,
    bool &did_inject_handles
) {
    Array field_handles;
    if (registry == nullptr) {
        did_inject_handles = false;
        return field_handles;
    }

    std::set<String> emitted_handles;
    bool injected = false;

    const auto add_handle_from_payload = [&](const Dictionary &handle_payload) {
        const bool ok = static_cast<bool>(handle_payload.get("ok", false));
        if (!ok) {
            return;
        }
        const String handle_id = String(handle_payload.get("handle_id", String()));
        if (handle_id.is_empty() || emitted_handles.count(handle_id) > 0) {
            return;
        }

        emitted_handles.insert(handle_id);
        Dictionary handle_entry = handle_payload.duplicate(true);
        handle_entry.erase("ok");
        if (!handle_entry.has("handle_id")) {
            handle_entry["handle_id"] = handle_id;
        }
        if (!handle_entry.has("id")) {
            handle_entry["id"] = handle_id;
        }
        field_handles.append(handle_entry);
        injected = true;
    };

    const auto resolve_field_reference = [&](const String &candidate_token) {
        if (candidate_token.is_empty()) {
            return;
        }
        const String token = candidate_token.strip_edges();
        const Dictionary resolved = registry->resolve_field_handle(token);
        if (static_cast<bool>(resolved.get("ok", false))) {
            add_handle_from_payload(resolved);
            return;
        }
        const Dictionary created = registry->create_field_handle(token);
        add_handle_from_payload(created);
    };

    if (frame_inputs.has("field_handles")) {
        const Variant explicit_handles_variant = frame_inputs.get("field_handles", Variant());
        if (explicit_handles_variant.get_type() == Variant::ARRAY) {
            const Array explicit_handles = explicit_handles_variant;
            for (int64_t i = 0; i < explicit_handles.size(); i += 1) {
                const Variant explicit_handle = explicit_handles[i];
                if (explicit_handle.get_type() == Variant::STRING || explicit_handle.get_type() == Variant::STRING_NAME) {
                    resolve_field_reference(String(explicit_handle));
                    continue;
                }
                if (explicit_handle.get_type() == Variant::DICTIONARY) {
                    String explicit_reference;
                    if (extract_reference_from_dictionary(explicit_handle, explicit_reference)) {
                        resolve_field_reference(explicit_reference);
                    }
                }
            }
        }
    }

    const Array input_keys = frame_inputs.keys();
    for (int64_t i = 0; i < input_keys.size(); i += 1) {
        const String key = String(input_keys[i]);
        if (key == String("field_handles")) {
            continue;
        }
        const Variant input_value = frame_inputs.get(key, Variant());
        String field_reference;
        if (input_value.get_type() == Variant::STRING || input_value.get_type() == Variant::STRING_NAME) {
            field_reference = String(input_value);
        } else if (input_value.get_type() == Variant::DICTIONARY) {
            if (extract_reference_from_dictionary(input_value, field_reference)) {
                // Intentionally keep empty reference values out.
            }
        }
        if (!field_reference.is_empty()) {
            resolve_field_reference(field_reference);
        }
    }

    did_inject_handles = injected;
    if (!injected) {
        return {};
    }
    return field_handles;
}

Dictionary maybe_inject_field_handles_into_environment_inputs(
    const Dictionary &environment_payload,
    IFieldRegistry *registry
) {
    const Dictionary source_inputs = environment_payload.get("inputs", Dictionary());
    if (source_inputs.is_empty()) {
        return source_inputs;
    }

    bool did_inject_handles = false;
    const Array field_handles = collect_input_field_handles(source_inputs, registry, did_inject_handles);
    if (!did_inject_handles) {
        return source_inputs;
    }

    Dictionary pipeline_inputs = source_inputs.duplicate(true);
    pipeline_inputs["field_handles"] = field_handles;
    return pipeline_inputs;
}

Dictionary extract_pipeline_feedback(const Dictionary &pipeline_result) {
    const Variant feedback = pipeline_result.get("physics_server_feedback", Dictionary());
    if (feedback.get_type() == Variant::DICTIONARY) {
        return feedback;
    }
    return Dictionary();
}

String as_status_text(const Variant &value, const String &fallback) {
    if (value.get_type() == Variant::STRING) {
        return String(value);
    }
    if (value.get_type() == Variant::STRING_NAME) {
        return String(static_cast<StringName>(value));
    }
    return fallback;
}

double as_status_float(const Variant &value, double fallback) {
    if (value.get_type() == Variant::FLOAT) {
        return static_cast<double>(value);
    }
    if (value.get_type() == Variant::INT) {
        return static_cast<double>(static_cast<int64_t>(value));
    }
    return fallback;
}

int64_t as_status_int(const Variant &value, int64_t fallback) {
    if (value.get_type() == Variant::INT) {
        return static_cast<int64_t>(value);
    }
    if (value.get_type() == Variant::FLOAT) {
        return static_cast<int64_t>(static_cast<double>(value));
    }
    return fallback;
}

int32_t clamp_to_bucket(double value, int32_t bucket_count) {
    if (!std::isfinite(value) || bucket_count <= 0) {
        return 0;
    }
    const double bounded_value = std::fabs(value);
    const double wrapped = std::fmod(bounded_value, static_cast<double>(bucket_count));
    const int64_t bucket = static_cast<int64_t>(std::floor(wrapped + 1.0e-12));
    return static_cast<int32_t>(std::max<int64_t>(0, std::min<int64_t>(bucket_count - 1, bucket)));
}

ImpactFractureProfile read_impact_fracture_profile(const Dictionary &configuration) {
    ImpactFractureProfile profile;
    if (configuration.has("impact_signal_gain")) {
        const double signal_gain = get_numeric_dictionary_value(configuration, StringName("impact_signal_gain"));
        if (signal_gain >= kImpactSignalGainMin) {
            profile.impact_signal_gain = signal_gain;
        }
    }
    if (configuration.has("watch_signal_threshold")) {
        const double watch_signal_threshold = get_numeric_dictionary_value(configuration, StringName("watch_signal_threshold"));
        if (watch_signal_threshold > 0.0) {
            profile.watch_signal_threshold = watch_signal_threshold;
        }
    }
    if (configuration.has("active_signal_threshold")) {
        const double active_signal_threshold = get_numeric_dictionary_value(configuration, StringName("active_signal_threshold"));
        if (active_signal_threshold > 0.0) {
            profile.active_signal_threshold = active_signal_threshold;
        }
    }
    if (configuration.has("fracture_radius_base")) {
        const double fracture_radius_base = get_numeric_dictionary_value(configuration, StringName("fracture_radius_base"));
        if (fracture_radius_base > 0.0) {
            profile.fracture_radius_base = fracture_radius_base;
        }
    }
    if (configuration.has("fracture_radius_gain")) {
        const double fracture_radius_gain = get_numeric_dictionary_value(configuration, StringName("fracture_radius_gain"));
        if (fracture_radius_gain >= 0.0) {
            profile.fracture_radius_gain = fracture_radius_gain;
        }
    }
    if (configuration.has("fracture_radius_max")) {
        const double fracture_radius_max = get_numeric_dictionary_value(configuration, StringName("fracture_radius_max"));
        if (fracture_radius_max > 0.0) {
            profile.fracture_radius_max = fracture_radius_max;
        }
    }
    if (configuration.has("fracture_value_softness")) {
        const double fracture_value_softness = get_numeric_dictionary_value(configuration, StringName("fracture_value_softness"));
        if (fracture_value_softness > 0.0) {
            profile.fracture_value_softness = fracture_value_softness;
        }
    }
    if (configuration.has("fracture_value_cap")) {
        const double fracture_value_cap = get_numeric_dictionary_value(configuration, StringName("fracture_value_cap"));
        if (fracture_value_cap > 0.0 && fracture_value_cap <= 1.0) {
            profile.fracture_value_cap = fracture_value_cap;
        }
    }
    if (profile.watch_signal_threshold >= profile.active_signal_threshold) {
        profile.watch_signal_threshold = std::max(
            0.1,
            std::min(profile.watch_signal_threshold, profile.active_signal_threshold - 0.1)
        );
    }
    return profile;
}

} // namespace

LocalAgentsSimulationCore::LocalAgentsSimulationCore() {
    field_registry_ = std::make_unique<LocalAgentsFieldRegistry>();
    scheduler_ = std::make_unique<LocalAgentsScheduler>();
    compute_manager_ = std::make_unique<LocalAgentsComputeManager>();
    query_service_ = std::make_unique<LocalAgentsQueryService>();
    sim_profiler_ = std::make_unique<LocalAgentsSimProfiler>();
    voxel_edit_engine_ = std::make_unique<VoxelEditEngine>();
    physics_contact_capacity_ = kDefaultPhysicsContactCapacity;
}

LocalAgentsSimulationCore::~LocalAgentsSimulationCore() = default;

void LocalAgentsSimulationCore::_bind_methods() {
    ClassDB::bind_method(D_METHOD("register_field", "field_name", "field_config"),
                         &LocalAgentsSimulationCore::register_field, DEFVAL(Dictionary()));
    ClassDB::bind_method(D_METHOD("create_field_handle", "field_name"),
                         &LocalAgentsSimulationCore::create_field_handle);
    ClassDB::bind_method(D_METHOD("resolve_field_handle", "handle_id"),
                         &LocalAgentsSimulationCore::resolve_field_handle);
    ClassDB::bind_method(D_METHOD("list_field_handles_snapshot"),
                         &LocalAgentsSimulationCore::list_field_handles_snapshot);
    ClassDB::bind_method(D_METHOD("register_system", "system_name", "system_config"),
                         &LocalAgentsSimulationCore::register_system, DEFVAL(Dictionary()));

    ClassDB::bind_method(D_METHOD("configure", "simulation_config"),
                         &LocalAgentsSimulationCore::configure, DEFVAL(Dictionary()));
    ClassDB::bind_method(D_METHOD("configure_field_registry", "field_registry_config"),
                         &LocalAgentsSimulationCore::configure_field_registry, DEFVAL(Dictionary()));
    ClassDB::bind_method(D_METHOD("configure_scheduler", "scheduler_config"),
                         &LocalAgentsSimulationCore::configure_scheduler, DEFVAL(Dictionary()));
    ClassDB::bind_method(D_METHOD("configure_compute_manager", "compute_config"),
                         &LocalAgentsSimulationCore::configure_compute_manager, DEFVAL(Dictionary()));

    ClassDB::bind_method(D_METHOD("step_simulation", "delta_seconds", "step_index"),
                         &LocalAgentsSimulationCore::step_simulation);
    ClassDB::bind_method(D_METHOD("step_structure_lifecycle", "step_index"),
                         &LocalAgentsSimulationCore::step_structure_lifecycle);
    ClassDB::bind_method(D_METHOD("enqueue_environment_voxel_edit_op", "stage_name", "op_payload"),
                         &LocalAgentsSimulationCore::enqueue_environment_voxel_edit_op, DEFVAL(Dictionary()));
    ClassDB::bind_method(D_METHOD("enqueue_voxel_edit_op", "stage_name", "op_payload"),
                         &LocalAgentsSimulationCore::enqueue_voxel_edit_op, DEFVAL(Dictionary()));
    ClassDB::bind_method(D_METHOD("apply_environment_stage", "stage_name", "payload"),
                         &LocalAgentsSimulationCore::apply_environment_stage, DEFVAL(Dictionary()));
    ClassDB::bind_method(D_METHOD("apply_voxel_stage", "stage_name", "payload"),
                         &LocalAgentsSimulationCore::apply_voxel_stage, DEFVAL(Dictionary()));
    ClassDB::bind_method(D_METHOD("execute_environment_stage", "stage_name", "payload"),
                         &LocalAgentsSimulationCore::execute_environment_stage, DEFVAL(Dictionary()));
    ClassDB::bind_method(D_METHOD("execute_voxel_stage", "stage_name", "payload"),
                         &LocalAgentsSimulationCore::execute_voxel_stage, DEFVAL(Dictionary()));
    ClassDB::bind_method(D_METHOD("ingest_physics_contacts", "contact_rows"),
                         &LocalAgentsSimulationCore::ingest_physics_contacts);
    ClassDB::bind_method(D_METHOD("clear_physics_contacts"), &LocalAgentsSimulationCore::clear_physics_contacts);
    ClassDB::bind_method(D_METHOD("get_physics_contact_snapshot"),
                         &LocalAgentsSimulationCore::get_physics_contact_snapshot);
    ClassDB::bind_method(D_METHOD("get_debug_snapshot"), &LocalAgentsSimulationCore::get_debug_snapshot);
    ClassDB::bind_method(D_METHOD("reset"), &LocalAgentsSimulationCore::reset);
}

bool LocalAgentsSimulationCore::register_field(const StringName &field_name, const Dictionary &field_config) {
    return field_registry_ && field_registry_->register_field(field_name, field_config);
}

Dictionary LocalAgentsSimulationCore::create_field_handle(const StringName &field_name) {
    if (!field_registry_) {
        Dictionary result;
        result["ok"] = false;
        result["error"] = String("field_registry_uninitialized");
        return result;
    }
    return field_registry_->create_field_handle(field_name);
}

Dictionary LocalAgentsSimulationCore::resolve_field_handle(const StringName &handle_id) const {
    if (!field_registry_) {
        Dictionary result;
        result["ok"] = false;
        result["error"] = String("field_registry_uninitialized");
        return result;
    }
    return field_registry_->resolve_field_handle(handle_id);
}

Dictionary LocalAgentsSimulationCore::list_field_handles_snapshot() const {
    if (!field_registry_) {
        Dictionary result;
        result["ok"] = false;
        result["error"] = String("field_registry_uninitialized");
        return result;
    }
    return field_registry_->list_field_handles_snapshot();
}

bool LocalAgentsSimulationCore::register_system(const StringName &system_name, const Dictionary &system_config) {
    return scheduler_ && scheduler_->register_system(system_name, system_config);
}

bool LocalAgentsSimulationCore::configure(const Dictionary &simulation_config) {
    if (!field_registry_ || !scheduler_ || !compute_manager_ || !voxel_edit_engine_) {
        return false;
    }

    Dictionary field_registry_config = simulation_config.get("field_registry", Dictionary());
    Dictionary scheduler_config = simulation_config.get("scheduler", Dictionary());
    Dictionary compute_config = simulation_config.get("compute", Dictionary());
    Dictionary voxel_edit_config = simulation_config.get("voxel_edit", Dictionary());
    const Dictionary impact_fracture_config = simulation_config.has("impact_fracture")
        ? simulation_config.get("impact_fracture", Dictionary())
        : simulation_config;
    const ImpactFractureProfile profile = read_impact_fracture_profile(impact_fracture_config);
    impact_signal_gain_ = profile.impact_signal_gain;
    impact_watch_signal_threshold_ = profile.watch_signal_threshold;
    impact_active_signal_threshold_ = profile.active_signal_threshold;
    impact_radius_base_ = profile.fracture_radius_base;
    impact_radius_gain_ = profile.fracture_radius_gain;
    impact_radius_max_ = profile.fracture_radius_max;
    fracture_value_softness_ = profile.fracture_value_softness;
    fracture_value_cap_ = profile.fracture_value_cap;

    const bool field_ok = field_registry_->configure(field_registry_config);
    const bool scheduler_ok = scheduler_->configure(scheduler_config);
    const bool compute_ok = compute_manager_->configure(compute_config);
    const bool voxel_edit_ok = voxel_edit_engine_->configure(voxel_edit_config);
    return field_ok && scheduler_ok && compute_ok && voxel_edit_ok;
}

bool LocalAgentsSimulationCore::configure_field_registry(const Dictionary &field_registry_config) {
    if (!field_registry_) {
        return false;
    }
    return field_registry_->configure(field_registry_config);
}

bool LocalAgentsSimulationCore::configure_scheduler(const Dictionary &scheduler_config) {
    return scheduler_ && scheduler_->configure(scheduler_config);
}

bool LocalAgentsSimulationCore::configure_compute_manager(const Dictionary &compute_config) {
    return compute_manager_ && compute_manager_->configure(compute_config);
}

Dictionary LocalAgentsSimulationCore::step_simulation(double delta_seconds, int64_t step_index) {
    Dictionary result;
    if (!scheduler_ || !compute_manager_ || !sim_profiler_) {
        result["ok"] = false;
        result["error"] = String("simulation_core_uninitialized");
        return result;
    }

    sim_profiler_->begin_step(step_index, delta_seconds);
    Dictionary scheduled_frame = scheduler_->step(delta_seconds, step_index);
    Dictionary compute_result = compute_manager_->execute_step(scheduled_frame);
    sim_profiler_->end_step(step_index, delta_seconds, compute_result);

    result["ok"] = true;
    result["step_index"] = step_index;
    result["delta_seconds"] = delta_seconds;
    result["schedule"] = scheduled_frame;
    result["compute"] = compute_result;
    return result;
}

Dictionary LocalAgentsSimulationCore::step_structure_lifecycle(int64_t step_index) {
    Dictionary result;
    result["ok"] = true;
    result["step_index"] = step_index;
    result["expanded"] = Array();
    result["abandoned"] = Array();
    return result;
}

Dictionary LocalAgentsSimulationCore::enqueue_environment_voxel_edit_op(
    const StringName &stage_name,
    const Dictionary &op_payload
) {
    if (!voxel_edit_engine_) {
        Dictionary result;
        result["ok"] = false;
        result["error"] = String("voxel_edit_engine_uninitialized");
        return result;
    }
    return voxel_edit_engine_->enqueue_op(String("environment"), stage_name, op_payload);
}

Dictionary LocalAgentsSimulationCore::enqueue_voxel_edit_op(const StringName &stage_name, const Dictionary &op_payload) {
    if (!voxel_edit_engine_) {
        Dictionary result;
        result["ok"] = false;
        result["error"] = String("voxel_edit_engine_uninitialized");
        return result;
    }
    return voxel_edit_engine_->enqueue_op(String("voxel"), stage_name, op_payload);
}

Dictionary LocalAgentsSimulationCore::apply_environment_stage(const StringName &stage_name, const Dictionary &payload) {
    if (!voxel_edit_engine_) {
        Dictionary result;
        result["ok"] = false;
        result["error"] = String("voxel_edit_engine_uninitialized");
        return result;
    }

    Dictionary effective_payload = payload.duplicate(true);
    if (!effective_payload.has("physics_contacts") && !physics_contact_rows_.is_empty()) {
        effective_payload["physics_contacts"] = get_physics_contact_snapshot();
    }

    environment_stage_dispatch_count_ += 1;
    const int64_t stage_dispatch_count = increment_stage_counter(environment_stage_counters_, stage_name);
    Dictionary result = voxel_edit_engine_->execute_stage(String("environment"), stage_name, effective_payload);
    if (compute_manager_) {
        Dictionary scheduled_frame;
        const ImpactFractureProfile fracture_profile = {
            impact_signal_gain_,
            impact_watch_signal_threshold_,
            impact_active_signal_threshold_,
            impact_radius_base_,
            impact_radius_gain_,
            impact_radius_max_,
            fracture_value_softness_,
            fracture_value_cap_
        };
        const Dictionary scheduled_frame_inputs = maybe_inject_field_handles_into_environment_inputs(effective_payload, field_registry_.get());
        scheduled_frame["ok"] = true;
        scheduled_frame["step_index"] = static_cast<int64_t>(environment_stage_dispatch_count_);
        scheduled_frame["delta_seconds"] = static_cast<double>(effective_payload.get("delta", 0.0));
        scheduled_frame["stage_name"] = String(stage_name);
        scheduled_frame["inputs"] = scheduled_frame_inputs;
        const Dictionary pipeline_result = compute_manager_->execute_step(scheduled_frame);
        result["pipeline"] = pipeline_result;
        result["physics_server_feedback"] = extract_pipeline_feedback(pipeline_result);

        Dictionary voxel_failure_emission = build_voxel_failure_emission_plan(
            extract_pipeline_feedback(pipeline_result),
            physics_contact_rows_,
            fracture_profile.impact_signal_gain,
            fracture_profile.watch_signal_threshold,
            fracture_profile.active_signal_threshold,
            fracture_profile.fracture_radius_base,
            fracture_profile.fracture_radius_gain,
            fracture_profile.fracture_radius_max,
            fracture_profile.fracture_value_softness,
            fracture_profile.fracture_value_cap);
        const String failure_emission_status = as_status_text(voxel_failure_emission.get("status", String("disabled")), String("disabled"));
        if (failure_emission_status == String("planned")) {
            const Array op_payloads = voxel_failure_emission.get("op_payloads", Array());
            // Planner contract:
            // - `target_domain` + `stage_name` are the single routing keys the core executes.
            // - `op_payloads` is the operation source of truth.
            const String plan_target_domain = as_status_text(
                voxel_failure_emission.get("target_domain", String("environment")),
                String("environment"));
            const String plan_stage_name = as_status_text(
                voxel_failure_emission.get("stage_name", String("physics_failure_emission")),
                String("physics_failure_emission"));
            Array enqueue_results;
            bool enqueued_all = true;
            for (int64_t i = 0; i < op_payloads.size(); i++) {
                const Variant op_variant = op_payloads[i];
                if (op_variant.get_type() != Variant::DICTIONARY) {
                    continue;
                }
                const Dictionary op_payload = op_variant;
                const Dictionary enqueue_result = voxel_edit_engine_->enqueue_op(
                    plan_target_domain,
                    StringName(plan_stage_name),
                    op_payload);
                enqueue_results.append(enqueue_result);
                enqueued_all = enqueued_all && bool(enqueue_result.get("ok", false));
            }
            voxel_failure_emission["enqueues"] = enqueue_results;
            if (enqueued_all) {
                Dictionary emission_payload;
                emission_payload["source_stage"] = String(stage_name);
                emission_payload["feedback_status"] = result.get("physics_server_feedback", Dictionary());
                const Dictionary feedback_reference = result.get("physics_server_feedback", Dictionary());
                emission_payload["failure_feedback"] = feedback_reference.is_empty() ? Dictionary() : feedback_reference.get("failure_feedback", Dictionary());
                emission_payload["failure_source"] = feedback_reference.is_empty() ? Dictionary() : feedback_reference.get("failure_source", Dictionary());
                emission_payload["destruction_feedback"] = feedback_reference.is_empty() ? Dictionary() : feedback_reference.get("destruction", Dictionary());
                const Dictionary execution = voxel_edit_engine_->execute_stage(
                    plan_target_domain,
                    StringName(plan_stage_name),
                    emission_payload);
                voxel_failure_emission["execution"] = execution;
                if (bool(execution.get("ok", false))) {
                    voxel_failure_emission["status"] = String("executed");
                    voxel_failure_emission["reason"] = as_status_text(voxel_failure_emission.get("reason", String("active_failure")), String("active_failure"));
                    voxel_failure_emission["executed_op_count"] = static_cast<int64_t>(execution.get("ops_changed", static_cast<int64_t>(0)));
                } else {
                    voxel_failure_emission["status"] = String("failed");
                    voxel_failure_emission["reason"] = String("voxel_execution_failed");
                    voxel_failure_emission["executed_op_count"] = static_cast<int64_t>(0);
                }
            } else {
                voxel_failure_emission["status"] = String("failed");
                voxel_failure_emission["reason"] = String("voxel_enqueue_failed");
                voxel_failure_emission["executed_op_count"] = static_cast<int64_t>(0);
            }
        }
        result["voxel_failure_emission"] = voxel_failure_emission;
    } else {
        const ImpactFractureProfile fracture_profile = {
            impact_signal_gain_,
            impact_watch_signal_threshold_,
            impact_active_signal_threshold_,
            impact_radius_base_,
            impact_radius_gain_,
            impact_radius_max_,
            fracture_value_softness_,
            fracture_value_cap_
        };
        Dictionary disabled_voxel_emission = build_voxel_failure_emission_plan(
            Dictionary(),
            Array(),
            fracture_profile.impact_signal_gain,
            fracture_profile.watch_signal_threshold,
            fracture_profile.active_signal_threshold,
            fracture_profile.fracture_radius_base,
            fracture_profile.fracture_radius_gain,
            fracture_profile.fracture_radius_max,
            fracture_profile.fracture_value_softness,
            fracture_profile.fracture_value_cap);
        disabled_voxel_emission["reason"] = String("compute_manager_unavailable");
        disabled_voxel_emission["status"] = String("disabled");
        result["voxel_failure_emission"] = disabled_voxel_emission;
    }
    result["counters"] = build_stage_dispatch_counters(environment_stage_dispatch_count_, stage_dispatch_count);
    return result;
}

Dictionary LocalAgentsSimulationCore::apply_voxel_stage(const StringName &stage_name, const Dictionary &payload) {
    if (!voxel_edit_engine_) {
        Dictionary result;
        result["ok"] = false;
        result["error"] = String("voxel_edit_engine_uninitialized");
        return result;
    }

    voxel_stage_dispatch_count_ += 1;
    const int64_t stage_dispatch_count = increment_stage_counter(voxel_stage_counters_, stage_name);
    Dictionary result = voxel_edit_engine_->execute_stage(String("voxel"), stage_name, payload);
    result["counters"] = build_stage_dispatch_counters(voxel_stage_dispatch_count_, stage_dispatch_count);
    return result;
}

Dictionary LocalAgentsSimulationCore::execute_environment_stage(const StringName &stage_name, const Dictionary &payload) {
    return apply_environment_stage(stage_name, payload);
}

Dictionary LocalAgentsSimulationCore::execute_voxel_stage(const StringName &stage_name, const Dictionary &payload) {
    return apply_voxel_stage(stage_name, payload);
}

Dictionary LocalAgentsSimulationCore::ingest_physics_contacts(const Array &contact_rows) {
    Dictionary result;
    if (physics_contact_capacity_ <= 0) {
        result["ok"] = false;
        result["error"] = String("physics_contact_capacity_invalid");
        return result;
    }

    int64_t accepted = 0;
    int64_t dropped = 0;
    for (int64_t i = 0; i < contact_rows.size(); i++) {
        const Dictionary normalized = normalize_contact_row(contact_rows[i]);
        if (normalized.is_empty()) {
            continue;
        }
        const double impulse = static_cast<double>(normalized.get("impulse", 0.0));
        const double relative_speed = static_cast<double>(normalized.get("relative_speed", 0.0));
        physics_contact_total_impulse_ += impulse;
        physics_contact_total_relative_speed_ += relative_speed;
        if (impulse > physics_contact_max_impulse_) {
            physics_contact_max_impulse_ = impulse;
        }

        physics_contact_rows_.append(normalized);
        physics_contact_rows_ingested_total_ += 1;
        accepted += 1;
        while (physics_contact_rows_.size() > physics_contact_capacity_) {
            physics_contact_rows_.remove_at(0);
            physics_contact_rows_dropped_total_ += 1;
            dropped += 1;
        }
    }
    physics_contact_batches_ingested_ += 1;

    result["ok"] = true;
    result["accepted_rows"] = accepted;
    result["dropped_rows"] = dropped;
    result["snapshot"] = get_physics_contact_snapshot();
    return result;
}

void LocalAgentsSimulationCore::clear_physics_contacts() {
    physics_contact_rows_.clear();
    physics_contact_batches_ingested_ = 0;
    physics_contact_rows_ingested_total_ = 0;
    physics_contact_rows_dropped_total_ = 0;
    physics_contact_total_impulse_ = 0.0;
    physics_contact_max_impulse_ = 0.0;
    physics_contact_total_relative_speed_ = 0.0;
}

Dictionary LocalAgentsSimulationCore::get_physics_contact_snapshot() const {
    Dictionary snapshot;
    const int64_t buffered_count = physics_contact_rows_.size();
    snapshot["buffered_rows"] = physics_contact_rows_.duplicate(true);
    snapshot["buffered_count"] = buffered_count;
    snapshot["capacity"] = physics_contact_capacity_;
    snapshot["batches_ingested"] = physics_contact_batches_ingested_;
    snapshot["rows_ingested_total"] = physics_contact_rows_ingested_total_;
    snapshot["rows_dropped_total"] = physics_contact_rows_dropped_total_;
    snapshot["total_impulse"] = physics_contact_total_impulse_;
    snapshot["max_impulse"] = physics_contact_max_impulse_;
    snapshot["total_relative_speed"] = physics_contact_total_relative_speed_;
    snapshot["average_impulse"] = physics_contact_rows_ingested_total_ > 0
        ? physics_contact_total_impulse_ / static_cast<double>(physics_contact_rows_ingested_total_)
        : 0.0;
    snapshot["average_relative_speed"] = physics_contact_rows_ingested_total_ > 0
        ? physics_contact_total_relative_speed_ / static_cast<double>(physics_contact_rows_ingested_total_)
        : 0.0;
    return snapshot;
}

Dictionary LocalAgentsSimulationCore::get_debug_snapshot() const {
    if (!field_registry_ || !scheduler_ || !compute_manager_ || !query_service_ || !sim_profiler_) {
        Dictionary snapshot;
        snapshot["ok"] = false;
        snapshot["error"] = String("simulation_core_uninitialized");
        return snapshot;
    }

    Dictionary snapshot = query_service_->build_debug_snapshot(
        *field_registry_,
        *scheduler_,
        *compute_manager_,
        *sim_profiler_
    );
    Dictionary stage_dispatch;
    stage_dispatch["environment_total"] = environment_stage_dispatch_count_;
    stage_dispatch["environment_stages"] = environment_stage_counters_.duplicate(true);
    stage_dispatch["voxel_total"] = voxel_stage_dispatch_count_;
    stage_dispatch["voxel_stages"] = voxel_stage_counters_.duplicate(true);
    snapshot["stage_dispatch"] = stage_dispatch;
    if (voxel_edit_engine_) {
        snapshot["voxel_edit"] = voxel_edit_engine_->get_debug_snapshot();
    } else {
        snapshot["voxel_edit"] = Dictionary();
    }
    snapshot["physics_contacts"] = get_physics_contact_snapshot();
    snapshot["ok"] = true;
    return snapshot;
}

void LocalAgentsSimulationCore::reset() {
    if (field_registry_) {
        field_registry_->clear();
    }
    if (scheduler_) {
        scheduler_->reset();
    }
    if (compute_manager_) {
        compute_manager_->reset();
    }
    if (sim_profiler_) {
        sim_profiler_->reset();
    }
    if (voxel_edit_engine_) {
        voxel_edit_engine_->reset();
    }
    clear_physics_contacts();
    environment_stage_dispatch_count_ = 0;
    voxel_stage_dispatch_count_ = 0;
    environment_stage_counters_.clear();
    voxel_stage_counters_.clear();
}
