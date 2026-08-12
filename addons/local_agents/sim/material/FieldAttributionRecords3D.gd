class_name LAFieldAttributionRecords
extends RefCounted

## Which pass produces each channel's ping-pong half, and which keys the report publishes. Keyed by CHANNEL;
## SINGLE channels are absent, and `read_raw` ignores the half for those.
const PRODUCERS: Dictionary = {
	"temp": "TransportPass",
	"h2o": "TransportPass",
	"silicate": "TransportPass",
	"o2": "TransportPass",
	"co2": "TransportPass",
	"n2": "TransportPass",
	"fert": "TransportPass",
	"shock": "TransportPass",
	"fungus": "FungusPass",
}

## Passes that bind no writable temp buffer. A heat leg above the readback resolution on one of these
## falsifies the instrument rather than the planet.
const SILENT_HEAT_PASSES: PackedStringArray = ["solid_derive", "fungus"]

## One report row per tracked scalar. `scalar` names the sampled quantity; the rest name the published keys.
## `residual_of` lists the scalars whose leg sums are subtracted from this row's step delta; it defaults to
## the row's own scalar.
const MASS_ROWS: Array = [
	{"scalar": "open", "total": "open_total", "step": "step_open", "legs": "legs_open",
		"residual": "residual_open", "chain": "chain_open"},
	{"scalar": "all", "total": "all_total", "step": "step_all", "legs": "legs_all",
		"residual": "residual_all", "chain": "chain_all"},
]

const ENERGY_ROWS: Array = [
	{"scalar": "stock", "total": "stock_j", "step": "step_total_j", "residual": "residual_j",
		"residual_of": ["heat", "capacity"], "chain": "chain_j"},
	{"scalar": "cap", "total": "cap_j_k"},
	{"scalar": "heat", "step": "step_heat_j", "legs": "legs_heat_j"},
	{"scalar": "capacity", "step": "step_cap_j", "legs": "legs_cap_j"},
]

## Which environment variable arms which substance, in the precedence the driver's single step-probe slot is
## handed out by.
const ORDER: PackedStringArray = ["LA_MINERAL_BUDGET", "LA_H2O_BUDGET", "LA_ENERGY_BUDGET"]


## The record for one armed environment variable. Empty for a name that is not in ORDER.
static func of(env_name: String) -> Dictionary:
	match env_name:
		"LA_MINERAL_BUDGET":
			return {
				"marker": "MINERAL_BUDGET",
				"channels": LAFieldLedgerRecords.MINERAL_SUM,
				"energy": false,
				"rows": MASS_ROWS,
				"parts": {"open": "open_parts", "all": "all_parts"},
				"derived": {"buried": ["all", "open"]},
				"resolution": {"key": "resolution", "scalar": "all"},
			}
		"LA_H2O_BUDGET":
			return {
				"marker": "H2O_BUDGET",
				"channels": LAFieldLedgerRecords.H2O,
				"energy": false,
				"rows": MASS_ROWS,
				"parts": {"open": "open_parts", "all": "all_parts"},
				"derived": {"buried": ["all", "open"]},
				"resolution": {"key": "resolution", "scalar": "all"},
			}
		"LA_ENERGY_BUDGET":
			return {
				"marker": "ENERGY_BUDGET",
				"channels": LAFieldLedgerRecords.energy(),
				"energy": true,
				"rows": ENERGY_ROWS,
				"parts": {},
				"derived": {},
				"resolution": {"key": "resolution_j", "scalar": "stock"},
				"silent_heat": SILENT_HEAT_PASSES,
			}
	return {}
