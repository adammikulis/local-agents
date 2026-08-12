#[compute]
#version 450

// The two enthalpy headers are libraries no kernel has adopted yet, so nothing would compile them and a
// syntax error in either would sit there unseen. This kernel exists to be COMPILED, not dispatched;
// test_enthalpy_roundtrip.gd reads its SPIR-V and fails on a compile error.
#include "enthalpy.glsli"
#include "mixture_enthalpy.glsli"

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict buffer Probe { float probe[]; };

void main() {
	uint i = gl_GlobalInvocationID.x * 5u;
	float h_total = probe[i];
	float p_pa = probe[i + 1u];
	float n_gas_mol = probe[i + 2u];
	SubstanceTh subs[LA_MIX_MAX];
	float mass[LA_MIX_MAX];
	subs[0] = la_h2o();
	subs[1] = la_silicate();
	subs[2] = la_h2o();
	subs[3] = la_silicate();
	mass[0] = probe[i + 3u];
	mass[1] = probe[i + 4u];
	mass[2] = 0.0;
	mass[3] = 0.0;
	bool pinned;
	float progress;
	float t = la_mix_state(subs, mass, 2, h_total, p_pa, n_gas_mol, 0.0, pinned, progress);
	vec4 st = la_enthalpy_to_state(subs[0], h_total, p_pa, 0.0);
	probe[i] = t + st.x + progress + float(pinned)
		+ la_mix_enthalpy_at(subs, mass, 2, t, p_pa, n_gas_mol, 0.0)
		+ la_state_to_enthalpy(subs[1], t, p_pa, 0.0);
}
