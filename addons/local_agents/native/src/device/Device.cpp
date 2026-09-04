#include "la/Device.hpp"

namespace la {

Device::~Device() = default;

#if LA_BACKEND_METAL
std::unique_ptr<Device> create_metal_device(int index, std::string &err);
#endif

std::unique_ptr<Device> Device::create(Backend backend, int index, std::string &err) {
	switch (backend) {
		case Backend::Metal:
#if LA_BACKEND_METAL
			return create_metal_device(index, err);
#else
			err = "this build carries no Metal backend";
			return nullptr;
#endif
		case Backend::Vulkan:
			err = "this build carries no Vulkan backend";
			return nullptr;
	}
	err = "unknown backend";
	return nullptr;
}

} // namespace la
