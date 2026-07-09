class_name LAMaterialReactions3D
extends RefCounted

## DATA TABLE for the generic DEFS reaction engine (Phase B3 §2). Every hand-coded "clean same-cell"
## chemical/phase reaction on the sphere path (gas sky-exchange, CO₂ vent, fungus decompose, …) is expressed
## HERE as a fixed-size Reaction RECORD instead of a bespoke kernel. `reactions_sphere3d.glsl` loops these
## records per cell; ReactionsPass uploads them once as a read-only SSBO. Adding a future reaction is adding a
## record to `records()` — NOT writing a kernel. (dissolve-don't-patch: success = bespoke kernels deleted.)
##
## The kernel binds every reactable CHANNEL at a fixed binding and a record names a channel by a SLOT enum
## (below), resolved through the kernel's read_ch/add_ch switch-ladders. Only the channels the live records
## touch need be bound (o2/co2/detritus/fungus + the fungus-fert SCRATCH here); the ladder covers the rest so
## a later record can reference them by adding the one binding.

# --- Channel slot enum (MUST match the #defines in reactions_sphere3d.glsl) --------------------------------
const TEMP: int = 0
const WATER: int = 1
const AIRWATER: int = 2
const O2: int = 3
const CO2: int = 4
const FUEL: int = 5
const FIRE: int = 6
const DETRITUS: int = 7
const FUNGUS: int = 8
const FERT: int = 9
const LAVA: int = 10

# --- Rate models (extent x per cell) ---------------------------------------------------------------------
const CONST_FRAC: int = 0             # x = k * driver
const BILINEAR: int = 1               # x = k * driver * driver2
const EXCESS_OVER_THRESHOLD: int = 2  # x = max(0, driver - threshold) * k
const RELAX_TARGET: int = 3           # x = k * (threshold - driver)  (signed; no reactant; product = driver)

# --- Gate bitflags (0 = ungated) -------------------------------------------------------------------------
const GATE_OPEN_ABOVE: int = 1
const GATE_SURFACE: int = 2
const GATE_NEAR_GROUND: int = 4
const GATE_DAYLIGHT: int = 8

# --- Product targets -------------------------------------------------------------------------------------
const TGT_SELF: int = 0               # add into the live/back cell channel
const TGT_SCRATCH: int = 3            # add into the per-cell scratch buffer (fungus-fert pattern)

const RECORD_BYTES: int = 128         # std430 size of one Reaction (see layout in serialize())

# Constants copied VERBATIM from the kernels being dissolved (MaterialGas3D.gd / MaterialFungus3D.gd).
const SKY_EXCHANGE: float = 0.5
const O2_AMBIENT: float = 1.0
const CO2_SKY_VENT: float = 0.25
const DECOMPOSE_RATE: float = 0.05
const CO2_PER_DECOMPOSE: float = 1.0
const O2_PER_DECOMPOSE: float = 0.8
const FERT_PER_DECOMPOSE: float = 1.5


## Author one record as a Dictionary (unspecified fields default to the ungated/no-op values). Reactant and
## product entries are Arrays of [slot, coeff] (products carry an optional 3rd element = target, default SELF).
static func _rec(rate_model: int, rate_k: float, driver_slot: int, reactants: Array, products: Array,
		gate_mask: int = 0, threshold: float = 0.0, driver2_slot: int = -1) -> Dictionary:
	return {
		"rate_model": rate_model, "rate_k": rate_k, "threshold": threshold, "gate_mask": gate_mask,
		"driver_slot": driver_slot, "driver2_slot": driver2_slot,
		"reactants": reactants, "products": products,
	}


