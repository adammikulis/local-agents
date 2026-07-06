class_name LAMaterialWater3D
extends RefCounted

## LAMaterialWater3D — the 3D WATER cellular-automaton step of the dense LAMaterialField3D, extracted from
## the field so the composition-root file stays under the size gate. It holds NO authoritative grid state:
## water + its double buffer live on the owning field (`_f._water`, `_f._wnext`) and it reaches into `_f`
## for the geometry (`_dim_*`, `_cell_count`), the masks (`_solid`, `_static`), the index helper (`_idx`),
## the pressure model (`_f._stable_below`, kept on the field because MaterialSlump3D + MaterialLava3D also
## call `_f._stable_below`), and the CA tunables (`_f.MAX_MASS` … `_f.LATERAL_FRACTION`).
##
## Finite-volume cellular water (fall, pressurise, spread — mass-conserving and stable): fills sealed
## caverns bottom-up + supports pressure so connected water finds its level (rivers, lakes, the sea, and
## underground pools + water pouring into a cave through a shaft). Adapted from the classic 2D "finite
## water cells" scheme, generalised to 3D (down, up-if-compressed, 4 lateral). The GPU port is
## kernels3d/water3d.glsl; this is the CPU oracle + headless path (the field's `step_water()` forwards here,
## which the parity harnesses call). (Explicit types only — no ':=' inferred typing.)

var _f = null                                            # back-reference to the owning LAMaterialField3D


func setup(field) -> void:
	_f = field


## One water step: gravity fall, upward pressure relief, then lateral levelling — mass-conserving via a
## double buffer. Fills caverns bottom-up and lets connected water find its level (rivers, lakes, sea,
## and now underground pools + water pouring into a cave through a shaft).
func step() -> void:
	if _f == null or _f._cell_count <= 0:
		return
	var dim_x: int = _f._dim_x
	var dim_y: int = _f._dim_y
	var dim_z: int = _f._dim_z
	var cell_count: int = _f._cell_count
	var solid: PackedByteArray = _f._solid
	var stat: PackedByteArray = _f._static
	var water: PackedFloat32Array = _f._water
	var wnext: PackedFloat32Array = _f._wnext
	var max_mass: float = _f.MAX_MASS
	var min_mass: float = _f.MIN_MASS
	var max_flow: float = _f.MAX_FLOW
	var min_flow: float = _f.MIN_FLOW
	var lateral_fraction: float = _f.LATERAL_FRACTION

	# Start next = current; every transfer edits wnext so reads stay on the stable water snapshot.
	for i in range(cell_count):
		wnext[i] = water[i]

	var layer: int = dim_x * dim_z
	for iy in range(dim_y):
		for iz in range(dim_z):
			for ix in range(dim_x):
				var i: int = (iy * dim_z + iz) * dim_x + ix
				# Skip rock and calm STATIC sea — the expensive flow math only runs on dynamic water.
				if solid[i] != 0 or stat[i] != 0:
					continue
				var remaining: float = water[i]
				if remaining < min_mass:
					continue
				var flow: float = 0.0

				# 1) DOWN — gravity. Move toward the stable split with the cell below (drain into sea).
				if iy > 0:
					var ib: int = i - layer
					if solid[ib] == 0:
						if stat[ib] != 0:
							# The sea below is an infinite sink: water pours in and is absorbed.
							wnext[i] -= remaining
							remaining = 0.0
						else:
							flow = _f._stable_below(remaining + water[ib]) - water[ib]
							flow = clampf(flow, 0.0, minf(max_flow, remaining))
							if flow > min_flow:
								wnext[i] -= flow
								wnext[ib] += flow
								remaining -= flow
				if remaining < min_mass:
					continue

				# 2) LATERAL — level out with the 4 side neighbours (only push to lower ones).
				var lat: Array = [
					[ix - 1, iz], [ix + 1, iz], [ix, iz - 1], [ix, iz + 1]
				]
				for pr in lat:
					if remaining < min_mass:
						break
					var nx: int = pr[0]
					var nz: int = pr[1]
					if nx < 0 or nx >= dim_x or nz < 0 or nz >= dim_z:
						continue
					var inb: int = _f._idx(nx, iy, nz)
					if solid[inb] != 0:
						continue
					if stat[inb] != 0:
						# Reached the sea sideways (a river mouth) — absorb a share and move on.
						var drain: float = clampf(remaining * lateral_fraction, 0.0, remaining)
						wnext[i] -= drain
						remaining -= drain
						continue
					var diff: float = remaining - water[inb]
					if diff > min_flow:
						var lflow: float = clampf(diff * lateral_fraction, 0.0, minf(max_flow, remaining))
						if lflow > min_flow:
							wnext[i] -= lflow
							wnext[inb] += lflow
							remaining -= lflow

				# 3) UP — only overflow (compressed above MAX_MASS) pushes into the cell above.
				if remaining > max_mass and iy < dim_y - 1:
					var iu: int = i + layer
					if solid[iu] == 0 and stat[iu] == 0:
						var uflow: float = remaining - _f._stable_below(remaining + water[iu])
						uflow = clampf(uflow, 0.0, minf(max_flow, remaining))
						if uflow > min_flow:
							wnext[i] -= uflow
							wnext[iu] += uflow
							remaining -= uflow

	# Commit the buffer (swap on the field so queries read the fresh state).
	_f._water = wnext
	_f._wnext = water
