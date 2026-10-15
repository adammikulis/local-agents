@tool
class_name LAEventViewRecord
extends Resource

## One observed kind: the scene that draws it, the processes it needs, and what feeds it.

const Offers: GDScript = preload("res://addons/local_agents/game/ui/WorldOffers.gd")

## Where a kind's events come from.
enum Source {
	OBSERVED,   ## Polled: the list of this kind's name LAFieldPhenomena.observe() publishes.
	FIELD,      ## A signal of the material field.
	ARRIVAL,    ## A signal of each actor of `arrival_class` the actors root holds or receives.
}

## The LAEventView scene one event is drawn with.
@export var scene: PackedScene = null
## Processes the phenomenon needs, in LAProcessSet.process_name spelling. A world lacking one has no
## view, no switch and no wiring for this kind.
@export var needs: PackedStringArray = PackedStringArray()
## An LAWorldOffers predicate that must answer true, for a thing that arrives from outside and whose
## admission that class decides. Empty: none.
@export var offered_by: StringName = &""
@export var source: Source = Source.OBSERVED
## FIELD, ARRIVAL: the signal that announces one event.
@export var signal_name: StringName = &""
## ARRIVAL: the class_name of the actor that carries `signal_name`.
@export var arrival_class: StringName = &""
## FIELD, ARRIVAL: the observation key each of the signal's arguments fills, in order.
@export var args: PackedStringArray = PackedStringArray()


## Whether this world contains everything the phenomenon needs.
func offered() -> bool:
	for n: String in needs:
		if LAProcessSet.process_entry(n).is_empty():
			return false
	return offered_by == &"" or bool(Offers.call(offered_by))
