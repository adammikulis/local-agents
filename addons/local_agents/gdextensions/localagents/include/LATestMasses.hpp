#ifndef LOCAL_AGENTS_LA_TEST_MASSES_HPP
#define LOCAL_AGENTS_LA_TEST_MASSES_HPP

#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/basis.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include <vector>

namespace godot {

// TEST MASSES: point probes the one ballistics integrator carries under the solved g. A probe writes no
// channel, declares no creation and has no cross-section to ram air with; it only reads where the field
// takes it. A world that solves no gravity has nothing for one to fall through and holds none.
// A drop is a throw at zero speed: one release path, one record.
class LATestMasses : public Node {
	GDCLASS(LATestMasses, Node);

	struct Orb {
		int id = -1;
		Vector3 dir;              // unit, in the BODY's frame: the direction it was thrown along
		double speed = 0.0;       // m/s the thrower gave it, over the ground
		double v_release = 0.0;   // m/s in the world frame, the ground's own motion included
		double g_release = 0.0;
		double r_release = 0.0;
		bool crossed = true;      // an orb released inside the box has no face crossing to report
	};

	Object *_body = nullptr;
	Object *_field = nullptr;
	std::vector<Orb> _orbs;
	int _fallen = 0;
	bool _auto = false;
	bool _off = false;
	double _release_height_m = 2000.0;
	double _throw_speed_m_s = 0.0;
	double _lob_speed = 0.0;
	double _lob_height = 0.0;
	double _lob_in_speed = 0.0;
	double _lob_in_clearance = 0.0;

	Vector3 body_centre() const;
	Vector3 ground_velocity(const Vector3 &p_at) const;
	Vector3 ground_under_site() const;
	// The box's outward face, in the body's frame and in the world's: where a lob from outside enters.
	Vector3 box_face_body() const;
	Object *grid() const;
	// Body -> world, the rotation the grid and every release point are carried by.
	Basis body_basis() const;
	// A unit vector perpendicular to p_up, taken off the world axis least aligned with it.
	static Vector3 across(const Vector3 &p_up);
	Dictionary row_of(const Orb &p_orb) const;
	void read_command_line();
	void watch_crossings();
	void report_crossing(const Orb &p_orb, const Dictionary &p_state);
	// The field a lob from outside is about to cross, sampled half a cell either side of the box's face.
	void report_face();

public:
	// Bound after the world has declared its processes: without a solved field this refuses to hold a
	// probe and says so.
	void setup(Object *p_body, Object *p_field);
	bool active() const;

	// Release a probe at p_at carrying p_velocity over the ground under it. A mass let go of a tower or
	// lobbed from the hand keeps the ground's own rotation; only the deflection off that is Coriolis.
	// -1 where there is no field. (`throw` is a C++ keyword, hence the name.)
	int throw_orb(const Vector3 &p_at, const Vector3 &p_velocity);
	int drop_at(const Vector3 &p_at);
	// The scene's own probe: release_height_m over the ground under the field box's centre.
	int drop_over_site();

	// Every probe's state, straight off the integrator, plus what the release recorded. The view and the
	// readout read this.
	Array rows() const;
	int fallen() const;

	void on_sim_step(int p_step);
	// The la_ballistics group's callback: what the integrator says reached the ground.
	void on_bodies_landed(const Array &p_landed);

	void set_release_height_m(double p_m);
	double get_release_height_m() const;
	// The speed the next lob leaves the hand at, m/s over the ground. The hand sets it; nothing reads it
	// but the next release and the readout.
	void set_throw_speed_m_s(double p_m_s);
	double get_throw_speed_m_s() const;

protected:
	static void _bind_methods();
	// Switched off, the probes it released are gone and none is released; switched on, the scene's own
	// probe falls again.
	void _notification(int p_what);
};

} // namespace godot

#endif // LOCAL_AGENTS_LA_TEST_MASSES_HPP
