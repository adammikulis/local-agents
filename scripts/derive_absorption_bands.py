#!/usr/bin/env python3
"""Regenerate the LAAbsorptionBands GDExtension table from HITRAN.

Usage, from scripts/:
    scripts/fetch_hitran.sh    # writes the line CSVs, CO2-CO2_2024.cia, o3_uv_serdyuchenko.dat
    python3 scripts/derive_absorption_bands.py addons/local_agents/gdextensions/localagents/src/LAAbsorptionBands.cpp

Needs numpy. The band table is DATA, not a modelling choice: every number here comes out of HITRAN
line parameters, HITRAN CIA cross-sections, measured O3 electronic cross-sections, or a published
continuum fit, by the method documented in the emitted file. Nothing in it was chosen to make an
output look right.
"""
import numpy as np

C2 = 1.4387768775039337      # h c / k, cm K (CODATA)
N_A = 6.02214076e23
P_REF = 1.0e4                # Pa, 100 mb
T_REF = 260.0                # K
HITRAN_P = 1.013e5
HITRAN_T = 296.0
NUM_WIDTHS = 1000.0
SAMPLES = 3000
TEMPS = [150.0, 200.0, 260.0, 320.0, 400.0, 500.0, 650.0, 800.0, 1000.0]
T_SUN = 5772.0               # K, solar effective temperature (IAU 2015 nominal)

# Thermal IR at line-band resolution, then the solar near-IR, visible (Chappuis), Huggins and Hartley
# ranges up to 46000 cm^-1 (217 nm), past which the solar blackbody carries under 1e-3 of its power.
EDGES = np.concatenate([np.arange(0.0, 500.0, 50.0), np.arange(500.0, 900.0, 10.0),
                        np.arange(900.0, 1500.0, 25.0), np.arange(1500.0, 2500.0, 50.0),
                        np.arange(2500.0, 10000.0, 500.0),
                        np.arange(10000.0, 14000.0, 500.0), np.arange(14000.0, 26000.0, 1000.0),
                        np.arange(26000.0, 34000.0, 500.0), np.arange(34000.0, 46001.0, 1000.0)])

O3_M_GMOL = 47.98474


def load(path, m_gmol, q_exp):
    rows = np.loadtxt(path, delimiter=',', usecols=(2, 3, 4, 5, 6))
    o = np.argsort(rows[:, 0])
    rows = rows[o]
    nu, sw, gair, nair, elow = rows[:, 0], rows[:, 1], rows[:, 2], rows[:, 3], rows[:, 4]
    s = 0.1 * (N_A / m_gmol) * sw
    return nu, s, gair, nair, elow, q_exp


def kappa_lines(data, grid, p, t):
    nu, s0, gair, nair, elow, q_exp = data
    gam = gair * (p / HITRAN_P) * (HITRAN_T / t) ** nair
    s = (s0 * (HITRAN_T / t) ** q_exp
         * np.exp(-C2 * elow * (1.0 / t - 1.0 / HITRAN_T))
         * (1.0 - np.exp(-C2 * nu / t)) / (1.0 - np.exp(-C2 * nu / HITRAN_T)))
    cut = NUM_WIDTHS * float(np.median(gam))
    out = np.zeros_like(grid)
    lo = int(np.searchsorted(nu, grid[0] - cut))
    hi = int(np.searchsorted(nu, grid[-1] + cut))
    for a in range(lo, hi, 4000):
        b = min(a + 4000, hi)
        dn = grid[None, :] - nu[a:b, None]
        g = gam[a:b, None]
        c = s[a:b, None] * g / (np.pi * (dn * dn + g * g))
        c[np.abs(dn) > NUM_WIDTHS * g] = 0.0
        out += c.sum(axis=0)
    return out


