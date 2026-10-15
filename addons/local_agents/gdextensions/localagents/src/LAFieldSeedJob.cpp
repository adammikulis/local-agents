#include "LAFieldSeedJob.hpp"
#include "LASeedCancellation.hpp"
#include "LABodySystem.hpp"
#include "LAFieldCellMass.hpp"
#include "LAFieldLithostaticSeed.hpp"
#include "LAFieldMirrors.hpp"
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include <cstdio>
#include <exception>
#include <system_error>

using namespace godot;

void LAFieldSeedContext::capture(Object *p_field, bool p_gravity) {
	for (const char *name : {"_grid", "_cell_count", "_solid", "_rock_fraction", "_water_fraction",
			"_surface_depth", "_t_rock", "_regolith", "_pivot"}) {
		data[name] = p_field->get(name);
	}
	sea = p_field->call("sea_radius");
	Object *gravity = p_field->get("_gravity");
	up = gravity->call("up_table");
	if (p_gravity) {
		phi = gravity->call("phi_abs");
	}
	LAFieldMirrors *source = LAFieldMirrors::mirrors_of(p_field);
	Ref<LAFieldMirrors> mirrors;
	mirrors.instantiate();
	mirrors->alloc(source->names(), source->cells());
	for (const String &name : source->names()) {
		mirrors->set_array(name, source->array(name));
	}
	data["_mirrors"] = mirrors;
}

bool LAFieldSeedContext::_get(const StringName &p_name, Variant &r_value) const {
	if (p_name == StringName("_gravity") || p_name == StringName("_seal")) {
		r_value = const_cast<LAFieldSeedContext *>(this);
	} else if (p_name == StringName("amounts")) {
		r_value = amounts;
	} else if (data.has(p_name)) {
		r_value = data[p_name];
	} else {
		return false;
	}
	return true;
}

bool LAFieldSeedContext::note_creation(const String &p_name, double p_amount) {
	amounts[p_name] = double(amounts.get(p_name, 0.0)) + p_amount;
	return true;
}

Dictionary LAFieldSeedContext::run(const PackedFloat32Array &p_gravity, bool p_present) {
	const PackedFloat32Array rock = data["_t_rock"];
	Dictionary result = p_present
			? LAFieldLithostaticSeed::settle(this, LABodySeeds::surface_temp_c(), p_gravity, phi, rock)
			: LAFieldLithostaticSeed::compress(this, p_gravity, rock);
	if (!result.is_empty()) {
		LAFieldCellMass3D::seed_enthalpy(this, rock, result);
	}
	return result;
}

LAFieldSeedJob3D::~LAFieldSeedJob3D() {
	cancel();
	if (worker.joinable()) {
		worker.join();
	}
}

Ref<LAFieldSeedContext> LAFieldSeedJob3D::capture(Object *p_field, bool p_gravity) {
	Ref<LAFieldSeedContext> result;
	result.instantiate();
	result->capture(p_field, p_gravity);
	return result;
}

bool LAFieldSeedJob3D::begin(Object *p_field, const PackedFloat32Array &p_gravity, bool p_present) {
	ERR_FAIL_COND_V_MSG(worker.joinable() || published, false, "SEED_ALREADY_STARTED");
	context = capture(p_field, p_present);
	try {
		worker = std::thread([this, p_gravity, p_present]() {
			LASeedCancellation cancellation(&cancel_requested);
			try {
				LASeedCancellation::check();
				balance = context->run(p_gravity, p_present);
			} catch (const LASeedCancellation::Cancelled &) {
				balance.clear();
			} catch (const std::exception &error) {
				std::fprintf(stderr, "SEED_WORKER_FAILED: %s\n", error.what());
				worker_failed = true;
			} catch (...) {
				std::fprintf(stderr, "SEED_WORKER_FAILED: unknown exception\n");
				worker_failed = true;
			}
			done.store(true, std::memory_order_release);
		});
	} catch (const std::system_error &error) {
		UtilityFunctions::push_error("SEED_WORKER_START_FAILED: ", error.what());
		return false;
	}
	return true;
}

bool LAFieldSeedJob3D::finished() const {
	return done.load(std::memory_order_acquire);
}

Dictionary LAFieldSeedJob3D::publish(Object *p_field) {
	if (failed() || published || !finished()) {
		return Dictionary();
	}
	worker.join();
	if (balance.is_empty()) {
		failure = true;
		return Dictionary();
	}
	Object *seal = p_field->get("_seal");
	const Dictionary amounts = context->get("amounts");
	for (const Variant &name : amounts.keys()) {
		if (!bool(seal->call("note_creation", name, amounts[name]))) {
			failure = true;
			return Dictionary();
		}
	}
	LAFieldMirrors *source = LAFieldMirrors::mirrors_of(context.ptr());
	LAFieldMirrors *target = LAFieldMirrors::mirrors_of(p_field);
	for (const String &name : source->names()) {
		target->set_array(name, source->array(name));
	}
	context.unref();
	published = true;
	return balance;
}

