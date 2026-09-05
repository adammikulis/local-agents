#include "LABallistics.hpp"

#include "LAFieldCellMass.hpp"
#include "LAGridGeometry.hpp"
#include "LAPhysicalRead.hpp"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <algorithm>
#include <cmath>
#include <unordered_map>
#include <vector>

using namespace godot;

namespace {

struct Dvec {
	double x = 0.0, y = 0.0, z = 0.0;
	Dvec() {}
	Dvec(double a, double b, double c) : x(a), y(b), z(c) {}
	explicit Dvec(const Vector3 &v) : x(v.x), y(v.y), z(v.z) {}
	Vector3 v3() const { return Vector3(float(x), float(y), float(z)); }
	Dvec operator+(const Dvec &o) const { return Dvec(x + o.x, y + o.y, z + o.z); }
	Dvec operator-(const Dvec &o) const { return Dvec(x - o.x, y - o.y, z - o.z); }
	Dvec operator*(double s) const { return Dvec(x * s, y * s, z * s); }
	double len() const { return std::sqrt(x * x + y * y + z * z); }
};

struct SystemBody {
	Dvec centre;
	double mu = 0.0;
	double radius = -1.0;
	bool frame = false;
};

struct FreeBody {
	int id = -1;
	Dvec pos;
	Dvec vel;
	double mass_kg = 0.0;
	double radius_m = 0.0;
	double fall_time_s = 0.0;
	double drag_heat_j = 0.0;
	bool armed = false;
	bool landed = false;
	double land_speed = 0.0;
};

// Every Godot-typed member lives behind a first-use allocation: a Variant constructed at static-init time
// runs before the binding pointers exist.
struct Table {
	std::vector<SystemBody> system;
	std::vector<FreeBody> bodies;
	std::unordered_map<int, size_t> index;
	int next_id = 1;
	Object *grid = nullptr;
	PackedFloat32Array gravity;
	PackedByteArray solid;
	Array mass_mirrors;
	PackedVector3Array centres;
	PackedByteArray levels;
	double cell_size = 0.0;
	Array landed_rows;
	Array drag_rows;
};

Table &tb() {
	static Table *t = new Table();
	return *t;
}

// Newton's constant, read from the one place it is declared.
double big_g() {
	static double g = la_physical("GRAVITATIONAL_CONSTANT");
	return g;
}

// Drag coefficient of a sphere in the Newtonian (hypersonic) limit: the surface integral of Cp = 2 sin^2
// theta over the forward hemisphere, which is 1 for a sphere with no free parameter.
// LA_APPROX: newtonian_sphere_drag
const double SPHERE_CD = 1.0;

const double PI_D = 3.14159265358979323846;

// The pull of one point mass, with Newton's shell theorem inside it: only the enclosed mass pulls, so the
// acceleration falls linearly to zero at the centre instead of diverging.
Dvec pull(double p_mu, double p_r_body, const Dvec &p_from, const Dvec &p_at) {
	const Dvec d = p_from - p_at;
	const double len = d.len();
	if (!(len > 1.0e-6)) {
		return Dvec();
	}
	const Dvec dir = d * (1.0 / len);
	if (p_r_body > 0.0 && len < p_r_body) {
		return dir * (p_mu * len / (p_r_body * p_r_body * p_r_body));
	}
	return dir * (p_mu / (len * len));
}

int frame_index() {
	for (size_t i = 0; i < tb().system.size(); i++) {
		if (tb().system[i].frame) {
			return int(i);
		}
	}
	return tb().system.empty() ? -1 : 0;
}

double cell_edge(int p_c) {
	if (p_c < 0 || p_c >= tb().levels.size()) {
		return tb().cell_size;
	}
	return tb().cell_size * std::pow(0.5, double(tb().levels[p_c]));
}

Dvec mirror_g(int p_c) {
	const int b = p_c * 3;
	if (p_c < 0 || b + 2 >= tb().gravity.size()) {
		return Dvec();
	}
	return Dvec(tb().gravity[b], tb().gravity[b + 1], tb().gravity[b + 2]);
}

// True where the point is rock: the field's solid mask inside the box, and inside a system body's own
// surface radius outside it.
bool occupied(const Dvec &p_at) {
	const Vector3 at = p_at.v3();
	if (tb().grid) {
		const int c = LAGridGeometry::cell_at(tb().grid, at);
		if (c >= 0) {
			return c < tb().solid.size() && tb().solid[c] != 0;
		}
	}
	const int b = LABallistics::dominant(at);
	if (b < 0) {
		return false;
	}
	const double r = tb().system[b].radius;
	return r > 0.0 && (p_at - tb().system[b].centre).len() < r;
}

} // namespace

