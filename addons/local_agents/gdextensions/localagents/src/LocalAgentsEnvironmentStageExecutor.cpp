#include "LocalAgentsEnvironmentStageExecutor.hpp"

#include "SimulationFailureEmissionPlanner.hpp"
#include "VoxelEditEngine.hpp"
#include "helpers/SimulationCoreDictionaryHelpers.hpp"

#include <godot_cpp/variant/variant.hpp>

using namespace godot;

namespace {
constexpr const char *kCanonicalProjectileMutationDomain = "environment";
constexpr const char *kCanonicalProjectileMutationStage = "physics_failure_emission";

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

String canonicalize_native_contract_error(const String &raw_error_code) {
    const String lowered = raw_error_code.strip_edges().to_lower();
    if (lowered.is_empty()) {
        return String("dispatch_failed");
    }
    if (lowered == String("gpu_required") || lowered.find("gpu_required") >= 0) {
        return String("gpu_required");
    }
    if (
        lowered == String("gpu_unavailable") ||
        lowered.find("gpu_rendering_device_unavailable") >= 0 ||
        lowered.find("gpu_backend_unavailable") >= 0 ||
        lowered.find("rendering_server_unavailable") >= 0 ||
        lowered.find("device_create_failed") >= 0
    ) {
        return String("gpu_unavailable");
    }
    if (
        lowered == String("native_required") ||
        lowered == String("native_unavailable") ||
        lowered.find("native_sim_core_unavailable") >= 0 ||
        lowered.find("native_required") >= 0 ||
        lowered.find("core_missing_method") >= 0
    ) {
        return String("native_required");
    }
    if (lowered.find("dispatch") >= 0 || lowered.find("shader") >= 0 || lowered.find("compute") >= 0) {
        return String("dispatch_failed");
    }
    return String("dispatch_failed");
}

Dictionary build_authoritative_mutation_status(
    bool ok,
    const String &status,
    bool dispatched,
    bool mutation_applied,
    const String &error_code
) {
    Dictionary authoritative_status;
    authoritative_status["ok"] = ok;
    authoritative_status["status"] = status;
    authoritative_status["dispatched"] = dispatched;
    authoritative_status["mutation_applied"] = mutation_applied;
    authoritative_status["error_code"] = error_code;
    authoritative_status["error"] = error_code;
    Dictionary execution_evidence;
    execution_evidence["ok"] = ok;
    execution_evidence["status"] = status;
    execution_evidence["dispatched"] = dispatched;
    execution_evidence["mutation_applied"] = mutation_applied;
    execution_evidence["error_code"] = error_code;
    execution_evidence["error"] = error_code;
    authoritative_status["execution"] = execution_evidence;
    return authoritative_status;
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
    Array failure_contact_rows = physics_contact_rows;
    if (failure_contact_rows.is_empty()) {
        Variant payload_contacts_variant = effective_payload.get("physics_server_contacts", Variant());
        if (payload_contacts_variant.get_type() != Variant::ARRAY) {
            payload_contacts_variant = effective_payload.get("physics_contacts", Variant());
        }
        if (payload_contacts_variant.get_type() == Variant::ARRAY) {
            failure_contact_rows = Array(payload_contacts_variant);
        } else if (payload_contacts_variant.get_type() == Variant::DICTIONARY) {
            const Dictionary payload_contacts = payload_contacts_variant;
            const Variant buffered_rows_variant = payload_contacts.get("buffered_rows", Variant());
            if (buffered_rows_variant.get_type() == Variant::ARRAY) {
                failure_contact_rows = Array(buffered_rows_variant);
            }
        }
    }
    if (!voxel_edit_engine) {
        Dictionary voxel_failure_emission;
        voxel_failure_emission["status"] = String("failed");
        voxel_failure_emission["reason"] = String("voxel_edit_engine_uninitialized");
        voxel_failure_emission["error"] = String("native_required");
        voxel_failure_emission["error_code"] = String("native_required");
        voxel_failure_emission["executed_op_count"] = static_cast<int64_t>(0);
        result["voxel_failure_emission"] = voxel_failure_emission;
        result["authoritative_mutation"] = build_authoritative_mutation_status(
            false,
            String("failed"),
            false,
            false,
            String("native_required"));
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
            failure_contact_rows,
            impact_signal_gain,
            watch_signal_threshold,
            active_signal_threshold,
            fracture_radius_base,
            fracture_radius_gain,
            fracture_radius_max,
            fracture_value_softness,
            fracture_value_cap);
        Dictionary authoritative_mutation = build_authoritative_mutation_status(
            true,
            String("not_requested"),
            true,
            false,
            String());
        authoritative_mutation["target_domain"] = String(kCanonicalProjectileMutationDomain);
        authoritative_mutation["stage_name"] = String(kCanonicalProjectileMutationStage);
        authoritative_mutation["planned_op_count"] =
            static_cast<int64_t>(voxel_failure_emission.get("planned_op_count", static_cast<int64_t>(0)));
        const String failure_emission_status =
            as_status_text(voxel_failure_emission.get("status", String("disabled")), String("disabled"));
        if (failure_emission_status == String("planned")) {
            const Array op_payloads = voxel_failure_emission.get("op_payloads", Array());
            Array enqueue_results;
            bool enqueued_all = true;
            String first_enqueue_error;
            for (int64_t i = 0; i < op_payloads.size(); i++) {
                const Variant op_variant = op_payloads[i];
                if (op_variant.get_type() != Variant::DICTIONARY) {
                    continue;
                }
                const Dictionary op_payload = op_variant;
                const Dictionary enqueue_result = voxel_edit_engine->enqueue_op(
                    String(kCanonicalProjectileMutationDomain),
                    StringName(kCanonicalProjectileMutationStage),
                    op_payload);
                enqueue_results.append(enqueue_result);
                const bool enqueue_ok = bool(enqueue_result.get("ok", false));
                enqueued_all = enqueued_all && enqueue_ok;
                if (!enqueue_ok && first_enqueue_error.is_empty()) {
                    first_enqueue_error = as_status_text(enqueue_result.get("error", String()), String());
                }
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
                    String(kCanonicalProjectileMutationDomain),
                    StringName(kCanonicalProjectileMutationStage),
                    emission_payload);
                voxel_failure_emission["execution"] = execution;
                result["authoritative_voxel_execution"] = execution.duplicate(true);
                if (bool(execution.get("ok", false))) {
                    voxel_failure_emission["status"] = String("executed");
                    voxel_failure_emission["reason"] = as_status_text(
                        voxel_failure_emission.get("reason", String("active_failure")),
                        String("active_failure"));
                    voxel_failure_emission["executed_op_count"] =
                        static_cast<int64_t>(execution.get("ops_changed", static_cast<int64_t>(0)));
                    voxel_failure_emission["error"] = String();
                    voxel_failure_emission["error_code"] = String();
                    authoritative_mutation = build_authoritative_mutation_status(
                        true,
                        String("executed"),
                        bool(execution.get("dispatched", true)),
                        static_cast<int64_t>(execution.get("ops_changed", static_cast<int64_t>(0))) > 0,
                        String());
                    authoritative_mutation["execution"] = execution.duplicate(true);
                } else {
                    const String execution_error = canonicalize_native_contract_error(
                        as_status_text(execution.get("error", String()), String("dispatch_failed")));
                    voxel_failure_emission["status"] = String("failed");
                    voxel_failure_emission["reason"] = String("voxel_execution_failed");
                    voxel_failure_emission["executed_op_count"] = static_cast<int64_t>(0);
                    voxel_failure_emission["error"] = execution_error;
                    voxel_failure_emission["error_code"] = execution_error;
                    authoritative_mutation = build_authoritative_mutation_status(
                        false,
                        String("failed"),
                        false,
                        false,
                        execution_error);
                    authoritative_mutation["execution"] = execution.duplicate(true);
                }
            } else {
                const String enqueue_error = canonicalize_native_contract_error(
                    first_enqueue_error.is_empty() ? String("native_required") : first_enqueue_error);
                voxel_failure_emission["status"] = String("failed");
                voxel_failure_emission["reason"] = String("voxel_enqueue_failed");
                voxel_failure_emission["executed_op_count"] = static_cast<int64_t>(0);
                voxel_failure_emission["error"] = enqueue_error;
                voxel_failure_emission["error_code"] = enqueue_error;
                authoritative_mutation = build_authoritative_mutation_status(
                    false,
                    String("failed"),
                    false,
                    false,
                    enqueue_error);
            }
        } else if (failure_emission_status == String("failed")) {
            const String planned_error = canonicalize_native_contract_error(
                as_status_text(
                    voxel_failure_emission.get("error_code", voxel_failure_emission.get("error", String("dispatch_failed"))),
                    String("dispatch_failed")));
            voxel_failure_emission["error"] = planned_error;
            voxel_failure_emission["error_code"] = planned_error;
            authoritative_mutation = build_authoritative_mutation_status(
                false,
                String("failed"),
                false,
                false,
                planned_error);
        }
        result["voxel_failure_emission"] = voxel_failure_emission;
        result["authoritative_mutation"] = authoritative_mutation;
        result["native_ops"] = voxel_failure_emission.get("op_payloads", Array());
        const Variant authority_execution_variant = authoritative_mutation.get("execution", Dictionary());
        if (authority_execution_variant.get_type() == Variant::DICTIONARY) {
            const Dictionary authority_execution = authority_execution_variant;
            if (authority_execution.has("changed_chunks")) {
                result["changed_chunks"] = authority_execution.get("changed_chunks", Array());
            }
            if (authority_execution.has("changed_region")) {
                result["changed_region"] = authority_execution.get("changed_region", Dictionary());
            }
        }
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
    disabled_voxel_emission["status"] = String("failed");
    disabled_voxel_emission["error"] = String("native_required");
    disabled_voxel_emission["error_code"] = String("native_required");
    disabled_voxel_emission["executed_op_count"] = static_cast<int64_t>(0);
    result["voxel_failure_emission"] = disabled_voxel_emission;
    result["authoritative_mutation"] = build_authoritative_mutation_status(
        false,
        String("failed"),
        false,
        false,
        String("native_required"));
    return result;
}

} // namespace local_agents::simulation
