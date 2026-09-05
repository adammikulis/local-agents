#pragma once

#include <cstdint>

#include "Generated.hpp"

namespace lasim {

// The matter channels in the order matter_channels.glsli's channel_at() reads them, which is
// LAMatterChannels.CHANNELS order. LA_CHANNEL_SLOTS of them.
inline constexpr uint32_t kChannelBinding[] = {
	LA_BIND_H2O, LA_BIND_SILICATE, LA_BIND_CARBONATE, LA_BIND_SILICA, LA_BIND_O2, LA_BIND_CO2,
	LA_BIND_N2, LA_BIND_BIOMASS, LA_BIND_FUNGUS, LA_BIND_DETRITUS, LA_BIND_FUEL, LA_BIND_ORG_H,
	LA_BIND_ORG_O, LA_BIND_FERT, LA_BIND_METAL, LA_BIND_OLIVINE, LA_BIND_PYROXENE,
	LA_BIND_PLAGIOCLASE, LA_BIND_HALITE, LA_BIND_APATITE, LA_BIND_H2, LA_BIND_CO, LA_BIND_SO2,
	LA_BIND_H2S, LA_BIND_CH4, LA_BIND_H2O_PORE
};
inline constexpr uint32_t kChannelSlots = sizeof(kChannelBinding) / sizeof(kChannelBinding[0]);

} // namespace lasim
