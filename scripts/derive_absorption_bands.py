#!/usr/bin/env python3
"""Regenerate addons/local_agents/sim/material/AbsorptionBands.gd from HITRAN.

Usage, from the repo root:
    scripts/fetch_hitran.sh                          # writes co2_lines.csv / h2o_lines.csv / CO2-CO2_2024.cia
    python3 scripts/derive_absorption_bands.py addons/local_agents/sim/material/AbsorptionBands.gd

Needs numpy. The band table is DATA, not a modelling choice: every number here comes out of HITRAN
line parameters, HITRAN CIA cross-sections, or a published continuum fit, by the method documented in
the emitted file. Nothing in it was chosen to make an output look right.
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

EDGES = np.concatenate([np.arange(0.0, 500.0, 50.0), np.arange(500.0, 900.0, 10.0),
                        np.arange(900.0, 1500.0, 25.0), np.arange(1500.0, 2500.0, 50.0),
                        np.arange(2500.0, 10001.0, 500.0)])


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


if __name__ == "__main__":
    co2 = load("co2_lines.csv", 44.0095, 1.0)
    h2o = load("h2o_lines.csv", 18.01528, 1.5)
    print("CO2 lines", len(co2[0]), " H2O lines", len(h2o[0]))
    cia = load_cia("CO2-CO2_2024.cia")
    print("CO2-CO2 CIA blocks", len(cia))
    kc = []; cc = []; ci = []; kw = []; cw = []
    for t in TEMPS:
        a, b, g = band_table(co2, co2_continuum, t, cia)
        c, e, _z = band_table(h2o, h2o_continuum, t)
        kc.append(a); cc.append(b); ci.append(g); kw.append(c); cw.append(e)
        print("  T = %.0f K done" % t)
    kc = np.array(kc); cc = np.array(cc); ci = np.array(ci)
    kw = np.array(kw); cw = np.array(cw)
    wsun = planck_above(C2 * EDGES[:-1] / T_SUN) - planck_above(C2 * EDGES[1:] / T_SUN)
    np.savez("bands.npz", edges=EDGES, temps=np.array(TEMPS), co2_line=kc, co2_cont=cc,
             co2_cia=ci, h2o_line=kw, h2o_cont=cw, w_sun=wsun)
    print(f"solar fraction below 10000 cm^-1: {wsun.sum():.4f}")
    print(f"{'band':>12} {'CO2 line':>11} {'CO2 cont':>11} {'CO2 cia':>11} {'H2O line':>11} {'H2O cont':>11} {'w_sun':>9}")
    ti = TEMPS.index(260.0)
    for i in range(kc.shape[1]):
        print(f"{EDGES[i]:5.0f}-{EDGES[i+1]:5.0f} {kc[ti][i]:11.4e} {cc[ti][i]:11.4e} "
              f"{ci[ti][i]:11.4e} {kw[ti][i]:11.4e} {cw[ti][i]:11.4e} {wsun[i]:9.5f}")

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


TPL = '''class_name LAAbsorptionBands
extends RefCounted

## Band-averaged mass absorption coefficients for the two absorbing gases this substrate carries, m^2/kg,
## on a %d-band wavenumber grid from 0 to 10000 cm^-1 and %d temperature slices.
##
## PROVENANCE. Lines: HITRAN (hitran.org line-by-line API, isotopologues 7-12 for CO2 and 1-4 for H2O),
## reduced by the method of Pierrehumbert, Principles of Planetary Climate chapter 4 and its PyTran
## courseware — Lorentz line shape, air-broadened half width gamma_air*(p/1.013e5)*(296/T)^n_air, line
## strength scaled by the partition-function ratio, the lower-state Boltzmann factor and the
## stimulated-emission factor, wings cut at 1000 line widths. The per-band statistic is the MEDIAN of
## kappa over 3000 samples, his choice (figure 4.17), because band-averaged transmission is set by the
## optically thin frequencies between the lines.
##
## Continua, three separate ones because they scale with three different pressures:
##   CO2_CONT  air-induced, his equations 4.89 (25-450 cm^-1) and 4.90 (1150-1800), quoted at 300 K and
##             100 mb, with his (300/T)^1.7 temperature law. Scales with TOTAL pressure.
##   CO2_CIA   CO2-CO2 collision-induced absorption, HITRAN CIA CO2-CO2_2024 (Karman et al. 2019,
##             Icarus 328:160), converted by kappa = 1e-4 * k * rho_CO2 * (N_A/M)^2 from k in
##             cm^5/molecule^2. Scales with the CO2 PARTIAL pressure, being a two-body process. This is
##             what makes a hundred-bar CO2 atmosphere opaque between its bands.
##   H2O_CONT  self-induced, his equations 4.91 (500-1400 cm^-1) and 4.92 (2100-3000), quoted at 296 K
##             and 100 mb of water vapour, with his (296/T)^4.25 law. Scales with the water partial
##             pressure.
##
## Reference pressure is Pierrehumbert's standard 100 mb, air-broadened. Lorentz broadening makes kappa
## proportional to the broadener's pressure, so a consumer scales each term by its own p/REF_PRESSURE_PA.
##
## N2, O2 and Ar are absent on purpose. Symmetric molecules acquire no dipole moment from rotation or
## stretching, so at planetary densities they do not absorb in the thermal infrared.
##
## VERIFIED against measurement in tests/test_radiative_transfer.gd: Earth clear-sky OLR, the radiative
## forcing of a CO2 doubling, and the CO2 share of Venus's greenhouse at 92 bar.

const REF_PRESSURE_PA: float = LAPhysical.ABSORPTION_REF_PRESSURE_PA
const BAND_COUNT: int = %d
const TEMP_COUNT: int = %d
## Sun as a blackbody at its effective temperature (IAU 2015 nominal), for the solar band weights.
const SOLAR_TEMPERATURE_K: float = LAPhysical.SOLAR_EFFECTIVE_TEMPERATURE_K
## Planck cumulative table handed to the GPU: G(x) for x = c2*nu/T over [0, CDF_XMAX].
const CDF_COUNT: int = 1024
const CDF_XMAX: float = 50.0

## Band edges, cm^-1. BAND_COUNT + 1 entries.
const EDGES_CM1: Array = [
%s
]

## Temperatures the coefficient slices are computed at, K.
const TEMPS_K: Array = [
%s
]

## Every coefficient array below is flat, indexed t * BAND_COUNT + b.

## CO2 line absorption, m^2/kg. Scales with total pressure.
const CO2_LINE: Array = [
%s
]

## CO2 air-induced continuum, m^2/kg. Scales with total pressure.
const CO2_CONT: Array = [
%s
]

## CO2-CO2 collision-induced absorption, m^2/kg. Scales with the CO2 partial pressure.
const CO2_CIA: Array = [
%s
]

## H2O line absorption, m^2/kg. Scales with total pressure.
const H2O_LINE: Array = [
%s
]

## H2O self-induced continuum, m^2/kg. Scales with the water partial pressure.
const H2O_CONT: Array = [
%s
]

static var _edges: PackedFloat32Array = PackedFloat32Array()
static var _solar: PackedFloat32Array = PackedFloat32Array()
static var _packed: PackedFloat32Array = PackedFloat32Array()


static func edges_cm1() -> PackedFloat32Array:
\tif _edges.is_empty():
\t\t_edges.resize(BAND_COUNT + 1)
\t\tfor i in BAND_COUNT + 1:
\t\t\t_edges[i] = float(EDGES_CM1[i])
\treturn _edges


## Temperature slice index and interpolation fraction for `t_k`, held flat outside the tabulated range.
## Returned as a Vector2 so a caller can hoist it out of its band loop.
static func slice_of(t_k: float) -> Vector2:
	if t_k <= float(TEMPS_K[0]):
		return Vector2(0.0, 0.0)
	if t_k >= float(TEMPS_K[TEMP_COUNT - 1]):
		return Vector2(float(TEMP_COUNT - 2), 1.0)
	var i: int = 0
	while i < TEMP_COUNT - 2 and t_k > float(TEMPS_K[i + 1]):
		i += 1
	var lo: float = float(TEMPS_K[i])
	return Vector2(float(i), (t_k - lo) / (float(TEMPS_K[i + 1]) - lo))


## Coefficient of band `b` at temperature `t_k`, linearly interpolated between slices and held flat
## outside them.
static func at(table: Array, b: int, t_k: float) -> float:
\tif t_k <= float(TEMPS_K[0]):
\t\treturn float(table[b])
\tif t_k >= float(TEMPS_K[TEMP_COUNT - 1]):
\t\treturn float(table[(TEMP_COUNT - 1) * BAND_COUNT + b])
\tvar i: int = 0
\twhile i < TEMP_COUNT - 2 and t_k > float(TEMPS_K[i + 1]):
\t\ti += 1
\tvar lo: float = float(TEMPS_K[i])
\tvar f: float = (t_k - lo) / (float(TEMPS_K[i + 1]) - lo)
\treturn lerpf(float(table[i * BAND_COUNT + b]), float(table[(i + 1) * BAND_COUNT + b]), f)


## Share of the solar constant in band `b`. Derived from the solar blackbody, not tabulated; the
## outermost band keeps everything above its lower edge, so the weights sum to 1.
static func solar_weight(b: int) -> float:
\tif _solar.is_empty():
\t\tvar e: PackedFloat32Array = edges_cm1()
\t\tvar c2: float = LAPhysical.PLANCK_C2_CM_K
\t\t_solar.resize(BAND_COUNT)
\t\tfor i in BAND_COUNT:
\t\t\tvar lo: float = LARadiativeColumn.planck_above(c2 * e[i] / SOLAR_TEMPERATURE_K)
\t\t\tvar hi: float = 0.0
\t\t\tif i < BAND_COUNT - 1:
\t\t\t\thi = LARadiativeColumn.planck_above(c2 * e[i + 1] / SOLAR_TEMPERATURE_K)
\t\t\t_solar[i] = maxf(lo - hi, 0.0)
\treturn _solar[b]


## The GPU upload. Header, band edges, temperature slices, solar weights, then five coefficients per
## (temperature, band), then the Planck cumulative table. heat3d_solar_sphere3d.glsl reads this layout.
static func packed() -> PackedFloat32Array:
\tif not _packed.is_empty():
\t\treturn _packed
\tvar e: PackedFloat32Array = edges_cm1()
\tvar out: PackedFloat32Array = PackedFloat32Array()
\tout.resize(4 + (BAND_COUNT + 1) + TEMP_COUNT + BAND_COUNT + TEMP_COUNT * BAND_COUNT * 5 + CDF_COUNT)
\tout[0] = float(BAND_COUNT)
\tout[1] = float(CDF_COUNT)
\tout[2] = CDF_XMAX
\tout[3] = float(TEMP_COUNT)
\tvar o: int = 4
\tfor i in BAND_COUNT + 1:
\t\tout[o + i] = e[i]
\to += BAND_COUNT + 1
\tfor i in TEMP_COUNT:
\t\tout[o + i] = float(TEMPS_K[i])
\to += TEMP_COUNT
\tfor b in BAND_COUNT:
\t\tout[o + b] = solar_weight(b)
\to += BAND_COUNT
\tfor t in TEMP_COUNT:
\t\tfor b in BAND_COUNT:
\t\t\tvar i: int = t * BAND_COUNT + b
\t\t\tvar k: int = o + i * 5
\t\t\tout[k + 0] = float(CO2_LINE[i])
\t\t\tout[k + 1] = float(CO2_CONT[i])
\t\t\tout[k + 2] = float(CO2_CIA[i])
\t\t\tout[k + 3] = float(H2O_LINE[i])
\t\t\tout[k + 4] = float(H2O_CONT[i])
\to += TEMP_COUNT * BAND_COUNT * 5
\tfor i in CDF_COUNT:
\t\tout[o + i] = LARadiativeColumn.planck_above(CDF_XMAX * float(i) / float(CDF_COUNT - 1))
\t_packed = out
\treturn _packed
'''

txt = TPL % (nb, nt, nb, nt,
             rows(edges, 10, "%.1f"),
             rows(temps, 10, "%.1f"),
             rows(d["co2_line"]), rows(d["co2_cont"]), rows(d["co2_cia"]),
             rows(d["h2o_line"]), rows(d["h2o_cont"]))
open(sys.argv[1], "w").write(txt)
print("wrote", sys.argv[1], nb, "bands", nt, "temps", len(txt.splitlines()), "lines")
