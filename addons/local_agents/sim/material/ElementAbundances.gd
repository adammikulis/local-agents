class_name LAElementAbundances
extends RefCounted

## Elemental composition of the planet's reservoirs, kg of element per kg of reservoir.
## McDonough 2003, Treatise on Geochemistry 2.15 (Tables 1-4); silicate Earth cross-checked against
## McDonough & Sun 1995, Chem. Geol. 120:223, Table 5. The seed and the composition gate read this file.

const PC = preload("res://addons/local_agents/sim/material/PhysicalConstants.gd")

## Core / Earth mass (McDonough 2003, Table 1).
const CORE_MASS_FRACTION: float = PC.EARTH_CORE_MASS_FRACTION

## Bulk Earth (McDonough 2003, Table 3).
const BULK_EARTH: Dictionary = {
	"Fe": 0.320, "O": 0.297, "Si": 0.161, "Mg": 0.154, "Ni": 0.0182, "Ca": 0.0171, "Al": 0.0159,
	"S": 6.35e-3, "Cr": 4.70e-3, "Na": 1.80e-3, "Co": 880e-6, "Ti": 810e-6, "Mn": 800e-6,
	"P": 715e-6, "C": 730e-6, "H": 260e-6, "K": 160e-6, "V": 105e-6, "Cl": 76e-6, "N": 25e-6,
	"Sc": 10.9e-6, "F": 10e-6, "Cu": 60e-6, "Zn": 40e-6, "Ge": 7e-6, "Mo": 1.7e-6, "Li": 1.1e-6,
	"Sn": 0.25e-6, "W": 0.17e-6, "Au": 0.16e-6, "Pb": 0.23e-6, "Ag": 50e-9, "Sb": 0.05e-6,
	"Te": 0.3e-6, "Pt": 1.9e-6, "Os": 0.9e-6, "Ir": 0.9e-6, "Ru": 1.3e-6, "Rh": 0.24e-6,
	"Pd": 1.0e-6, "Re": 0.075e-6, "U": 15e-9, "Th": 55e-9,
	"La": 0.44e-6, "Ce": 1.13e-6, "Pr": 0.17e-6, "Nd": 0.84e-6, "Sm": 0.27e-6, "Eu": 0.10e-6,
	"Gd": 0.37e-6, "Tb": 0.067e-6, "Dy": 0.46e-6, "Ho": 0.10e-6, "Er": 0.30e-6, "Tm": 0.046e-6,
	"Yb": 0.30e-6, "Lu": 0.046e-6,
}

## Silicate Earth / pyrolite (McDonough & Sun 1995, Table 5; F per McDonough 2003, Table 2).
const SILICATE_EARTH: Dictionary = {
	"O": 0.44, "Mg": 0.228, "Si": 0.210, "Fe": 0.0626, "Ca": 0.0253, "Al": 0.0235, "Na": 2.67e-3,
	"Cr": 2.625e-3, "Ni": 1.96e-3, "Mn": 1.045e-3, "Ti": 1.205e-3, "K": 240e-6, "S": 250e-6,
	"P": 90e-6, "C": 120e-6, "H": 100e-6, "Co": 105e-6, "V": 82e-6, "Cl": 17e-6, "F": 15e-6,
	"Sc": 16.2e-6, "N": 2e-6, "Cu": 30e-6, "Zn": 55e-6, "Ge": 1.1e-6, "Li": 1.6e-6,
	"Mo": 50e-9, "Ag": 8e-9, "Sn": 130e-9, "Sb": 5.5e-9, "Te": 12e-9, "W": 29e-9, "Au": 1.0e-9,
	"Pb": 150e-9, "Pt": 7.1e-9, "Os": 3.4e-9, "Ir": 3.2e-9, "Ru": 5.0e-9, "Rh": 0.9e-9,
	"Pd": 3.9e-9, "Re": 0.28e-9, "U": 20.3e-9, "Th": 79.5e-9,
	"La": 0.648e-6, "Ce": 1.675e-6, "Pr": 0.254e-6, "Nd": 1.250e-6, "Sm": 0.406e-6,
	"Eu": 0.154e-6, "Gd": 0.544e-6, "Tb": 0.099e-6, "Dy": 0.674e-6, "Ho": 0.149e-6,
	"Er": 0.438e-6, "Tm": 0.068e-6, "Yb": 0.441e-6, "Lu": 0.0675e-6,
}

