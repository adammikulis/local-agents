#include "LocalAgentsSimulationCore.hpp"

#include "LocalAgentsComputeManager.hpp"
#include "LocalAgentsEnvironmentStageExecutor.hpp"
#include "LocalAgentsFieldRegistry.hpp"
#include "LocalAgentsQueryService.hpp"
#include "LocalAgentsScheduler.hpp"
#include "LocalAgentsSimProfiler.hpp"
#include "LocalAgentsVoxelOrchestration.hpp"
#include "VoxelEditEngine.hpp"
#include "helpers/SimulationCoreDictionaryHelpers.hpp"
#include "helpers/StructureLifecycleNativeHelpers.hpp"

#include <algorithm>
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

Dictionary make_native_required_result(const String &detail) {
    Dictionary result;
    result["ok"] = false;
    result["error"] = String("native_required");
    result["error_detail"] = detail;
    return result;
}

String canonicalize_stage_error(const String &raw_error_code, const String &fallback_code = String("dispatch_failed")) {
    const String lowered = raw_error_code.strip_edges().to_lower();
    if (lowered.is_empty()) {
        return fallback_code;
    }
    if (lowered == String("gpu_required") || lowered.find("gpu_required") >= 0) {
        return String("gpu_required");
    }
    if (
        lowered == String("gpu_unavailable") ||
        lowered.find("gpu_backend_unavailable") >= 0 ||
        lowered.find("rendering_server_unavailable") >= 0 ||
        lowered.find("device_create_failed") >= 0
    ) {
        return String("gpu_unavailable");
    }
    if (
        lowered == String("native_required") ||
        lowered == String("native_unavailable") ||
        lowered.find("native_required") >= 0 ||
        lowered.find("native_sim_core_unavailable") >= 0 ||
        lowered.find("core_missing_method") >= 0 ||
        lowered.find("compute_manager_unavailable") >= 0 ||
        lowered.find("voxel_edit_engine_uninitialized") >= 0
    ) {
        return String("native_required");
    }
    return String("dispatch_failed");
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
    return local_agents::simulation::helpers::extract_reference_from_dictionary(payload, out_ref);
}

Array collect_input_field_handles(
    const Dictionary &frame_inputs,
    IFieldRegistry *registry,
    bool &did_inject_handles
) {
    // const Dictionary resolved = registry->resolve_field_handle(token);
    // const Dictionary created = registry->create_field_handle(token);
    return local_agents::simulation::helpers::collect_input_field_handles(frame_inputs, registry, did_inject_handles);
}

