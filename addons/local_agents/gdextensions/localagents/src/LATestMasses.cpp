#include "LATestMasses.hpp"

#include "LABallistics.hpp"
#include "LAProcessSet.hpp"

#include <godot_cpp/classes/json.hpp>
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <cmath>

using namespace godot;

namespace {

// The pass that solves the potential. Without it this world has no vertical and no field to fall through.
const char *GRAVITY_PASS = "GravityPass.gd";
// Cells the ground march walks before it gives up, at the box's finest edge.
const int MARCH_STEPS = 20000;

bool has_gravity() {
	return LAProcessSet::has_record("pass", GRAVITY_PASS, LAProcessSet::ANY);
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
	add_to_group("la_ballistics");
}

bool LATestMasses::active() const {
	return _body != nullptr && _field != nullptr;
}

Vector3 LATestMasses::body_centre() const {
	return _body ? Vector3(_body->call("center")) : Vector3();
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

int LATestMasses::drop_at(const Vector3 &p_at) {
	if (!active() || _off) {
		return -1;
	}
	const int id = LABallistics::drop(p_at, ground_velocity(p_at), 0.0, 0.0);
	_ids.append(id);
	return id;
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

Array LATestMasses::rows() const {
	Array out;
	for (int i = 0; i < _ids.size(); i++) {
		out.push_back(LABallistics::state(_ids[i]));
	}
	return out;
}

int LATestMasses::fallen() const {
	return _fallen;
}

void LATestMasses::on_sim_step(int) {
	if (!active() || _auto || !LABallistics::has_field()) {
		return;
	}
	_auto = true;
	drop_over_site();
}

void LATestMasses::on_bodies_landed(const Array &p_landed) {
	for (int i = 0; i < p_landed.size(); i++) {
		const Dictionary row = p_landed[i];
		if (!_ids.has(int(row.get("id", -1)))) {
			continue;
		}
		_fallen++;
		Dictionary out;
		for (const char *key : { "id", "height_m", "g_release", "time", "speed", "cell" }) {
			out[String(key)] = row.get(String(key), 0.0);
		}
		UtilityFunctions::print("TEST_MASS_LANDED=" + JSON::stringify(out));
	}
}

void LATestMasses::_notification(int p_what) {
	if (p_what == NOTIFICATION_ENABLED) {
		_off = false;
		return;
	}
	if (p_what != NOTIFICATION_DISABLED) {
		return;
	}
	_off = true;
	_auto = false;
	for (int i = 0; i < _ids.size(); i++) {
		LABallistics::release(_ids[i]);
	}
	_ids.clear();
}

void LATestMasses::set_release_height_m(double p_m) {
	_release_height_m = p_m;
}

double LATestMasses::get_release_height_m() const {
	return _release_height_m;
}

void LATestMasses::_bind_methods() {
	ClassDB::bind_method(D_METHOD("setup", "body", "field"), &LATestMasses::setup);
	ClassDB::bind_method(D_METHOD("active"), &LATestMasses::active);
	ClassDB::bind_method(D_METHOD("drop_at", "at"), &LATestMasses::drop_at);
	ClassDB::bind_method(D_METHOD("drop_over_site"), &LATestMasses::drop_over_site);
	ClassDB::bind_method(D_METHOD("rows"), &LATestMasses::rows);
	ClassDB::bind_method(D_METHOD("fallen"), &LATestMasses::fallen);
	ClassDB::bind_method(D_METHOD("on_sim_step", "step"), &LATestMasses::on_sim_step);
	ClassDB::bind_method(D_METHOD("on_bodies_landed", "landed"), &LATestMasses::on_bodies_landed);
	ClassDB::bind_method(D_METHOD("set_release_height_m", "m"), &LATestMasses::set_release_height_m);
	ClassDB::bind_method(D_METHOD("get_release_height_m"), &LATestMasses::get_release_height_m);
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "release_height_m", PROPERTY_HINT_NONE, "suffix:m"),
			"set_release_height_m", "get_release_height_m");
}
