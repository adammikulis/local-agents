#include "LATestMasses.hpp"

#include "LABallistics.hpp"
#include "LAGridGeometry.hpp"
#include "LAProcessSet.hpp"

#include <godot_cpp/classes/json.hpp>
#include <godot_cpp/classes/os.hpp>
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/basis.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include <godot_cpp/variant/vector3i.hpp>

#include <cmath>

using namespace godot;

namespace {

// The pass that solves the potential. Without it this world has no vertical and no field to fall through.
const char *GRAVITY_PASS = "GravityPass.gd";
// Cells the ground march walks before it gives up, at the box's finest edge.
const int MARCH_STEPS = 20000;
// A lob asked for on the command line: "--lob=<speed m/s>,<height m>" over the site, and
// "--lob-in=<speed m/s>,<clearance m>" from outside the box's outward face.
const char *ARG_LOB = "--lob=";
const char *ARG_LOB_IN = "--lob-in=";
bool has_gravity() {
	return LAProcessSet::has_record("pass", GRAVITY_PASS, LAProcessSet::ANY);
}

// "<a>,<b>" off a flag, or false when it names fewer than two numbers.
bool two_numbers(const String &p_arg, const char *p_prefix, double &r_a, double &r_b) {
	const String tail = p_arg.substr(String(p_prefix).length());
	const PackedStringArray f = tail.split(",");
	if (f.size() < 2) {
		return false;
	}
	r_a = f[0].to_float();
	r_b = f[1].to_float();
	return true;
}

} // namespace

void LATestMasses::setup(Object *p_body, Object *p_field) {
	if (!has_gravity()) {
		Dictionary d;
		d["rung"] = LAProcessSet::name_of(LAProcessSet::active());
		d["needs"] = String(GRAVITY_PASS);
		UtilityFunctions::print("TEST_MASS_REFUSED=" + JSON::stringify(d));
		return;
	}
	_body = p_body;
	_field = p_field;
	read_command_line();
	add_to_group("la_ballistics");
}

void LATestMasses::read_command_line() {
	const PackedStringArray args = OS::get_singleton()->get_cmdline_user_args();
	for (int i = 0; i < args.size(); i++) {
		const String a = args[i];
		if (a.begins_with(ARG_LOB_IN)) {
			two_numbers(a, ARG_LOB_IN, _lob_in_speed, _lob_in_clearance);
		} else if (a.begins_with(ARG_LOB)) {
			two_numbers(a, ARG_LOB, _lob_speed, _lob_height);
		}
	}
}

bool LATestMasses::active() const {
	return _body != nullptr && _field != nullptr;
}

Vector3 LATestMasses::body_centre() const {
	return _body ? Vector3(_body->call("center")) : Vector3();
}

Object *LATestMasses::grid() const {
	if (!_field) {
		return nullptr;
	}
	Object *g = _field->get("_grid");
	return g;
}

Basis LATestMasses::body_basis() const {
	return _field ? Basis(_field->get("_body_basis")) : Basis();
}

Vector3 LATestMasses::ground_velocity(const Vector3 &p_at) const {
	if (!_body) {
		return Vector3();
	}
	const double rate = double(_body->call("angular_velocity_rad_s"));
	if (!std::isfinite(rate)) {
		return Vector3();
	}
	const Vector3 axis = Vector3(_body->call("spin_axis")).normalized();
	return (axis * float(rate)).cross(p_at - body_centre());
}

Vector3 LATestMasses::across(const Vector3 &p_up) {
	const Vector3 axes[3] = { Vector3(1, 0, 0), Vector3(0, 1, 0), Vector3(0, 0, 1) };
	int best = 0;
	double least = 2.0;
	for (int k = 0; k < 3; k++) {
		const double d = std::fabs(double(axes[k].dot(p_up)));
		if (d < least) {
			least = d;
			best = k;
		}
	}
	return axes[best].cross(p_up).normalized();
}

