#include "LocalAgentsBoidsNativeBridge.hpp"

#include <godot_cpp/classes/rendering_device.hpp>
#include <godot_cpp/classes/rendering_server.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/memory.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include <godot_cpp/variant/variant.hpp>

#include <algorithm>

using namespace godot;

namespace {

constexpr int64_t kDefaultWorkgroupSize = 64;
constexpr int64_t kDefaultMaxWorkgroups = 65535;
constexpr const char *kGpuRequired = "GPU_REQUIRED";
constexpr const char *kNativeRequired = "NATIVE_REQUIRED";

int64_t as_i64(const Dictionary &source, const StringName &key, int64_t fallback) {
    const Variant value = source.get(key, fallback);
    if (value.get_type() == Variant::INT) {
        return static_cast<int64_t>(value);
    }
    if (value.get_type() == Variant::FLOAT) {
        return static_cast<int64_t>(value);
    }
    return fallback;
}

String as_error_code(const Dictionary &source) {
    const String value = String(source.get("error_code", source.get("error", String())));
    const String lowered = value.strip_edges().to_lower();
    if (lowered == "gpu_required" || lowered == "gpu_unavailable" || lowered == "gpu") {
        return String(kGpuRequired);
    }
    if (!lowered.is_empty()) {
        return String(kNativeRequired);
    }
    return String();
}

bool query_compute_limits(int64_t &max_workgroup_size, int64_t &max_workgroups_per_dispatch, String &error_code) {
    const RenderingServer *rendering_server = RenderingServer::get_singleton();
    if (rendering_server == nullptr) {
        error_code = String(kGpuRequired);
        return false;
    }

    RenderingDevice *rendering_device = rendering_server->get_rendering_device();
    bool owns_rendering_device = false;
    if (rendering_device == nullptr) {
        rendering_device = rendering_server->create_local_rendering_device();
        owns_rendering_device = rendering_device != nullptr;
    }
    if (rendering_device == nullptr) {
        error_code = String(kGpuRequired);
        return false;
    }

    max_workgroup_size = static_cast<int64_t>(rendering_device->limit_get(RenderingDevice::LIMIT_MAX_COMPUTE_WORKGROUP_SIZE_X));
    max_workgroups_per_dispatch = static_cast<int64_t>(rendering_device->limit_get(RenderingDevice::LIMIT_MAX_COMPUTE_WORKGROUP_COUNT_X));
    if (max_workgroup_size <= 0 || max_workgroups_per_dispatch <= 0) {
        error_code = String(kGpuRequired);
    }

    if (owns_rendering_device) {
        memdelete(rendering_device);
    }

    if (!error_code.is_empty()) {
        return false;
    }
    return true;
}

} // namespace

void LocalAgentsBoidsNativeBridge::_bind_methods() {
    ClassDB::bind_method(
        D_METHOD("can_execute_boids_step", "agent_count", "request"),
        &LocalAgentsBoidsNativeBridge::can_execute_boids_step,
        DEFVAL(Dictionary()));
    ClassDB::bind_method(
        D_METHOD("run_native_boids_step", "payload"),
        &LocalAgentsBoidsNativeBridge::run_native_boids_step);
    ClassDB::bind_method(
        D_METHOD("validate_boids_gpu_contract", "request"),
        &LocalAgentsBoidsNativeBridge::validate_boids_gpu_contract);
}

Dictionary LocalAgentsBoidsNativeBridge::make_boids_error_contract(
    const int64_t agent_count,
    const String &error_code,
    const String &error_detail,
    const int64_t workgroup_size,
    const int64_t required_workgroups,
    const int64_t max_workgroups_per_dispatch) const {
    Dictionary contract;
    contract["ok"] = false;
    contract["agent_count"] = agent_count;
    contract["workgroup_size"] = std::max<int64_t>(1, workgroup_size);
    contract["required_workgroups"] = std::max<int64_t>(0, required_workgroups);
    contract["max_workgroups_per_dispatch"] = std::max<int64_t>(0, max_workgroups_per_dispatch);
    contract["max_supported_agents"] = (std::max<int64_t>(1, workgroup_size) * std::max<int64_t>(0, max_workgroups_per_dispatch));
    const String normalized_error = error_code.to_upper();
    contract["backend"] = String("native");
    contract["backend_authority"] = String("native_required");
    contract["error"] = normalized_error;
    contract["error_code"] = normalized_error;
    contract["error_detail"] = error_detail;
    contract["status"] = String("contract_rejected");
    return contract;
}