void LABallistics::set_system(const Array &p_bodies) {
	tb().system.clear();
	tb().system.reserve(p_bodies.size());
	for (int i = 0; i < p_bodies.size(); i++) {
		const Dictionary row = p_bodies[i];
		const double m = double(row.get("mass_kg", 0.0));
		if (!(std::isfinite(m) && m > 0.0)) {
			continue; // A body that cannot say how much matter it is contributes no pull.
		}
		SystemBody b;
		b.centre = Dvec(Vector3(row.get("center", Vector3())));
		b.mu = big_g() * m;
		const double r = double(row.get("radius_m", -1.0));
		b.radius = (std::isfinite(r) && r > 0.0) ? r : -1.0;
		b.frame = bool(row.get("frame", false));
		tb().system.push_back(b);
	}
}

int LABallistics::system_size() {
	return int(tb().system.size());
}

Vector3 LABallistics::body_center(int p_i) {
	if (p_i < 0 || p_i >= int(tb().system.size())) {
		return Vector3();
	}
	return tb().system[p_i].centre.v3();
}

double LABallistics::body_radius(int p_i) {
	if (p_i < 0 || p_i >= int(tb().system.size())) {
		return -1.0;
	}
	return tb().system[p_i].radius;
}

double LABallistics::body_mu(int p_i) {
	if (p_i < 0 || p_i >= int(tb().system.size())) {
		return 0.0;
	}
	return tb().system[p_i].mu;
}

int LABallistics::dominant(const Vector3 &p_at) {
	const Dvec at(p_at);
	int best = -1;
	double best_a = -1.0;
	for (size_t i = 0; i < tb().system.size(); i++) {
		const double a = pull(tb().system[i].mu, tb().system[i].radius, tb().system[i].centre, at).len();
		if (a > best_a) {
			best_a = a;
			best = int(i);
		}
	}
	return best;
}

double LABallistics::circular_speed(const Vector3 &p_at) {
	const int b = dominant(p_at);
	if (b < 0) {
		return 0.0;
	}
	const Dvec at(p_at);
	const double r = (tb().system[b].centre - at).len();
	if (!(r > 0.0)) {
		return 0.0;
	}
	return std::sqrt(pull(tb().system[b].mu, tb().system[b].radius, tb().system[b].centre, at).len() * r);
}

Vector3 LABallistics::acceleration_at(const Vector3 &p_at, int p_exclude) {
	const int fr = frame_index();
	if (fr < 0) {
		return Vector3();
	}
	const Dvec at(p_at);
	const Dvec frame_c = tb().system[fr].centre;
	Dvec a;
	for (size_t i = 0; i < tb().system.size(); i++) {
		const SystemBody &b = tb().system[i];
		if (int(i) != p_exclude) {
			a = a + pull(b.mu, b.radius, b.centre, at);
		}
		if (int(i) != fr) {
			// The coordinates are the frame body's, so its own acceleration is subtracted from every point.
			a = a - pull(b.mu, b.radius, b.centre, frame_c);
		}
	}
	return a.v3();
}

void LABallistics::set_field(Object *p_grid, const PackedFloat32Array &p_gravity,
		const PackedByteArray &p_solid, const Array &p_mass_mirrors) {
	tb().grid = p_grid;
	tb().gravity = p_gravity;
	tb().solid = p_solid;
	tb().mass_mirrors = p_mass_mirrors;
	if (p_grid) {
		tb().centres = p_grid->get("centres");
		tb().levels = p_grid->get("levels");
		tb().cell_size = double(p_grid->get("cell_size"));
	} else {
		tb().centres = PackedVector3Array();
		tb().levels = PackedByteArray();
		tb().cell_size = 0.0;
	}
}

void LABallistics::clear_field() {
	set_field(nullptr, PackedFloat32Array(), PackedByteArray(), Array());
}

bool LABallistics::has_field() {
	return tb().grid != nullptr && tb().gravity.size() > 0;
}

Vector3 LABallistics::g_at(const Vector3 &p_at) {
	if (tb().grid && tb().gravity.size() > 0) {
		const int c = LAGridGeometry::cell_at(tb().grid, p_at);
		if (c >= 0 && c < tb().centres.size()) {
			// Trilinear over the cell centres: the fraction of the way from this centre to the neighbouring
			// one on each axis, so the field is continuous across a face instead of stepping at it.
			const Vector3 ctr = tb().centres[c];
			const double e = cell_edge(c);
			const Dvec d(p_at.x - ctr.x, p_at.y - ctr.y, p_at.z - ctr.z);
			const double da[3] = { d.x, d.y, d.z };
			double t[3];
			double s[3];
			for (int k = 0; k < 3; k++) {
				s[k] = da[k] >= 0.0 ? 1.0 : -1.0;
				t[k] = e > 0.0 ? std::min(std::fabs(da[k]) / e, 0.5) : 0.0;
			}
			Dvec acc;
			for (int corner = 0; corner < 8; corner++) {
				double w = 1.0;
				Vector3 probe = ctr;
				for (int k = 0; k < 3; k++) {
					const bool far = (corner >> k) & 1;
					w *= far ? t[k] : (1.0 - t[k]);
					if (far) {
						const double off = s[k] * e;
						if (k == 0) {
							probe.x += float(off);
						} else if (k == 1) {
							probe.y += float(off);
						} else {
							probe.z += float(off);
						}
					}
				}
				if (w <= 0.0) {
					continue;
				}
				int pc = LAGridGeometry::cell_at(tb().grid, probe);
				if (pc < 0) {
					pc = c; // A corner past the box edge takes this cell's own value rather than nothing.
				}
				acc = acc + mirror_g(pc) * w;
			}
			return acc.v3();
		}
	}
	return acceleration_at(p_at, -1);
}

