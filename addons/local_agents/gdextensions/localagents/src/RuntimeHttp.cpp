#include "RuntimeHttp.hpp"
#include "RuntimeStringUtils.hpp"
#include <godot_cpp/classes/json.hpp>
#include <godot_cpp/variant/array.hpp>
#include <curl/curl.h>
#include <string>
#include <cmath>
#include <limits>
using namespace godot;
namespace local_agents::runtime {
struct StreamState {
    std::string body;
    std::string pending;
    String text;
    Callable progress;
    CURL *curl = nullptr;
    bool done = false;
    bool malformed = false;
    Dictionary usage;
    Dictionary tool_calls;
};

void consume_event(StreamState &state, const std::string &event) {
    if (event == "[DONE]") { state.done = true; return; }
    Variant parsed = JSON::parse_string(String::utf8(event.c_str()));
    if (parsed.get_type() != Variant::DICTIONARY) { state.malformed = true; return; }
    Dictionary chunk = parsed;
    if (chunk.has("error")) { state.malformed = true; return; }
    if (chunk.has("usage") && chunk["usage"].get_type() == Variant::DICTIONARY) state.usage = chunk["usage"];
    Variant choices_value = chunk.get("choices", Array());
    if (choices_value.get_type() != Variant::ARRAY) { state.malformed = true; return; }
    Array choices = choices_value;
    if (choices.is_empty()) return;
    if (choices[0].get_type() != Variant::DICTIONARY) { state.malformed = true; return; }
    Dictionary choice = choices[0];
    Variant delta_value = choice.get("delta", Dictionary());
    if (delta_value.get_type() != Variant::DICTIONARY) { state.malformed = true; return; }
    Dictionary delta = delta_value;
    Variant content_value = delta.get("content", Variant());
    if (content_value.get_type() != Variant::NIL && content_value.get_type() != Variant::STRING) { state.malformed = true; return; }
    String content = content_value.get_type() == Variant::STRING ? String(content_value) : String();
    if (!content.is_empty()) {
        state.text += content;
        state.progress.call_deferred(state.text);
    }
    Variant tools_value = delta.get("tool_calls", Array());
    if (tools_value.get_type() != Variant::ARRAY) { state.malformed = true; return; }
    Array tools = tools_value;
    for (int i = 0; i < tools.size(); ++i) {
        if (tools[i].get_type() != Variant::DICTIONARY) { state.malformed = true; return; }
        Dictionary fragment = tools[i];
        if (fragment.has("index")) {
            Variant index = fragment["index"];
            if (index.get_type() != Variant::INT && index.get_type() != Variant::FLOAT) { state.malformed = true; return; }
            double number = index;
            if (!std::isfinite(number) || number < 0 || std::floor(number) != number || number > std::numeric_limits<int>::max()) { state.malformed = true; return; }
        }
        for (const char *key : {"id", "type"}) {
            if (fragment.has(key) && fragment[key].get_type() != Variant::STRING) { state.malformed = true; return; }
        }
        int index = fragment.get("index", i);
        Dictionary tool = state.tool_calls.get(index, Dictionary());
        if (fragment.has("id")) tool["id"] = fragment["id"];
        if (fragment.has("type")) tool["type"] = fragment["type"];
        Dictionary function = tool.get("function", Dictionary());
        Variant function_value = fragment.get("function", Dictionary());
        if (function_value.get_type() != Variant::DICTIONARY) { state.malformed = true; return; }
        Dictionary incoming = function_value;
        for (const char *key : {"name", "arguments"}) {
            if (incoming.has(key) && incoming[key].get_type() != Variant::STRING) { state.malformed = true; return; }
        }
        if (incoming.has("name")) function["name"] = incoming["name"];
        if (incoming.has("arguments")) function["arguments"] = String(function.get("arguments", String())) + String(incoming["arguments"]);
        tool["function"] = function;
        state.tool_calls[index] = tool;
    }
}

size_t curl_write_stream(void *contents, size_t size, size_t count, void *userdata) {
    auto &state = *static_cast<StreamState *>(userdata);
    size_t total = size * count;
    state.body.append(static_cast<const char *>(contents), total);
    long status = 0;
    curl_easy_getinfo(state.curl, CURLINFO_RESPONSE_CODE, &status);
    if (status < 200 || status >= 300) return total;
    state.pending.append(static_cast<const char *>(contents), total);
    size_t end;
    while ((end = state.pending.find('\n')) != std::string::npos) {
        std::string line = state.pending.substr(0, end);
        state.pending.erase(0, end + 1);
        if (!line.empty() && line.back() == '\r') line.pop_back();
        if (line.rfind("data:", 0) == 0) {
            std::string event = line.substr(5);
            if (!event.empty() && event.front() == ' ') event.erase(0, 1);
            consume_event(state, event);
        }
    }
    return total;
}

size_t curl_write_string(void *contents, size_t size, size_t nmemb, void *userdata) {
    if (!userdata) {
        return 0;
    }
    const size_t total = size * nmemb;
    std::string *buffer = static_cast<std::string *>(userdata);
    buffer->append(static_cast<const char *>(contents), total);
    return total;
}

HttpJsonResponse http_post_json(
    const String &url,
    const Dictionary &payload,
    const PackedStringArray &headers,
    int timeout_seconds,
    const Callable &progress
) {
    HttpJsonResponse result;
    result.body = String();
    result.error = String();

    CURL *curl = curl_easy_init();
    if (!curl) {
        result.error = String("curl_init_failed");
        return result;
    }

    struct curl_slist *header_list = nullptr;
    for (int i = 0; i < headers.size(); ++i) {
        std::string header = to_utf8(headers[i]);
        header_list = curl_slist_append(header_list, header.c_str());
    }
    if (!header_list) {
        header_list = curl_slist_append(header_list, "Content-Type: application/json");
    }

    std::string response_buffer;
    StreamState stream;
    stream.progress = progress;
    stream.curl = curl;
    std::string payload_text = to_utf8(JSON::stringify(payload));
    std::string url_utf8 = to_utf8(url);

    curl_easy_setopt(curl, CURLOPT_URL, url_utf8.c_str());
    curl_easy_setopt(curl, CURLOPT_HTTPHEADER, header_list);
    curl_easy_setopt(curl, CURLOPT_POST, 1L);
    curl_easy_setopt(curl, CURLOPT_POSTFIELDS, payload_text.c_str());
    curl_easy_setopt(curl, CURLOPT_POSTFIELDSIZE, static_cast<long>(payload_text.size()));
    if (progress.is_valid()) {
        curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, curl_write_stream);
        curl_easy_setopt(curl, CURLOPT_WRITEDATA, &stream);
    } else {
        curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, curl_write_string);
        curl_easy_setopt(curl, CURLOPT_WRITEDATA, &response_buffer);
    }
    curl_easy_setopt(curl, CURLOPT_TIMEOUT, timeout_seconds > 0 ? timeout_seconds : 120);
    curl_easy_setopt(curl, CURLOPT_CONNECTTIMEOUT, 10L);

    CURLcode code = curl_easy_perform(curl);
    if (code != CURLE_OK) {
        result.error = String::utf8(curl_easy_strerror(code));
    } else {
        result.ok = true;
    }

    long status_code = 0;
    curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &status_code);
    result.status_code = status_code;
    result.body = String::utf8(progress.is_valid() ? stream.body.c_str() : response_buffer.c_str());
    if (progress.is_valid() && result.ok && status_code >= 200 && status_code < 300) {
        if (!stream.done || stream.malformed) {
            result.ok = false;
            result.error = stream.malformed ? String("invalid_stream_event") : String("stream_incomplete");
        } else {
            Dictionary message;
            message["role"] = String("assistant");
            message["content"] = stream.text;
            Array tools;
            Array indices = stream.tool_calls.keys();
            indices.sort();
            for (int i = 0; i < indices.size(); ++i) tools.append(stream.tool_calls[indices[i]]);
            if (!tools.is_empty()) message["tool_calls"] = tools;
            Dictionary choice;
            choice["message"] = message;
            Array choices;
            choices.append(choice);
            Dictionary completion;
            completion["choices"] = choices;
            if (!stream.usage.is_empty()) completion["usage"] = stream.usage;
            result.body = JSON::stringify(completion);
        }
    }

    curl_slist_free_all(header_list);
    curl_easy_cleanup(curl);
    return result;
}

}