// The first rock under the box centre, walked along the field's own solid mask at its finest edge.
Vector3 LATestMasses::ground_under_site() const {
	const Vector3 nowhere(NAN, NAN, NAN);
	Ref<RefCounted> slice = _field->get("_slice");
	if (slice.is_null()) {
		return nowhere;
	}
	const Vector3 centre = Vector3(_field->call("field_to_point",
			body_centre() + Vector3(slice->call("resolved_offset", _body))));
	const Vector3 up = (centre - body_centre()).normalized();
	const double edge = double(slice->get("fine_size"));
	const float step = float(edge > 0.0 ? edge : 1.0);
	Vector3 p = centre;
	int guard = MARCH_STEPS;
	// Out of the rock first where the site stands above the box centre, then down onto the first solid.
	while (LABallistics::rock_at(p) && guard-- > 0) {
		p += up * step;
	}
	while (!LABallistics::rock_at(p) && guard-- > 0) {
		p -= up * step;
	}
	return guard > 0 ? p + up * step : nowhere;
}

// The middle of the box's outward face, in the BODY's frame -- which is the grid's, so a cell lookup
// takes it as it stands. The box is tall along the axis its offset points down.
Vector3 LATestMasses::box_face_body() const {
	const Vector3 nowhere(NAN, NAN, NAN);
	Ref<RefCounted> slice = _field->get("_slice");
	if (slice.is_null()) {
		UtilityFunctions::print("TEST_MASS_NO_BOX={\"slice\":false}");
		return nowhere;
	}
	const Vector3 off = Vector3(slice->call("resolved_offset", _body));
	if (!(off.length() > 0.0)) {
		UtilityFunctions::print("TEST_MASS_NO_BOX={\"offset\":0}");
		return nowhere;
	}
	int axis = 0;
	for (int k = 1; k < 3; k++) {
		if (std::fabs(double(off[k])) > std::fabs(double(off[axis]))) {
			axis = k;
		}
	}
	const Vector3i dims = Vector3i(slice->get("dims"));
	const double edge = double(slice->get("cell_size"));
	const double half = 0.5 * double(dims[axis]) * edge;
	return body_centre() + off + off.normalized() * float(half);
}

int LATestMasses::throw_orb(const Vector3 &p_at, const Vector3 &p_velocity) {
	if (!active()) {
		return -1;
	}
	const Vector3 world_vel = ground_velocity(p_at) + p_velocity;
	const int id = LABallistics::drop(p_at, world_vel, 0.0, 0.0);
	const Dictionary st = LABallistics::state(id);
	Orb o;
	o.id = id;
	o.speed = double(p_velocity.length());
	// Carried in the body's frame: between release and landing the ground under it has turned east.
	o.dir = o.speed > 0.0 ? body_basis().inverse().xform(p_velocity.normalized()) : Vector3();
	o.v_release = double(world_vel.length());
	o.g_release = double(st.get("g_release", 0.0));
	o.r_release = double((p_at - body_centre()).length());
	o.crossed = int(st.get("cell", -1)) >= 0;
	_orbs.push_back(o);
	Dictionary d;
	d["id"] = id;
	d["throw_speed_m_s"] = o.speed;
	d["cell"] = st.get("cell", -1);
	d["g_release"] = o.g_release;
	d["r_release"] = o.r_release;
	UtilityFunctions::print("ORB_RELEASED=" + JSON::stringify(d));
	return id;
}

int LATestMasses::drop_at(const Vector3 &p_at) {
	return throw_orb(p_at, Vector3());
}

int LATestMasses::drop_over_site() {
	if (!active()) {
		return -1;
	}
	const Vector3 ground = ground_under_site();
	if (!std::isfinite(ground.x)) {
		return -1;
	}
	return drop_at(ground + (ground - body_centre()).normalized() * float(_release_height_m));
}

