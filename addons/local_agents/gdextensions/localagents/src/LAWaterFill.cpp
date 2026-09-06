#include "LAWaterFill.hpp"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <algorithm>
#include <cmath>
#include <limits>
#include <queue>
#include <vector>

using namespace godot;

namespace {

const double kPi = std::acos(-1.0);
const float kDry = std::numeric_limits<float>::quiet_NaN();

struct Node {
	double lat_lo = 0.0;   // radians
	double lat_hi = 0.0;
};

// Row i spans latitudes [90 - (i+1)*d, 90 - i*d]; its nodes' area is R^2 * dlon * (sin hi - sin lo).
double row_area(int p_i, int p_nlat, int p_nlon, double p_r_m) {
	const double d = kPi / double(p_nlat);
	const double hi = 0.5 * kPi - double(p_i) * d;
	const double lo = 0.5 * kPi - double(p_i + 1) * d;
	return p_r_m * p_r_m * (2.0 * kPi / double(p_nlon)) * (std::sin(hi) - std::sin(lo));
}

// The four neighbours of (i, j): longitude wraps, and a pole row's outward neighbour is the node half a
// turn away in the same row, which is what lies across the pole.
void neighbours_of(int p_i, int p_j, int p_nlat, int p_nlon, int p_out[4]) {
	p_out[0] = p_i * p_nlon + (p_j + 1) % p_nlon;
	p_out[1] = p_i * p_nlon + (p_j + p_nlon - 1) % p_nlon;
	p_out[2] = p_i > 0 ? (p_i - 1) * p_nlon + p_j : p_i * p_nlon + (p_j + p_nlon / 2) % p_nlon;
	p_out[3] = p_i < p_nlat - 1 ? (p_i + 1) * p_nlon + p_j
							   : p_i * p_nlon + (p_j + p_nlon / 2) % p_nlon;
}

struct QItem {
	double key = 0.0;
	int a = 0;
	int b = 0;
	bool operator<(const QItem &o) const { return key > o.key; }   // min-heap
};

// A water body: the nodes it covers, sorted by elevation, and the water standing in it.
struct Body {
	std::vector<int> nodes;   // ascending by elevation
	double water_m3 = 0.0;
	double level_m = 0.0;
	bool level_known = false;
};

// The level at which `p_body` holds its water: capacity(l) = sum over nodes of area * max(l - h, 0),
// solved by walking the sorted nodes, which makes the capacity piecewise linear and the solve exact.
double solve_level(Body &p_body, const float *p_elev, const std::vector<double> &p_area) {
	if (p_body.level_known) {
		return p_body.level_m;
	}
	double area_acc = 0.0;
	double cap = 0.0;   // capacity at the current node's elevation
	double level = p_body.nodes.empty() ? 0.0 : double(p_elev[p_body.nodes[0]]);
	for (size_t k = 0; k < p_body.nodes.size(); k++) {
		const double h = double(p_elev[p_body.nodes[k]]);
		const double next_cap = cap + area_acc * (h - level);
		if (next_cap >= p_body.water_m3) {
			break;
		}
		cap = next_cap;
		level = h;
		area_acc += p_area[p_body.nodes[k]];
	}
	if (area_acc > 0.0) {
		level += (p_body.water_m3 - cap) / area_acc;
	}
	p_body.level_m = level;
	p_body.level_known = true;
	return level;
}

int find_root(std::vector<int> &p_parent, int p_x) {
	while (p_parent[p_x] != p_x) {
		p_parent[p_x] = p_parent[p_parent[p_x]];
		p_x = p_parent[p_x];
	}
	return p_x;
}

} // namespace

Vector3 LAWaterFill::node_dir(int p_i, int p_j, int p_nlat, int p_nlon) {
	const double lat = 0.5 * kPi - (double(p_i) + 0.5) * kPi / double(p_nlat);
	const double lon = (double(p_j) + 0.5) * 2.0 * kPi / double(p_nlon);
	const double c = std::cos(lat);
	return Vector3(float(c * std::cos(lon)), float(std::sin(lat)), float(c * std::sin(lon)));
}

double LAWaterFill::level_at(const PackedFloat32Array &p_level_m, int p_nlat, int p_nlon,
		const Vector3 &p_dir) {
	const int n = p_nlat * p_nlon;
	if (p_level_m.size() != n || n <= 0) {
		return std::numeric_limits<double>::quiet_NaN();
	}
	const Vector3 d = p_dir.normalized();
	const double lat = std::asin(std::clamp(double(d.y), -1.0, 1.0));
	double lon = std::atan2(double(d.z), double(d.x));
	if (lon < 0.0) {
		lon += 2.0 * kPi;
	}
	const double fi = (0.5 * kPi - lat) * double(p_nlat) / kPi - 0.5;
	const double fj = lon * double(p_nlon) / (2.0 * kPi) - 0.5;
	const int i0 = std::clamp(int(std::floor(fi)), 0, p_nlat - 1);
	const int i1 = std::clamp(i0 + 1, 0, p_nlat - 1);
	const int j0 = ((int(std::floor(fj)) % p_nlon) + p_nlon) % p_nlon;
	const int j1 = (j0 + 1) % p_nlon;
	// THE HIGHEST SURFACE THE FOUR NODES AROUND THE COLUMN CARRY. A fine column is under water where its
	// own crust stands below that; between a wet node and a dry one the shoreline then runs where the
	// crust crosses the level rather than jumping at the lattice edge.
	double best = std::numeric_limits<double>::quiet_NaN();
	for (int i : { i0, i1 }) {
		for (int j : { j0, j1 }) {
			const double v = double(p_level_m[i * p_nlon + j]);
			if (std::isfinite(v) && (!std::isfinite(best) || v > best)) {
				best = v;
			}
		}
	}
	return best;
}

