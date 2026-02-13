#include "sim/UnifiedSimulationPipeline.hpp"

#include "sim/UnifiedSimulationPipelineInternal.hpp"

using namespace godot;

namespace local_agents::simulation {

bool UnifiedSimulationPipeline::configure(const Dictionary &config) {
    config_ = config.duplicate(true);
    required_channels_ = config.get("required_channels", unified_pipeline::default_required_channels());
    mechanics_stages_ = config.get("mechanics_stages", Array());
    pressure_stages_ = config.get("pressure_stages", Array());
    thermal_stages_ = config.get("thermal_stages", Array());
    reaction_stages_ = config.get("reaction_stages", Array());
    destruction_stages_ = config.get("destruction_stages", Array());
    return true;
}

Dictionary UnifiedSimulationPipeline::execute_step(const Dictionary &scheduled_frame) {
    executed_steps_ += 1;

    const double delta_seconds = unified_pipeline::clamped(scheduled_frame.get("delta_seconds", 1.0 / 60.0), 1.0e-6, 10.0, 1.0 / 60.0);
    const Dictionary frame_inputs = scheduled_frame.get("inputs", Dictionary());

    Array missing_channels;
    for (int64_t i = 0; i < required_channels_.size(); i++) {
        const String channel = String(required_channels_[i]);
        if (channel.is_empty()) {
            continue;
        }
        if (!frame_inputs.has(channel)) {
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

    for (int64_t i = 0; i < mechanics_stages_.size(); i++) {
        const Variant stage_variant = mechanics_stages_[i];
        if (stage_variant.get_type() != Variant::DICTIONARY) {
            continue;
        }
        const Dictionary stage_result = run_mechanics_stage(stage_variant, frame_inputs, delta_seconds);
        mechanics_results.append(stage_result);
        Dictionary stage_totals = conservation_diagnostics.get("by_stage_type", Dictionary());
        unified_pipeline::append_conservation(stage_totals, "mechanics", stage_result);
        conservation_diagnostics["by_stage_type"] = stage_totals;
    }

    for (int64_t i = 0; i < pressure_stages_.size(); i++) {
        const Variant stage_variant = pressure_stages_[i];
        if (stage_variant.get_type() != Variant::DICTIONARY) {
            continue;
        }
        const Dictionary stage_result = run_pressure_stage(stage_variant, frame_inputs, delta_seconds);
        pressure_results.append(stage_result);
        Dictionary stage_totals = conservation_diagnostics.get("by_stage_type", Dictionary());
        unified_pipeline::append_conservation(stage_totals, "pressure", stage_result);
        conservation_diagnostics["by_stage_type"] = stage_totals;
    }

    for (int64_t i = 0; i < thermal_stages_.size(); i++) {
        const Variant stage_variant = thermal_stages_[i];
        if (stage_variant.get_type() != Variant::DICTIONARY) {
            continue;
        }
        const Dictionary stage_result = run_thermal_stage(stage_variant, frame_inputs, delta_seconds);
        thermal_results.append(stage_result);
        Dictionary stage_totals = conservation_diagnostics.get("by_stage_type", Dictionary());
        unified_pipeline::append_conservation(stage_totals, "thermal", stage_result);
        conservation_diagnostics["by_stage_type"] = stage_totals;
    }

    for (int64_t i = 0; i < reaction_stages_.size(); i++) {
        const Variant stage_variant = reaction_stages_[i];
        if (stage_variant.get_type() != Variant::DICTIONARY) {
            continue;
        }
        const Dictionary stage_result = run_reaction_stage(stage_variant, frame_inputs, delta_seconds);
        reaction_results.append(stage_result);
        Dictionary stage_totals = conservation_diagnostics.get("by_stage_type", Dictionary());
        unified_pipeline::append_conservation(stage_totals, "reaction", stage_result);
        conservation_diagnostics["by_stage_type"] = stage_totals;
    }

    for (int64_t i = 0; i < destruction_stages_.size(); i++) {
        const Variant stage_variant = destruction_stages_[i];
        if (stage_variant.get_type() != Variant::DICTIONARY) {
            continue;
        }
        const Dictionary stage_result = run_destruction_stage(stage_variant, frame_inputs, delta_seconds);
        destruction_results.append(stage_result);
        Dictionary stage_totals = conservation_diagnostics.get("by_stage_type", Dictionary());
        unified_pipeline::append_conservation(stage_totals, "destruction", stage_result);
        conservation_diagnostics["by_stage_type"] = stage_totals;
    }

    unified_pipeline::aggregate_overall_conservation(conservation_diagnostics);

    const Dictionary field_evolution = unified_pipeline::run_field_buffer_evolution(
        config_,
        mechanics_stages_,
        pressure_stages_,
        thermal_stages_,
        frame_inputs,
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

    last_step_summary_ = summary.duplicate(true);
    return summary;
}

void UnifiedSimulationPipeline::reset() {
    config_.clear();
    required_channels_.clear();
    mechanics_stages_.clear();
    pressure_stages_.clear();
    thermal_stages_.clear();
    reaction_stages_.clear();
    destruction_stages_.clear();
    executed_steps_ = 0;
    last_step_summary_.clear();
}

Dictionary UnifiedSimulationPipeline::get_debug_snapshot() const {
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
