#include "LAFieldMirrors.hpp"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <cmath>
#include <cstring>

using namespace godot;

namespace {

RID rid_at(const Array &a, int i) {
	if (i < 0 || i >= a.size()) {
		return RID();
	}
	const RID r = a[i];
	return r;
}

std::string key_of(const String &p_name) {
	return std::string(p_name.utf8().get_data());
}

} // namespace

void LAFieldMirrors::set_device(RenderingDevice *p_rd) {
	_rd = p_rd;
}

void LAFieldMirrors::alloc(const PackedStringArray &p_names, int p_cells) {
	_cells = p_cells > 0 ? p_cells : 0;
	_names = p_names;
	_index.clear();
	for (int i = 0; i < _names.size(); i++) {
		_index[key_of(_names[i])] = i;
	}
	_store.assign((size_t)_names.size() * (size_t)_cells, 0.0f);
	_stamp.assign((size_t)_names.size(), 0);
	_drain_count = 0;
}

int LAFieldMirrors::cells() const {
	return _cells;
}

PackedStringArray LAFieldMirrors::names() const {
	return _names;
}

int LAFieldMirrors::_slot(const String &p_name) const {
	const auto it = _index.find(key_of(p_name));
	return it == _index.end() ? -1 : it->second;
}

bool LAFieldMirrors::has(const String &p_name) const {
	return _cells > 0 && _slot(p_name) >= 0;
}

bool LAFieldMirrors::live(const String &p_name) const {
	const int s = _slot(p_name);
	return s >= 0 && _cells > 0 && _drain_count > 0 && _stamp[(size_t)s] == _drain_count;
}

Dictionary LAFieldMirrors::drain(const RID &p_staging, const Array &p_mirror_srcs,
		const PackedStringArray &p_mirror_names, const Array &p_probe_srcs,
		const PackedStringArray &p_probe_names) {
	Dictionary probe;
	if (_rd == nullptr || !p_staging.is_valid() || _cells <= 0) {
		return probe;
	}
	const int mirrors = MIN(p_mirror_srcs.size(), p_mirror_names.size());
	const int probes = MIN(p_probe_srcs.size(), p_probe_names.size());
	const int total = mirrors + probes;
	if (total <= 0) {
		_drain_count++;
		return probe;
	}
	const uint32_t span = (uint32_t)_cells * 4u;
	for (int i = 0; i < total; ++i) {
		const RID src = i < mirrors ? rid_at(p_mirror_srcs, i) : rid_at(p_probe_srcs, i - mirrors);
		if (!src.is_valid()) {
			UtilityFunctions::push_error("LAFieldMirrors.drain: slot ", i,
					" has no buffer, so this drain read NOTHING; every reading it would have carried "
					"is absent.");
			return probe;
		}
		_rd->buffer_copy(src, p_staging, 0, (uint32_t)i * span, span);
	}
	const PackedByteArray raw = _rd->buffer_get_data(p_staging, 0, (uint32_t)total * span);
	if (raw.size() < (int64_t)total * (int64_t)span) {
		UtilityFunctions::push_error("LAFieldMirrors.drain: the staging buffer returned ", raw.size(),
				" bytes against ", (int64_t)total * (int64_t)span, " asked for.");
		return probe;
	}
	_drain_count++;
	for (int i = 0; i < mirrors; ++i) {
		const int s = _slot(p_mirror_names[i]);
		if (s < 0) {
			continue;
		}
		std::memcpy(&_store[(size_t)s * (size_t)_cells], raw.ptr() + (int64_t)i * (int64_t)span,
				(size_t)span);
		_stamp[(size_t)s] = _drain_count;
	}
	for (int i = 0; i < probes; ++i) {
		PackedFloat32Array vals;
		vals.resize(_cells);
		std::memcpy(vals.ptrw(), raw.ptr() + (int64_t)(mirrors + i) * (int64_t)span, (size_t)span);
		probe[p_probe_names[i]] = vals;
	}
	return probe;
}