Dictionary LAWaterFill::solve(const PackedFloat32Array &p_elev_m, int p_nlat, int p_nlon,
		double p_body_r_m, double p_water_m3) {
	Dictionary out;
	const int n = p_nlat * p_nlon;
	if (n <= 0 || p_elev_m.size() != n || !(p_body_r_m > 0.0) || !(p_water_m3 > 0.0)) {
		UtilityFunctions::push_error("LAWaterFill: no crust lattice or no water inventory, so there is "
									 "nothing for the fill to lay down.");
		return out;
	}
	const float *elev = p_elev_m.ptr();
	std::vector<double> area((size_t)n, 0.0);
	for (int i = 0; i < p_nlat; i++) {
		const double a = row_area(i, p_nlat, p_nlon, p_body_r_m);
		for (int j = 0; j < p_nlon; j++) {
			area[(size_t)(i * p_nlon + j)] = a;
		}
	}

	// --- 1. PRIORITY-FLOOD WATERSHED (Barnes et al. 2014). Every node drains to one minimum; where two
	// labels meet, the higher of the two nodes is the saddle the water has to climb to cross between them.
	std::vector<int> label((size_t)n, -1);
	std::priority_queue<QItem> pq;
	int nb[4];
	int bodies = 0;
	for (int i = 0; i < p_nlat; i++) {
		for (int j = 0; j < p_nlon; j++) {
			const int c = i * p_nlon + j;
			neighbours_of(i, j, p_nlat, p_nlon, nb);
			bool lowest = true;
			for (int k = 0; k < 4 && lowest; k++) {
				lowest = elev[nb[k]] >= elev[c];
			}
			if (lowest) {
				label[(size_t)c] = bodies++;
				pq.push({ double(elev[c]), c, 0 });
			}
		}
	}
	if (bodies == 0) {
		UtilityFunctions::push_error("LAWaterFill: the crust lattice has no minimum, so no basin drains "
									 "anywhere and the fill has nowhere to start.");
		return out;
	}
	// Saddles between labels, as they are found; the lowest contact between two basins is what counts,
	// so the heap is popped in order and the first contact seen between a pair is their spill.
	std::vector<QItem> edges;
	while (!pq.empty()) {
		const QItem it = pq.top();
		pq.pop();
		const int c = it.a;
		const int i = c / p_nlon;
		const int j = c % p_nlon;
		neighbours_of(i, j, p_nlat, p_nlon, nb);
		for (int k = 0; k < 4; k++) {
			const int m = nb[k];
			if (label[(size_t)m] < 0) {
				label[(size_t)m] = label[(size_t)c];
				pq.push({ std::max(double(elev[m]), it.key), m, 0 });
			} else if (label[(size_t)m] != label[(size_t)c]) {
				edges.push_back({ std::max(double(elev[c]), double(elev[m])),
						label[(size_t)c], label[(size_t)m] });
			}
		}
	}

	// --- 2. THE INVENTORY GOES TO THE LOWEST PLACE IT CAN REACH. Condensing onto a planet with no climate
	// yet, water runs downhill and evaporates back out of anything standing above the level it settles at,
	// so the seeded state is the equilibrium: the deepest basin, filling and overtopping. A lake is what
	// the running water cycle leaves behind, never a seed.
	std::vector<Body> body((size_t)bodies);
	int deepest_node = 0;
	for (int c = 0; c < n; c++) {
		body[(size_t)label[(size_t)c]].nodes.push_back(c);
		if (elev[c] < elev[deepest_node]) {
			deepest_node = c;
		}
	}
	body[(size_t)label[(size_t)deepest_node]].water_m3 = p_water_m3;
	for (Body &b : body) {
		std::sort(b.nodes.begin(), b.nodes.end(),
				[&](int x, int y) { return elev[x] < elev[y]; });
	}

	// --- 3. FILL AND OVERTOP. A basin whose level reaches the lowest saddle out of it is the same body
	// of water as its neighbour across that saddle; the two become one and the level is solved again.
	std::vector<int> parent((size_t)bodies);
	for (int b = 0; b < bodies; b++) {
		parent[(size_t)b] = b;
	}
	std::vector<std::vector<QItem>> out_edges((size_t)bodies);
	for (const QItem &e : edges) {
		out_edges[(size_t)e.a].push_back(e);
		out_edges[(size_t)e.b].push_back(e);
	}
	for (std::vector<QItem> &v : out_edges) {
		std::sort(v.begin(), v.end(), [](const QItem &x, const QItem &y) { return x.key < y.key; });
		std::reverse(v.begin(), v.end());   // pop_back gives the lowest saddle
	}
	std::priority_queue<QItem> active;   // group keyed by its lowest saddle
	for (int b = 0; b < bodies; b++) {
		if (!out_edges[(size_t)b].empty()) {
			active.push({ out_edges[(size_t)b].back().key, b, 0 });
		}
	}
	int merges = 0;
	while (!active.empty()) {
		const QItem top = active.top();
		active.pop();
		const int g = find_root(parent, top.a);
		if (g != top.a) {
			continue;   // stale: this group was merged into another and re-pushed under its root
		}
		std::vector<QItem> &es = out_edges[(size_t)g];
		while (!es.empty() && find_root(parent, es.back().a) == find_root(parent, es.back().b)) {
			es.pop_back();   // the saddle is inside one body of water now
		}
		if (es.empty()) {
			continue;
		}
		const QItem e = es.back();
		if (e.key != top.key) {
			active.push({ e.key, g, 0 });   // the group's lowest saddle moved: re-key it
			continue;
		}
		const int a = find_root(parent, e.a);
		const int b = find_root(parent, e.b);
		const double la = solve_level(body[(size_t)a], elev, area);
		const double lb = solve_level(body[(size_t)b], elev, area);
		if (std::max(la, lb) < e.key) {
			continue;   // neither body reaches the saddle: they stand at their own levels
		}
		es.pop_back();
		// Small into large, so the sorted node lists and the saddle lists cost O(N log N) over the run.
		int big = body[(size_t)a].nodes.size() >= body[(size_t)b].nodes.size() ? a : b;
		int small = big == a ? b : a;
		parent[(size_t)small] = big;
		Body &B = body[(size_t)big];
		const Body &S = body[(size_t)small];
		const size_t cut = B.nodes.size();
		B.nodes.insert(B.nodes.end(), S.nodes.begin(), S.nodes.end());
		std::inplace_merge(B.nodes.begin(), B.nodes.begin() + cut, B.nodes.end(),
				[&](int x, int y) { return elev[x] < elev[y]; });
		B.water_m3 += S.water_m3;
		B.level_known = false;
		body[(size_t)small].nodes.clear();
		body[(size_t)small].nodes.shrink_to_fit();
		std::vector<QItem> &se = out_edges[(size_t)small];
		if (se.size() > out_edges[(size_t)big].size()) {
			out_edges[(size_t)big].swap(se);
		}
		out_edges[(size_t)big].insert(out_edges[(size_t)big].end(), se.begin(), se.end());
		se.clear();
		se.shrink_to_fit();
		std::sort(out_edges[(size_t)big].begin(), out_edges[(size_t)big].end(),
				[](const QItem &x, const QItem &y) { return x.key > y.key; });
		if (!out_edges[(size_t)big].empty()) {
			active.push({ out_edges[(size_t)big].back().key, big, 0 });
		}
		merges++;
	}

	// --- 4. THE SURFACE THE FILL LEFT, per node.
	PackedFloat32Array level;
	level.resize(n);
	float *w = level.ptrw();
	for (int c = 0; c < n; c++) {
		w[c] = kDry;
	}
	int wet = 0;
	int standing = 0;
	double deepest = 0.0;
	for (int b = 0; b < bodies; b++) {
		if (find_root(parent, b) != b || body[(size_t)b].nodes.empty()) {
			continue;
		}
		const double l = solve_level(body[(size_t)b], elev, area);
		bool any = false;
		for (int c : body[(size_t)b].nodes) {
			if (double(elev[c]) >= l) {
				break;   // sorted ascending: nothing above the level is under water
			}
			w[c] = float(l);
			deepest = std::max(deepest, l - double(elev[c]));
			wet++;
			any = true;
		}
		standing += any ? 1 : 0;
	}
	out["level_m"] = level;
	out["nlat"] = p_nlat;
	out["nlon"] = p_nlon;
	out["wet_nodes"] = wet;
	out["bodies"] = standing;
	out["basins"] = bodies;
	out["merges"] = merges;
	out["deepest_m"] = deepest;
	return out;
}

void LAWaterFill::_bind_methods() {
	ClassDB::bind_static_method("LAWaterFill",
			D_METHOD("solve", "elev_m", "nlat", "nlon", "body_r_m", "water_m3"), &LAWaterFill::solve);
	ClassDB::bind_static_method("LAWaterFill", D_METHOD("node_dir", "i", "j", "nlat", "nlon"),
			&LAWaterFill::node_dir);
	ClassDB::bind_static_method("LAWaterFill", D_METHOD("level_at", "level_m", "nlat", "nlon", "dir"),
			&LAWaterFill::level_at);
}