// The integrator's own state plus what the release recorded: the speed it was given, and how far over the
// ground it has come since -- along the direction it was thrown and across it.
Dictionary LATestMasses::row_of(const Orb &p_orb) const {
	Dictionary out = LABallistics::state(p_orb.id);
	if (out.is_empty()) {
		return out;
	}
	out["id"] = p_orb.id;
	out["throw_speed_m_s"] = p_orb.speed;
	const Vector3 from = Vector3(out.get("from", Vector3()));
	const Vector3 at = Vector3(out.get("position", Vector3()));
	const Vector3 up = (from - body_centre()).normalized();
	const Vector3 d = at - from;
	const Vector3 flat = d - up * d.dot(up);
	const Vector3 dir = body_basis().xform(p_orb.dir);
	const double along = double(flat.dot(dir));
	out["range_m"] = double(flat.length());
	out["along_m"] = along;
	out["cross_m"] = double((flat - dir * float(along)).length());
	const double omega = _body ? double(_body->call("angular_velocity_rad_s")) : NAN;
	if (std::isfinite(omega)) {
		out["omega_rad_s"] = omega;
	}
	return out;
}

Array LATestMasses::rows() const {
	Array out;
	for (const Orb &o : _orbs) {
		out.push_back(row_of(o));
	}
	return out;
}

int LATestMasses::fallen() const {
	return _fallen;
}

void LATestMasses::on_sim_step(int) {
	if (!active() || !LABallistics::has_field()) {
		return;
	}
	if (!_auto) {
		_auto = true;
		drop_over_site();
		if (_lob_speed > 0.0) {
			const Vector3 ground = ground_under_site();
			if (std::isfinite(ground.x)) {
				const Vector3 up = (ground - body_centre()).normalized();
				throw_orb(ground + up * float(_lob_height), across(up) * float(_lob_speed));
			}
		}
		if (_lob_in_speed > 0.0) {
			const Vector3 face = box_face_body();
			if (std::isfinite(face.x)) {
				const Vector3 at = Vector3(_field->call("field_to_point",
						face + (face - body_centre()).normalized() * float(_lob_in_clearance)));
				const Vector3 up = (at - body_centre()).normalized();
				report_face();
				throw_orb(at, across(up) * float(_lob_in_speed));
			}
		}
	}
	watch_crossings();
}

// An orb released outside the box enters it once. What it flew into is read off the field there.
void LATestMasses::watch_crossings() {
	for (Orb &o : _orbs) {
		if (o.crossed) {
			continue;
		}
		const Dictionary st = LABallistics::state(o.id);
		if (st.is_empty()) {
			continue;
		}
		const bool in = int(st.get("cell", -1)) >= 0;
		if (!in) {
			continue;
		}
		o.crossed = true;
		report_crossing(o, st);
	}
}

void LATestMasses::report_face() {
	Ref<RefCounted> slice = _field->get("_slice");
	const Vector3 face = box_face_body();
	if (slice.is_null() || !std::isfinite(face.x)) {
		return;
	}
	const double edge = double(slice->get("cell_size"));
	// Half a cell either side of the face: the cell-centre offset, where the mirror holds its own value.
	const Vector3 half = (face - body_centre()).normalized() * float(0.5 * edge);
	const Vector3 in_body = face - half;
	const Vector3 out_body = face + half;
	const Vector3 in_world = Vector3(_field->call("field_to_point", in_body));
	const Vector3 out_world = Vector3(_field->call("field_to_point", out_body));
	const Vector3 g_in = LABallistics::g_at(in_world);
	const Vector3 g_out = LABallistics::g_at(out_world);
	const Vector3 up_world = (out_world - body_centre()).normalized();
	Object *g = grid();

	Dictionary d;
	d["edge_m"] = edge;
	d["cell_in"] = g ? LAGridGeometry::cell_at(g, in_body) : -1;
	d["cell_out"] = g ? LAGridGeometry::cell_at(g, out_body) : -1;
	d["g_in"] = double(g_in.length());
	d["g_out"] = double(g_out.length());
	d["r_in"] = double((in_world - body_centre()).length());
	d["r_out"] = double((out_world - body_centre()).length());
	d["radial_in"] = double(-g_in.normalized().dot(up_world));
	d["radial_out"] = double(-g_out.normalized().dot(up_world));
	UtilityFunctions::print("ORB_FACE=" + JSON::stringify(d));
}

