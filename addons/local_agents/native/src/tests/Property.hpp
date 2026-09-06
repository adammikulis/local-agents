#pragma once

#include <cstdint>
#include <string>
#include <vector>

namespace la {
class Device;
}

namespace lasim {

// One property of one kernel, asserted over randomised inputs. `mutate` flips a sign or shifts the
// property's OWN reference: the runner demands green without it and red with it, so a property that
// cannot fail is reported instead of counted.
struct Case {
	la::Device &dev;
	uint64_t seed = 0;
	bool mutate = false;
	uint32_t examined = 0; // cases the property actually compared; zero is a failure
	std::string why;       // what went wrong, on a red arm
};

struct Property {
	const char *kernel;
	const char *name;
	bool (*run)(Case &);
};

// A reference the mutated arm moves off the true value by far more than any tolerance admits, at every
// magnitude including zero.
inline float shifted(float v, bool mutate) {
	return mutate ? (v * 1.001f + 1.0f) : v;
}

void add_reduce_properties(std::vector<Property> &out);
void add_derive_properties(std::vector<Property> &out);
void add_flux_properties(std::vector<Property> &out);
void add_gravity_properties(std::vector<Property> &out);
void add_pressure_properties(std::vector<Property> &out);
void add_reaction_properties(std::vector<Property> &out);
void add_probe_properties(std::vector<Property> &out);
void add_sparse_properties(std::vector<Property> &out);
void add_mesh_properties(std::vector<Property> &out);

} // namespace lasim
