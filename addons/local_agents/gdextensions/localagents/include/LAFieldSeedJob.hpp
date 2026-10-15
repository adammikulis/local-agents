#ifndef LOCAL_AGENTS_LA_FIELD_SEED_JOB_HPP
#define LOCAL_AGENTS_LA_FIELD_SEED_JOB_HPP

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/classes/ref.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_float64_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <atomic>
#include <thread>

namespace godot {

class LAFieldSeedContext : public RefCounted {
	GDCLASS(LAFieldSeedContext, RefCounted);
	Dictionary data;
	Dictionary amounts;
	PackedInt32Array up;
	PackedFloat64Array phi;
	double sea = 0.0;

public:
	void capture(Object *p_field, bool p_gravity);
	Dictionary run(const PackedFloat32Array &p_gravity, bool p_present);
	PackedInt32Array up_table() const { return up; }
	PackedFloat64Array phi_abs() const { return phi; }
	double sea_radius() const { return sea; }
	bool note_creation(const String &p_name, double p_amount);

protected:
	bool _get(const StringName &p_name, Variant &r_value) const;
	static void _bind_methods();
};

class LAFieldSeedJob3D : public RefCounted {
	GDCLASS(LAFieldSeedJob3D, RefCounted);
	Ref<LAFieldSeedContext> context;
	std::thread worker;
	std::atomic<bool> done{false};
	std::atomic<bool> cancel_requested{false};
	Dictionary balance;
	bool published = false;
	bool failure = false;
	bool worker_failed = false;
	int activation_stage = 0;

public:
	~LAFieldSeedJob3D();
	Ref<LAFieldSeedContext> capture(Object *p_field, bool p_gravity);
	bool begin(Object *p_field, const PackedFloat32Array &p_gravity, bool p_present);
	bool finished() const;
	void cancel() { cancel_requested.store(true, std::memory_order_relaxed); }
	Dictionary publish(Object *p_field);
	static void prepare_gravity(Object *p_field);
	bool complete(Object *p_field, bool p_gravity);
	bool failed() const { return failure || cancel_requested.load(std::memory_order_relaxed) || (finished() && worker_failed); }

protected:
	static void _bind_methods();
};

}
#endif