double LAFieldMirrors::at(const String &p_name, int p_c) const {
	const int s = _slot(p_name);
	if (s < 0 || p_c < 0 || p_c >= _cells) {
		return NAN;
	}
	return (double)_store[(size_t)s * (size_t)_cells + (size_t)p_c];
}

Vector3 LAFieldMirrors::vec3(const String &p_x, const String &p_y, const String &p_z, int p_c) const {
	const double x = at(p_x, p_c);
	const double y = at(p_y, p_c);
	const double z = at(p_z, p_c);
	if (std::isnan(x) || std::isnan(y) || std::isnan(z)) {
		return Vector3();
	}
	return Vector3((float)x, (float)y, (float)z);
}

PackedFloat32Array LAFieldMirrors::slice(const String &p_name, int p_from, int p_count) const {
	PackedFloat32Array out;
	const int s = _slot(p_name);
	if (s < 0 || p_from < 0 || p_count <= 0 || p_from + p_count > _cells) {
		return out;
	}
	out.resize(p_count);
	std::memcpy(out.ptrw(), &_store[(size_t)s * (size_t)_cells + (size_t)p_from],
			(size_t)p_count * 4u);
	return out;
}

PackedFloat32Array LAFieldMirrors::array(const String &p_name) const {
	return slice(p_name, 0, _cells);
}

PackedByteArray LAFieldMirrors::bytes(const String &p_name, int p_from, int p_count) const {
	PackedByteArray out;
	const int s = _slot(p_name);
	if (s < 0 || p_from < 0 || p_count <= 0 || p_from + p_count > _cells) {
		return out;
	}
	out.resize((int64_t)p_count * 4);
	std::memcpy(out.ptrw(), &_store[(size_t)s * (size_t)_cells + (size_t)p_from],
			(size_t)p_count * 4u);
	return out;
}

double LAFieldMirrors::sum(const String &p_name) const {
	const int s = _slot(p_name);
	if (s < 0) {
		return NAN;
	}
	double acc = 0.0;
	const float *p = &_store[(size_t)s * (size_t)_cells];
	for (int c = 0; c < _cells; ++c) {
		acc += (double)p[c];
	}
	return acc;
}

PackedInt32Array LAFieldMirrors::cells_with_phase_mass(const String &p_mass, const String &p_frac,
		double p_min) const {
	PackedInt32Array out;
	const int sm = _slot(p_mass);
	const int sf = _slot(p_frac);
	if (sm < 0 || sf < 0) {
		return out;
	}
	const float *m = &_store[(size_t)sm * (size_t)_cells];
	const float *f = &_store[(size_t)sf * (size_t)_cells];
	for (int c = 0; c < _cells; ++c) {
		const double frac = std::fmin(std::fmax((double)f[c], 0.0), 1.0);
		if (std::fmax((double)m[c], 0.0) * frac >= p_min) {
			out.push_back(c);
		}
	}
	return out;
}

void LAFieldMirrors::set_array(const String &p_name, const PackedFloat32Array &p_values) {
	const int s = _slot(p_name);
	if (s < 0) {
		UtilityFunctions::push_error("LAFieldMirrors.set_array(\"", p_name,
				"\"): no such channel, so nothing was written.");
		return;
	}
	if (p_values.size() != _cells) {
		UtilityFunctions::push_error("LAFieldMirrors.set_array(\"", p_name, "\"): ", p_values.size(),
				" values over ", _cells, " cells, so nothing was written.");
		return;
	}
	std::memcpy(&_store[(size_t)s * (size_t)_cells], p_values.ptr(), (size_t)_cells * 4u);
}

void LAFieldMirrors::fill(const String &p_name, double p_value) {
	const int s = _slot(p_name);
	if (s < 0) {
		return;
	}
	float *p = &_store[(size_t)s * (size_t)_cells];
	for (int c = 0; c < _cells; ++c) {
		p[c] = (float)p_value;
	}
}

