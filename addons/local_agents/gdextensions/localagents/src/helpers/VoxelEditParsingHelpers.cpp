#include "helpers/VoxelEditParsingHelpers.hpp"

#include <godot_cpp/variant/vector3.hpp>

#include <cmath>
#include <limits>

using namespace godot;

namespace local_agents::simulation::helpers {

bool parse_int32_variant(const Variant &value, int32_t &out) {
    if (value.get_type() == Variant::INT) {
        const int64_t raw = static_cast<int64_t>(value);
        if (raw < std::numeric_limits<int32_t>::min() || raw > std::numeric_limits<int32_t>::max()) {
            return false;
        }
        out = static_cast<int32_t>(raw);
        return true;
    }
    if (value.get_type() == Variant::FLOAT) {
        const double raw = static_cast<double>(value);
        if (!std::isfinite(raw)) {
            return false;
        }
        if (raw < static_cast<double>(std::numeric_limits<int32_t>::min()) ||
            raw > static_cast<double>(std::numeric_limits<int32_t>::max())) {
            return false;
        }
        out = static_cast<int32_t>(raw);
        return true;
    }
    return false;
}

bool parse_double_variant(const Variant &value, double &out) {
    if (value.get_type() == Variant::INT) {
        out = static_cast<double>(static_cast<int64_t>(value));
        return true;
    }
    if (value.get_type() == Variant::FLOAT) {
        const double raw = static_cast<double>(value);
        if (!std::isfinite(raw)) {
            return false;
        }
        out = raw;
        return true;
    }
    return false;
}

bool parse_fracture_shape(const String &shape, String &out_shape) {
    String normalized = shape.to_lower();
    if (normalized.is_empty()) {
        return false;
    }
    if (normalized == String("sphere") || normalized == String("radial") || normalized == String("round")) {
        out_shape = normalized == String("round") ? String("sphere") : normalized;
        return true;
    }
    return false;
}

bool parse_vector3_variant(const Variant &value, double &out_x, double &out_y, double &out_z) {
    if (value.get_type() == Variant::VECTOR3) {
        const Vector3 vector = value;
        if (!std::isfinite(vector.x) || !std::isfinite(vector.y) || !std::isfinite(vector.z)) {
            return false;
        }
        out_x = vector.x;
        out_y = vector.y;
        out_z = vector.z;
        return true;
    }
    if (value.get_type() != Variant::DICTIONARY) {
        return false;
    }
    const Dictionary source = value;
    if (!source.has("x") || !source.has("y") || !source.has("z")) {
        return false;
    }

    double x = 0.0;
    double y = 0.0;
    double z = 0.0;
    if (!parse_double_variant(source["x"], x) || !parse_double_variant(source["y"], y) || !parse_double_variant(source["z"], z)) {
        return false;
    }
    if (!std::isfinite(x) || !std::isfinite(y) || !std::isfinite(z)) {
        return false;
    }

    out_x = x;
    out_y = y;
    out_z = z;
    return true;
}

Dictionary build_point_dict(int32_t x, int32_t y, int32_t z) {
    Dictionary point;
    point["x"] = x;
    point["y"] = y;
    point["z"] = z;
    return point;
}

} // namespace local_agents::simulation::helpers