def co2_continuum(nu, t=300.0):
    """Pierrehumbert eq. 4.89 / 4.90 — kappa_CO2 continuum at 300 K, 100 mb, air-induced, m^2/kg."""
    k = np.zeros_like(nu)
    a = (nu >= 25.0) & (nu <= 450.0)
    x = nu[a]
    k[a] = np.exp(-8.853 + 0.028534 * x - 0.00043194 * x**2
                  + 1.4349e-6 * x**3 - 1.5539e-9 * x**4)
    b = (nu >= 1150.0) & (nu <= 1800.0)
    x = nu[b]
    k[b] = np.exp(-537.09 + 1.0886 * x - 0.0007566 * x**2
                  + 1.8863e-7 * x**3 - 8.2635e-12 * x**4)
    return k * (300.0 / t) ** 1.7


def h2o_continuum(nu, t=296.0):
    """Pierrehumbert eq. 4.91 / 4.92 — kappa_H2O SELF continuum at 296 K, 100 mb H2O, m^2/kg."""
    k = np.zeros_like(nu)
    a = (nu >= 500.0) & (nu <= 1400.0)
    x = nu[a]
    k[a] = np.exp(12.167 - 0.050898 * x + 8.3207e-5 * x**2
                  - 7.0748e-8 * x**3 + 2.3261e-11 * x**4)
    b = (nu >= 2100.0) & (nu <= 3000.0)
    x = nu[b] - 2500.0
    k[b] = np.exp(-6.0055 - 0.0021363 * x + 6.4723e-7 * x**2 - 1.493e-8 * x**3
                  + 2.5621e-11 * x**4 + 7.328e-14 * x**5)
    return k * (296.0 / t) ** 4.25


def load_cia(path):
    """HITRAN CIA file -> list of (numin, numax, T, nu[], k[]) blocks. k is cm^5/molecule^2."""
    blocks = []
    with open(path) as f:
        lines = f.read().splitlines()
    i = 0
    while i < len(lines):
        h = lines[i].split()
        if len(h) < 5 or not h[0].startswith("CO2-CO2"):
            i += 1
            continue
        numin, numax, npts, temp = float(h[1]), float(h[2]), int(h[3]), float(h[4])
        nu = np.empty(npts); kk = np.empty(npts)
        for j in range(npts):
            a, b = lines[i + 1 + j].split()[:2]
            nu[j] = float(a); kk[j] = float(b)
        blocks.append((numin, numax, temp, nu, np.maximum(kk, 0.0)))
        i += 1 + npts
    return blocks


# HITRAN CIA k [cm^5/molecule^2] -> mass absorption coefficient [m^2/kg] at the REFERENCE CO2 partial
# pressure. tau = k * n^2 * L with n the number density; dividing by the mass path u = rho*L and
# substituting n = rho*N_A/M gives kappa = 1e-4 * k * rho * (N_A/M)^2, so it is linear in the CO2
# partial density and therefore scales with the CO2 partial pressure, not the total.
def cia_kappa(blocks, grid, t):
    out = np.zeros_like(grid)
    lo, hi = grid[0], grid[-1]
    regions = {}
    for numin, numax, temp, nu, kk in blocks:
        if numax < lo or numin > hi:
            continue
        regions.setdefault((round(numin), round(numax)), []).append((temp, nu, kk))
    for _key, entries in regions.items():
        entries.sort(key=lambda e: e[0])
        temps = [e[0] for e in entries]
        if t <= temps[0]:
            pick = [(entries[0], 1.0)]
        elif t >= temps[-1]:
            pick = [(entries[-1], 1.0)]
        else:
            i = int(np.searchsorted(temps, t)) - 1
            f = (t - temps[i]) / (temps[i + 1] - temps[i])
            pick = [(entries[i], 1.0 - f), (entries[i + 1], f)]
        for (temp, nu, kk), w in pick:
            out += w * np.interp(grid, nu, kk, left=0.0, right=0.0)
    rho_ref = P_REF * (44.0095e-3) / (8.314462618 * t)
    return out * 1.0e-4 * rho_ref * (N_A / 44.0095) ** 2


