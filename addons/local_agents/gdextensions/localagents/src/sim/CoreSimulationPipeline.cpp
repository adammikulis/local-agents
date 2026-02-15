#include "sim/CoreSimulationPipeline.hpp"

#include "sim/CoreSimulationPipelineInternal.hpp"
#include "sim/CoreSimulationPipelineFieldInputResolution.hpp"

using namespace godot;

namespace local_agents::simulation {

namespace {

constexpr uint8_t kDomainMechanicsMask = 1u << 0;
constexpr uint8_t kDomainPressureMask = 1u << 1;
constexpr uint8_t kDomainThermalMask = 1u << 2;
constexpr uint8_t kDomainReactionMask = 1u << 3;
constexpr uint8_t kDomainDestructionMask = 1u << 4;

godot::String normalize_transform_stage_name(const godot::String &value) {
    return value.strip_edges().to_lower();
}

godot::String resolve_requested_transform_stage_name(
    const godot::Dictionary &scheduled_frame,
    godot::String &metadata_requested_stage_name,
    godot::String &metadata_dispatched_stage_name,
    godot::String &metadata_source,
    int64_t &metadata_dispatch_index
) {
    const String fallback_stage_name = String(scheduled_frame.get("stage_name", String()));

    metadata_requested_stage_name = String();
    metadata_dispatched_stage_name = String();
    metadata_source = String();
    metadata_dispatch_index = -1;

    Variant dispatch_variant = scheduled_frame.get("transform_stage_dispatch", Variant());
    if (dispatch_variant.get_type() == Variant::DICTIONARY) {
        metadata_source = String("transform_stage_dispatch");
    } else {
        dispatch_variant = scheduled_frame.get("environment_stage_dispatch", Variant());
        if (dispatch_variant.get_type() != Variant::DICTIONARY) {
            return fallback_stage_name;
        }
        metadata_source = String("environment_stage_dispatch");
    }

    const Dictionary dispatch_metadata = dispatch_variant;
    metadata_requested_stage_name = String(dispatch_metadata.get("requested_stage_name", String()));
    metadata_dispatched_stage_name = String(dispatch_metadata.get("dispatched_stage_name", String()));
    const String dispatch_source = String(dispatch_metadata.get("source", String()));
    if (!dispatch_source.is_empty()) {
        metadata_source = dispatch_source;
    }
    metadata_dispatch_index = static_cast<int64_t>(dispatch_metadata.get("dispatch_index", Variant(int64_t(-1))));

    const String metadata_requested = metadata_requested_stage_name.strip_edges();
    if (!metadata_requested.is_empty()) {
        return metadata_requested;
    }
    const String metadata_dispatched = metadata_dispatched_stage_name.strip_edges();
    if (!metadata_dispatched.is_empty()) {
        return metadata_dispatched;
    }

    return fallback_stage_name;
}

} // namespace

Array to_field_handles_array(const Dictionary &frame_inputs, bool &provided) {
    provided = frame_inputs.has("field_handles");
    if (!provided) {
        return Array();
    }
    const Variant field_handles_variant = frame_inputs.get("field_handles", Variant());
    if (field_handles_variant.get_type() != Variant::ARRAY) {
        return Array();
    }
    return field_handles_variant;
}

String field_handle_label(const Variant &handle_variant, int64_t index) {
    if (handle_variant.get_type() == Variant::DICTIONARY) {
        const Dictionary handle_dict = handle_variant;
        if (handle_dict.has("id")) {
            return String(handle_dict.get("id", String()));
        }
        if (handle_dict.has("name")) {
            return String(handle_dict.get("name", String()));
        }
        if (handle_dict.has("handle")) {
            return String(handle_dict.get("handle", String()));
        }
        return String("dict_") + String::num_int64(index);
    }
    if (handle_variant.get_type() == Variant::STRING || handle_variant.get_type() == Variant::STRING_NAME || handle_variant.get_type() == Variant::INT || handle_variant.get_type() == Variant::FLOAT) {
        return String(handle_variant);
    }
    return String("type_") + String(Variant::get_type_name(handle_variant.get_type())) + String("_") + String::num_int64(index);
}

Dictionary make_field_handle_entry(const Variant &handle_variant, int64_t index) {
    Dictionary entry;
    entry["index"] = index;
    entry["read"] = unified_pipeline::make_dictionary(
        "placeholder", true,
        "status", String("not_implemented"),
        "count", static_cast<int64_t>(0));
    entry["write"] = unified_pipeline::make_dictionary(
        "placeholder", true,
        "status", String("not_implemented"),
        "count", static_cast<int64_t>(0));
    entry["handle_label"] = field_handle_label(handle_variant, index);
    if (handle_variant.get_type() == Variant::DICTIONARY) {
        entry["handle"] = Dictionary(handle_variant).duplicate(true);
    } else {
        entry["handle"] = handle_variant;
    }
    return entry;
}

Dictionary build_field_buffer_input_patch(const Dictionary &field_evolution) {
    const Dictionary updated_fields = field_evolution.get("updated_fields", Dictionary());
    const Variant updated_fields_type = field_evolution.get("updated_fields", Dictionary());
    if (updated_fields_type.get_type() != Variant::DICTIONARY || updated_fields.is_empty()) {
        return Dictionary();
    }

    Dictionary field_buffers_patch;
    Dictionary frame_input_patch;

    const Variant mass_variant = updated_fields.get("mass", Variant());
    if (mass_variant.get_type() == Variant::ARRAY) {
        const Array mass = mass_variant;
        field_buffers_patch["mass"] = mass.duplicate(true);
        frame_input_patch["mass"] = mass.duplicate(true);
        frame_input_patch["mass_field"] = mass.duplicate(true);
    }

    const Variant pressure_variant = updated_fields.get("pressure", Variant());
    if (pressure_variant.get_type() == Variant::ARRAY) {
        const Array pressure = pressure_variant;
        field_buffers_patch["pressure"] = pressure.duplicate(true);
        frame_input_patch["pressure"] = pressure.duplicate(true);
        frame_input_patch["pressure_field"] = pressure.duplicate(true);
    }

    const Variant temperature_variant = updated_fields.get("temperature", Variant());
    if (temperature_variant.get_type() == Variant::ARRAY) {
        const Array temperature = temperature_variant;
        field_buffers_patch["temperature"] = temperature.duplicate(true);
        frame_input_patch["temperature"] = temperature.duplicate(true);
        frame_input_patch["temperature_field"] = temperature.duplicate(true);
    }

    const Variant velocity_variant = updated_fields.get("velocity", Variant());
    if (velocity_variant.get_type() == Variant::ARRAY) {
        const Array velocity = velocity_variant;
        field_buffers_patch["velocity"] = velocity.duplicate(true);
        frame_input_patch["velocity"] = velocity.duplicate(true);
        frame_input_patch["velocity_field"] = velocity.duplicate(true);
    }

    const Variant density_variant = updated_fields.get("density", Variant());
    if (density_variant.get_type() == Variant::ARRAY) {
        const Array density = density_variant;
        field_buffers_patch["density"] = density.duplicate(true);
        frame_input_patch["density"] = density.duplicate(true);
        frame_input_patch["density_field"] = density.duplicate(true);
    }

    const Variant neighbor_topology_variant = updated_fields.get("neighbor_topology", Variant());
    if (neighbor_topology_variant.get_type() == Variant::ARRAY) {
        const Array neighbor_topology = neighbor_topology_variant;
        field_buffers_patch["neighbor_topology"] = neighbor_topology.duplicate(true);
        frame_input_patch["neighbor_topology"] = neighbor_topology.duplicate(true);
    }

    const Variant updated_cells_variant = updated_fields.get("updated_cells", Variant());
    if (updated_cells_variant.get_type() == Variant::ARRAY) {
        const Array updated_cells = updated_cells_variant;
        field_buffers_patch["cells"] = updated_cells.duplicate(true);
        frame_input_patch["cells"] = updated_cells.duplicate(true);
    }

    if (field_buffers_patch.is_empty()) {
        return Dictionary();
    }

    frame_input_patch["field_buffers"] = field_buffers_patch;
    return frame_input_patch;
}

Dictionary merge_field_inputs_for_next_step(const Dictionary &incoming_inputs, const Dictionary &patch) {
    Dictionary merged_inputs = incoming_inputs.duplicate(true);
    if (patch.is_empty()) {
        return merged_inputs;
    }

    const Dictionary patch_field_buffers = patch.get("field_buffers", Dictionary());
    if (patch_field_buffers.is_empty()) {
        return merged_inputs;
    }

    Dictionary merged_field_buffers = patch_field_buffers.duplicate(true);
    if (merged_inputs.has("field_buffers")) {
        const Dictionary incoming_field_buffers = merged_inputs.get("field_buffers", Dictionary());
        const Array incoming_buffer_keys = incoming_field_buffers.keys();
        for (int64_t i = 0; i < incoming_buffer_keys.size(); i++) {
            const String field_key = String(incoming_buffer_keys[i]);
            if (field_key.is_empty()) {
                continue;
            }
            merged_field_buffers[field_key] = incoming_field_buffers.get(field_key, Variant());
        }
    }

    merged_inputs["field_buffers"] = merged_field_buffers;
    return merged_inputs;
}

bool CoreSimulationPipeline::configure(const Dictionary &config) {
    config_ = config.duplicate(true);
    carried_field_inputs_.clear();
    required_channels_ = config.get("required_channels", unified_pipeline::default_required_channels());
    mechanics_stages_ = config.get("mechanics_stages", Array());
    pressure_stages_ = config.get("pressure_stages", Array());
    thermal_stages_ = config.get("thermal_stages", Array());
    reaction_stages_ = config.get("reaction_stages", Array());
    destruction_stages_ = config.get("destruction_stages", Array());
    return true;
}

Dictionary CoreSimulationPipeline::execute_step(const Dictionary &scheduled_frame) {
    String metadata_requested_stage_name;
    String metadata_dispatched_stage_name;
    String metadata_source;
    int64_t metadata_dispatch_index = -1;
    const String requested_stage_name = resolve_requested_transform_stage_name(
        scheduled_frame,
        metadata_requested_stage_name,
        metadata_dispatched_stage_name,
        metadata_source,
        metadata_dispatch_index);
    const TransformStageDispatch transform_stage_dispatch = resolve_transform_stage_dispatch(requested_stage_name);
    const bool stage_routing_enabled = transform_stage_dispatch.is_routable;
    const bool run_mechanics = !stage_routing_enabled || ((transform_stage_dispatch.domain_mask & kDomainMechanicsMask) != 0);
    const bool run_pressure = !stage_routing_enabled || ((transform_stage_dispatch.domain_mask & kDomainPressureMask) != 0);
    const bool run_thermal = !stage_routing_enabled || ((transform_stage_dispatch.domain_mask & kDomainThermalMask) != 0);
    const bool run_reaction = !stage_routing_enabled || ((transform_stage_dispatch.domain_mask & kDomainReactionMask) != 0);
    const bool run_destruction = !stage_routing_enabled || ((transform_stage_dispatch.domain_mask & kDomainDestructionMask) != 0);
    const Array mechanics_stage_batch = run_mechanics ? mechanics_stages_ : Array();
    const Array pressure_stage_batch = run_pressure ? pressure_stages_ : Array();
    const Array thermal_stage_batch = run_thermal ? thermal_stages_ : Array();
    const Array reaction_stage_batch = run_reaction ? reaction_stages_ : Array();
    const Array destruction_stage_batch = run_destruction ? destruction_stages_ : Array();

    executed_steps_ += 1;

    const double delta_seconds = unified_pipeline::clamped(scheduled_frame.get("delta_seconds", 1.0 / 60.0), 1.0e-6, 10.0, 1.0 / 60.0);
    const Dictionary frame_inputs = merge_field_inputs_for_next_step(scheduled_frame.get("inputs", Dictionary()), carried_field_inputs_);
    bool field_handles_provided = false;
    const Array field_handles = to_field_handles_array(frame_inputs, field_handles_provided);
    const int64_t field_handle_count = field_handles.size();
    const Dictionary field_handle_cache = unified_pipeline::build_handle_field_cache(field_handles, 512);
    Dictionary stage_field_input_diagnostics;
    const Dictionary stage_field_inputs = resolve_stage_field_inputs(
        frame_inputs,
        field_handles,
        field_handles_provided,
        stage_field_input_diagnostics,
        field_handle_cache);
    const String field_handle_mode = field_handles_provided ? String("field_handles") : String("scalar");
    Array field_handle_io;
    String field_handle_marker;
    if (field_handles_provided) {
        field_handle_io.resize(field_handle_count);
        field_handle_marker = String("field_handles:v1|count=") + String::num_int64(field_handle_count);
        for (int64_t i = 0; i < field_handle_count; i++) {
            const Variant handle_variant = field_handles[i];
            field_handle_io[i] = make_field_handle_entry(handle_variant, i);
            field_handle_marker += String("|") + field_handle_label(handle_variant, i);
        }
    }

    Array missing_channels;
    for (int64_t i = 0; i < required_channels_.size(); i++) {
        const String channel = String(required_channels_[i]);
        if (channel.is_empty()) {
            continue;
        }
        if (!stage_field_inputs.has(channel)) {
            missing_channels.append(channel);
        }
    }

    Array mechanics_results;
    Array pressure_results;
    Array thermal_results;
    Array reaction_results;
    Array destruction_results;

    Dictionary conservation_diagnostics;
    Dictionary by_stage_type;
    by_stage_type["mechanics"] = unified_pipeline::stage_total_template("mechanics");
    by_stage_type["pressure"] = unified_pipeline::stage_total_template("pressure");
    by_stage_type["thermal"] = unified_pipeline::stage_total_template("thermal");
    by_stage_type["reaction"] = unified_pipeline::stage_total_template("reaction");
    by_stage_type["destruction"] = unified_pipeline::stage_total_template("destruction");
    conservation_diagnostics["by_stage_type"] = by_stage_type;
    conservation_diagnostics["field_handle_mode"] = field_handle_mode;
    conservation_diagnostics["field_handle_count"] = field_handle_count;
    if (field_handles_provided) {
        conservation_diagnostics["field_handle_marker"] = field_handle_marker;
        conservation_diagnostics["field_handle_io"] = field_handle_io;
    }

    for (int64_t i = 0; i < mechanics_stage_batch.size(); i++) {
        const Variant stage_variant = mechanics_stage_batch[i];
        if (stage_variant.get_type() != Variant::DICTIONARY) {
            continue;
        }
        const Dictionary stage_config = stage_variant;
        Dictionary mechanics_stage_inputs = stage_field_inputs.duplicate(true);
        if (field_handles_provided && !pressure_stage_compatibility_fallback_enabled(stage_config)) {
            scrub_mechanics_scalar_snapshot_inputs(mechanics_stage_inputs, stage_field_input_diagnostics);
        }
        const Dictionary stage_result = run_mechanics_stage(stage_config, mechanics_stage_inputs, delta_seconds);
        mechanics_results.append(stage_result);
        Dictionary stage_totals = conservation_diagnostics.get("by_stage_type", Dictionary());
        unified_pipeline::append_conservation(stage_totals, "mechanics", stage_result);
        conservation_diagnostics["by_stage_type"] = stage_totals;
    }

    for (int64_t i = 0; i < pressure_stage_batch.size(); i++) {
        const Variant stage_variant = pressure_stage_batch[i];
        if (stage_variant.get_type() != Variant::DICTIONARY) {
            continue;
        }
        const Dictionary stage_config = stage_variant;
        Dictionary pressure_stage_inputs = stage_field_inputs.duplicate(true);
        if (field_handles_provided && !pressure_stage_compatibility_fallback_enabled(stage_config)) {
            scrub_pressure_scalar_snapshot_inputs(pressure_stage_inputs, stage_field_input_diagnostics);
        }
        const Dictionary stage_result = run_pressure_stage(stage_config, pressure_stage_inputs, delta_seconds);
        pressure_results.append(stage_result);
        Dictionary stage_totals = conservation_diagnostics.get("by_stage_type", Dictionary());
        unified_pipeline::append_conservation(stage_totals, "pressure", stage_result);
        conservation_diagnostics["by_stage_type"] = stage_totals;
    }

    for (int64_t i = 0; i < thermal_stage_batch.size(); i++) {
        const Variant stage_variant = thermal_stage_batch[i];
        if (stage_variant.get_type() != Variant::DICTIONARY) {
            continue;
        }
        const Dictionary stage_config = stage_variant;
        Dictionary thermal_stage_inputs = stage_field_inputs.duplicate(true);
        if (field_handles_provided && !pressure_stage_compatibility_fallback_enabled(stage_config)) {
            scrub_thermal_scalar_snapshot_inputs(thermal_stage_inputs, stage_field_input_diagnostics);
        }
        const Dictionary stage_result = run_thermal_stage(stage_config, thermal_stage_inputs, delta_seconds);
        thermal_results.append(stage_result);
        Dictionary stage_totals = conservation_diagnostics.get("by_stage_type", Dictionary());
        unified_pipeline::append_conservation(stage_totals, "thermal", stage_result);
        conservation_diagnostics["by_stage_type"] = stage_totals;
    }

    for (int64_t i = 0; i < reaction_stage_batch.size(); i++) {
        const Variant stage_variant = reaction_stage_batch[i];
        if (stage_variant.get_type() != Variant::DICTIONARY) {
            continue;
        }
        const Dictionary stage_config = stage_variant;
        Dictionary reaction_stage_inputs = stage_field_inputs.duplicate(true);
        if (field_handles_provided && !pressure_stage_compatibility_fallback_enabled(stage_config)) {
            scrub_reaction_scalar_snapshot_inputs(reaction_stage_inputs, stage_field_input_diagnostics);
        }
        const Dictionary stage_result = run_reaction_stage(stage_config, reaction_stage_inputs, delta_seconds);
        reaction_results.append(stage_result);
        Dictionary stage_totals = conservation_diagnostics.get("by_stage_type", Dictionary());
        unified_pipeline::append_conservation(stage_totals, "reaction", stage_result);
        conservation_diagnostics["by_stage_type"] = stage_totals;
    }

    for (int64_t i = 0; i < destruction_stage_batch.size(); i++) {
        const Variant stage_variant = destruction_stage_batch[i];
        if (stage_variant.get_type() != Variant::DICTIONARY) {
            continue;
        }
        const Dictionary stage_config = stage_variant;
        Dictionary destruction_stage_inputs = stage_field_inputs.duplicate(true);
        if (field_handles_provided && !pressure_stage_compatibility_fallback_enabled(stage_config)) {
            scrub_destruction_scalar_snapshot_inputs(destruction_stage_inputs, stage_field_input_diagnostics);
        }
        const Dictionary stage_result = run_destruction_stage(stage_config, destruction_stage_inputs, delta_seconds);
        destruction_results.append(stage_result);
        Dictionary stage_totals = conservation_diagnostics.get("by_stage_type", Dictionary());
        unified_pipeline::append_conservation(stage_totals, "destruction", stage_result);
        conservation_diagnostics["by_stage_type"] = stage_totals;
    }

    unified_pipeline::aggregate_overall_conservation(conservation_diagnostics);

    const Dictionary field_evolution = unified_pipeline::run_field_buffer_evolution(
        config_,
        mechanics_stage_batch,
        pressure_stage_batch,
        thermal_stage_batch,
        frame_inputs,
        field_handles,
        field_handle_cache,
        field_handles_provided,
        delta_seconds);

    Dictionary summary;
    summary["ok"] = true;
    summary["executed_steps"] = executed_steps_;
    summary["delta_seconds"] = delta_seconds;
    summary["mechanics"] = mechanics_results;
    summary["pressure"] = pressure_results;
    summary["thermal"] = thermal_results;
    summary["reaction"] = reaction_results;
    summary["destruction"] = destruction_results;
    summary["required_channels"] = required_channels_.duplicate(true);
    summary["missing_channels"] = missing_channels;
    summary["physics_ready"] = missing_channels.is_empty();
    summary["stage_counts"] = unified_pipeline::make_dictionary(
        "mechanics", mechanics_results.size(),
        "pressure", pressure_results.size(),
        "thermal", thermal_results.size(),
        "reaction", reaction_results.size(),
        "destruction", destruction_results.size());
    summary["conservation_diagnostics"] = conservation_diagnostics;
    summary["field_evolution"] = field_evolution;
    summary["field_mass_drift_proxy"] = unified_pipeline::clamped(field_evolution.get("mass_drift_proxy", 0.0), -1.0e18, 1.0e18, 0.0);
    summary["field_energy_drift_proxy"] = unified_pipeline::clamped(field_evolution.get("energy_drift_proxy", 0.0), -1.0e18, 1.0e18, 0.0);
    summary["field_cell_count_updated"] = static_cast<int64_t>(field_evolution.get("cell_count_updated", static_cast<int64_t>(0)));
    Dictionary transform_stage_dispatch_summary = unified_pipeline::make_dictionary(
        "requested_stage_name", transform_stage_dispatch.requested_stage_name,
        "dispatched_stage_name", transform_stage_dispatch.dispatched_stage_name,
        "stage_id", static_cast<int64_t>(transform_stage_dispatch.stage_id),
        "is_routable", transform_stage_dispatch.is_routable,
        "is_routed", transform_stage_dispatch.is_routed,
        "domain_mask", static_cast<int64_t>(transform_stage_dispatch.domain_mask));
    if (!metadata_source.is_empty()) {
        transform_stage_dispatch_summary["source"] = metadata_source;
    }
    if (!metadata_requested_stage_name.is_empty()) {
        transform_stage_dispatch_summary["metadata_requested_stage_name"] = metadata_requested_stage_name;
    }
    if (!metadata_dispatched_stage_name.is_empty()) {
        transform_stage_dispatch_summary["metadata_dispatched_stage_name"] = metadata_dispatched_stage_name;
    }
    if (metadata_dispatch_index >= 0) {
        transform_stage_dispatch_summary["dispatch_index"] = metadata_dispatch_index;
    }
    summary["transform_stage_dispatch"] = transform_stage_dispatch_summary;
    // Deprecated compatibility key. Prefer "transform_stage_dispatch".
    summary["environment_stage_dispatch"] = transform_stage_dispatch_summary;
    summary["stage_coupling"] = field_evolution.get("stage_coupling", Dictionary());
    summary["coupling_markers"] = field_evolution.get("coupling_markers", Array());
    summary["coupling_scalar_diagnostics"] = field_evolution.get("coupling_scalar_diagnostics", Dictionary());
    summary["physics_server_feedback"] = summarize_physics_server_feedback(destruction_results, field_evolution);
    summary["stage_field_input_diagnostics"] = stage_field_input_diagnostics;
    summary["field_handle_mode"] = field_handle_mode;
    summary["field_handle_count"] = field_handle_count;
    if (field_handles_provided) {
        summary["field_handle_marker"] = field_handle_marker;
        summary["field_handle_io"] = field_handle_io;
    }

    const Dictionary field_input_patch = build_field_buffer_input_patch(field_evolution);
    if (!field_input_patch.is_empty()) {
        carried_field_inputs_ = field_input_patch;
    }

    last_step_summary_ = summary.duplicate(true);
    return summary;
}

CoreSimulationPipeline::TransformStageDispatch CoreSimulationPipeline::resolve_transform_stage_dispatch(
    const String &requested_stage_name
) const {
    TransformStageDispatch dispatch;
    dispatch.requested_stage_name = requested_stage_name;
    dispatch.dispatched_stage_name = requested_stage_name;

    const String normalized_stage_name = normalize_transform_stage_name(requested_stage_name);
    if (normalized_stage_name.is_empty()) {
        return dispatch;
    }

    // Canonical transform-stage contracts only.
    if (normalized_stage_name == "thermal_transform_step") {
        dispatch.dispatched_stage_name = String("thermal_transform_step");
        dispatch.stage_id = TransformStageId::kThermalTransform;
        dispatch.domain_mask = kDomainThermalMask;
        dispatch.is_routable = true;
        dispatch.is_routed = true;
        return dispatch;
    }

    if (normalized_stage_name == "pressure_transform_step") {
        dispatch.dispatched_stage_name = String("pressure_transform_step");
        dispatch.stage_id = TransformStageId::kPressureTransform;
        dispatch.domain_mask = kDomainPressureMask;
        dispatch.is_routable = true;
        dispatch.is_routed = true;
        return dispatch;
    }

    if (normalized_stage_name == "destruction_transform_step") {
        dispatch.dispatched_stage_name = String("destruction_transform_step");
        dispatch.stage_id = TransformStageId::kDestructionTransform;
        dispatch.domain_mask = kDomainDestructionMask;
        dispatch.is_routable = true;
        dispatch.is_routed = true;
        return dispatch;
    }

    if (normalized_stage_name == "radiance_transform_step") {
        dispatch.dispatched_stage_name = String("radiance_transform_step");
        dispatch.stage_id = TransformStageId::kRadianceTransform;
        dispatch.domain_mask = kDomainThermalMask;
        dispatch.is_routable = true;
        dispatch.is_routed = true;
        return dispatch;
    }

    dispatch.dispatched_stage_name = normalized_stage_name;
    return dispatch;
}

void CoreSimulationPipeline::reset() {
    config_.clear();
    required_channels_.clear();
    mechanics_stages_.clear();
    pressure_stages_.clear();
    thermal_stages_.clear();
    reaction_stages_.clear();
    destruction_stages_.clear();
    executed_steps_ = 0;
    last_step_summary_.clear();
    carried_field_inputs_.clear();
}

Dictionary CoreSimulationPipeline::get_debug_snapshot() const {
    Dictionary snapshot;
    snapshot["configured"] = !config_.is_empty();
    snapshot["required_channels"] = required_channels_.duplicate(true);
    snapshot["mechanics_stage_count"] = mechanics_stages_.size();
    snapshot["pressure_stage_count"] = pressure_stages_.size();
    snapshot["thermal_stage_count"] = thermal_stages_.size();
    snapshot["reaction_stage_count"] = reaction_stages_.size();
    snapshot["destruction_stage_count"] = destruction_stages_.size();
    snapshot["executed_steps"] = executed_steps_;
    snapshot["config"] = config_.duplicate(true);
    snapshot["last_step_summary"] = last_step_summary_.duplicate(true);
    return snapshot;
}

} // namespace local_agents::simulation
