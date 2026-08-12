class_name LACreatureExcretion
extends RefCounted


## Minimum pending digested residue before a feces deposit is made, as a fraction of gut capacity.
const FECES_MIN_GUT_FRAC: float = 0.02

## Detritus deposited into the field's soil-nutrient loop per unit of feces mass (same 1:1 conserving-transfer
## convention CreatureRagdoll.DETRITUS_YIELD uses for carcasses) — R15 fungus-decompose then rots it into
## fertility, and R19 photosynthesis now actually consumes that fertility to grow (the loop this closes).
const FECES_DETRITUS_YIELD: float = 1.0


static func tick(c, ground_pos: Vector3, delta: float) -> void:
	c._poop_cd -= delta
	if c._poop_cd <= 0.0:
		c._poop_cd = LASimRng.for_domain("life").randf_range(24.0, 48.0)
		if c.gut_waste >= maxf(float(c.gut_capacity), 0.0) * FECES_MIN_GUT_FRAC:
			deposit(c, ground_pos, "feces", c.gut_waste)
			c.gut_waste = 0.0                     # expelled — the pending digested residue is passed (no double count)
	c._urine_cd -= delta
	if c._urine_cd <= 0.0:
		c._urine_cd = LASimRng.for_domain("life").randf_range(10.0, 22.0)
		deposit(c, ground_pos, "urine", 0.0)


## Deposit waste at `ground_pos`. Faeces is organic matter, so it enters the detritus channel and rots there.
static func deposit(c, ground_pos: Vector3, kind: String, waste_amount: float) -> void:
	if c._material == null:
		return
	if kind == "feces" and waste_amount > 0.0 and c._material.has_method("deposit_detritus"):
		c._material.deposit_detritus(ground_pos, waste_amount * FECES_DETRITUS_YIELD)
