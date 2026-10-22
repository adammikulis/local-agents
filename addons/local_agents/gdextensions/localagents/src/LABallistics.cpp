#include "LABallistics.hpp"
#include "LAFieldDriver.hpp"

#include "LABodySystem.hpp"
#include "LAFieldCellMass.hpp"
#include "LAFieldMirrors.hpp"
#include "LAFieldLithostaticSeed.hpp"
#include "LAGridGeometry.hpp"
#include "LAPhysicalRead.hpp"
#include "LAProcessSet.hpp"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <godot_cpp/core/math.hpp>
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
	double dot(const Dvec &o) const { return x * o.x + y * o.y + z * o.z; }
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
	int64_t sub_steps = 0;
	bool armed = false;
	bool landed = false;
	double land_speed = 0.0;
	Dvec rest_field;
	Dvec from_field;
	double g_release = 0.0;
};

// The grid is laid in the BODY's frame and a free body flies in the world's. Rows are field -> world.
struct Frame {
	double m[9] = { 1, 0, 0, 0, 1, 0, 0, 0, 1 };
	double mi[9] = { 1, 0, 0, 0, 1, 0, 0, 0, 1 };
	Dvec pivot;
};

// Every Godot-typed member lives behind a first-use allocation: a Variant constructed at static-init time
// runs before the binding pointers exist.
struct Table {
	std::vector<SystemBody> system;
	std::vector<FreeBody> bodies;
	std::unordered_map<int, size_t> index;
	int next_id = 1;
	Object *grid = nullptr;
	Frame frame;
	PackedFloat32Array gravity;
	PackedByteArray solid;
	Ref<LAFieldMirrors> mass_mirrors;
	Array mass_channels;
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

// Drag coefficient of a sphere in the Newtonian (hypersonic) limit: Cp = 2 cos^2 phi from the
// stagnation point, integrated over the forward hemisphere, 2 * 2 * int_0^{pi/2} cos^3 sin dphi.
// LA_APPROX: newtonian_sphere_drag
const double SPHERE_CD = 2.0 * 2.0 * (1.0 / 4.0);


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

// The gravity switch, not the gravity record: a world whose gravity is off has no pull anywhere, and
// no tide either.
bool gravity_on() {
	return LAProcessSet::is_switched_on("pass", "GravityPass.gd");
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

Dvec rot(const double *p_m, const Dvec &p_v) {
	return Dvec(p_m[0] * p_v.x + p_m[1] * p_v.y + p_m[2] * p_v.z,
			p_m[3] * p_v.x + p_m[4] * p_v.y + p_m[5] * p_v.z,
			p_m[6] * p_v.x + p_m[7] * p_v.y + p_m[8] * p_v.z);
}

// A world point in the grid's frame, and a grid-frame vector back in the world's.
Dvec to_field(const Dvec &p_world) {
	return tb().frame.pivot + rot(tb().frame.mi, p_world - tb().frame.pivot);
}

Dvec from_field(const Dvec &p_field) {
	return tb().frame.pivot + rot(tb().frame.m, p_field - tb().frame.pivot);
}

// The cell a world point stands in, -1 outside the box or with no field.
int cell_of(const Dvec &p_at) {
	return tb().grid ? LAGridGeometry::cell_at(tb().grid, to_field(p_at).v3()) : -1;
}

// The centre radii are measured from: the frame body's, or the frame the grid was laid about.
Dvec pivot() {
	const int fr = frame_index();
	return fr >= 0 ? tb().system[fr].centre : tb().frame.pivot;
}

// True where the point is rock: the field's solid mask inside the box, and inside a system body's own
// surface radius outside it.
bool occupied(const Dvec &p_at) {
	const Vector3 at = p_at.v3();
	if (tb().grid) {
		const int c = cell_of(p_at);
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

// THE LENGTH A STRIDE MAY NOT EXCEED, m. Inside the box it is the cell the body stands in: g and the
// medium's density are cell-wise, so a stride longer than a cell skips cells the ram drag should have
// acted in. Outside it the body is falling toward the air, whose e-folding length is the scale height
// R T / M / g of the seeded column, so a stride of one H cannot cross the atmosphere unbraked. With no
// air and no box the only force is the point-mass sum, whose scale is the distance to the body itself.
double stride_m(const Dvec &p_at) {
	const int c = cell_of(p_at);
	if (c >= 0) {
		return cell_edge(c);
	}
	if (tb().grid) {
		const double g = Dvec(LABallistics::g_at(p_at.v3())).len();
		const double rt = LAFieldLithostaticSeed::seeded_air_rt_over_m(LABodySeeds::surface_temp_c());
		if (std::isfinite(rt) && rt > 0.0 && g > 0.0) {
			return rt / g;
		}
	}
	const int b = LABallistics::dominant(p_at.v3());
	return b >= 0 ? (p_at - tb().system[b].centre).len() : 0.0;
}

// Seconds in the next stride: one length scale at the speed the body is at, read WHERE THE BODY IS, and
// never more than what is left of the step. Over a constant L that is p_dt_s / ceil(|v| dt / L).
double sub_step_h(const FreeBody &p_b, double p_left) {
	const double l = stride_m(p_b.pos);
	const double v = p_b.vel.len();
	const double h = (l > 0.0 && v > 0.0) ? l / v : p_left;
	return (std::isfinite(h) && h > 0.0 && h < p_left) ? h : p_left;
}

// Joules the drag left in one cell, and where along the arc it first entered it.
struct CellHeat {
	double joules = 0.0;
	Dvec at;
};

// ONE SUB-STEP. Velocity Verlet about the exact parabola of a constant acceleration -- second order and
// symplectic, so a bound orbit stays bound -- then the ram drag F = 1/2 rho Cd A v^2 over the same
// interval, whose dv/dt = -k v^2 has the closed solution v/(1 + k v h) that no step length can turn the
// body around. Lands it at the first rock along the arc.
void advance(FreeBody &b, double p_h, std::unordered_map<int, CellHeat> &p_heat) {
	// A body launched out of rock is not landed in it until it has reached open ground.
	if (!b.armed && !occupied(b.pos)) {
		b.armed = true;
	}
	const Dvec v0 = b.vel;
	const Dvec a0 = Dvec(LABallistics::g_at(b.pos.v3()));
	const Dvec start = b.pos;
	auto path = [&](double s) {
		const double t = s * p_h;
		return start + v0 * t + a0 * (0.5 * t * t);
	};
	const Dvec next = path(1.0);
	if (b.armed && occupied(next)) {
		// Where along this arc the rock begins, so the landing time is not rounded up to a sub-step.
		double lo = 0.0, hi = 1.0;
		for (int it = 0; it < 24; it++) {
			const double mid = 0.5 * (lo + hi);
			if (occupied(path(mid))) {
				hi = mid;
			} else {
				lo = mid;
			}
		}
		b.pos = path(hi);
		b.rest_field = to_field(b.pos);
		b.vel = v0 + a0 * (hi * p_h);
		b.fall_time_s += p_h * hi;
		b.land_speed = b.vel.len();
		b.landed = true;
		return;
	}
	b.pos = next;
	b.vel = v0 + (a0 + Dvec(LABallistics::g_at(next.v3()))) * (0.5 * p_h);
	// Only a body with a mass and a cross-section rams anything; a declared point has neither.
	if (b.armed && b.mass_kg > 0.0 && b.radius_m > 0.0) {
		const double rho = LABallistics::medium_density_at(b.pos.v3());
		const double speed = b.vel.len();
		if (rho > 0.0 && speed > 0.0) {
			const double area = Math::PI * b.radius_m * b.radius_m;
			const double k = 0.5 * rho * SPHERE_CD * area / b.mass_kg;
			const double after = speed / (1.0 + k * speed * p_h);
			const double joules = 0.5 * b.mass_kg * (speed * speed - after * after);
			b.vel = b.vel * (after / speed);
			b.drag_heat_j += joules;
			if (joules > 0.0) {
				CellHeat &e = p_heat[cell_of(b.pos)];
				if (!(e.joules > 0.0)) {
					e.at = b.pos;
				}
				e.joules += joules;
			}
		}
	}
	b.fall_time_s += p_h;
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

bool LABallistics::upload_tide(RenderingDevice *p_rd, const RID &p_buffer, int p_elements, LAFieldDriver *p_driver) {
	const PackedByteArray bytes = tide_table().to_byte_array();
	String error;
	if (!p_rd || !p_buffer.is_valid() || !p_driver) {
		error = "tide/buffer_absent";
	} else if (bytes.size() > int64_t(p_elements) * 4) {
		error = "tide/buffer_capacity";
	} else if (p_rd->buffer_update(p_buffer, 0, bytes.size(), bytes) != OK) {
		error = "tide/buffer_update";
	}
	if (error.is_empty()) { return true; }
	if (p_driver) { p_driver->fail(error); }
	else { UtilityFunctions::push_error(error); }
	return false;
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

Vector3 LABallistics::tidal_at(const Vector3 &p_at) {
	const int fr = frame_index();
	if (fr < 0) {
		return Vector3();
	}
	const Dvec at(p_at);
	const Dvec c = tb().system[fr].centre;
	Dvec a;
	for (size_t i = 0; i < tb().system.size(); i++) {
		if (int(i) == fr) {
			continue;
		}
		const SystemBody &b = tb().system[i];
		a = a + pull(b.mu, b.radius, b.centre, at) - pull(b.mu, b.radius, b.centre, c);
	}
	return a.v3();
}

double LABallistics::tide_peak_ratio() {
	const int fr = frame_index();
	if (fr < 0 || !gravity_on() || !(tb().system[fr].radius > 0.0)) {
		return NAN;
	}
	const double r = tb().system[fr].radius;
	const Dvec c = tb().system[fr].centre;
	Dvec toward;
	double lead = 0.0;
	for (size_t i = 0; i < tb().system.size(); i++) {
		if (int(i) == fr) {
			continue;
		}
		const Dvec off = tb().system[i].centre - c;
		const double d = off.len();
		if (!(d > 0.0)) {
			continue;
		}
		const double a = 2.0 * tb().system[i].mu * r / (d * d * d);
		if (a > lead) {
			lead = a;
			toward = off * (1.0 / d);
		}
	}
	if (!(lead > 0.0)) {
		return NAN;
	}
	return Dvec(tidal_at((c + toward * r).v3())).len() / lead;
}

double LABallistics::tidal_potential_at(const Vector3 &p_at) {
	const int fr = frame_index();
	if (fr < 0) {
		return 0.0;
	}
	const Dvec c = tb().system[fr].centre;
	const Dvec s = Dvec(p_at) - c;
	double phi = 0.0;
	for (size_t i = 0; i < tb().system.size(); i++) {
		if (int(i) == fr) {
			continue;
		}
		const SystemBody &b = tb().system[i];
		const Dvec off = b.centre - c;
		const double cl = off.len();
		const double dl = (s - off).len();
		if (!(cl > 0.0) || !(dl > 0.0)) {
			continue;
		}
		phi += -b.mu * (1.0 / dl - 1.0 / cl - s.dot(off) / (cl * cl * cl));
	}
	return phi;
}

int LABallistics::tide_rows() {
	return int(tb().system.size()) - (frame_index() >= 0 ? 1 : 0);
}

PackedFloat32Array LABallistics::tide_table() {
	const int p_rows = tide_rows();
	PackedFloat32Array out;
	// Slot 0 is how many rows follow; each row is four floats from slot 4 on.
	out.resize((p_rows + 1) * 4);
	out.fill(0.0f);
	const int fr = frame_index();
	if (fr < 0 || !gravity_on()) {
		return out;
	}
	const Dvec c = tb().system[fr].centre;
	int k = 0;
	for (size_t i = 0; i < tb().system.size(); i++) {
		if (int(i) == fr) {
			continue;
		}
		// The kernel reads the grid's own coordinates, so the offset turns with the body the grid rides.
		const Dvec off = rot(tb().frame.mi, tb().system[i].centre - c);
		k++;
		out[k * 4] = float(off.x);
		out[k * 4 + 1] = float(off.y);
		out[k * 4 + 2] = float(off.z);
		out[k * 4 + 3] = float(tb().system[i].mu);
	}
	out[0] = float(k);
	return out;
}

void LABallistics::set_field(Object *p_grid, const PackedFloat32Array &p_gravity,
		const PackedByteArray &p_solid, Object *p_mass_mirrors, const Array &p_mass_channels,
		const Basis &p_frame, const Vector3 &p_pivot) {
	tb().grid = p_grid;
	tb().gravity = p_gravity;
	tb().solid = p_solid;
	tb().mass_mirrors = Ref<LAFieldMirrors>(Object::cast_to<LAFieldMirrors>(p_mass_mirrors));
	tb().mass_channels = p_mass_channels;
	const Basis inv = p_frame.inverse();
	for (int r = 0; r < 3; r++) {
		for (int k = 0; k < 3; k++) {
			tb().frame.m[r * 3 + k] = double(p_frame[r][k]);
			tb().frame.mi[r * 3 + k] = double(inv[r][k]);
		}
	}
	tb().frame.pivot = Dvec(p_pivot);
	// A body that has landed lies on the ground, and the ground turns with the body it is part of.
	for (FreeBody &b : tb().bodies) {
		if (b.landed) {
			b.pos = from_field(b.rest_field);
		}
	}
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
	set_field(nullptr, PackedFloat32Array(), PackedByteArray(), nullptr, Array(), Basis(), Vector3());
}

bool LABallistics::has_field() {
	return tb().grid != nullptr && tb().gravity.size() > 0;
}

bool LABallistics::rock_at(const Vector3 &p_at) {
	return occupied(Dvec(p_at));
}

Vector3 LABallistics::g_at(const Vector3 &p_at) {
	if (!gravity_on()) {
		return Vector3();
	}
	if (tb().grid && tb().gravity.size() > 0) {
		const Vector3 at = to_field(Dvec(p_at)).v3();
		const int c = LAGridGeometry::cell_at(tb().grid, at);
		if (c >= 0 && c < tb().centres.size()) {
			// Trilinear over the cell centres: the fraction of the way from this centre to the neighbouring
			// one on each axis, so the field is continuous across a face instead of stepping at it.
			const Vector3 ctr = tb().centres[c];
			const double e = cell_edge(c);
			const Dvec d(at.x - ctr.x, at.y - ctr.y, at.z - ctr.z);
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
			return (rot(tb().frame.m, acc) + Dvec(tidal_at(p_at))).v3();
		}
	}
	return acceleration_at(p_at, -1);
}

double LABallistics::medium_density_at(const Vector3 &p_at) {
	if (!tb().grid || tb().mass_mirrors.is_null() || tb().mass_channels.is_empty()) {
		return 0.0;
	}
	const int c = cell_of(Dvec(p_at));
	if (c < 0) {
		return 0.0;
	}
	return LAFieldCellMass3D::kg_m3_at(tb().mass_mirrors.ptr(), tb().mass_channels, c);
}

double LABallistics::read_check(int p_samples) {
	const int cc = tb().centres.size();
	if (!tb().grid || cc <= 0 || tb().gravity.size() != cc * 3 || p_samples <= 0) {
		return NAN;
	}
	const int stride = MAX(cc / p_samples, 1);
	double worst = NAN;
	for (int c = 0; c < cc; c += stride) {
		const Vector3 world = from_field(Dvec(tb().centres[c])).v3();
		const Dvec want = rot(tb().frame.m, mirror_g(c)) + Dvec(tidal_at(world));
		const double mag = want.len();
		if (!(mag > 0.0)) {
			continue;
		}
		const double rel = (Dvec(g_at(world)) - want).len() / mag;
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
	b.from_field = to_field(b.pos);
	b.g_release = Dvec(g_at(p_pos)).len();
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
	out["sub_steps"] = b.sub_steps;
	out["mass_kg"] = b.mass_kg;
	out["cell"] = cell_of(b.pos);
	// The release point, carried in the grid's frame: the ground it was let go of turns under it.
	const Dvec from = from_field(b.from_field);
	out["from"] = from.v3();
	out["g_release"] = b.g_release;
	out["height_m"] = (from - pivot()).len() - (b.pos - pivot()).len();
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
		// EVERY BODY ON ITS OWN CLOCK. The field's step is the field's, and a rock at escape speed crosses
		// the whole air column inside one of them. A stride is one length scale at the body's own speed --
		// n = ceil(|v| dt / L) where L holds -- so the ram drag acts in every cell of the air it passes.
		std::unordered_map<int, CellHeat> heat;
		double left = p_dt_s;
		long long n = 0;
		while (left > 0.0 && !b.landed) {
			const double h = sub_step_h(b, left);
			advance(b, h, heat);
			left -= h;
			n++;
		}
		b.sub_steps = n;
		// The joules the ram took out, cell by cell: the energy came out of the air the body pushed aside,
		// so it goes back into the cells it was taken from and not into the one it ended the step in.
		for (const std::pair<const int, CellHeat> &e : heat) {
			Dictionary row;
			row["id"] = b.id;
			row["position"] = e.second.at.v3();
			row["cell"] = e.first;
			row["joules"] = e.second.joules;
			tb().drag_rows.push_back(row);
		}
		if (b.landed) {
			Dictionary row;
			row["id"] = b.id;
			row["position"] = b.pos.v3();
			row["speed"] = b.land_speed;
			row["time"] = b.fall_time_s;
			row["cell"] = cell_of(b.pos);
			row["g_release"] = b.g_release;
			row["sub_steps"] = b.sub_steps;
			// The RADIAL drop: a radius is the same in either frame, and between release and landing the
			// ground under the body has turned a long way east.
			row["height_m"] = (from_field(b.from_field) - pivot()).len() - (b.pos - pivot()).len();
			tb().landed_rows.push_back(row);
		}
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
	ClassDB::bind_static_method("LABallistics", D_METHOD("tidal_at", "at"), &LABallistics::tidal_at);
	ClassDB::bind_static_method("LABallistics", D_METHOD("tide_peak_ratio"),
			&LABallistics::tide_peak_ratio);
	ClassDB::bind_static_method("LABallistics", D_METHOD("tidal_potential_at", "at"),
			&LABallistics::tidal_potential_at);
	ClassDB::bind_static_method("LABallistics", D_METHOD("tide_rows"), &LABallistics::tide_rows);
	ClassDB::bind_static_method("LABallistics", D_METHOD("tide_table"), &LABallistics::tide_table);
	ClassDB::bind_static_method("LABallistics", D_METHOD("upload_tide", "rd", "buffer", "elements", "driver"),
			&LABallistics::upload_tide);
	ClassDB::bind_static_method("LABallistics",
			D_METHOD("set_field", "grid", "gravity", "solid", "mass_mirrors", "mass_channels", "frame", "pivot"),
			&LABallistics::set_field);
	ClassDB::bind_static_method("LABallistics", D_METHOD("clear_field"), &LABallistics::clear_field);
	ClassDB::bind_static_method("LABallistics", D_METHOD("has_field"), &LABallistics::has_field);
	ClassDB::bind_static_method("LABallistics", D_METHOD("g_at", "at"), &LABallistics::g_at);
	ClassDB::bind_static_method("LABallistics", D_METHOD("rock_at", "at"), &LABallistics::rock_at);
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