double LABallistics::medium_density_at(const Vector3 &p_at) {
	if (!tb().grid || tb().mass_mirrors.size() == 0) {
		return 0.0;
	}
	const int c = LAGridGeometry::cell_at(tb().grid, p_at);
	if (c < 0) {
		return 0.0;
	}
	return LAFieldCellMass3D::kg_m3_at(tb().mass_mirrors, c);
}

double LABallistics::read_check(int p_samples) {
	const int cc = tb().centres.size();
	if (!tb().grid || cc <= 0 || tb().gravity.size() != cc * 3 || p_samples <= 0) {
		return NAN;
	}
	const int stride = MAX(cc / p_samples, 1);
	double worst = NAN;
	for (int c = 0; c < cc; c += stride) {
		const Dvec want = mirror_g(c);
		const double mag = want.len();
		if (!(mag > 0.0)) {
			continue;
		}
		const double rel = (Dvec(g_at(tb().centres[c])) - want).len() / mag;
		worst = std::isnan(worst) ? rel : MAX(worst, rel);
	}
	return worst;
}

int LABallistics::drop(const Vector3 &p_pos, const Vector3 &p_vel, double p_mass_kg, double p_radius_m) {
	FreeBody b;
	b.id = tb().next_id++;
	b.pos = Dvec(p_pos);
	b.vel = Dvec(p_vel);
	b.mass_kg = (std::isfinite(p_mass_kg) && p_mass_kg > 0.0) ? p_mass_kg : 0.0;
	b.radius_m = (std::isfinite(p_radius_m) && p_radius_m > 0.0) ? p_radius_m : 0.0;
	// A body launched out of rock is not landed in it: it arms once it has reached open ground.
	b.armed = !occupied(b.pos);
	tb().index[b.id] = tb().bodies.size();
	tb().bodies.push_back(b);
	return b.id;
}

void LABallistics::release(int p_id) {
	const auto it = tb().index.find(p_id);
	if (it == tb().index.end()) {
		return;
	}
	const size_t i = it->second;
	const size_t last = tb().bodies.size() - 1;
	if (i != last) {
		tb().bodies[i] = tb().bodies[last];
		tb().index[tb().bodies[i].id] = i;
	}
	tb().bodies.pop_back();
	tb().index.erase(p_id);
}

Dictionary LABallistics::state(int p_id) {
	Dictionary out;
	const auto it = tb().index.find(p_id);
	if (it == tb().index.end()) {
		return out;
	}
	const FreeBody &b = tb().bodies[it->second];
	out["position"] = b.pos.v3();
	out["velocity"] = b.vel.v3();
	out["speed"] = b.landed ? b.land_speed : b.vel.len();
	out["landed"] = b.landed;
	out["fall_time_s"] = b.fall_time_s;
	out["drag_heat_j"] = b.drag_heat_j;
	out["mass_kg"] = b.mass_kg;
	return out;
}

int LABallistics::live_count() {
	int n = 0;
	for (const FreeBody &b : tb().bodies) {
		if (!b.landed) {
			n++;
		}
	}
	return n;
}

