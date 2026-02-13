#include "LocalAgentsSimulationCore.hpp"

#include "LocalAgentsComputeManager.hpp"
#include "LocalAgentsFieldRegistry.hpp"
#include "LocalAgentsQueryService.hpp"
#include "LocalAgentsScheduler.hpp"
#include "LocalAgentsSimProfiler.hpp"

#include <godot_cpp/core/class_db.hpp>

using namespace godot;
using namespace local_agents::simulation;

namespace {
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

Dictionary build_stage_dispatch_result(
    const String &stage_domain,
    const StringName &stage_name,
    const Dictionary &payload,
    int64_t domain_dispatch_count,
    int64_t stage_dispatch_count
) {
    Dictionary result;
    result["ok"] = true;
    result["stage_domain"] = stage_domain;
    result["stage_name"] = stage_name;
    result["payload"] = payload.duplicate(true);

    Dictionary counters;
    counters["domain_dispatch_count"] = domain_dispatch_count;
    counters["stage_dispatch_count"] = stage_dispatch_count;
    result["counters"] = counters;

    Dictionary execution;
    execution["backend"] = String("gpu_dispatch_stub");
    execution["kernel_status"] = String("not_implemented");
    execution["dispatched"] = false;
    execution["reason"] = String("no_gpu_stage_kernel_registered");
    result["execution"] = execution;
    return result;
}

Dictionary build_stage_dispatch_error(
    const String &stage_domain,
    const StringName &stage_name,
    const Dictionary &payload,
    const String &error_code,
    int64_t domain_dispatch_count,
    int64_t stage_dispatch_count
) {
    Dictionary result;
    result["ok"] = false;
    result["stage_domain"] = stage_domain;
    result["stage_name"] = stage_name;
    result["payload"] = payload.duplicate(true);
    result["error"] = error_code;

    Dictionary counters;
    counters["domain_dispatch_count"] = domain_dispatch_count;
    counters["stage_dispatch_count"] = stage_dispatch_count;
    result["counters"] = counters;

    Dictionary execution;
    execution["backend"] = String("gpu_dispatch_stub");
    execution["kernel_status"] = String("not_implemented");
    execution["dispatched"] = false;
    result["execution"] = execution;
    return result;
}
} // namespace

LocalAgentsSimulationCore::LocalAgentsSimulationCore() {
    field_registry_ = std::make_unique<LocalAgentsFieldRegistry>();
    scheduler_ = std::make_unique<LocalAgentsScheduler>();
    compute_manager_ = std::make_unique<LocalAgentsComputeManager>();
    query_service_ = std::make_unique<LocalAgentsQueryService>();
    sim_profiler_ = std::make_unique<LocalAgentsSimProfiler>();
}

LocalAgentsSimulationCore::~LocalAgentsSimulationCore() = default;

void LocalAgentsSimulationCore::_bind_methods() {
    ClassDB::bind_method(D_METHOD("register_field", "field_name", "field_config"),
                         &LocalAgentsSimulationCore::register_field, DEFVAL(Dictionary()));
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
    ClassDB::bind_method(D_METHOD("execute_environment_stage", "stage_name", "payload"),
                         &LocalAgentsSimulationCore::execute_environment_stage, DEFVAL(Dictionary()));
    ClassDB::bind_method(D_METHOD("execute_voxel_stage", "stage_name", "payload"),
                         &LocalAgentsSimulationCore::execute_voxel_stage, DEFVAL(Dictionary()));
    ClassDB::bind_method(D_METHOD("get_debug_snapshot"), &LocalAgentsSimulationCore::get_debug_snapshot);
    ClassDB::bind_method(D_METHOD("reset"), &LocalAgentsSimulationCore::reset);
}

bool LocalAgentsSimulationCore::register_field(const StringName &field_name, const Dictionary &field_config) {
    return field_registry_ && field_registry_->register_field(field_name, field_config);
}

bool LocalAgentsSimulationCore::register_system(const StringName &system_name, const Dictionary &system_config) {
    return scheduler_ && scheduler_->register_system(system_name, system_config);
}

bool LocalAgentsSimulationCore::configure(const Dictionary &simulation_config) {
    if (!field_registry_ || !scheduler_ || !compute_manager_) {
        return false;
    }

    Dictionary field_registry_config = simulation_config.get("field_registry", Dictionary());
    Dictionary scheduler_config = simulation_config.get("scheduler", Dictionary());
    Dictionary compute_config = simulation_config.get("compute", Dictionary());

    const bool field_ok = field_registry_->configure(field_registry_config);
    const bool scheduler_ok = scheduler_->configure(scheduler_config);
    const bool compute_ok = compute_manager_->configure(compute_config);
    return field_ok && scheduler_ok && compute_ok;
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

Dictionary LocalAgentsSimulationCore::execute_environment_stage(const StringName &stage_name, const Dictionary &payload) {
    if (String(stage_name).is_empty()) {
        return build_stage_dispatch_error(
            String("environment"),
            stage_name,
            payload,
            String("invalid_stage_name"),
            environment_stage_dispatch_count_,
            0
        );
    }

    environment_stage_dispatch_count_ += 1;
    const int64_t stage_dispatch_count = increment_stage_counter(environment_stage_counters_, stage_name);
    return build_stage_dispatch_result(
        String("environment"),
        stage_name,
        payload,
        environment_stage_dispatch_count_,
        stage_dispatch_count
    );
}

Dictionary LocalAgentsSimulationCore::execute_voxel_stage(const StringName &stage_name, const Dictionary &payload) {
    if (String(stage_name).is_empty()) {
        return build_stage_dispatch_error(
            String("voxel"),
            stage_name,
            payload,
            String("invalid_stage_name"),
            voxel_stage_dispatch_count_,
            0
        );
    }

    voxel_stage_dispatch_count_ += 1;
    const int64_t stage_dispatch_count = increment_stage_counter(voxel_stage_counters_, stage_name);
    return build_stage_dispatch_result(
        String("voxel"),
        stage_name,
        payload,
        voxel_stage_dispatch_count_,
        stage_dispatch_count
    );
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
    environment_stage_dispatch_count_ = 0;
    voxel_stage_dispatch_count_ = 0;
    environment_stage_counters_.clear();
    voxel_stage_counters_.clear();
}