def load_o3_uv(path):
    """Serdyuchenko/Gorshelev O3 electronic cross-sections (AMT 7:625 / 7:609): vacuum wavelength nm,
    then 11 columns of cm^2/molecule at 293..193 K descending."""
    rows = np.loadtxt(path, skiprows=45)
    nu = 1.0e7 / rows[:, 0]
    temps = np.arange(293.0, 192.0, -10.0)
    o = np.argsort(nu)
    return nu[o], rows[o, 1:], temps


def o3_uv_kappa(uv, grid, t):
    """m^2/kg on `grid`, interpolated in temperature and held flat outside the measured 193-293 K."""
    nu, xs, temps = uv
    order = np.argsort(temps)
    ts = temps[order]
    tt = min(max(t, ts[0]), ts[-1])
    i = int(np.searchsorted(ts, tt))
    if i <= 0:
        pick = [(order[0], 1.0)]
    elif i >= len(ts):
        pick = [(order[-1], 1.0)]
    else:
        f = (tt - ts[i - 1]) / (ts[i] - ts[i - 1])
        pick = [(order[i - 1], 1.0 - f), (order[i], f)]
    sig = np.zeros_like(grid)
    for col, w in pick:
        sig += w * np.interp(grid, nu, xs[:, col], left=0.0, right=0.0)
    return sig * 1.0e-4 * N_A / (O3_M_GMOL * 1.0e-3)


def planck_above(x):
    """Fraction of blackbody power emitted above dimensionless frequency x = c2*nu/T.
    Siegel & Howell series; G(0) = 1."""
    x = np.atleast_1d(np.asarray(x, dtype=float))
    out = np.zeros_like(x)
    for n in range(1, 40):
        out += np.exp(-n * x) * (x**3 / n + 3 * x**2 / n**2 + 6 * x / n**3 + 6 / n**4)
    return (15.0 / np.pi**4) * out


def band_table(data, cont, t, cia=None):
    line, con, sci = [], [], []
    for i in range(len(EDGES) - 1):
        grid = np.linspace(EDGES[i], EDGES[i + 1], SAMPLES, endpoint=False)
        line.append(float(np.median(kappa_lines(data, grid, P_REF, t))))
        con.append(float(np.median(cont(grid, t))))
        sci.append(float(np.mean(cia_kappa(cia, grid, t))) if cia is not None else 0.0)
    return np.array(line), np.array(con), np.array(sci)


def no_continuum(nu, t=0.0):
    return np.zeros_like(nu)


# The minor greenhouse gases, line absorption only. H2 carries no column: its dipole-forbidden lines are
# orders weaker, and its real channel — H2-N2/H2-H2 collision-induced absorption — only matters at H2
# mole fractions of order 0.1 (Wordsworth & Pierrehumbert 2013, Science 339:64), 100x the outgassed 1e-3.
# q_exp is the rotational partition exponent: 1.0 linear, 1.5 nonlinear (Pierrehumbert ch. 4).
MINOR = [("ch4", "ch4_lines.csv", 16.04276, 1.5), ("co", "co_lines.csv", 28.0104, 1.0),
         ("so2", "so2_lines.csv", 64.0588, 1.5), ("h2s", "h2s_lines.csv", 34.07588, 1.5)]

