#pragma once
#include "la/Device.hpp"
#include <string>

namespace lasim {
int serve(la::Backend backend, int device_index, const std::string &blob, const std::string &publications);
}
