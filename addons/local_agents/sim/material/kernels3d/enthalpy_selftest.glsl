#[compute]
#version 450

#include "bindings.glsli"

// Every entry point of the two enthalpy headers at once: state_derive.glsl and reactions_sphere3d.glsl
// each adopt a part, so a syntax error in a path neither takes still fails the build. Compiled, never
// dispatched; test_enthalpy_roundtrip.gd reads its SPIR-V.
#include "enthalpy.glsli"
#define LA_MIX_SLOTS 2
#include "mixture_enthalpy.glsli"

layout(local_size_x = 64) in;

layout(set = 0, binding = LA_BIND_ENTHALPY_PROBE, std430) restrict buffer Probe { float probe[]; };

// The cell this probe stands up: two slots, each with its own mass.
float mix_m[LA_MIX_SLOTS];

int la_mix_n() { return LA_MIX_SLOTS; }
float la_mix_mass(int k) { return mix_m[k]; }
// Water in both slots.
SubstanceTh la_mix_sub(int k) { return la_h2o(); }

void main() {
	uint i = gl_GlobalInvocationID.x * 5u;
	float h_total = probe[i];
	float p_pa = probe[i + 1u];
	float room_m3 = probe[i + 2u];
	mix_m[0] = probe[i + 3u];
	mix_m[1] = probe[i + 4u];
	bool pinned;
	float progress;
	float t = la_mix_state(h_total, p_pa, room_m3, 0.0, pinned, progress);
	vec4 st = la_enthalpy_to_state(la_h2o(), h_total, p_pa, 0.0);
	probe[i] = t + st.x + progress + float(pinned)
		+ la_mix_enthalpy_at(t, p_pa, room_m3, 0.0)
		+ la_state_to_enthalpy(la_h2o(), t, p_pa, 0.0);
}
