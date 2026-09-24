#ifndef LOCAL_AGENTS_LA_PARALLEL_HPP
#define LOCAL_AGENTS_LA_PARALLEL_HPP

#include <algorithm>
#include <atomic>
#include <thread>
#include <vector>

namespace godot {

// p_fn(i) for every i in [0, p_count) across the host's cores, claimed in chunks off one counter.
// p_fn writes only index i's own slots.
template <typename F>
void la_parallel_for(int p_count, const F &p_fn) {
	const int workers = int(std::max(std::thread::hardware_concurrency(), 1u));
	const int chunk = 16;
	std::atomic<int> next(0);
	auto run = [&]() {
		for (int lo = next.fetch_add(chunk); lo < p_count; lo = next.fetch_add(chunk)) {
			const int hi = std::min(lo + chunk, p_count);
			for (int i = lo; i < hi; i++) {
				p_fn(i);
			}
		}
	};
	std::vector<std::thread> pool;
	for (int t = 1; t < workers && t * chunk < p_count; t++) {
		pool.emplace_back(run);
	}
	run();
	for (std::thread &t : pool) {
		t.join();
	}
}

// Cells in the order their column's top-down walk reaches them: levels[k] holds every cell k steps below
// the top of its column, so a level's cells read only levels above it. False where p_up closes on itself.
inline bool la_column_levels(const std::vector<int> &p_up, const std::vector<char> &p_in,
		std::vector<std::vector<int>> &r_levels) {
	const int n = int(p_up.size());
	std::vector<int> depth(n, -1), chain;
	r_levels.clear();
	for (int c = 0; c < n; c++) {
		if (!p_in[c] || depth[c] >= 0) {
			continue;
		}
		chain.clear();
		int base = 0;
		for (int a = c;;) {
			chain.push_back(a);
			if (int(chain.size()) > n) {
				return false;
			}
			const int u = p_up[a];
			if (u < 0 || !p_in[u] || depth[u] >= 0) {
				base = (u >= 0 && p_in[u]) ? depth[u] + 1 : 0;
				break;
			}
			a = u;
		}
		for (int j = int(chain.size()) - 1; j >= 0; j--) {
			depth[chain[j]] = base + int(chain.size()) - 1 - j;
		}
	}
	for (int c = 0; c < n; c++) {
		if (depth[c] >= 0) {
			if (int(r_levels.size()) <= depth[c]) {
				r_levels.resize(depth[c] + 1);
			}
			r_levels[depth[c]].push_back(c);
		}
	}
	return true;
}

} // namespace godot

#endif // LOCAL_AGENTS_LA_PARALLEL_HPP