## Core (McDonough 2003, Table 4). Devoid of U, Th and K.
const CORE: Dictionary = {
	"Fe": 0.855, "Ni": 0.052, "Si": 0.060, "S": 0.019, "Cr": 9.0e-3, "Co": 2.5e-3, "P": 2.0e-3,
	"C": 2.0e-3, "H": 600e-6, "Mn": 300e-6, "Cl": 200e-6, "V": 150e-6, "Cu": 125e-6, "N": 75e-6,
	"Ge": 20e-6, "Mo": 5e-6, "Ru": 4e-6, "Pd": 3.1e-6, "Os": 2.8e-6, "Ir": 2.6e-6, "Pt": 5.7e-6,
	"Rh": 0.74e-6, "Te": 0.85e-6, "Sn": 0.5e-6, "Au": 0.5e-6, "W": 0.47e-6, "Pb": 0.4e-6,
	"Re": 0.23e-6, "Ag": 0.15e-6, "Sb": 0.13e-6,
}

## Elements the shell's mineral formulas carry; everything else in SILICATE_EARTH rides as a trace.
const SHELL_FORMULA_ELEMENTS: PackedStringArray = ["O", "Mg", "Si", "Fe", "Ca", "Al", "Na", "P",
	"Cl", "F"]

## Elements the core metal's formula carries.
const CORE_FORMULA_ELEMENTS: PackedStringArray = ["Fe", "Ni", "S", "Si"]

## kg/mol per element symbol, for the formula elements. IUPAC 2021, via LAPhysical.
const ATOMIC_MASS_KG_MOL: Dictionary = {
	"H": PC.MOLAR_MASS_HYDROGEN_KG_MOL, "C": PC.MOLAR_MASS_CARBON_KG_MOL,
	"N": PC.MOLAR_MASS_NITROGEN_KG_MOL, "O": PC.MOLAR_MASS_OXYGEN_KG_MOL,
	"F": PC.MOLAR_MASS_F_KG_MOL, "Na": PC.MOLAR_MASS_NA_KG_MOL, "Mg": PC.MOLAR_MASS_MG_KG_MOL,
	"Al": PC.MOLAR_MASS_AL_KG_MOL, "Si": PC.MOLAR_MASS_SI_KG_MOL, "P": PC.MOLAR_MASS_P_KG_MOL,
	"S": PC.MOLAR_MASS_S_KG_MOL, "Cl": PC.MOLAR_MASS_CL_KG_MOL, "K": PC.MOLAR_MASS_K_KG_MOL,
	"Ca": PC.MOLAR_MASS_CA_KG_MOL, "Fe": PC.MOLAR_MASS_FE_KG_MOL, "Ni": PC.MOLAR_MASS_NI_KG_MOL,
}


static func atomic_mass(el: String) -> float:
	var v: float = float(ATOMIC_MASS_KG_MOL.get(el, 0.0))
	if v <= 0.0:
		push_error("LAElementAbundances.atomic_mass(\"%s\"): no atomic mass declared." % el)
	return v


## kg one mole of `formula` weighs.
static func molar_mass(formula: Dictionary) -> float:
	var m: float = 0.0
	for el in formula:
		m += float(formula[el]) * atomic_mass(String(el))
	return m


## Mass fraction of each element in one mole of `formula`.
static func mass_fractions(formula: Dictionary) -> Dictionary:
	var m: float = molar_mass(formula)
	var out: Dictionary = {}
	if m <= 0.0:
		return out
	for el in formula:
		out[el] = float(formula[el]) * atomic_mass(String(el)) / m
	return out


## The reservoir's elements NOT carried by a mineral formula: what each shell mineral hosts as a trace,
## kg of element per kg of mineral, so the shell bulk reads the registry whatever the mineral mix is.
static func shell_traces() -> Dictionary:
	return _traces_of(SILICATE_EARTH, SHELL_FORMULA_ELEMENTS)


static func core_traces() -> Dictionary:
	return _traces_of(CORE, CORE_FORMULA_ELEMENTS)


static func _traces_of(reservoir: Dictionary, formula_elements: PackedStringArray) -> Dictionary:
	var out: Dictionary = {}
	for el in reservoir:
		if not formula_elements.has(String(el)):
			out[el] = float(reservoir[el])
	return out