## The live reaction table (Phase B3 §1 "clean same-cell" set that folds now). Order is irrelevant — every
## record writes only its own cell, so the per-cell loop is order-independent.
static func records() -> Array:
	return [
		# R11 — Gas O₂ SKY-REFILL: relax O₂ toward ambient at sky-exposed surface cells (gas_sky_sphere3d:55).
		# RELAX_TARGET: x = SKY_EXCHANGE*(O2_AMBIENT - o2); product = O2 itself, no reactant.
		_rec(RELAX_TARGET, SKY_EXCHANGE, O2, [], [[O2, 1.0, TGT_SELF]], GATE_SURFACE, O2_AMBIENT),

		# R12 — Gas CO₂ SKY-VENT: const-frac decay of CO₂ at the surface (gas_sky_sphere3d:56).
		# CONST_FRAC: x = CO2_SKY_VENT*co2; the single reactant IS co2, no product → co2 -= x.
		_rec(CONST_FRAC, CO2_SKY_VENT, CO2, [[CO2, 1.0]], [], GATE_SURFACE),

		# R15 — Fungus DECOMPOSE: detritus + O₂ → CO₂ (self) + fertility (scratch) (fungus_sphere3d:100-118).
		# BILINEAR: x = DECOMPOSE_RATE*fungus*detritus, capped by the detritus + O₂ reactants (the aerobic cap
		# falls out of listing O₂ as a reactant, coeff O2_PER_DECOMPOSE). Fert → SCRATCH (fungus_fert reduce).
		_rec(BILINEAR, DECOMPOSE_RATE, FUNGUS,
			[[DETRITUS, 1.0], [O2, O2_PER_DECOMPOSE]],
			[[CO2, CO2_PER_DECOMPOSE, TGT_SELF], [FERT, FERT_PER_DECOMPOSE, TGT_SCRATCH]],
			0, 0.0, DETRITUS),
	]


## Serialize the records into a std430 SSBO byte buffer. Layout per Reaction (128 bytes, 16-aligned):
##   0 rate_model(i) 4 rate_k(f) 8 threshold(f) 12 gate_mask(i) | 16 driver_slot(i) 20 driver2_slot(i)
##   24 cap_slot(i) 28 cap_coeff(f) | 32 n_react(i) 36 n_prod(i) 40 pad 44 pad |
##   48 react_slot[4](i) | 64 react_coeff[4](f) | 80 prod_slot[4](i) | 96 prod_coeff[4](f) | 112 prod_target[4](i)
static func serialize(recs: Array) -> PackedByteArray:
	var buf: PackedByteArray = PackedByteArray()
	buf.resize(recs.size() * RECORD_BYTES)
	for r in range(recs.size()):
		var rec: Dictionary = recs[r]
		var base: int = r * RECORD_BYTES
		var reactants: Array = rec.get("reactants", [])
		var products: Array = rec.get("products", [])
		buf.encode_s32(base + 0, int(rec.get("rate_model", CONST_FRAC)))
		buf.encode_float(base + 4, float(rec.get("rate_k", 0.0)))
		buf.encode_float(base + 8, float(rec.get("threshold", 0.0)))
		buf.encode_s32(base + 12, int(rec.get("gate_mask", 0)))
		buf.encode_s32(base + 16, int(rec.get("driver_slot", 0)))
		buf.encode_s32(base + 20, int(rec.get("driver2_slot", -1)))
		buf.encode_s32(base + 24, int(rec.get("cap_slot", -1)))
		buf.encode_float(base + 28, float(rec.get("cap_coeff", 0.0)))
		buf.encode_s32(base + 32, reactants.size())
		buf.encode_s32(base + 36, products.size())
		buf.encode_s32(base + 40, 0)
		buf.encode_s32(base + 44, 0)
		for k in range(4):
			var rs: int = int(reactants[k][0]) if k < reactants.size() else -1
			var rc: float = float(reactants[k][1]) if k < reactants.size() else 0.0
			buf.encode_s32(base + 48 + k * 4, rs)
			buf.encode_float(base + 64 + k * 4, rc)
		for k in range(4):
			var ps: int = -1
			var pc: float = 0.0
			var pt: int = TGT_SELF
			if k < products.size():
				ps = int(products[k][0])
				pc = float(products[k][1])
				pt = int(products[k][2]) if products[k].size() > 2 else TGT_SELF
			buf.encode_s32(base + 80 + k * 4, ps)
			buf.encode_float(base + 96 + k * 4, pc)
			buf.encode_s32(base + 112 + k * 4, pt)
	return buf