if __name__ == "__main__":
    co2 = load("co2_lines.csv", 44.0095, 1.0)
    h2o = load("h2o_lines.csv", 18.01528, 1.5)
    o3 = load("o3_lines.csv", O3_M_GMOL, 1.5)
    print("CO2 lines", len(co2[0]), " H2O lines", len(h2o[0]), " O3 lines", len(o3[0]))
    minor = {name: load(path, m, q) for name, path, m, q in MINOR}
    for name, _p, _m, _q in MINOR:
        print("%s lines %d" % (name.upper(), len(minor[name][0])))
    cia = load_cia("CO2-CO2_2024.cia")
    uv = load_o3_uv("o3_uv_serdyuchenko.dat")
    print("CO2-CO2 CIA blocks", len(cia), " O3 UV points", len(uv[0]))
    kc = []; cc = []; ci = []; kw = []; cw = []; ko = []; xo = []
    km = {name: [] for name, _p, _m, _q in MINOR}
    for t in TEMPS:
        a, b, g = band_table(co2, co2_continuum, t, cia)
        c, e, _z = band_table(h2o, h2o_continuum, t)
        kc.append(a); cc.append(b); ci.append(g); kw.append(c); cw.append(e)
        for name, _p, _m, _q in MINOR:
            km[name].append(band_table(minor[name], no_continuum, t)[0])
        line_o3 = []; xsc_o3 = []
        for i in range(len(EDGES) - 1):
            grid = np.linspace(EDGES[i], EDGES[i + 1], SAMPLES, endpoint=False)
            line_o3.append(float(np.median(kappa_lines(o3, grid, P_REF, t))))
            xsc_o3.append(float(np.mean(o3_uv_kappa(uv, grid, t))))
        ko.append(np.array(line_o3)); xo.append(np.array(xsc_o3))
        print("  T = %.0f K done" % t)
    kc = np.array(kc); cc = np.array(cc); ci = np.array(ci)
    kw = np.array(kw); cw = np.array(cw); ko = np.array(ko); xo = np.array(xo)
    wsun = planck_above(C2 * EDGES[:-1] / T_SUN) - planck_above(C2 * EDGES[1:] / T_SUN)
    np.savez("bands.npz", edges=EDGES, temps=np.array(TEMPS), co2_line=kc, co2_cont=cc,
             co2_cia=ci, h2o_line=kw, h2o_cont=cw, o3_line=ko, o3_xsc=xo, w_sun=wsun,
             ch4_line=np.array(km["ch4"]), co_line=np.array(km["co"]),
             so2_line=np.array(km["so2"]), h2s_line=np.array(km["h2s"]))
    print(f"solar fraction below {EDGES[-1]:.0f} cm^-1: {wsun.sum():.4f}")
    print(f"{'band':>12} {'CO2 line':>11} {'CO2 cont':>11} {'CO2 cia':>11} {'H2O line':>11} {'H2O cont':>11} {'O3 line':>11} {'O3 xsc':>11} {'w_sun':>9}")
    ti = TEMPS.index(260.0)
    for i in range(kc.shape[1]):
        print(f"{EDGES[i]:5.0f}-{EDGES[i+1]:5.0f} {kc[ti][i]:11.4e} {cc[ti][i]:11.4e} "
              f"{ci[ti][i]:11.4e} {kw[ti][i]:11.4e} {cw[ti][i]:11.4e} {ko[ti][i]:11.4e} "
              f"{xo[ti][i]:11.4e} {wsun[i]:9.5f}")

    # --- validation against Pierrehumbert's own quantitative statements -----------------------------
    # Table 4.1 pressure-weighted equivalent paths (100 mb reference, cos(theta)=1/2):
    #   modern Earth 47 kg/m2, early Earth (10% CO2) 15000, early Mars (2 bar pure CO2) 1e6.
    # Text: modern Earth/Mars tau > 1 over roughly 610-750 cm^-1; early Earth 520-830; early Mars
    # nearly opaque 500-1100.
    for name, path, lo, hi in [("modern Earth", 47.0, 610, 750),
                               ("early Earth", 15000.0, 520, 830),
                               ("early Mars", 1.0e6, 500, 1100)]:
        tau = (kc[ti] + cc[ti]) * path
        thick = [(EDGES[i], EDGES[i + 1]) for i in range(len(tau)) if tau[i] > 1.0]
        if thick:
            print(f"  {name:14s} path {path:9.0f}: CO2 tau>1 over "
                  f"{min(t[0] for t in thick):.0f}-{max(t[1] for t in thick):.0f} cm^-1 "
                  f"(book says {lo}-{hi})")

