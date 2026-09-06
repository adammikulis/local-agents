#ifndef LOCAL_AGENTS_LA_TEST_MASSES_HPP
#define LOCAL_AGENTS_LA_TEST_MASSES_HPP

#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/vector3.hpp>

namespace godot {

// TEST MASSES: point probes the one ballistics integrator carries under the solved g. A probe writes no
// channel, declares no creation and has no cross-section to ram air with; it only reads where the field
// takes it. A world that solves no gravity has nothing for one to fall through and holds none.
class LATestMasses : public Node {
	GDCLASS(LATestMasses, Node);

	Object *_body = nullptr;
	Object *_field = nullptr;
	PackedInt32Array _ids;
	int _fallen = 0;
	bool _auto = false;
	double _release_height_m = 2000.0;

	Vector3 body_centre() const;
	Vector3 ground_velocity(const Vector3 &p_at) const;
	Vector3 ground_under_site() const;

public:
	// Bound after the world has declared its processes: without a solved field this refuses to hold a
	// probe and says so.
	void setup(Object *p_body, Object *p_field);
	bool active() const;

	// Release a probe at rest with respect to the ground under it. A mass let go of a tower keeps the
	// ground's own rotation; only the deflection off that is Coriolis. -1 where there is no field.
	int drop_at(const Vector3 &p_at);
	// The scene's own probe: release_height_m over the ground under the field box's centre.
	int drop_over_site();

	// Every probe's state, straight off the integrator. The view and the readout read this.
	Array rows() const;
	int fallen() const;

	void on_sim_step(int p_step);
	// The la_ballistics group's callback: what the integrator says reached the ground.
	void on_bodies_landed(const Array &p_landed);

	void set_release_height_m(double p_m);
	double get_release_height_m() const;

protected:
	static void _bind_methods();
};

} // namespace godot

#endif // LOCAL_AGENTS_LA_TEST_MASSES_HPP