void LATestMasses::report_crossing(const Orb &p_orb, const Dictionary &p_state) {
	const Vector3 at = Vector3(p_state.get("position", Vector3()));
	Dictionary d;
	d["id"] = p_orb.id;
	d["throw_speed_m_s"] = p_orb.speed;
	d["g_release"] = p_orb.g_release;
	d["g_entry"] = double(LABallistics::g_at(at).length());
	d["r_release"] = p_orb.r_release;
	d["r_entry"] = double((at - body_centre()).length());
	d["v_release"] = p_orb.v_release;
	d["v_entry"] = double(p_state.get("speed", 0.0));
	UtilityFunctions::print("ORB_CROSSED=" + JSON::stringify(d));
}

void LATestMasses::on_bodies_landed(const Array &p_landed) {
	for (int i = 0; i < p_landed.size(); i++) {
		const Dictionary row = p_landed[i];
		const int id = int(row.get("id", -1));
		for (const Orb &o : _orbs) {
			if (o.id != id) {
				continue;
			}
			_fallen++;
			const Dictionary state = row_of(o);
			Dictionary out;
			out["id"] = id;
			out["time"] = row.get("time", 0.0);
			for (const char *key : { "height_m", "g_release", "speed", "cell", "throw_speed_m_s",
						 "range_m", "along_m", "cross_m" }) {
				out[String(key)] = state.get(String(key), 0.0);
			}
			if (state.has("omega_rad_s")) {
				out["omega_rad_s"] = state["omega_rad_s"];
			}
			UtilityFunctions::print("TEST_MASS_LANDED=" + JSON::stringify(out));
			break;
		}
	}
}

void LATestMasses::set_release_height_m(double p_m) {
	_release_height_m = p_m;
}

double LATestMasses::get_release_height_m() const {
	return _release_height_m;
}

void LATestMasses::set_throw_speed_m_s(double p_m_s) {
	_throw_speed_m_s = (std::isfinite(p_m_s) && p_m_s > 0.0) ? p_m_s : 0.0;
}

double LATestMasses::get_throw_speed_m_s() const {
	return _throw_speed_m_s;
}

void LATestMasses::_bind_methods() {
	ClassDB::bind_method(D_METHOD("setup", "body", "field"), &LATestMasses::setup);
	ClassDB::bind_method(D_METHOD("active"), &LATestMasses::active);
	ClassDB::bind_method(D_METHOD("throw_orb", "at", "velocity"), &LATestMasses::throw_orb);
	ClassDB::bind_method(D_METHOD("drop_at", "at"), &LATestMasses::drop_at);
	ClassDB::bind_method(D_METHOD("drop_over_site"), &LATestMasses::drop_over_site);
	ClassDB::bind_method(D_METHOD("rows"), &LATestMasses::rows);
	ClassDB::bind_method(D_METHOD("fallen"), &LATestMasses::fallen);
	ClassDB::bind_method(D_METHOD("on_sim_step", "step"), &LATestMasses::on_sim_step);
	ClassDB::bind_method(D_METHOD("on_bodies_landed", "landed"), &LATestMasses::on_bodies_landed);
	ClassDB::bind_method(D_METHOD("set_release_height_m", "m"), &LATestMasses::set_release_height_m);
	ClassDB::bind_method(D_METHOD("get_release_height_m"), &LATestMasses::get_release_height_m);
	ClassDB::bind_method(D_METHOD("set_throw_speed_m_s", "m_s"), &LATestMasses::set_throw_speed_m_s);
	ClassDB::bind_method(D_METHOD("get_throw_speed_m_s"), &LATestMasses::get_throw_speed_m_s);
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "release_height_m", PROPERTY_HINT_NONE, "suffix:m"),
			"set_release_height_m", "get_release_height_m");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "throw_speed_m_s", PROPERTY_HINT_NONE, "suffix:m/s"),
			"set_throw_speed_m_s", "get_throw_speed_m_s");
}
