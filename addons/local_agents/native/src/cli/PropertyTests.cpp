#include "Selftest.hpp"

#include "la/Device.hpp"
#include "tests/Property.hpp"

#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

namespace lasim {

namespace {

std::vector<Property> all_properties() {
	std::vector<Property> out;
	add_reduce_properties(out);
	add_derive_properties(out);
	add_flux_properties(out);
	add_gravity_properties(out);
	add_pressure_properties(out);
	add_reaction_properties(out);
	add_probe_properties(out);
	add_sparse_properties(out);
	add_mesh_properties(out);
	return out;
}

bool arm(const Property &p, Case &c) {
	const bool ok = p.run(c);
	// A property that compared nothing proved nothing, whatever it returned.
	return ok && c.examined > 0;
}

} // namespace

// EVERY KERNEL THE BLOB CARRIES, one property at a time, over randomised inputs. Each is run twice: once
// as written, and once with its own reference shifted, which must come back red — a property that passes
// either way is not one.
int property_tests(la::Device &dev, const std::string &blob, uint64_t seed, const char *only) {
	std::string err;
	if (!dev.load_kernels(blob, err)) {
		std::fprintf(stderr, "property-tests: %s\n", err.c_str());
		return 2;
	}
	const std::vector<Property> props = all_properties();
	int code = 0;
	uint32_t ran = 0;
	for (const Property &p : props) {
		if (only != nullptr && std::strcmp(only, p.name) != 0) { continue; }
		++ran;
		Case live{ dev, seed, false, 0u, std::string() };
		const bool held = arm(p, live);
		Case control{ dev, seed, true, 0u, std::string() };
		const bool control_held = arm(p, control);
		const bool ok = held && !control_held;
		std::printf("NATIVE_PROPERTY={\"kernel\":\"%s\",\"name\":\"%s\",\"held\":%s,"
					"\"control_red\":%s}\n",
				p.kernel, p.name, held ? "true" : "false", control_held ? "false" : "true");
		if (!held) {
			std::fprintf(stderr, "property-tests: %s / %s FAILED: %s (--seed %llu)\n", p.kernel,
					p.name, live.why.empty() ? "the property does not hold" : live.why.c_str(),
					static_cast<unsigned long long>(seed));
			code = 1;
		} else if (control_held) {
			std::fprintf(stderr,
					"property-tests: %s / %s cannot fail: it passed with its own reference shifted, "
					"so it asserts nothing (--seed %llu)\n",
					p.kernel, p.name, static_cast<unsigned long long>(seed));
			code = 1;
		}
		if (!ok) { continue; }
	}
	if (ran == 0) {
		std::fprintf(stderr, "property-tests: no property matched, so nothing was asserted\n");
		return 2;
	}
	if (code == 0) {
		std::printf("NATIVE_PROPERTIES_OK={\"properties\":%u,\"seed\":%llu}\n", ran,
				static_cast<unsigned long long>(seed));
	}
	return code;
}

} // namespace lasim
