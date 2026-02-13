#include "sim/UnifiedSimulationPipelineInternal.hpp"

#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_float64_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>

#include <algorithm>
#include <cmath>
#include <cstdint>

using namespace godot;

namespace local_agents::simulation::unified_pipeline {
namespace {
double as_number(const Variant &value, double fallback) {
    if (value.get_type() == Variant::FLOAT) {
        return static_cast<double>(value);
    }
    if (value.get_type() == Variant::INT) {
        return static_cast<double>(static_cast<int64_t>(value));
    }
    return fallback;
}

int64_t as_index(const Variant &value, int64_t fallback) {
    if (value.get_type() == Variant::INT) {
        return static_cast<int64_t>(value);
    }
    if (value.get_type() == Variant::FLOAT) {
        return static_cast<int64_t>(static_cast<double>(value));
    }
    return fallback;
}

Array to_numeric_array(const Variant &value) {
    Array out;
    if (value.get_type() == Variant::ARRAY) {
        const Array source = value;
        out.resize(source.size());
        for (int64_t i = 0; i < source.size(); i++) {
            out[i] = as_number(source[i], 0.0);
        }
        return out;
    }
    if (value.get_type() == Variant::PACKED_FLOAT32_ARRAY) {
        const PackedFloat32Array source = value;
        out.resize(source.size());
        for (int64_t i = 0; i < source.size(); i++) {
            out[i] = static_cast<double>(source[i]);
        }
        return out;
    }
    if (value.get_type() == Variant::PACKED_FLOAT64_ARRAY) {
        const PackedFloat64Array source = value;
        out.resize(source.size());
        for (int64_t i = 0; i < source.size(); i++) {
            out[i] = source[i];
        }
        return out;
    }
    return out;
}

Array to_topology_row(const Variant &value) {
    Array row;
    if (value.get_type() == Variant::ARRAY) {
        const Array source = value;
        row.resize(source.size());
        for (int64_t i = 0; i < source.size(); i++) {
            row[i] = as_index(source[i], -1);
        }
        return row;
    }
    if (value.get_type() == Variant::PACKED_INT32_ARRAY) {
        const PackedInt32Array source = value;
        row.resize(source.size());
        for (int64_t i = 0; i < source.size(); i++) {
            row[i] = static_cast<int64_t>(source[i]);
        }
        return row;
    }
    if (value.get_type() == Variant::PACKED_INT64_ARRAY) {
        const PackedInt64Array source = value;
        row.resize(source.size());
        for (int64_t i = 0; i < source.size(); i++) {
            row[i] = static_cast<int64_t>(source[i]);
        }
        return row;
    }
    return row;
}

Array to_topology(const Variant &value) {
    Array topology;
    if (value.get_type() != Variant::ARRAY) {
        return topology;
    }
    const Array source = value;
    topology.resize(source.size());
    for (int64_t i = 0; i < source.size(); i++) {
        topology[i] = to_topology_row(source[i]);
    }
    return topology;
}

double sum_array(const Array &values) {
    double total = 0.0;
    for (int64_t i = 0; i < values.size(); i++) {
        total += as_number(values[i], 0.0);
    }
    return total;
}

double proxy_energy_total(const Array &mass, const Array &velocity, const Array &pressure, const Array &temperature) {
    const int64_t count = std::min(std::min(mass.size(), velocity.size()), std::min(pressure.size(), temperature.size()));
    double total = 0.0;
    for (int64_t i = 0; i < count; i++) {
        const double m = std::max(1.0e-9, as_number(mass[i], 0.0));
        const double v = as_number(velocity[i], 0.0);
        const double p = as_number(pressure[i], 0.0);
        const double t = as_number(temperature[i], 0.0);
        total += 0.5 * m * v * v + p + t;
    }
    return total;
}

double averaged_stage_param(const Array &stages, const char *key, double fallback, double min_v, double max_v) {
    double total = 0.0;
    int64_t count = 0;
    for (int64_t i = 0; i < stages.size(); i++) {
        const Variant stage_variant = stages[i];
        if (stage_variant.get_type() != Variant::DICTIONARY) {
            continue;
        }
        const Dictionary stage = stage_variant;
        total += clamped(stage.get(String(key), fallback), min_v, max_v, fallback);
        count += 1;
    }
    if (count == 0) {
        return fallback;
    }
    return total / static_cast<double>(count);
}

void copy_if_missing(Array &target, const Array &source, double fill) {
    if (!target.is_empty()) {
        return;
    }
    target.resize(source.size());
    for (int64_t i = 0; i < source.size(); i++) {
        target[i] = fill;
    }
}

void set_default_topology(Array &topology, int64_t count) {
    if (!topology.is_empty()) {
        return;
    }
    topology.resize(count);
    for (int64_t i = 0; i < count; i++) {
        Array neighbors;
        if (i > 0) {
            neighbors.append(i - 1);
        }
        if (i + 1 < count) {
            neighbors.append(i + 1);
        }
        topology[i] = neighbors;
    }
}

Array wave_a_coupling_markers() {
    Array markers;
    markers.append(String("pressure->mechanics"));
    markers.append(String("reaction->thermal"));
    markers.append(String("damage->voxel"));
    return markers;
}

Dictionary wave_a_stage_coupling(double pressure_to_mechanics, double reaction_to_thermal, double damage_to_voxel) {
    Dictionary stage_coupling;
    stage_coupling["pressure->mechanics"] = unified_pipeline::make_dictionary(
        "marker", String("pressure->mechanics"),
        "wave", String("A"),
        "source_stage", String("pressure"),
        "target_stage", String("mechanics"),
        "scalar", pressure_to_mechanics);
    stage_coupling["reaction->thermal"] = unified_pipeline::make_dictionary(
        "marker", String("reaction->thermal"),
        "wave", String("A"),
        "source_stage", String("reaction"),
        "target_stage", String("thermal"),
        "scalar", reaction_to_thermal);
    stage_coupling["damage->voxel"] = unified_pipeline::make_dictionary(
        "marker", String("damage->voxel"),
        "wave", String("A"),
        "source_stage", String("damage"),
        "target_stage", String("voxel"),
        "scalar", damage_to_voxel);
    return stage_coupling;
}

Dictionary wave_a_coupling_scalar_diagnostics(
    double pressure_to_mechanics,
    double reaction_to_thermal,
    double damage_to_voxel,
    double mechanics_rate,
    double pressure_diffusivity,
    double thermal_diffusivity,
    double mass_transfer_coeff) {
    return unified_pipeline::make_dictionary(
        "pressure_to_mechanics_scalar", pressure_to_mechanics,
        "reaction_to_thermal_scalar", reaction_to_thermal,
        "damage_to_voxel_scalar", damage_to_voxel,
        "mechanics_exchange_rate", mechanics_rate,
        "pressure_diffusivity", pressure_diffusivity,
        "thermal_diffusivity", thermal_diffusivity,
        "mass_transfer_coeff", mass_transfer_coeff);
}
} // namespace

Array default_required_channels() {
    Array channels;
    static const char *k_channels[] = {"mass", "position", "velocity", "force", "pressure", "pressure_gradient", "density", "temperature",
        "velocity_divergence", "neighbor_temperature", "ambient_temperature", "normal_force", "contact_velocity", "slope_angle_deg",
        "shock_impulse", "shock_distance", "reactant_a", "reactant_b", "stress", "strain", "damage"};
    for (const char *channel : k_channels) {
        channels.append(String(channel));
    }
    return channels;
}

double clamped(const Variant &value, double min_v, double max_v, double fallback) {
    return std::clamp(as_number(value, fallback), min_v, max_v);
}

double pressure_window_factor(double pressure, double min_pressure, double max_pressure, double optimal_pressure) {
    if (pressure < min_pressure || pressure > max_pressure) {
        return 0.0;
    }
    const double left = std::max(1.0e-6, optimal_pressure - min_pressure);
    const double right = std::max(1.0e-6, max_pressure - optimal_pressure);
    if (pressure <= optimal_pressure) {
        return std::clamp((pressure - min_pressure) / left, 0.0, 1.0);
    }
    return std::clamp((max_pressure - pressure) / right, 0.0, 1.0);
}

Dictionary boundary_contract(const Dictionary &stage_config, const Dictionary &frame_inputs) {
    const String mode_raw = String(frame_inputs.get("boundary_mode", stage_config.get("boundary_mode", "open"))).to_lower();
    const String mode = (mode_raw == "closed" || mode_raw == "reflective") ? mode_raw : String("open");
    const double obstacle_attenuation = clamped(
        frame_inputs.get("obstacle_attenuation", stage_config.get("obstacle_attenuation", 0.0)),
        0.0,
        1.0,
        0.0);
    const double constraint_factor = clamped(frame_inputs.get("constraint_factor", stage_config.get("constraint_factor", 1.0)), 0.0, 1.0, 1.0);
    double directional_multiplier = (1.0 - obstacle_attenuation) * constraint_factor;
    if (mode == "closed") {
        directional_multiplier = 0.0;
    } else if (mode == "reflective") {
        directional_multiplier = -directional_multiplier;
    }
    return unified_pipeline::make_dictionary(
        "mode", mode,
        "obstacle_attenuation", obstacle_attenuation,
        "constraint_factor", constraint_factor,
        "directional_multiplier", directional_multiplier,
        "scalar_multiplier", std::abs(directional_multiplier));
}

Dictionary stage_total_template(const String &stage_type) {
    Dictionary total;
    total["stage_type"] = stage_type;
    total["count"] = static_cast<int64_t>(0);
    total["mass_proxy_delta_sum"] = 0.0;
    total["energy_proxy_delta_sum"] = 0.0;
    return total;
}

void append_conservation(Dictionary &totals, const String &stage_type, const Dictionary &stage_result) {
    Dictionary stage_total = totals.get(stage_type, stage_total_template(stage_type));
    const int64_t previous_count = static_cast<int64_t>(stage_total.get("count", static_cast<int64_t>(0)));
    const double previous_mass_sum = clamped(stage_total.get("mass_proxy_delta_sum", 0.0), -1e18, 1e18, 0.0);
    const double previous_energy_sum = clamped(stage_total.get("energy_proxy_delta_sum", 0.0), -1e18, 1e18, 0.0);

    const Dictionary conservation = stage_result.get("conservation", Dictionary());
    const double mass_delta = clamped(conservation.get("mass_proxy_delta", 0.0), -1e18, 1e18, 0.0);
    const double energy_delta = clamped(conservation.get("energy_proxy_delta", 0.0), -1e18, 1e18, 0.0);

    stage_total["count"] = previous_count + 1;
    stage_total["mass_proxy_delta_sum"] = previous_mass_sum + mass_delta;
    stage_total["energy_proxy_delta_sum"] = previous_energy_sum + energy_delta;
    totals[stage_type] = stage_total;
}

void aggregate_overall_conservation(Dictionary &diagnostics) {
    const Dictionary stage_totals = diagnostics.get("by_stage_type", Dictionary());

    double mass_total = 0.0;
    double energy_total = 0.0;
    int64_t stage_count = 0;

    const Array keys = stage_totals.keys();
    for (int64_t i = 0; i < keys.size(); i++) {
        const Variant key = keys[i];
        if (key.get_type() != Variant::STRING && key.get_type() != Variant::STRING_NAME) {
            continue;
        }
        const Dictionary stage_total = stage_totals.get(key, Dictionary());
        mass_total += clamped(stage_total.get("mass_proxy_delta_sum", 0.0), -1e18, 1e18, 0.0);
        energy_total += clamped(stage_total.get("energy_proxy_delta_sum", 0.0), -1e18, 1e18, 0.0);
        stage_count += static_cast<int64_t>(stage_total.get("count", static_cast<int64_t>(0)));
    }

    diagnostics["overall"] = unified_pipeline::make_dictionary(
        "stage_count", stage_count,
        "mass_proxy_delta_total", mass_total,
        "energy_proxy_delta_total", energy_total);
}

Dictionary run_field_buffer_evolution(
    const Dictionary &config,
    const Array &mechanics_stages,
    const Array &pressure_stages,
    const Array &thermal_stages,
    const Dictionary &frame_inputs,
    double delta_seconds) {
    const Dictionary field_buffers = frame_inputs.get("field_buffers", Dictionary());

    Array mass = to_numeric_array(field_buffers.get("mass", frame_inputs.get("mass_field", Variant())));
    Array pressure = to_numeric_array(field_buffers.get("pressure", frame_inputs.get("pressure_field", Variant())));
    Array temperature = to_numeric_array(field_buffers.get("temperature", frame_inputs.get("temperature_field", Variant())));
    Array velocity = to_numeric_array(field_buffers.get("velocity", frame_inputs.get("velocity_field", Variant())));
    Array density = to_numeric_array(field_buffers.get("density", frame_inputs.get("density_field", Variant())));
    Array topology = to_topology(field_buffers.get("neighbor_topology", frame_inputs.get("neighbor_topology", Variant())));

    String mode = "array";
    if (mass.is_empty() || pressure.is_empty() || temperature.is_empty() || velocity.is_empty()) {
        const Array cells = field_buffers.get("cells", frame_inputs.get("cells", Array()));
        if (!cells.is_empty()) {
            mode = "cell";
            mass.clear();
            pressure.clear();
            temperature.clear();
            velocity.clear();
            density.clear();
            topology.clear();
            mass.resize(cells.size());
            pressure.resize(cells.size());
            temperature.resize(cells.size());
            velocity.resize(cells.size());
            density.resize(cells.size());
            topology.resize(cells.size());
            for (int64_t i = 0; i < cells.size(); i++) {
                const Variant cell_variant = cells[i];
                if (cell_variant.get_type() != Variant::DICTIONARY) {
                    mass[i] = 0.0;
                    pressure[i] = 0.0;
                    temperature[i] = 0.0;
                    velocity[i] = 0.0;
                    density[i] = 0.0;
                    topology[i] = Array();
                    continue;
                }
                const Dictionary cell = cell_variant;
                const double cell_mass = clamped(cell.get("mass", 0.0), 0.0, 1.0e9, 0.0);
                mass[i] = cell_mass;
                pressure[i] = clamped(cell.get("pressure", 0.0), -1.0e9, 1.0e9, 0.0);
                temperature[i] = clamped(cell.get("temperature", 0.0), 0.0, 2.0e4, 0.0);
                velocity[i] = clamped(cell.get("velocity", 0.0), -1.0e6, 1.0e6, 0.0);
                density[i] = clamped(cell.get("density", cell_mass), 0.0, 1.0e9, cell_mass);
                topology[i] = to_topology_row(cell.get("neighbors", Array()));
            }
        }
    }

    if (mass.is_empty() || pressure.is_empty() || temperature.is_empty() || velocity.is_empty()) {
        Dictionary result = unified_pipeline::make_dictionary(
            "enabled", false,
            "mode", String("none"),
            "cell_count_updated", static_cast<int64_t>(0),
            "mass_drift_proxy", 0.0,
            "energy_drift_proxy", 0.0,
            "pair_updates", static_cast<int64_t>(0));
        result["stage_coupling"] = wave_a_stage_coupling(0.0, 0.0, 0.0);
        result["coupling_markers"] = wave_a_coupling_markers();
        result["coupling_scalar_diagnostics"] = wave_a_coupling_scalar_diagnostics(0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0);
        return result;
    }

    const int64_t cell_count = std::min(std::min(mass.size(), pressure.size()), std::min(temperature.size(), velocity.size()));
    if (cell_count <= 0) {
        Dictionary result = unified_pipeline::make_dictionary(
            "enabled", false,
            "mode", String("none"),
            "cell_count_updated", static_cast<int64_t>(0),
            "mass_drift_proxy", 0.0,
            "energy_drift_proxy", 0.0,
            "pair_updates", static_cast<int64_t>(0));
        result["stage_coupling"] = wave_a_stage_coupling(0.0, 0.0, 0.0);
        result["coupling_markers"] = wave_a_coupling_markers();
        result["coupling_scalar_diagnostics"] = wave_a_coupling_scalar_diagnostics(0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0);
        return result;
    }

    mass.resize(cell_count);
    pressure.resize(cell_count);
    temperature.resize(cell_count);
    velocity.resize(cell_count);
    density.resize(cell_count);
    copy_if_missing(density, mass, 0.0);
    if (density.size() != cell_count) {
        density.resize(cell_count);
        for (int64_t i = 0; i < cell_count; i++) {
            density[i] = clamped(density[i], 0.0, 1.0e9, clamped(mass[i], 0.0, 1.0e9, 0.0));
        }
    }

    set_default_topology(topology, cell_count);

    const double mechanics_rate = averaged_stage_param(
        mechanics_stages,
        "neighbor_exchange_rate",
        clamped(config.get("field_mechanics_exchange_rate", 0.05), 0.0, 1.0e6, 0.05),
        0.0,
        1.0e6);
    const double pressure_diffusivity = averaged_stage_param(
        pressure_stages,
        "neighbor_diffusivity",
        clamped(config.get("field_pressure_diffusivity", 0.05), 0.0, 1.0e6, 0.05),
        0.0,
        1.0e6);
    const double thermal_diffusivity = averaged_stage_param(
        thermal_stages,
        "neighbor_diffusivity",
        clamped(config.get("field_thermal_diffusivity", 0.05), 0.0, 1.0e6, 0.05),
        0.0,
        1.0e6);
    const double mass_transfer_coeff = clamped(config.get("field_mass_transfer_coeff", pressure_diffusivity * 0.1), 0.0, 1.0e6, pressure_diffusivity * 0.1);
    const double pressure_to_mechanics_scalar = mechanics_rate * pressure_diffusivity;
    const double reaction_to_thermal_scalar = clamped(config.get("field_reaction_thermal_coupling", thermal_diffusivity), 0.0, 1.0e6, thermal_diffusivity);
    const double damage_to_voxel_scalar = clamped(config.get("field_damage_voxel_coupling", mass_transfer_coeff), 0.0, 1.0e6, mass_transfer_coeff);

    Array mass_next = mass.duplicate();
    Array pressure_next = pressure.duplicate();
    Array temperature_next = temperature.duplicate();
    Array velocity_next = velocity.duplicate();
    Array density_next = density.duplicate();

    int64_t pair_updates = 0;
    for (int64_t i = 0; i < cell_count; i++) {
        const Array neighbors = to_topology_row(topology[i]);
        for (int64_t n = 0; n < neighbors.size(); n++) {
            const int64_t j = as_index(neighbors[n], -1);
            if (j <= i || j < 0 || j >= cell_count) {
                continue;
            }

            const double mass_i = std::max(1.0e-6, clamped(mass[i], 0.0, 1.0e9, 0.0));
            const double mass_j = std::max(1.0e-6, clamped(mass[j], 0.0, 1.0e9, 0.0));
            const double velocity_i = clamped(velocity[i], -1.0e6, 1.0e6, 0.0);
            const double velocity_j = clamped(velocity[j], -1.0e6, 1.0e6, 0.0);
            const double pressure_i = clamped(pressure[i], -1.0e9, 1.0e9, 0.0);
            const double pressure_j = clamped(pressure[j], -1.0e9, 1.0e9, 0.0);
            const double temperature_i = clamped(temperature[i], 0.0, 2.0e4, 0.0);
            const double temperature_j = clamped(temperature[j], 0.0, 2.0e4, 0.0);

            const double impulse = mechanics_rate * (velocity_j - velocity_i) * delta_seconds;
            const double velocity_delta_i = impulse / mass_i;
            const double velocity_delta_j = -impulse / mass_j;
            velocity_next[i] = clamped(as_number(velocity_next[i], 0.0) + velocity_delta_i, -1.0e6, 1.0e6, 0.0);
            velocity_next[j] = clamped(as_number(velocity_next[j], 0.0) + velocity_delta_j, -1.0e6, 1.0e6, 0.0);

            const double pressure_flux = pressure_diffusivity * (pressure_j - pressure_i) * delta_seconds;
            pressure_next[i] = as_number(pressure_next[i], 0.0) + pressure_flux;
            pressure_next[j] = as_number(pressure_next[j], 0.0) - pressure_flux;

            const double thermal_flux = thermal_diffusivity * (temperature_j - temperature_i) * delta_seconds;
            temperature_next[i] = std::max(0.0, as_number(temperature_next[i], 0.0) + thermal_flux);
            temperature_next[j] = std::max(0.0, as_number(temperature_next[j], 0.0) - thermal_flux);

            const double desired_transfer = mass_transfer_coeff * (pressure_j - pressure_i) * delta_seconds;
            const double max_from_i = std::max(0.0, as_number(mass_next[i], 0.0) - 1.0e-6);
            const double max_from_j = std::max(0.0, as_number(mass_next[j], 0.0) - 1.0e-6);
            double transfer_to_i = desired_transfer;
            if (transfer_to_i > 0.0) {
                transfer_to_i = std::min(transfer_to_i, max_from_j);
            } else {
                transfer_to_i = std::max(transfer_to_i, -max_from_i);
            }

            mass_next[i] = std::max(1.0e-6, as_number(mass_next[i], 0.0) + transfer_to_i);
            mass_next[j] = std::max(1.0e-6, as_number(mass_next[j], 0.0) - transfer_to_i);
            density_next[i] = std::max(1.0e-6, as_number(density_next[i], 0.0) + transfer_to_i);
            density_next[j] = std::max(1.0e-6, as_number(density_next[j], 0.0) - transfer_to_i);

            pair_updates += 1;
        }
    }

    const double mass_before = sum_array(mass);
    const double mass_after = sum_array(mass_next);
    const double energy_before = proxy_energy_total(mass, velocity, pressure, temperature);
    const double energy_after = proxy_energy_total(mass_next, velocity_next, pressure_next, temperature_next);
    const double mass_drift_proxy = clamped(mass_after - mass_before, -1.0e18, 1.0e18, 0.0);
    const double energy_drift_proxy = clamped(energy_after - energy_before, -1.0e18, 1.0e18, 0.0);

    Dictionary result = unified_pipeline::make_dictionary(
        "enabled", true,
        "mode", mode,
        "cell_count_updated", cell_count,
        "pair_updates", pair_updates,
        "mechanics_exchange_rate", mechanics_rate,
        "pressure_diffusivity", pressure_diffusivity,
        "thermal_diffusivity", thermal_diffusivity,
        "mass_transfer_coeff", mass_transfer_coeff,
        "mass_drift_proxy", mass_drift_proxy,
        "energy_drift_proxy", energy_drift_proxy);
    result["updated_fields"] = unified_pipeline::make_dictionary(
        "mass", mass_next,
        "density", density_next,
        "pressure", pressure_next,
        "temperature", temperature_next,
        "velocity", velocity_next,
        "neighbor_topology", topology);
    result["stage_coupling"] = wave_a_stage_coupling(pressure_to_mechanics_scalar, reaction_to_thermal_scalar, damage_to_voxel_scalar);
    result["coupling_markers"] = wave_a_coupling_markers();
    result["coupling_scalar_diagnostics"] = wave_a_coupling_scalar_diagnostics(
        pressure_to_mechanics_scalar,
        reaction_to_thermal_scalar,
        damage_to_voxel_scalar,
        mechanics_rate,
        pressure_diffusivity,
        thermal_diffusivity,
        mass_transfer_coeff);

    if (mode == "cell") {
        const Array source_cells = field_buffers.get("cells", frame_inputs.get("cells", Array()));
        Array updated_cells;
        updated_cells.resize(cell_count);
        for (int64_t i = 0; i < cell_count; i++) {
            Dictionary cell;
            if (i < source_cells.size() && source_cells[i].get_type() == Variant::DICTIONARY) {
                cell = Dictionary(source_cells[i]).duplicate(true);
            }
            cell["mass"] = mass_next[i];
            cell["density"] = density_next[i];
            cell["pressure"] = pressure_next[i];
            cell["temperature"] = temperature_next[i];
            cell["velocity"] = velocity_next[i];
            cell["neighbors"] = to_topology_row(topology[i]);
            updated_cells[i] = cell;
        }
        result["updated_cells"] = updated_cells;
    }

    return result;
}

} // namespace local_agents::simulation::unified_pipeline
