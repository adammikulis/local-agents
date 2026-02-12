extends Resource
class_name LocalAgentsMammalProfileResource

@export var schema_version: int = 1
@export var profile_id: String = "mammal_default"
@export var can_smell: bool = true
@export var smell_acuity: float = 1.0
@export var food_smell_radius_cells: int = 8
@export var danger_smell_radius_cells: int = 4
@export var danger_threshold: float = 0.14

@export var chem_hexanal: float = 0.0
@export var chem_cis_3_hexenol: float = 0.0
@export var chem_linalool: float = 0.0
@export var chem_methyl_salicylate: float = 0.0
@export var chem_benzyl_acetate: float = 0.0
@export var chem_phenylacetaldehyde: float = 0.0
@export var chem_geraniol: float = 0.0
@export var chem_sugars: float = 0.0
@export var chem_tannins: float = 0.0
@export var chem_alkaloids: float = 0.0
@export var chem_ammonia: float = 0.0
@export var chem_butyric_acid: float = 0.0
@export var chem_2_heptanone: float = 0.0

func as_weights(negative_tannins: bool = false, negative_alkaloids: bool = false) -> Dictionary:
	var t = chem_tannins
	var a = chem_alkaloids
	if negative_tannins:
		t = -absf(t)
	if negative_alkaloids:
		a = -absf(a)
	var acuity := maxf(0.0, smell_acuity)
	return {
		"hexanal": chem_hexanal * acuity,
		"cis_3_hexenol": chem_cis_3_hexenol * acuity,
		"linalool": chem_linalool * acuity,
		"methyl_salicylate": chem_methyl_salicylate * acuity,
		"benzyl_acetate": chem_benzyl_acetate * acuity,
		"phenylacetaldehyde": chem_phenylacetaldehyde * acuity,
		"geraniol": chem_geraniol * acuity,
		"sugars": chem_sugars * acuity,
		"tannins": t * acuity,
		"alkaloids": a * acuity,
		"ammonia": chem_ammonia * acuity,
		"butyric_acid": chem_butyric_acid * acuity,
		"2_heptanone": chem_2_heptanone * acuity,
	}
