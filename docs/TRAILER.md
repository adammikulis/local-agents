# Trailer script — Local Agents (0.3)

**Length: 30 s hard cap.** 16:9, 1080p (720p fallback). Fast cuts, music builds quickly. **Arc:**
serenity → the hunt → civilization → cataclysm → reveal. Open calm so the eruption lands; lead with the
one thing nobody else has — **every creature thinks on your machine, offline** (show one thought bubble).

## Capture setup (so retakes match)
- Record with Godot **movie-maker** (`--write-movie=<path>`) at fixed fps — not a screen grab.
- **Pin the world seed AND music seed** (`LA_MUSIC_SEED`) so retakes are identical.
- Cameras: **fly/drone** (low, dynamic), **geosync** (locked tracking), **orbit** (reveals),
  **solar-system view** (the pull-out). Use **`--fast`** for the day/night flash + volcano build, realtime
  for the action.
- Thought bubbles: the creature thought-inspector; select the featured creature deterministically.
- Grade: warm golden open → fiery cataclysm → deep-space blue reveal. Music: calm → thunderous, event
  stings on impacts.

## Shot list (7 shots, ~30 s)
1. **0:00–0:04 (4s)** — **Serenity + the hook.** Low **fly-cam** over sunlit grass, **rabbits grazing**;
   a **thought bubble** pops on one — *"Well-fed. Tending my nest."* with a **"local model · offline"**
   badge. Calm pad. *The animals think, on your machine.*
2. **0:04–0:08 (4s)** — **The hunt.** A **fox** stalks and bursts; the rabbit **herd stampedes**
   (emergent), **geosync** tracking; a rabbit's bubble flips to *"Run!"*. Tension hit.
3. **0:08–0:11 (3s)** — **Civilization.** Quick **orbit** reveal of **villagers by their huts**, foxes at
   the margins — the world filling with minds.
4. **0:11–0:14 (3s)** — **Hand of god.** The spawn-brush sweeps in a **forest**; a fast **day→night
   flash** (`--fast`), clouds and rain. *You shape it; the climate is emergent.*
5. **0:14–0:22 (8s)** — **CATACLYSM (the payoff).** **Volcano erupts** — lava **ejecta arcing** on real
   momentum, **lightning** in the ash, creatures fleeing, then a **new island rises** from the sea.
   **Fly-cam** pulling back through the chaos. Peak music + stings. *All emergent from one substrate.*
6. **0:22–0:27 (5s)** — **Reveal + the threat.** Pull **way back** to the whole **planet turning**
   (eruption still glowing), then the **solar-system view** snaps out — the planet lit by its sun. As it
   does, a **large asteroid sweeps into frame on a collision course with the planet** — the "it's not
   over" cliffhanger. *Scale, and a looming threat.* (Capture: a big rock/meteor placed on an approach
   trajectory, framed against the planet in the solar view.)
7. **0:27–0:30 (3s)** — **Title.** **LOCAL AGENTS** · *"A living world driven by local AI. Fully
   offline."* · **Created by Adam Mikulis** · *Play it on itch.io*.

**If it runs long:** compress shots 3 + 4 to ~2 s each — protect the eruption (5) and the reveal (6);
those two are the trailer.

## On-screen text (minimal)
Only the two thought bubbles (rabbit calm → "Run!") and the end card. End-card lines in order:
**LOCAL AGENTS** · *A living world driven by local AI. Fully offline.* · **Created by Adam Mikulis** ·
*Play it on itch.io*.

## Also capture (for the itch page + README)
2–3 looping **GIFs**: the stampede, the eruption, a thought bubble.
