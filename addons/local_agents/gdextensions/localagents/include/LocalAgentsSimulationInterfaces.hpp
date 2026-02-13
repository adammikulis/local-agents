#ifndef LOCAL_AGENTS_SIMULATION_INTERFACES_HPP
#define LOCAL_AGENTS_SIMULATION_INTERFACES_HPP

#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/string_name.hpp>

#include <cstdint>

namespace local_agents::simulation {

class IFieldRegistry {
public:
    virtual ~IFieldRegistry() = default;

    virtual bool register_field(const godot::StringName &field_name, const godot::Dictionary &field_config) = 0;
    virtual bool configure(const godot::Dictionary &config) = 0;
    virtual void clear() = 0;
    virtual godot::Dictionary get_debug_snapshot() const = 0;
};

class IScheduler {
public:
    virtual ~IScheduler() = default;

    virtual bool register_system(const godot::StringName &system_name, const godot::Dictionary &system_config) = 0;
    virtual bool configure(const godot::Dictionary &config) = 0;
    virtual godot::Dictionary step(double delta_seconds, int64_t step_index) = 0;
    virtual void reset() = 0;
    virtual godot::Dictionary get_debug_snapshot() const = 0;
};

class IComputeManager {
public:
    virtual ~IComputeManager() = default;

    virtual bool configure(const godot::Dictionary &config) = 0;
    virtual godot::Dictionary execute_step(const godot::Dictionary &scheduled_frame) = 0;
    virtual void reset() = 0;
    virtual godot::Dictionary get_debug_snapshot() const = 0;
};

class ISimProfiler {
public:
    virtual ~ISimProfiler() = default;

    virtual void begin_step(int64_t step_index, double delta_seconds) = 0;
    virtual void end_step(int64_t step_index, double delta_seconds, const godot::Dictionary &step_result) = 0;
    virtual void reset() = 0;
    virtual godot::Dictionary get_debug_snapshot() const = 0;
};

class IQueryService {
public:
    virtual ~IQueryService() = default;

    virtual godot::Dictionary build_debug_snapshot(
        const IFieldRegistry &field_registry,
        const IScheduler &scheduler,
        const IComputeManager &compute_manager,
        const ISimProfiler &sim_profiler
    ) const = 0;
};

} // namespace local_agents::simulation

#endif // LOCAL_AGENTS_SIMULATION_INTERFACES_HPP