# --- emitter -----------------------------------------------------------------------------------------
import sys

d = np.load("bands.npz")
edges = d["edges"]
temps = d["temps"]
nb = len(edges) - 1
nt = len(temps)


def rows(a, per=8, fmt="%.5e"):
    a = np.asarray(a).reshape(-1)
    return "\n".join("\t" + ", ".join(fmt % v for v in a[i:i + per]) + ","
                     for i in range(0, len(a), per))


TPL = '''// GENERATED by scripts/derive_absorption_bands.py -- edit the generator, never this file.
#include "LAAbsorptionBands.hpp"

#include <godot_cpp/classes/resource_loader.hpp>
#include <godot_cpp/classes/script.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/error_macros.hpp>
#include <godot_cpp/core/math.hpp>
#include <godot_cpp/variant/dictionary.hpp>

#include <algorithm>
#include <cmath>

using namespace godot;

namespace {

// Band edges, cm^-1, on a %d-band wavenumber grid from 0 to 46000 cm^-1. BAND_COUNT + 1 entries.
const double EDGES_CM1[] = {
%s
};

// Temperatures the %d coefficient slices are computed at, K.
const double TEMPS_K[] = {
%s
};

// Flat arrays, indexed t * BAND_COUNT + b. N2, O2, Ar absent: no dipole, no thermal-IR absorption.
// CO2 line absorption, m^2/kg: HITRAN lbl isotopologues 7-12, reduced per Pierrehumbert ch. 4 (Lorentz,
// air-broadened, per-band MEDIAN of 3000 samples). Scales with total pressure against
// LAPhysical.ABSORPTION_REF_PRESSURE_PA.
const double CO2_LINE[] = {
%s
};

// CO2 air-induced continuum, m^2/kg, his eqs 4.89/4.90. Scales with total pressure.
const double CO2_CONT[] = {
%s
};

// CO2-CO2 collision-induced absorption, m^2/kg: HITRAN CO2-CO2_2024 (Karman et al. 2019, Icarus
// 328:160). A two-body process, so it scales with the CO2 partial pressure.
const double CO2_CIA[] = {
%s
};

// H2O line absorption, m^2/kg: HITRAN lbl isotopologues 1-4, same reduction. Scales with total pressure.
const double H2O_LINE[] = {
%s
};

// H2O self-induced continuum, m^2/kg, his eqs 4.91/4.92. Scales with the water partial pressure.
const double H2O_CONT[] = {
%s
};

// O3 line absorption, m^2/kg: HITRAN lbl isotopologues 16-20, same reduction. Scales with total pressure.
const double O3_LINE[] = {
%s
};

// O3 electronic cross-sections, m^2/kg, 213-1100 nm (Hartley, Huggins, Chappuis, Wulf bands):
// Serdyuchenko et al. 2014, AMT 7:625; Gorshelev et al. 2014, AMT 7:609. Pressure-independent,
// temperature-interpolated over 193-293 K, held flat outside.
const double O3_XSC[] = {
%s
};

// The minor greenhouse gases, HITRAN lbl, same reduction; all scale with total pressure. H2 is absent:
// no dipole, and its collision-induced channel only matters at H2 mole fractions of order 0.1
// (Wordsworth & Pierrehumbert 2013, Science 339:64).
const double CH4_LINE[] = {
%s
};

const double CO_LINE[] = {
%s
};

const double SO2_LINE[] = {
%s
};

const double H2S_LINE[] = {
%s
};

constexpr size_t NB = size_t(LAAbsorptionBands::BAND_COUNT);
constexpr size_t NT = size_t(LAAbsorptionBands::TEMP_COUNT);
static_assert(sizeof(EDGES_CM1) / sizeof(double) == NB + 1, "edges disagree with LAAbsorptionBands.hpp");
static_assert(sizeof(TEMPS_K) / sizeof(double) == NT, "temps disagree with LAAbsorptionBands.hpp");
static_assert(sizeof(CO2_LINE) / sizeof(double) == NB * NT, "CO2_LINE disagrees with LAAbsorptionBands.hpp");
static_assert(sizeof(CO2_CONT) / sizeof(double) == NB * NT, "CO2_CONT disagrees with LAAbsorptionBands.hpp");
static_assert(sizeof(CO2_CIA) / sizeof(double) == NB * NT, "CO2_CIA disagrees with LAAbsorptionBands.hpp");
static_assert(sizeof(H2O_LINE) / sizeof(double) == NB * NT, "H2O_LINE disagrees with LAAbsorptionBands.hpp");
static_assert(sizeof(H2O_CONT) / sizeof(double) == NB * NT, "H2O_CONT disagrees with LAAbsorptionBands.hpp");
static_assert(sizeof(O3_LINE) / sizeof(double) == NB * NT, "O3_LINE disagrees with LAAbsorptionBands.hpp");
static_assert(sizeof(O3_XSC) / sizeof(double) == NB * NT, "O3_XSC disagrees with LAAbsorptionBands.hpp");
static_assert(sizeof(CH4_LINE) / sizeof(double) == NB * NT, "CH4_LINE disagrees with LAAbsorptionBands.hpp");
static_assert(sizeof(CO_LINE) / sizeof(double) == NB * NT, "CO_LINE disagrees with LAAbsorptionBands.hpp");
static_assert(sizeof(SO2_LINE) / sizeof(double) == NB * NT, "SO2_LINE disagrees with LAAbsorptionBands.hpp");
static_assert(sizeof(H2S_LINE) / sizeof(double) == NB * NT, "H2S_LINE disagrees with LAAbsorptionBands.hpp");

// Fraction of blackbody power emitted above dimensionless frequency x = c2*nu/T. Siegel & Howell
// series; planck_above(0) == 1.
double planck_above(double x) {
	if (x <= 0.0) {
		return 1.0;
	}
	if (x > 60.0) {
		return 0.0;
	}
	double sum = 0.0;
	for (int n = 1; n < 40; n++) {
		const double fn = double(n);
		sum += std::exp(-fn * x) * (x * x * x / fn + 3.0 * x * x / (fn * fn)
				+ 6.0 * x / (fn * fn * fn) + 6.0 / (fn * fn * fn * fn));
	}
	constexpr double kPi = 3.14159265358979323846;
	return 15.0 / std::pow(kPi, 4.0) * sum;
}

// PhysicalConstants.gd stays the one declaration of every physical constant; this reads it, never copies it.
double la_physical(const char *p_name) {
	const Ref<Script> pc = ResourceLoader::get_singleton()->load(
			"res://addons/local_agents/sim/material/PhysicalConstants.gd");
	ERR_FAIL_COND_V_MSG(pc.is_null(), NAN, "LAAbsorptionBands: PhysicalConstants.gd failed to load.");
	const Dictionary constants = pc->get_script_constant_map();
	ERR_FAIL_COND_V_MSG(!constants.has(p_name), NAN,
			String("LAAbsorptionBands: LAPhysical carries no ") + p_name + ".");
	return double(constants[p_name]);
}

} // namespace

PackedFloat32Array LAAbsorptionBands::packed() {
	static PackedFloat32Array cached;
	if (!cached.is_empty()) {
		return cached;
	}
	// Sun as a blackbody at its effective temperature (IAU 2015 nominal), for the solar band weights.
	const double solar_t_k = la_physical("SOLAR_EFFECTIVE_TEMPERATURE_K");
	const double c2 = la_physical("PLANCK_C2_CM_K");
	ERR_FAIL_COND_V(std::isnan(solar_t_k) || std::isnan(c2), PackedFloat32Array());
	PackedFloat32Array out;
	out.resize(4 + (BAND_COUNT + 1) + TEMP_COUNT + BAND_COUNT + TEMP_COUNT * BAND_COUNT * 11 + CDF_COUNT);
	float *w = out.ptrw();
	w[0] = float(BAND_COUNT);
	w[1] = float(CDF_COUNT);
	w[2] = CDF_XMAX;
	w[3] = float(TEMP_COUNT);
	int o = 4;
	for (int i = 0; i < BAND_COUNT + 1; i++) {
		w[o + i] = float(EDGES_CM1[i]);
	}
	o += BAND_COUNT + 1;
	for (int i = 0; i < TEMP_COUNT; i++) {
		w[o + i] = float(TEMPS_K[i]);
	}
	o += TEMP_COUNT;
	// Share of the solar constant per band, derived from the solar blackbody rather than tabulated; the
	// outermost band keeps everything above its lower edge, so the weights sum to 1.
	for (int b = 0; b < BAND_COUNT; b++) {
		const double lo = planck_above(c2 * double(float(EDGES_CM1[b])) / solar_t_k);
		const double hi = (b < BAND_COUNT - 1)
				? planck_above(c2 * double(float(EDGES_CM1[b + 1])) / solar_t_k)
				: 0.0;
		w[o + b] = float(std::max(lo - hi, 0.0));
	}
	o += BAND_COUNT;
	for (int t = 0; t < TEMP_COUNT; t++) {
		for (int b = 0; b < BAND_COUNT; b++) {
			const int i = t * BAND_COUNT + b;
			const int k = o + i * 11;
			w[k + 0] = float(CO2_LINE[i]);
			w[k + 1] = float(CO2_CONT[i]);
			w[k + 2] = float(CO2_CIA[i]);
			w[k + 3] = float(H2O_LINE[i]);
			w[k + 4] = float(H2O_CONT[i]);
			w[k + 5] = float(O3_LINE[i]);
			w[k + 6] = float(O3_XSC[i]);
			w[k + 7] = float(CH4_LINE[i]);
			w[k + 8] = float(CO_LINE[i]);
			w[k + 9] = float(SO2_LINE[i]);
			w[k + 10] = float(H2S_LINE[i]);
		}
	}
	o += TEMP_COUNT * BAND_COUNT * 11;
	// Planck cumulative table handed to the GPU: G(x) for x = c2*nu/T over [0, CDF_XMAX].
	for (int i = 0; i < CDF_COUNT; i++) {
		w[o + i] = float(planck_above(double(CDF_XMAX) * double(i) / double(CDF_COUNT - 1)));
	}
	cached = out;
	return cached;
}

void LAAbsorptionBands::_bind_methods() {
	ClassDB::bind_static_method("LAAbsorptionBands", D_METHOD("packed"), &LAAbsorptionBands::packed);
	BIND_CONSTANT(BAND_COUNT);
	BIND_CONSTANT(TEMP_COUNT);
	BIND_CONSTANT(CDF_COUNT);
}
'''

txt = TPL % (nb, rows(edges, 10, "%.1f"),
             nt, rows(temps, 10, "%.1f"),
             rows(d["co2_line"], 20), rows(d["co2_cont"], 20), rows(d["co2_cia"], 20),
             rows(d["h2o_line"], 20), rows(d["h2o_cont"], 20),
             rows(d["o3_line"], 20), rows(d["o3_xsc"], 20),
             rows(d["ch4_line"], 20), rows(d["co_line"], 20),
             rows(d["so2_line"], 20), rows(d["h2s_line"], 20))
open(sys.argv[1], "w").write(txt)
print("wrote", sys.argv[1], nb, "bands", nt, "temps", len(txt.splitlines()), "lines")
