#[compute]
#version 450

// Rotating-frame terms on momentum: Coriolis -2w x v and centrifugal -w x (w x r), per unit volume.

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict buffer MomX { float mom_x[]; };
layout(set = 0, binding = 1, std430) restrict buffer MomY { float mom_y[]; };
layout(set = 0, binding = 2, std430) restrict buffer MomZ { float mom_z[]; };
layout(set = 0, binding = 3, std430) restrict readonly buffer VelX { float vel_x[]; };
layout(set = 0, binding = 4, std430) restrict readonly buffer VelY { float vel_y[]; };
layout(set = 0, binding = 5, std430) restrict readonly buffer VelZ { float vel_z[]; };
layout(set = 0, binding = 6, std430) restrict readonly buffer RhoCond { float rho_cond[]; };
layout(set = 0, binding = 7, std430) restrict readonly buffer GasMol { float n_gas_m3[]; };
layout(set = 0, binding = 8, std430) restrict readonly buffer Pos { float pos[]; };

layout(push_constant, std430) uniform Params {
	uint cell_count;
	float dt_s;
	float omega_x;      // the body's angular velocity in the field's own axes, rad/s
	float omega_y;
	float omega_z;
	float gas_kg_mol;   // LAPhysical.MOLAR_MASS_DRY_AIR_KG_MOL
	float centre_x;     // the spin axis passes through the body centre
	float centre_y;
	float centre_z;
} params;

void main() {
	uint g = gl_GlobalInvocationID.x;
	if (g >= params.cell_count) {
		return;
	}
	vec3 omega = vec3(params.omega_x, params.omega_y, params.omega_z);
	if (dot(omega, omega) <= 0.0) {
		return;
	}
	float rho = rho_cond[g] + n_gas_m3[g] * params.gas_kg_mol;
	if (rho <= 0.0) {
		return;
	}
	vec3 v = vec3(vel_x[g], vel_y[g], vel_z[g]);
	vec3 r = vec3(pos[g * 3u], pos[g * 3u + 1u], pos[g * 3u + 2u])
		- vec3(params.centre_x, params.centre_y, params.centre_z);
	vec3 a = -2.0 * cross(omega, v) - cross(omega, cross(omega, r));
	vec3 dp = a * rho * params.dt_s;
	mom_x[g] += dp.x;
	mom_y[g] += dp.y;
	mom_z[g] += dp.z;
}