void LAFieldMirrors::set_at(const String &p_name, int p_c, double p_v) {
	const int s = _slot(p_name);
	if (s < 0 || p_c < 0 || p_c >= _cells) {
		return;
	}
	_store[(size_t)s * (size_t)_cells + (size_t)p_c] = (float)p_v;
}

void LAFieldMirrors::add_at(const String &p_name, int p_c, double p_v) {
	const int s = _slot(p_name);
	if (s < 0 || p_c < 0 || p_c >= _cells) {
		return;
	}
	_store[(size_t)s * (size_t)_cells + (size_t)p_c] += (float)p_v;
}

LAFieldMirrors *LAFieldMirrors::mirrors_of(Object *p_field) {
	if (p_field == nullptr) {
		return nullptr;
	}
	const Variant v = p_field->get("_mirrors");
	if (v.get_type() != Variant::OBJECT) {
		return nullptr;
	}
	return Object::cast_to<LAFieldMirrors>(v);
}

PackedFloat32Array LAFieldMirrors::of(Object *p_field, const String &p_name) {
	LAFieldMirrors *m = mirrors_of(p_field);
	return m == nullptr ? PackedFloat32Array() : m->array(p_name);
}

void LAFieldMirrors::store(Object *p_field, const String &p_name,
		const PackedFloat32Array &p_values) {
	LAFieldMirrors *m = mirrors_of(p_field);
	if (m == nullptr) {
		UtilityFunctions::push_error("LAFieldMirrors.store(\"", p_name,
				"\"): the field carries no `_mirrors`, so the walk's result was DROPPED.");
		return;
	}
	m->set_array(p_name, p_values);
}

void LAFieldMirrors::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_device", "rd"), &LAFieldMirrors::set_device);
	ClassDB::bind_method(D_METHOD("alloc", "names", "cells"), &LAFieldMirrors::alloc);
	ClassDB::bind_method(D_METHOD("cells"), &LAFieldMirrors::cells);
	ClassDB::bind_method(D_METHOD("names"), &LAFieldMirrors::names);
	ClassDB::bind_method(D_METHOD("has", "name"), &LAFieldMirrors::has);
	ClassDB::bind_method(D_METHOD("live", "name"), &LAFieldMirrors::live);
	ClassDB::bind_method(D_METHOD("drain", "staging", "mirror_srcs", "mirror_names", "probe_srcs",
								  "probe_names"),
			&LAFieldMirrors::drain);
	ClassDB::bind_method(D_METHOD("at", "name", "cell"), &LAFieldMirrors::at);
	ClassDB::bind_method(D_METHOD("vec3", "name_x", "name_y", "name_z", "cell"),
			&LAFieldMirrors::vec3);
	ClassDB::bind_method(D_METHOD("slice", "name", "from", "count"), &LAFieldMirrors::slice);
	ClassDB::bind_method(D_METHOD("array", "name"), &LAFieldMirrors::array);
	ClassDB::bind_method(D_METHOD("bytes", "name", "from", "count"), &LAFieldMirrors::bytes);
	ClassDB::bind_method(D_METHOD("sum", "name"), &LAFieldMirrors::sum);
	ClassDB::bind_method(D_METHOD("cells_with_phase_mass", "mass", "frac", "min"),
			&LAFieldMirrors::cells_with_phase_mass);
	ClassDB::bind_method(D_METHOD("set_array", "name", "values"), &LAFieldMirrors::set_array);
	ClassDB::bind_method(D_METHOD("fill", "name", "value"), &LAFieldMirrors::fill);
	ClassDB::bind_method(D_METHOD("set_at", "name", "cell", "value"), &LAFieldMirrors::set_at);
	ClassDB::bind_method(D_METHOD("add_at", "name", "cell", "value"), &LAFieldMirrors::add_at);
}