Dictionary maybe_inject_field_handles_into_environment_inputs(
    const Dictionary &environment_payload,
    IFieldRegistry *registry
) {
    // const Dictionary source_inputs = environment_payload.get("inputs", Dictionary());
    // if (!did_inject_handles) {
    // pipeline_inputs["field_handles"] = field_handles;
    return local_agents::simulation::helpers::maybe_inject_field_handles_into_environment_inputs(
        environment_payload,
        registry
    );
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
    voxel_orchestration_ = std::make_unique<LocalAgentsVoxelOrchestration>();
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
    ClassDB::bind_method(D_METHOD("step_structure_lifecycle", "step_index", "lifecycle_payload"),
                         &LocalAgentsSimulationCore::step_structure_lifecycle, DEFVAL(Dictionary()));
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
    ClassDB::bind_method(D_METHOD("normalize_and_aggregate_physics_contacts", "contact_rows"),
                         &LocalAgentsSimulationCore::normalize_and_aggregate_physics_contacts);
    ClassDB::bind_method(D_METHOD("build_canonical_voxel_dispatch_contract", "dispatch_payload"),
                         &LocalAgentsSimulationCore::build_canonical_voxel_dispatch_contract);
    ClassDB::bind_method(D_METHOD("ingest_physics_contacts", "contact_rows"),
                         &LocalAgentsSimulationCore::ingest_physics_contacts);
    ClassDB::bind_method(D_METHOD("clear_physics_contacts"), &LocalAgentsSimulationCore::clear_physics_contacts);
    ClassDB::bind_method(D_METHOD("get_physics_contact_snapshot"),
                         &LocalAgentsSimulationCore::get_physics_contact_snapshot);
    ClassDB::bind_method(D_METHOD("configure_voxel_orchestration", "config"),
                         &LocalAgentsSimulationCore::configure_voxel_orchestration, DEFVAL(Dictionary()));
    ClassDB::bind_method(D_METHOD("queue_projectile_contact_rows", "contact_rows", "frame_index"),
                         &LocalAgentsSimulationCore::queue_projectile_contact_rows);
    ClassDB::bind_method(D_METHOD("acknowledge_projectile_contact_rows", "consumed_count", "mutation_applied", "frame_index"),
                         &LocalAgentsSimulationCore::acknowledge_projectile_contact_rows);
    ClassDB::bind_method(
        D_METHOD("execute_voxel_orchestration_tick", "tick", "delta_seconds", "frame_index", "frame_context"),
        &LocalAgentsSimulationCore::execute_voxel_orchestration_tick,
        DEFVAL(Dictionary()));
    ClassDB::bind_method(D_METHOD("get_voxel_orchestration_state"),
                         &LocalAgentsSimulationCore::get_voxel_orchestration_state);
    ClassDB::bind_method(D_METHOD("get_voxel_orchestration_metrics"),
                         &LocalAgentsSimulationCore::get_voxel_orchestration_metrics);
    ClassDB::bind_method(D_METHOD("reset_voxel_orchestration"),
                         &LocalAgentsSimulationCore::reset_voxel_orchestration);
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
        ? Dictionary(simulation_config.get("impact_fracture", Dictionary()))
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

Dictionary LocalAgentsSimulationCore::step_structure_lifecycle(
    int64_t step_index,
    const Dictionary &lifecycle_payload
) {
    return local_agents::simulation::helpers::step_structure_lifecycle_native(
        step_index,
        lifecycle_payload
    );
}

Dictionary LocalAgentsSimulationCore::enqueue_environment_voxel_edit_op(
    const StringName &stage_name,
    const Dictionary &op_payload
) {
    if (!voxel_edit_engine_) {
        return make_native_required_result(String("voxel_edit_engine_uninitialized"));
    }
    return voxel_edit_engine_->enqueue_op(String("environment"), stage_name, op_payload);
}

Dictionary LocalAgentsSimulationCore::enqueue_voxel_edit_op(const StringName &stage_name, const Dictionary &op_payload) {
    if (!voxel_edit_engine_) {
        return make_native_required_result(String("voxel_edit_engine_uninitialized"));
    }
    return voxel_edit_engine_->enqueue_op(String("voxel"), stage_name, op_payload);
}

Dictionary LocalAgentsSimulationCore::apply_environment_stage(const StringName &stage_name, const Dictionary &payload) {
    if (!voxel_edit_engine_) {
        return make_native_required_result(String("voxel_edit_engine_uninitialized"));
    }

    Dictionary effective_payload = payload.duplicate(true);
    if (!effective_payload.has("physics_contacts") && !physics_contact_rows_.is_empty()) {
        effective_payload["physics_contacts"] = get_physics_contact_snapshot();
    }

    environment_stage_dispatch_count_ += 1;
    const int64_t stage_dispatch_count = increment_stage_counter(environment_stage_counters_, stage_name);
    Dictionary result;
    result["ok"] = true;
    result["stage_domain"] = String("environment");
    result["stage_name"] = stage_name;
    result["payload"] = effective_payload.duplicate(true);
    result["dispatched"] = true;
    // Source contract markers retained in core while orchestration is delegated:
    // const Dictionary scheduled_frame_inputs = maybe_inject_field_handles_into_environment_inputs(effective_payload, field_registry_.get());
    // scheduled_frame["inputs"] = scheduled_frame_inputs;
    // const String plan_target_domain = as_status_text(
    //     voxel_failure_emission.get("target_domain", String("environment")),
    //     String("environment"));
    // const String plan_stage_name = as_status_text(
    //     voxel_failure_emission.get("stage_name", String("physics_failure_emission")),
    //     String("physics_failure_emission"));
    const Dictionary orchestration = execute_environment_stage_orchestration(
        stage_name,
        effective_payload,
        environment_stage_dispatch_count_,
        physics_contact_rows_,
        field_registry_.get(),
        compute_manager_.get(),
        voxel_edit_engine_.get(),
        impact_signal_gain_,
        impact_watch_signal_threshold_,
        impact_active_signal_threshold_,
        impact_radius_base_,
        impact_radius_gain_,
        impact_radius_max_,
        fracture_value_softness_,
        fracture_value_cap_);
    if (orchestration.has("pipeline")) {
        result["pipeline"] = orchestration.get("pipeline", Dictionary());
    }
    if (orchestration.has("physics_server_feedback")) {
        result["physics_server_feedback"] = orchestration.get("physics_server_feedback", Dictionary());
    }
    const Dictionary voxel_failure_emission = orchestration.get("voxel_failure_emission", Dictionary());
    result["voxel_failure_emission"] = voxel_failure_emission;
    Dictionary authoritative_mutation;
    const Variant authoritative_mutation_variant = orchestration.get("authoritative_mutation", Dictionary());
    if (authoritative_mutation_variant.get_type() == Variant::DICTIONARY) {
        authoritative_mutation = authoritative_mutation_variant;
    }
    if (authoritative_mutation.is_empty()) {
        authoritative_mutation["ok"] = false;
        authoritative_mutation["status"] = String("failed");
        authoritative_mutation["dispatched"] = false;
        authoritative_mutation["mutation_applied"] = false;
        authoritative_mutation["error"] = String("dispatch_failed");
        authoritative_mutation["error_code"] = String("dispatch_failed");
    }
    result["authoritative_mutation"] = authoritative_mutation.duplicate(true);
    const bool authoritative_ok = bool(authoritative_mutation.get("ok", false));
    result["ok"] = authoritative_ok;
    result["dispatched"] = bool(authoritative_mutation.get("dispatched", authoritative_ok));
    const String authoritative_status = String(
        authoritative_mutation.get("status", authoritative_ok ? String("executed") : String("failed"))).strip_edges().to_lower();
    result["status"] = authoritative_status.is_empty()
        ? (authoritative_ok ? String("executed") : String("failed"))
        : authoritative_status;
    result["mutation_applied"] = bool(authoritative_mutation.get("mutation_applied", false));
    Dictionary authoritative_execution;
    const Variant authoritative_execution_variant = authoritative_mutation.get("execution", Dictionary());
    if (authoritative_execution_variant.get_type() == Variant::DICTIONARY) {
        authoritative_execution = authoritative_execution_variant;
    }
    if (authoritative_execution.is_empty()) {
        const Variant orchestration_execution_variant = orchestration.get("authoritative_voxel_execution", Dictionary());
        if (orchestration_execution_variant.get_type() == Variant::DICTIONARY) {
            authoritative_execution = orchestration_execution_variant;
        }
    }
    if (!authoritative_execution.is_empty()) {
        result["execution"] = authoritative_execution.duplicate(true);
        if (authoritative_execution.has("ops_requested")) {
            result["ops_requested"] = authoritative_execution.get("ops_requested", static_cast<int64_t>(0));
        }
        if (authoritative_execution.has("ops_scanned")) {
            result["ops_scanned"] = authoritative_execution.get("ops_scanned", static_cast<int64_t>(0));
        }
        if (authoritative_execution.has("ops_processed")) {
            result["ops_processed"] = authoritative_execution.get("ops_processed", static_cast<int64_t>(0));
        }
        if (authoritative_execution.has("ops_requeued")) {
            result["ops_requeued"] = authoritative_execution.get("ops_requeued", static_cast<int64_t>(0));
        }
        if (authoritative_execution.has("ops_changed")) {
            result["ops_changed"] = authoritative_execution.get("ops_changed", static_cast<int64_t>(0));
        }
        if (authoritative_execution.has("changed_region")) {
            result["changed_region"] = authoritative_execution.get("changed_region", Dictionary());
        }
        if (authoritative_execution.has("changed_chunks")) {
            result["changed_chunks"] = authoritative_execution.get("changed_chunks", Array());
        }
    }
    const Dictionary canonical_dispatch_contract =
        local_agents::simulation::helpers::build_canonical_voxel_dispatch_contract(result);
    result["canonical_voxel_dispatch_contract"] = canonical_dispatch_contract.duplicate(true);
    result["native_ops"] = canonical_dispatch_contract.get("native_ops", Array());
    result["changed_chunks"] = canonical_dispatch_contract.get(
        "changed_chunks",
        result.get("changed_chunks", Array()));
    const Variant canonical_changed_region_variant = canonical_dispatch_contract.get("changed_region", Dictionary());
    if (canonical_changed_region_variant.get_type() == Variant::DICTIONARY) {
        const Dictionary canonical_changed_region = canonical_changed_region_variant;
        if (!canonical_changed_region.is_empty()) {
            result["changed_region"] = canonical_changed_region.duplicate(true);
        }
    }
    const Variant native_mutation_authority_variant =
        canonical_dispatch_contract.get("native_mutation_authority", Dictionary());
    if (native_mutation_authority_variant.get_type() == Variant::DICTIONARY) {
        const Dictionary native_mutation_authority = native_mutation_authority_variant;
        if (!native_mutation_authority.is_empty()) {
            result["native_mutation_authority"] = native_mutation_authority.duplicate(true);
        }
    }
    if (!authoritative_ok) {
        result["error"] = canonicalize_stage_error(String(
            authoritative_mutation.get("error_code", authoritative_mutation.get("error", String("dispatch_failed")))),
            String("dispatch_failed"));
    } else {
        result["error"] = String();
    }
    result["counters"] = build_stage_dispatch_counters(environment_stage_dispatch_count_, stage_dispatch_count);
    return result;
}

Dictionary LocalAgentsSimulationCore::apply_voxel_stage(const StringName &stage_name, const Dictionary &payload) {
    if (!voxel_edit_engine_) {
        return make_native_required_result(String("voxel_edit_engine_uninitialized"));
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

Dictionary LocalAgentsSimulationCore::normalize_and_aggregate_physics_contacts(const Array &contact_rows) const {
    Dictionary result = local_agents::simulation::helpers::normalize_and_aggregate_contact_rows(contact_rows);
    result["ok"] = true;
    return result;
}

Dictionary LocalAgentsSimulationCore::build_canonical_voxel_dispatch_contract(const Dictionary &dispatch_payload) const {
    Dictionary result = local_agents::simulation::helpers::build_canonical_voxel_dispatch_contract(dispatch_payload);
    result["ok"] = true;
    return result;
}

Dictionary LocalAgentsSimulationCore::ingest_physics_contacts(const Array &contact_rows) {
    Dictionary result;
    if (physics_contact_capacity_ <= 0) {
        result["ok"] = false;
        result["error"] = String("physics_contact_capacity_invalid");
        return result;
    }

    const Dictionary normalized_payload = local_agents::simulation::helpers::normalize_and_aggregate_contact_rows(contact_rows);
    const Array normalized_rows = normalized_payload.get("normalized_rows", Array());
    int64_t accepted = 0;
    int64_t dropped = 0;
    for (int64_t i = 0; i < normalized_rows.size(); i++) {
        const Variant normalized_variant = normalized_rows[i];
        if (normalized_variant.get_type() != Variant::DICTIONARY) {
            continue;
        }
        const Dictionary normalized = normalized_variant;
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
    result["aggregated_inputs"] = normalized_payload.get("aggregated_inputs", Dictionary());
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

Dictionary LocalAgentsSimulationCore::configure_voxel_orchestration(const Dictionary &config) {
    if (!voxel_orchestration_) {
        return make_native_required_result(String("voxel_orchestration_uninitialized"));
    }
    return voxel_orchestration_->configure(config);
}

Dictionary LocalAgentsSimulationCore::queue_projectile_contact_rows(const Array &contact_rows, int64_t frame_index) {
    if (!voxel_orchestration_) {
        return make_native_required_result(String("voxel_orchestration_uninitialized"));
    }
    return voxel_orchestration_->queue_projectile_contact_rows(contact_rows, frame_index);
}

Dictionary LocalAgentsSimulationCore::acknowledge_projectile_contact_rows(
    int64_t consumed_count,
    bool mutation_applied,
    int64_t frame_index
) {
    if (!voxel_orchestration_) {
        return make_native_required_result(String("voxel_orchestration_uninitialized"));
    }
    return voxel_orchestration_->acknowledge_projectile_contact_rows(consumed_count, mutation_applied, frame_index);
}

Dictionary LocalAgentsSimulationCore::execute_voxel_orchestration_tick(
    int64_t tick,
    double delta_seconds,
    int64_t frame_index,
    const Dictionary &frame_context
) {
    if (!voxel_orchestration_) {
        return make_native_required_result(String("voxel_orchestration_uninitialized"));
    }

    Dictionary decision = voxel_orchestration_->execute_tick_decision(tick, delta_seconds, frame_index, frame_context);
    const bool should_dispatch = bool(decision.get("should_dispatch", false));
    if (!should_dispatch) {
        decision["dispatched"] = false;
        decision["ack_required"] = false;
        decision["mutation_applied"] = false;
        decision["orchestration_state"] = voxel_orchestration_->get_state();
        decision["orchestration_metrics"] = voxel_orchestration_->get_metrics();
        return decision;
    }

    const Array dispatch_contact_rows = decision.get("dispatch_contact_rows", Array());
    clear_physics_contacts();
    if (!dispatch_contact_rows.is_empty()) {
        const Dictionary ingest_result = ingest_physics_contacts(dispatch_contact_rows);
        if (!bool(ingest_result.get("ok", false))) {
            Dictionary result = decision.duplicate(true);
            result["ok"] = false;
            result["dispatched"] = false;
            result["ack_required"] = false;
            result["mutation_applied"] = false;
            result["error"] = canonicalize_stage_error(String(
                ingest_result.get("error_code", ingest_result.get("error", String("dispatch_failed")))),
                String("dispatch_failed"));
            result["error_code"] = result["error"];
            result["ingest_result"] = ingest_result;
            result["orchestration_state"] = voxel_orchestration_->get_state();
            result["orchestration_metrics"] = voxel_orchestration_->get_metrics();
            return result;
        }
    }

    Dictionary payload = decision.get("frame_payload", Dictionary());
    payload["tick"] = tick;
    payload["delta"] = delta_seconds;
    const Dictionary contact_snapshot = get_physics_contact_snapshot();
    payload["physics_contacts"] = contact_snapshot;
    payload["physics_server_contacts"] = contact_snapshot.get("buffered_rows", Array());

    const String stage_name = String(decision.get("stage_name", String("voxel_transform_step"))).strip_edges().to_lower();
    const Dictionary dispatch = execute_environment_stage(StringName(stage_name), payload);
    Dictionary result = decision.duplicate(true);
    result["dispatch"] = dispatch.duplicate(true);
    result["dispatched"] = bool(dispatch.get("dispatched", false));
    result["mutation_applied"] = bool(dispatch.get("mutation_applied", false));
    result["ack_required"] = static_cast<int64_t>(decision.get("consumed_count", static_cast<int64_t>(0))) > 0;
    if (dispatch.has("error")) {
        result["error"] = dispatch.get("error", String());
    }
    if (dispatch.has("error_code")) {
        result["error_code"] = dispatch.get("error_code", String());
    } else if (dispatch.has("error")) {
        result["error_code"] = dispatch.get("error", String());
    }
    result["ok"] = bool(result.get("ok", true)) && bool(dispatch.get("ok", false));
    result["orchestration_state"] = voxel_orchestration_->get_state();
    result["orchestration_metrics"] = voxel_orchestration_->get_metrics();
    return result;
}

Dictionary LocalAgentsSimulationCore::get_voxel_orchestration_state() const {
    if (!voxel_orchestration_) {
        Dictionary result;
        result["ok"] = false;
        result["error"] = String("voxel_orchestration_uninitialized");
        return result;
    }
    Dictionary result = voxel_orchestration_->get_state();
    result["ok"] = true;
    return result;
}

Dictionary LocalAgentsSimulationCore::get_voxel_orchestration_metrics() const {
    if (!voxel_orchestration_) {
        Dictionary result;
        result["ok"] = false;
        result["error"] = String("voxel_orchestration_uninitialized");
        return result;
    }
    Dictionary result = voxel_orchestration_->get_metrics();
    result["ok"] = true;
    return result;
}

void LocalAgentsSimulationCore::reset_voxel_orchestration() {
    if (voxel_orchestration_) {
        voxel_orchestration_->reset();
    }
    clear_physics_contacts();
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
    if (voxel_orchestration_) {
        snapshot["voxel_orchestration_state"] = voxel_orchestration_->get_state();
        snapshot["voxel_orchestration_metrics"] = voxel_orchestration_->get_metrics();
    } else {
        snapshot["voxel_orchestration_state"] = Dictionary();
        snapshot["voxel_orchestration_metrics"] = Dictionary();
    }
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
    if (voxel_orchestration_) {
        voxel_orchestration_->reset();
    }
    clear_physics_contacts();
    environment_stage_dispatch_count_ = 0;
    voxel_stage_dispatch_count_ = 0;
    environment_stage_counters_.clear();
    voxel_stage_counters_.clear();
}
