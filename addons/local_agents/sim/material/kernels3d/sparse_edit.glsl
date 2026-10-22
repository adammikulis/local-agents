#[compute]
#version 450

#include "bindings.glsli"

// One thread per NAMED cell: ADD credits from outside the field, MOVE debits a source and credits a
// destination. `inject_src`/`inject_dst` are the pair the dispatch names; one channel on both sets `same`.

#include "cellvol.glsli"

layout(local_size_x = 64) in;

// Not `restrict`: with `same` set both point at one buffer, and only `src_ch` is then touched.
layout(set = 0, binding = LA_BIND_INJECT_SRC, std430) buffer InjSrc { float src_ch[]; };
layout(set = 0, binding = LA_BIND_INJECT_DST, std430) buffer InjDst { float dst_ch[]; };
// Per entry: source cell, destination cell (-1 = none), op.
layout(set = 0, binding = LA_BIND_INJECT_IDX, std430) restrict readonly buffer InjIdx { int inj_idx[]; };
// Per entry: amount, ceiling.
layout(set = 0, binding = LA_BIND_INJECT_VAL, std430) restrict readonly buffer InjVal { float inj_val[]; };
// Per entry: what the device actually applied, in source-cell fractions.
layout(set = 0, binding = LA_BIND_INJECT_APPLIED, std430) restrict writeonly buffer InjApplied { float inj_applied[]; };

const int LA_INJECT_ADD = 0;
const int LA_INJECT_MOVE = 1;
// A credit to a stock with no zero: internal energy, momentum, charge.
const int LA_INJECT_ADD_SIGNED = 2;

layout(push_constant, std430) uniform Params {
	uint base;         // first entry of this dispatch
	uint count;        // entries in it
	uint cell_count;   // interior plus ghost tail: an index past it names no cell
	uint same;         // 1 = source and destination are one channel
	uint chunk_stride; // chunk.glsli: over this dispatch's entries
	uint chunk_phase;
} params;

#include "chunk.glsli"

void main() {
	uint t = la_cell();
	if (t >= params.count) {
		return;
	}
	uint e = params.base + t;
	inj_applied[e] = 0.0;
	int s = inj_idx[e * 3u];
	int d = inj_idx[e * 3u + 1u];
	int op = inj_idx[e * 3u + 2u];
	if (s < 0 || uint(s) >= params.cell_count) {
		return;
	}
	uint su = uint(s);
	float amount = inj_val[e * 2u];
	float ceiling = inj_val[e * 2u + 1u];
	if (op != LA_INJECT_MOVE) {
		float before = src_ch[su];
		float delta = amount;
		if (delta > 0.0) {
			delta = min(delta, max(0.0, ceiling - before));   // fill the headroom, never push a cell down
		}
		// An amount of matter stops at none; a signed stock has no zero to stop at.
		float after = op == LA_INJECT_ADD ? max(0.0, before + delta) : before + delta;
		src_ch[su] = after;
		inj_applied[e] = after - before;
		return;
	}
	// MOVE: what the source holds is the bound, so a debit can never exceed what is there.
	float before = src_ch[su];
	float take = min(max(amount, 0.0), before);
	if (d >= 0 && uint(d) < params.cell_count) {
		uint du = uint(d);
		// A channel value is a fill fraction, so the same matter is a different fraction of a different cell.
		float ratio = vol_ratio(su, du);
		float held = params.same == 1u ? src_ch[du] : dst_ch[du];
		// THE DEBIT IS DECIDED ONCE, IN THE SOURCE'S OWN UNIT: never a credit divided back.
		float headroom = max(0.0, ceiling - held);
		take = min(take, ratio > 0.0 ? headroom / ratio : 0.0);
		float gain = take * ratio;
		if (params.same == 1u) {
			src_ch[du] = held + gain;
		} else {
			dst_ch[du] = held + gain;
		}
	}
	// The stock as it stands, less a debit it already bounds: what leaves is what the stock lost.
	float after = src_ch[su] - take;
	src_ch[su] = after;
	inj_applied[e] = before - after;
}