Dictionary LocalAgentsBoidsNativeBridge::validate_boids_gpu_contract(const Dictionary &request) const {
    const int64_t requested_workgroup_size = as_i64(request, StringName("workgroup_size"), kDefaultWorkgroupSize);
    const int64_t requested_max_workgroups = as_i64(request, StringName("max_workgroups_per_dispatch"), kDefaultMaxWorkgroups);

    String error_code;
    int64_t max_workgroup_size = 0;
    int64_t max_workgroups_per_dispatch = 0;
    if (!query_compute_limits(max_workgroup_size, max_workgroups_per_dispatch, error_code)) {
        return make_boids_error_contract(0, error_code, String("gpu_rendering_unavailable"), requested_workgroup_size, 0, 0);
    }

    const int64_t normalized_workgroup_size = std::max<int64_t>(1, requested_workgroup_size);
    if (normalized_workgroup_size > max_workgroup_size) {
        return make_boids_error_contract(0, String(kNativeRequired), String("boids_workgroup_size_exceeds_gpu_limit"), normalized_workgroup_size, 0, max_workgroups_per_dispatch);
    }

    const int64_t effective_max_workgroups = std::max<int64_t>(1, std::min(max_workgroups_per_dispatch, std::max<int64_t>(1, requested_max_workgroups)));
    const int64_t agent_count = as_i64(request, StringName("agent_count"), 0);
    const int64_t required_workgroups = (agent_count <= 0) ? 0 : ((agent_count + normalized_workgroup_size - 1) / normalized_workgroup_size);
    const int64_t max_supported_agents = normalized_workgroup_size * effective_max_workgroups;

    Dictionary contract;
    contract["agent_count"] = agent_count;
    contract["workgroup_size"] = normalized_workgroup_size;
    contract["required_workgroups"] = required_workgroups;
    contract["max_workgroups_per_dispatch"] = effective_max_workgroups;
    contract["max_supported_agents"] = max_supported_agents;
    contract["backend"] = String("shader_compute");
    contract["backend_authority"] = String("shader_authoritative");
    contract["error"] = String();
    contract["error_code"] = String();
    contract["error_detail"] = String();
    contract["status"] = String("shader_authoritative");
    contract["ok"] = required_workgroups <= effective_max_workgroups && required_workgroups <= kDefaultMaxWorkgroups;
    if (!contract.get("ok", false)) {
        const String detail = String(required_workgroups > effective_max_workgroups ? "boids_shader_dispatch_exceeds_max_workgroups" : "boids_workgroups_exceed_internal_limit");
        contract = make_boids_error_contract(
            agent_count,
            String(kNativeRequired),
            detail,
            normalized_workgroup_size,
            required_workgroups,
            effective_max_workgroups
        );
    }
    return contract;
}

Dictionary LocalAgentsBoidsNativeBridge::can_execute_boids_step(int64_t agent_count, const Dictionary &request) const {
    if (agent_count < 0) {
        return make_boids_error_contract(agent_count, String(kNativeRequired), String("agent_count must be >= 0"), kDefaultWorkgroupSize, 0, 0);
    }
    Dictionary normalized_request = request.duplicate(true);
    normalized_request[StringName("agent_count")] = agent_count;
    return validate_boids_gpu_contract(normalized_request);
}

Dictionary LocalAgentsBoidsNativeBridge::run_native_boids_step(const Dictionary &payload) {
    const int64_t agent_count = as_i64(payload, StringName("agent_count"), 0);
    const Dictionary contract = can_execute_boids_step(agent_count, payload);
    const String error_code = as_error_code(contract);

    if (!bool(contract.get("ok", false))) {
        Dictionary rejected = contract.duplicate(true);
        rejected["backend"] = error_code == String(kGpuRequired) ? String("shader_compute") : String("native");
        rejected["backend_authority"] = error_code == String(kGpuRequired) ? String("shader_contract_required") : String("native_required");
        rejected["status"] = String(error_code == String(kGpuRequired) ? "shader_authority_rejected" : "native_required");

        if (error_code == String(kGpuRequired)) {
            UtilityFunctions::push_error(String(kGpuRequired) + String(": ") + String(contract.get("error_detail", "gpu render device unavailable")));
            return rejected;
        }

        const String native_detail = String(contract.get("error_detail", ""));
        rejected["error"] = String(kNativeRequired);
        rejected["error_code"] = String(kNativeRequired);
        rejected["error_detail"] = native_detail.is_empty() ? String("Native lane required but native implementation is unavailable.") : native_detail;
        rejected["scope_confirmation"] = String("Native support lane required by shader contract but not implemented.");
        return rejected;
    }

    if (bool(contract.get("ok", false))) {
        Dictionary shader_needed_but_not_required;
        shader_needed_but_not_required["ok"] = false;
        shader_needed_but_not_required["agent_count"] = agent_count;
        shader_needed_but_not_required["backend"] = String("shader_compute");
        shader_needed_but_not_required["backend_authority"] = String("shader_authoritative");
        shader_needed_but_not_required["error"] = String("NATIVE_REQUESTED_BUT_NOT_NEEDED");
        shader_needed_but_not_required["error_code"] = String("NATIVE_REQUIRED");
        shader_needed_but_not_required["error_detail"] = String("Native execution is not required; shader path is authoritative for this request");
        shader_needed_but_not_required["status"] = String("shader_authoritative");
        return shader_needed_but_not_required;
    }

    Dictionary native_contract;
    native_contract["ok"] = false;
    native_contract["agent_count"] = agent_count;
    native_contract["backend"] = String("native");
    native_contract["backend_authority"] = String("native_required");
    native_contract["error"] = String(kNativeRequired);
    native_contract["error_code"] = String(kNativeRequired);
    native_contract["error_detail"] = String("Native boids execution is unavailable: native implementation is intentionally deferred");
    native_contract["status"] = String("native_not_implemented");
    native_contract["payload"] = payload.duplicate(true);
    UtilityFunctions::push_error(String(kNativeRequired) + String(": ") + String(native_contract.get("error_detail", "")));
    return native_contract;
}