bool LAFieldSeedJob3D::prepare_gravity(Object *p_field) {
	Object *gravity = p_field->get("_gravity");
	gravity->call("solve");
	Object *gpu = p_field->get("_gpu");
	if (bool(gpu->call("refused", "the seed"))) { return false; }
	LAFieldCellMass3D::regolith(p_field);
	const PackedByteArray regolith = p_field->get("_regolith");
	ERR_FAIL_COND_V_MSG(!regolith.has(1), false, "SEED_REGOLITH_EMPTY: solved gravity marked no permeable cell");
	return true;
}

bool LAFieldSeedJob3D::finish_restore(Object *p_field, bool p_gravity) {
	Object *gpu = p_field->get("_gpu");
	if (p_gravity) {
		Object *gravity = p_field->get("_gravity");
		gravity->call("solve");
		if (bool(gpu->call("refused", "the seed"))) { return false; }
	}
	gpu->call("derive_seeded", true);
	if (bool(gpu->call("refused", "the seed"))) { return false; }
	Object *measure = p_field->get("_body_measure");
	if (measure != nullptr) {
		measure->call("measure", p_field, LABodySeeds::spin_axis_of(p_field->get("_body_key")));
	}
	return true;
}

bool LAFieldSeedJob3D::complete(Object *p_field, bool p_gravity) {
	if (failed() || !finished()) {
		return false;
	}
	if (!published && publish(p_field).is_empty()) {
		failure = true;
		return false;
	}
	Object *gpu = p_field->get("_gpu");
	auto refused = [&]() {
		if (!bool(gpu->call("refused", "the seed"))) { return false; }
		failure = true;
		return true;
	};
	switch (activation_stage++) {
		case 0: {
			Object *measure = p_field->get("_body_measure");
			if (measure != nullptr) {
				measure->call("measure", p_field, LABodySeeds::spin_axis_of(p_field->get("_body_key")));
			}
			gpu->call("_seed_regolith");
			return false;
		}
		case 1:
			gpu->call("_seed", "pressure", balance["pressure"]);
			gpu->call("_seed", "p_fluid", balance["fluid"]);
			gpu->call("_upload_mirror", "e_j_m3");
			gpu->call("_upload_mirror", "e_lith_j_m3");
			for (const String &name : LAFieldCellMass3D::mirror_names(p_field)) {
				gpu->call("seed_field", name, p_field->get("_seal"));
			}
			gpu->call("mark_h_dirty");
			return false;
		case 2:
			if (p_gravity) {
				Object *gravity = p_field->get("_gravity");
				gravity->call("solve");
			}
			refused();
			return false;
		case 3:
			gpu->call("derive_seeded", true);
			if (refused()) { return false; }
			p_field->set("_ready_sim", true);
			return true;
		default:
			return true;
	}
}

void LAFieldSeedContext::_bind_methods() {
	ClassDB::bind_method(D_METHOD("run", "gravity", "present"), &LAFieldSeedContext::run);
	ClassDB::bind_method(D_METHOD("up_table"), &LAFieldSeedContext::up_table);
	ClassDB::bind_method(D_METHOD("phi_abs"), &LAFieldSeedContext::phi_abs);
	ClassDB::bind_method(D_METHOD("sea_radius"), &LAFieldSeedContext::sea_radius);
	ClassDB::bind_method(D_METHOD("note_creation", "name", "amount"), &LAFieldSeedContext::note_creation);
}

void LAFieldSeedJob3D::_bind_methods() {
	ClassDB::bind_static_method("LAFieldSeedJob3D", D_METHOD("finish_restore", "field", "gravity"), &LAFieldSeedJob3D::finish_restore);
	ClassDB::bind_static_method("LAFieldSeedJob3D", D_METHOD("prepare_gravity", "field"), &LAFieldSeedJob3D::prepare_gravity);
	ClassDB::bind_method(D_METHOD("capture", "field", "gravity"), &LAFieldSeedJob3D::capture);
	ClassDB::bind_method(D_METHOD("begin", "field", "gravity", "present"), &LAFieldSeedJob3D::begin);
	ClassDB::bind_method(D_METHOD("cancel"), &LAFieldSeedJob3D::cancel);
	ClassDB::bind_method(D_METHOD("finished"), &LAFieldSeedJob3D::finished);
	ClassDB::bind_method(D_METHOD("publish", "field"), &LAFieldSeedJob3D::publish);
	ClassDB::bind_method(D_METHOD("complete", "field", "gravity"), &LAFieldSeedJob3D::complete);
	ClassDB::bind_method(D_METHOD("failed"), &LAFieldSeedJob3D::failed);
}
