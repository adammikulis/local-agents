#include "LocalAgentsEnvironmentStageExecutor.hpp"

#include "SimulationFailureEmissionPlanner.hpp"
#include "VoxelEditEngine.hpp"
#include "helpers/SimulationCoreDictionaryHelpers.hpp"

#include <godot_cpp/variant/variant.hpp>

using namespace godot;

namespace {

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

} // namespace

namespace local_agents::simulation {

Dictionary execute_environment_stage_orchestration(
    const StringName &stage_name,
    const Dictionary &effective_payload,
    int64_t environment_stage_dispatch_count,
    const Array &physics_contact_rows,
    IFieldRegistry *field_registry,
    IComputeManager *compute_manager,
    VoxelEditEngine *voxel_edit_engine,
    double impact_signal_gain,
    double watch_signal_threshold,
    double active_signal_threshold,
    double fracture_radius_base,
    double fracture_radius_gain,
    double fracture_radius_max,
    double fracture_value_softness,
    double fracture_value_cap
) {
    Dictionary result;
    if (!voxel_edit_engine) {
        return result;
    }

    if (compute_manager) {
        Dictionary scheduled_frame;
        const Dictionary scheduled_frame_inputs =
            helpers::maybe_inject_field_handles_into_environment_inputs(effective_payload, field_registry);
        const String normalized_stage_name = String(stage_name).strip_edges().to_lower();
        scheduled_frame["ok"] = true;
        scheduled_frame["step_index"] = static_cast<int64_t>(environment_stage_dispatch_count);
        scheduled_frame["delta_seconds"] = static_cast<double>(effective_payload.get("delta", 0.0));
        scheduled_frame["stage_name"] = normalized_stage_name;
        Dictionary environment_stage_dispatch;
        environment_stage_dispatch["requested_stage_name"] = normalized_stage_name;
        environment_stage_dispatch["dispatched_stage_name"] = normalized_stage_name;
        environment_stage_dispatch["dispatch_index"] = static_cast<int64_t>(environment_stage_dispatch_count);
        environment_stage_dispatch["source"] = String("environment_stage_executor");
        scheduled_frame["environment_stage_dispatch"] = environment_stage_dispatch;
        scheduled_frame["inputs"] = scheduled_frame_inputs;
        const Dictionary pipeline_result = compute_manager->execute_step(scheduled_frame);
        result["pipeline"] = pipeline_result;
        result["physics_server_feedback"] = extract_pipeline_feedback(pipeline_result);

        Dictionary voxel_failure_emission = build_voxel_failure_emission_plan(
            extract_pipeline_feedback(pipeline_result),
            physics_contact_rows,
            impact_signal_gain,
            watch_signal_threshold,
            active_signal_threshold,
            fracture_radius_base,
            fracture_radius_gain,
            fracture_radius_max,
            fracture_value_softness,
            fracture_value_cap);
        const String failure_emission_status =
            as_status_text(voxel_failure_emission.get("status", String("disabled")), String("disabled"));
        if (failure_emission_status == String("planned")) {
            const Array op_payloads = voxel_failure_emission.get("op_payloads", Array());
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
                const Dictionary enqueue_result = voxel_edit_engine->enqueue_op(
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
                const Dictionary failure_feedback = feedback_reference.is_empty()
                    ? Dictionary()
                    : Dictionary(feedback_reference.get("failure_feedback", Dictionary()));
                const Dictionary failure_source = feedback_reference.is_empty()
                    ? Dictionary()
                    : Dictionary(feedback_reference.get("failure_source", Dictionary()));
                const Dictionary destruction_feedback = feedback_reference.is_empty()
                    ? Dictionary()
                    : Dictionary(feedback_reference.get("destruction", Dictionary()));
                emission_payload["failure_feedback"] = failure_feedback;
                emission_payload["failure_source"] = failure_source;
                emission_payload["destruction_feedback"] = destruction_feedback;
                const Dictionary execution = voxel_edit_engine->execute_stage(
                    plan_target_domain,
                    StringName(plan_stage_name),
                    emission_payload);
                voxel_failure_emission["execution"] = execution;
                if (bool(execution.get("ok", false))) {
                    voxel_failure_emission["status"] = String("executed");
                    voxel_failure_emission["reason"] = as_status_text(
                        voxel_failure_emission.get("reason", String("active_failure")),
                        String("active_failure"));
                    voxel_failure_emission["executed_op_count"] =
                        static_cast<int64_t>(execution.get("ops_changed", static_cast<int64_t>(0)));
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
        return result;
    }

    Dictionary disabled_voxel_emission = build_voxel_failure_emission_plan(
        Dictionary(),
        Array(),
        impact_signal_gain,
        watch_signal_threshold,
        active_signal_threshold,
        fracture_radius_base,
        fracture_radius_gain,
        fracture_radius_max,
        fracture_value_softness,
        fracture_value_cap);
    disabled_voxel_emission["reason"] = String("compute_manager_unavailable");
    disabled_voxel_emission["status"] = String("disabled");
    result["voxel_failure_emission"] = disabled_voxel_emission;
    return result;
}

} // namespace local_agents::simulation
