#ifndef LOCAL_AGENTS_LA_BALLISTICS_HPP
#define LOCAL_AGENTS_LA_BALLISTICS_HPP

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/basis.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/vector3.hpp>

namespace godot {

// EVERY FREE BODY, ONE INTEGRATOR. A meteor, an ejecta parcel and a dropped test mass are the same thing:
// mass at a position with a velocity, coasting under g. Nothing here knows which is which.
//
// g is the SOLVED field inside the box (trilinear over the cell centres GravityPass drained) and the
// Newtonian sum over the system's point masses outside it. A body stops at the first solid cell it enters
// after leaving solid, or below the dominant body's surface radius when it is outside the box.
class LABallistics : public RefCounted {
	GDCLASS(LABallistics, RefCounted);

public:
	// The system's point masses, in the scene's own frame. Republished every step: the bodies move.
	// Each row: {"center": Vector3, "mass_kg": float, "radius_m": float, "frame": bool}. The row marked
	// `frame` is the one the coordinates are measured from, so its own acceleration is subtracted.
	static void set_system(const Array &p_bodies);
	static int system_size();
	static Vector3 body_center(int p_i);
	static double body_radius(int p_i);
	// Standard gravitational parameter GM of one row, m^3/s^2. 0 for a row with no measured mass.
	static double body_mu(int p_i);
	// The largest |g| any declared body's monopole field reaches, m/s^2: GM/R^2 at its own surface,
	// which is the maximum outside it and above every value inside it. 0 with no body.
	static double max_surface_gravity();
	// The row whose DIRECT pull is largest at a point; -1 when the system is empty.
	static int dominant(const Vector3 &p_at);
	// Circular-orbit speed about that row, m/s.
	static double circular_speed(const Vector3 &p_at);
	// The Newtonian sum, frame-corrected. p_exclude drops one row from the direct term (a body does not
	// pull on itself).
	static Vector3 acceleration_at(const Vector3 &p_at, int p_exclude);

	// The field's own state, republished when it re-solves: the grid, the drained gravity mirror
	// (flat cell*3, m/s^2), the solid mask (1 = rock), LAFieldCellMass3D.mirrors() for the medium's
	// mass density, and the frame the grid is laid in (body -> world, about p_pivot).
	static void set_field(Object *p_grid, const PackedFloat32Array &p_gravity,
			const PackedByteArray &p_solid, const Array &p_mass_mirrors, const Basis &p_frame,
			const Vector3 &p_pivot);
	static void clear_field();
	static bool has_field();

	// What a body at this point falls under: the solved field inside the box, the point-mass sum outside.
	static Vector3 g_at(const Vector3 &p_at);
	// True where a body would stop: the field's solid mask inside the box, a body's surface radius outside.
	static bool rock_at(const Vector3 &p_at);
	// Mass density of the medium at a point, kg/m^3. 0 outside the box or with no field.
	static double medium_density_at(const Vector3 &p_at);
	// Largest relative gap between g_at(a cell centre) and that cell's own value in the mirror this was
	// handed, over p_samples cells spread through the box. NAN when no sampled cell has a solved g.
	static double read_check(int p_samples);

	// A free body. p_mass_kg and p_radius_m give it a cross-section to ram air with; a body declared with
	// neither is a point, and a point has no drag. Returns the id state() and release() take.
	static int drop(const Vector3 &p_pos, const Vector3 &p_vel, double p_mass_kg, double p_radius_m);
	static void release(int p_id);
	// {position, velocity, speed, landed, fall_time_s, drag_heat_j, cell, from, g_release, height_m}.
	// Empty for an unknown id.
	static Dictionary state(int p_id);
	static int live_count();
	// Advance every live body by p_dt_s and return the rows that landed this step:
	// {id, position, speed, time, cell}. A landed body stays readable until released.
	static Array step(double p_dt_s);
	// Joules the drag took out of the live bodies this step, as {id, cell, joules, position} rows, so the
	// caller can put that energy back into the medium it came out of.
	static Array drag_work();
	static void clear();

protected:
	static void _bind_methods();
};

} // namespace godot

#endif // LOCAL_AGENTS_LA_BALLISTICS_HPP