Array LABallistics::step(double p_dt_s) {
	tb().landed_rows.clear();
	tb().drag_rows.clear();
	if (!(p_dt_s > 0.0)) {
		return tb().landed_rows;
	}
	for (FreeBody &b : tb().bodies) {
		if (b.landed) {
			continue;
		}
		// Symplectic Euler: the gravity kick first, then the drift, so a bound orbit stays bound instead
		// of gaining energy every revolution the way explicit Euler does.
		const Dvec a = Dvec(g_at(b.pos.v3()));
		b.vel = b.vel + a * p_dt_s;

		if (!b.armed && !occupied(b.pos)) {
			b.armed = true;
		}
		// Ram drag, F = 1/2 rho Cd A v^2, integrated EXACTLY over the step: dv/dt = -k v^2 has the closed
		// solution v/(1 + k v dt), which no step size can turn the body around. Only a body with a mass
		// and a cross-section rams anything; a declared point has neither.
		if (b.armed && b.mass_kg > 0.0 && b.radius_m > 0.0) {
			const double rho = medium_density_at(b.pos.v3());
			const double speed = b.vel.len();
			if (rho > 0.0 && speed > 0.0) {
				const double area = PI_D * b.radius_m * b.radius_m;
				const double k = 0.5 * rho * SPHERE_CD * area / b.mass_kg;
				const double after = speed / (1.0 + k * speed * p_dt_s);
				const double joules = 0.5 * b.mass_kg * (speed * speed - after * after);
				b.vel = b.vel * (after / speed);
				b.drag_heat_j += joules;
				if (joules > 0.0) {
					Dictionary row;
					row["id"] = b.id;
					row["position"] = b.pos.v3();
					row["joules"] = joules;
					tb().drag_rows.push_back(row);
				}
			}
		}

		const Dvec next = b.pos + b.vel * p_dt_s;
		if (b.armed && occupied(next)) {
			// Where along this step the rock begins, so the landing time is not rounded up to a whole tick.
			double lo = 0.0, hi = 1.0;
			for (int it = 0; it < 24; it++) {
				const double mid = 0.5 * (lo + hi);
				if (occupied(b.pos + (next - b.pos) * mid)) {
					hi = mid;
				} else {
					lo = mid;
				}
			}
			b.pos = b.pos + (next - b.pos) * hi;
			b.fall_time_s += p_dt_s * hi;
			b.land_speed = b.vel.len();
			b.landed = true;
			Dictionary row;
			row["id"] = b.id;
			row["position"] = b.pos.v3();
			row["speed"] = b.land_speed;
			row["time"] = b.fall_time_s;
			tb().landed_rows.push_back(row);
			continue;
		}
		b.pos = next;
		b.fall_time_s += p_dt_s;
	}
	return tb().landed_rows;
}

Array LABallistics::drag_work() {
	return tb().drag_rows;
}

void LABallistics::clear() {
	tb().bodies.clear();
	tb().index.clear();
	tb().landed_rows.clear();
	tb().drag_rows.clear();
}

void LABallistics::_bind_methods() {
	ClassDB::bind_static_method("LABallistics", D_METHOD("set_system", "bodies"), &LABallistics::set_system);
	ClassDB::bind_static_method("LABallistics", D_METHOD("system_size"), &LABallistics::system_size);
	ClassDB::bind_static_method("LABallistics", D_METHOD("body_center", "i"), &LABallistics::body_center);
	ClassDB::bind_static_method("LABallistics", D_METHOD("body_radius", "i"), &LABallistics::body_radius);
	ClassDB::bind_static_method("LABallistics", D_METHOD("body_mu", "i"), &LABallistics::body_mu);
	ClassDB::bind_static_method("LABallistics", D_METHOD("dominant", "at"), &LABallistics::dominant);
	ClassDB::bind_static_method("LABallistics", D_METHOD("circular_speed", "at"), &LABallistics::circular_speed);
	ClassDB::bind_static_method("LABallistics", D_METHOD("acceleration_at", "at", "exclude"),
			&LABallistics::acceleration_at, DEFVAL(-1));
	ClassDB::bind_static_method("LABallistics", D_METHOD("set_field", "grid", "gravity", "solid", "mass_mirrors"),
			&LABallistics::set_field);
	ClassDB::bind_static_method("LABallistics", D_METHOD("clear_field"), &LABallistics::clear_field);
	ClassDB::bind_static_method("LABallistics", D_METHOD("has_field"), &LABallistics::has_field);
	ClassDB::bind_static_method("LABallistics", D_METHOD("g_at", "at"), &LABallistics::g_at);
	ClassDB::bind_static_method("LABallistics", D_METHOD("medium_density_at", "at"),
			&LABallistics::medium_density_at);
	ClassDB::bind_static_method("LABallistics", D_METHOD("read_check", "samples"),
			&LABallistics::read_check);
	ClassDB::bind_static_method("LABallistics", D_METHOD("drop", "pos", "vel", "mass_kg", "radius_m"),
			&LABallistics::drop, DEFVAL(Vector3()), DEFVAL(0.0), DEFVAL(0.0));
	ClassDB::bind_static_method("LABallistics", D_METHOD("release", "id"), &LABallistics::release);
	ClassDB::bind_static_method("LABallistics", D_METHOD("state", "id"), &LABallistics::state);
	ClassDB::bind_static_method("LABallistics", D_METHOD("live_count"), &LABallistics::live_count);
	ClassDB::bind_static_method("LABallistics", D_METHOD("step", "dt_s"), &LABallistics::step);
	ClassDB::bind_static_method("LABallistics", D_METHOD("drag_work"), &LABallistics::drag_work);
	ClassDB::bind_static_method("LABallistics", D_METHOD("clear"), &LABallistics::clear);
}
