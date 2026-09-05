#include "LAFieldStateCache.hpp"

#include <godot_cpp/classes/dir_access.hpp>
#include <godot_cpp/classes/file_access.hpp>
#include <godot_cpp/classes/project_settings.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>

using namespace godot;

namespace {

const char *MASK_DIR = "user://la_solid_cache";
const char *STATE_DIR = "user://la_field_cache";

String entry_path(const char *p_dir, const String &p_key) {
	return String(p_dir) + "/" + p_key + ".bin";
}

void ensure_dir(const char *p_dir) {
	DirAccess::make_dir_recursive_absolute(ProjectSettings::get_singleton()->globalize_path(p_dir));
}

} // namespace

String LAFieldStateCache::mask_key(const Dictionary &p_opts, int p_nx, int p_ny, int p_nz, double p_cell,
		const Vector3 &p_origin, const PackedStringArray &p_sources) {
	PackedStringArray parts;
	Array names = p_opts.keys();
	names.sort();
	for (int i = 0; i < names.size(); i++) {
		const String k = names[i];
		// view_distance changes how much terrain is streamed, never what the SDF says at a point.
		if (k == "view_distance") {
			continue;
		}
		parts.append(k + String("=") + String(p_opts[names[i]]));
	}
	parts.append(String("dims=") + itos(p_nx) + "," + itos(p_ny) + "," + itos(p_nz));
	parts.append(String("cell=") + String::num(p_cell, 6));
	parts.append(String("origin=") + String::num(p_origin.x, 4) + "," + String::num(p_origin.y, 4) + "," +
			String::num(p_origin.z, 4));
	for (int i = 0; i < p_sources.size(); i++) {
		Ref<FileAccess> src = FileAccess::open(p_sources[i], FileAccess::READ);
		if (src.is_null()) {
			return String();
		}
		parts.append(p_sources[i] + String("=") + src->get_as_text().sha256_text());
	}
	// The walks this key stands for are NATIVE, so a rebuilt extension is a different walk.
	Ref<FileAccess> hf = FileAccess::open(
			"res://addons/local_agents/gdextensions/localagents/bin/SOURCE_HASH", FileAccess::READ);
	if (hf.is_null()) {
		return String();
	}
	parts.append(String("ext=") + hf->get_as_text());
	return String("\n").join(parts).sha256_text();
}

String LAFieldStateCache::state_key(const String &p_tree_key, int p_nx, int p_ny, int p_nz, double p_cell,
		const Vector3 &p_origin) {
	if (p_tree_key.is_empty()) {
		return String();
	}
	PackedStringArray parts;
	parts.append(p_tree_key);
	parts.append(String("dims=") + itos(p_nx) + "," + itos(p_ny) + "," + itos(p_nz));
	parts.append(String("cell=") + String::num(p_cell, 6));
	parts.append(String("origin=") + String::num(p_origin.x, 4) + "," + String::num(p_origin.y, 4) + "," +
			String::num(p_origin.z, 4));
	return String("\n").join(parts).sha256_text();
}

Dictionary LAFieldStateCache::load_state(const String &p_key, int p_cell_count) {
	Dictionary empty;
	if (p_key.is_empty()) {
		return empty;
	}
	Ref<FileAccess> f = FileAccess::open(entry_path(STATE_DIR, p_key), FileAccess::READ);
	if (f.is_null()) {
		return empty;
	}
	const Variant raw = f->get_var();
	if (raw.get_type() != Variant::DICTIONARY) {
		return empty;
	}
	const Dictionary data = raw;
	if (int(data.get("cell_count", -1)) != p_cell_count) {
		return empty;
	}
	const PackedByteArray snapshot = data.get("snapshot", PackedByteArray());
	return snapshot.is_empty() ? empty : data;
}

Dictionary LAFieldStateCache::load_blob(const String &p_key) {
	Dictionary empty;
	if (p_key.is_empty()) {
		return empty;
	}
	Ref<FileAccess> f = FileAccess::open(entry_path(STATE_DIR, p_key), FileAccess::READ);
	if (f.is_null()) {
		return empty;
	}
	const Variant raw = f->get_var();
	return raw.get_type() == Variant::DICTIONARY ? Dictionary(raw) : empty;
}

void LAFieldStateCache::save_blob(const String &p_key, const Dictionary &p_data) {
	save_state(p_key, p_data);
}

void LAFieldStateCache::save_state(const String &p_key, const Dictionary &p_data) {
	if (p_key.is_empty() || p_data.is_empty()) {
		return;
	}
	ensure_dir(STATE_DIR);
	Ref<FileAccess> f = FileAccess::open(entry_path(STATE_DIR, p_key), FileAccess::WRITE);
	if (f.is_valid()) {
		f->store_var(p_data);
	}
}

void LAFieldStateCache::_bind_methods() {
	ClassDB::bind_static_method("LAFieldStateCache",
			D_METHOD("mask_key", "opts", "nx", "ny", "nz", "cell", "origin", "sources"),
			&LAFieldStateCache::mask_key);
	ClassDB::bind_static_method("LAFieldStateCache", D_METHOD("load_blob", "key"), &LAFieldStateCache::load_blob);
	ClassDB::bind_static_method("LAFieldStateCache", D_METHOD("save_blob", "key", "data"), &LAFieldStateCache::save_blob);
	ClassDB::bind_static_method("LAFieldStateCache",
			D_METHOD("state_key", "tree_key", "nx", "ny", "nz", "cell", "origin"),
			&LAFieldStateCache::state_key);
	ClassDB::bind_static_method("LAFieldStateCache", D_METHOD("load_state", "key", "cell_count"),
			&LAFieldStateCache::load_state);
	ClassDB::bind_static_method("LAFieldStateCache", D_METHOD("save_state", "key", "data"),
			&LAFieldStateCache::save_state);
}
