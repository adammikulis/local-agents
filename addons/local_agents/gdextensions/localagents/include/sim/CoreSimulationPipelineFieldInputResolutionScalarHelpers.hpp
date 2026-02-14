#ifndef LOCAL_AGENTS_UNIFIED_SIMULATION_PIPELINE_FIELD_INPUT_RESOLUTION_SCALAR_HELPERS_HPP
#define LOCAL_AGENTS_UNIFIED_SIMULATION_PIPELINE_FIELD_INPUT_RESOLUTION_SCALAR_HELPERS_HPP

#include "sim/CoreSimulationPipelineFieldInputResolution.hpp"

namespace local_agents::simulation {

Array hot_field_candidate_keys(const String &requested_field);

bool try_resolve_scalar_from_candidate_keys(
    const Dictionary &container,
    const Array &candidate_keys,
    double &scalar_value,
    String &resolved_key,
    String &resolution_key);

bool try_resolve_hot_field_from_handles(
    const Dictionary &frame_inputs,
    const Dictionary &field_handle_cache,
    const String &requested_field,
    double &out_scalar,
    String &resolved_source,
    String &resolved_key,
    String &matched_handle,
    int64_t &attempt_count);

void resolve_scalar_aliases(Dictionary &stage_inputs, const Dictionary &frame_inputs);

} // namespace local_agents::simulation

#endif // LOCAL_AGENTS_UNIFIED_SIMULATION_PIPELINE_FIELD_INPUT_RESOLUTION_SCALAR_HELPERS_HPP
