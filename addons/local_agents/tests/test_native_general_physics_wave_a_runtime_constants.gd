extends RefCounted

const PIPELINE_STAGE_NAME := "wave_a_continuity"

const BASE_MASS := [1.0, 2.0]
const BASE_PRESSURE := [100.0, 110.0]
const BASE_TEMPERATURE := [300.0, 320.0]
const BASE_VELOCITY := [0.0, 1.0]
const BASE_DENSITY := [1.0, 2.0]
const BASE_TOPOLOGY := [[1], [0]]
const TRANSPORT_MASS := [1.5, 0.8, 1.2]
const TRANSPORT_PRESSURE := [110.0, 95.0, 102.0]
const TRANSPORT_TEMPERATURE := [295.0, 320.0, 305.0]
const TRANSPORT_VELOCITY := [1.0, -0.4, 0.6]
const TRANSPORT_DENSITY := [1.0, 1.1, 1.4]
const TRANSPORT_TOPOLOGY_ORDER_A := [[1, 2], [0, 2], [0, 1]]
const TRANSPORT_TOPOLOGY_ORDER_B := [[2, 1], [2, 0], [1, 0]]
const TRANSPORT_TOPOLOGY_INVALID_A := [[-1, 1, 2, 256, 1.5, 99], [2, 0, 999, 0.5], [0, 1, -7, 400]]
const TRANSPORT_TOPOLOGY_INVALID_B := [[2, 99, 1.5, -2, 1], [0, 2, 0.0, -1], [1, 0, 256, 3.14]]
const TRANSPORT_INVALID_EXPECTED_PAIR_UPDATES := 3
const HOT_FIELDS := ["mass", "pressure", "temperature", "velocity", "density"]
const HANDLE_MODE_OPTIONAL_SUMMARY_KEYS := ["field_handle_marker", "field_handle_io"]
const HANDLE_MODE_RESOLVED_SOURCE := "field_buffers"
const HANDLE_MODE_EXPECTED_REFS := {
	"mass": "mass_density",
	"pressure": "pressure",
	"temperature": "temperature",
	"velocity": "momentum_x",
	"density": "density",
}
const WAVE_B_REGRESSION_SCENARIO_ORDER := ["impact", "flood", "fire", "cooling", "collapse", "mixed_material"]
const WAVE_B_REGRESSION_STEPS := 2
const WAVE_B_REPEATED_LOAD_STEPS := 8
const WAVE_B_FIELD_GROWTH_FACTOR := 25.0
const WAVE_B_FIELD_ABS_CAP := 1.0e6
const WAVE_B_BASE_MASS := [1.0, 1.1]
const WAVE_B_BASE_PRESSURE := [102.0, 118.0]
const WAVE_B_BASE_TEMPERATURE := [292.0, 308.0]
const WAVE_B_BASE_VELOCITY := [0.45, 0.55]
const WAVE_B_BASE_DENSITY := [1.0, 1.15]
const WAVE_B_BASE_TOPOLOGY := [[1], [0]]
const WAVE_B_SCENARIO_EXTRA_INPUTS := {
	"impact": {
		"shock_impulse": 4.0,
		"shock_distance": 2.5,
		"shock_gain": 1.2,
		"stress": 1.8e7,
		"cohesion": 0.62,
	},
	"flood": {
		"pressure_gradient": 1.5,
		"moisture": 0.86,
		"phase": 0,
		"porosity": 0.4,
		"porous_flow_channels": {
			"seepage": 0.22,
			"drainage": 0.18,
			"capillary": 0.25,
		},
		"neighbor_temperature": 296.0,
	},
	"fire": {
		"temperature": 900.0,
		"reactant_a": 1.2,
		"reactant_b": 0.8,
		"reaction_rate": 0.68,
		"fuel": 1.0,
		"oxygen": 0.24,
		"material_flammability": 0.92,
	},
	"cooling": {
		"ambient_temperature": 262.0,
		"velocity": 1.2,
		"temperature": 298.0,
		"thermal_diffusivity": 0.00008,
		"thermal_capacity": 2500.0,
		"thermal_conductivity": 250.0,
	},
	"collapse": {
		"stress": 2.8e8,
		"strain": 0.45,
		"damage": 0.11,
		"hardness": 0.22,
		"slope_angle_deg": 32.0,
		"normal_force": 1500.0,
	},
	"mixed_material": {
		"phase_transition_capacity": 0.35,
		"liquid_fraction": 0.18,
		"vapor_fraction": 0.02,
		"phase": 1,
		"temperature": 315.0,
		"reaction_channels": {
			"combustion": 0.32,
			"oxidation": 0.44,
			"decomposition": 0.28,
		},
		"phase_change_channels": {
			"melting": 0.07,
			"freezing": 0.0,
			"evaporation": 0.09,
		},
	},
}
