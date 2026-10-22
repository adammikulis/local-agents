class_name LAWorldEnd
extends RefCounted

## A freed world's statics, put back to what a fresh process holds, so the next world is built as the first.


static func release() -> void:
	LAAblate.release()
	LAFakes.reset()
	LASimReport.reset(true)
	LASimRng.forget()
	LAGroupIndex.forget()
	LAMeteorImpacts.forget()
	LACreatureSetup.forget()
	LACreatureAffiliation.forget()
	LACreatureRagdoll.forget()
	LAVoxelHarness.forget()
	LAWorldOffers.bind_field(null)
	LABallistics.clear()
	LABallistics.clear_field()
