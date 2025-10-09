#ifndef LOCAL_AGENTS_MODEL_DOWNLOAD_MANAGER_HPP
#define LOCAL_AGENTS_MODEL_DOWNLOAD_MANAGER_HPP

#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/string.hpp>

#include <functional>

namespace godot {

class ModelDownloadManager {
public:
    struct Callbacks {
        std::function<void(const String &label, const String &path)> started;
        std::function<void(const String &label, double progress, int64_t received, int64_t total, const String &path)> progress;
        std::function<void(const String &line, const String &path)> log;
        std::function<void(bool ok, const String &error, const String &path)> finished;
    };

    Dictionary download(const Dictionary &request,
                        const Callbacks &callbacks,
                        const String &runtime_directory) const;
};

} // namespace godot

#endif // LOCAL_AGENTS_MODEL_DOWNLOAD_MANAGER_HPP
