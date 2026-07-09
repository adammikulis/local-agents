# Trailer script — Local Agents (0.3)

**Length:** ~70 s. **Aspect:** 16:9, 1080p (720p fallback). **Arc:** serenity → the hunt →
civilization → cataclysm → reveal. Open genuinely calm so the destruction hits harder; feature chaos
and destruction, but lead with life and the one differentiator no other god-game has — **every creature
thinks on your own machine, offline** (show the thought bubbles).

## Capture setup (so retakes match)
- Record with Godot **movie-maker** (`--write-movie=<path>`) at a fixed fps for smooth, deterministic
  frames — not a screen grab.
- **Pin the world seed AND the music seed** (`LA_MUSIC_SEED`) so every retake is identical.
- Camera modes to use: **fly/drone** (low, dynamic), **geosync** (locked tracking of a region),
  **orbit** (reveals), **solar-system view** (the capstone pull-out).
- Use **`--fast`** (time-scale) for the slow-emergent beats (day/night sweep, the volcano building),
  then drop to realtime for the action beats.
- Thought bubbles come from the creature thought-inspector — select the featured creature
  deterministically each take.
- Music: the generative engine, arced calm → tense → thunderous; event stings land on impacts.
- Grade: warm golden open → cooler tension → fiery cataclysm → deep-space blue reveal.

---

## Shot list

### Act 1 — Serenity (0:00–0:14)
1. **0:00–0:05 (5s)** — Low **fly-cam** drifting slowly over sunlit grass, golden hour. A few
   **rabbits grazing** peacefully, ears flicking. No UI. Ambient pad + birdsong. *Hook: it's alive and
   calm.*
2. **0:05–0:10 (5s)** — Slow **push-in on one rabbit**; its **thought bubble** fades in —
   *"Watered and well-fed — tending my nest."* with the small **"thinking · local model · offline"**
   badge. *Hook: the animals genuinely think, on your machine.*
3. **0:10–0:14 (4s)** — Rise into a gentle **orbit** over a **rabbit family** clustered by a burrow; a
   faint **kinship line** flickers between kin. Warm. *Hook: living herds + real lineage.*

### Act 2 — The hunt (0:14–0:30)
4. **0:14–0:18 (4s)** — Cut to a **fox at the treeline**, low **geosync** angle, stalking. Music drops
   to a tense low note. Fox thought: *"Prey ahead — move in."* *Hook: predator cognition.*
5. **0:18–0:24 (6s)** — The fox bursts; the rabbit **herd explodes into a stampede** — emergent scatter
   and dust, **geosync** tracking the panic. A rabbit's thought flips to *"Run!"*. *Hook: the stampede
   falls out of a real scare — nothing scripted.*
6. **0:24–0:30 (6s)** — Quick cuts: foxes chasing, one rabbit caught (tasteful — a tumble via the
   physics shadow, no gore), then the **herd reforming over a ridge**. *Hook: consequence, and herds
   self-heal.*

### Act 3 — Civilization (0:30–0:42)
7. **0:30–0:36 (6s)** — Rising **orbit/crane reveal**: **villagers by their huts** on a hillside, foxes
   prowling the margins, rabbits scattered between. A villager thought: *"Danger near the herd."* A
   busier world, more minds. *Hook: humans layer in — the world gets complex.*
8. **0:36–0:42 (6s)** — **Hand of god**: the spawn-brush sweeps in a **forest**; `--fast` blurs a
   **day/night sweep** — sun terminator racing, clouds forming and raining. *Hook: you shape it, and the
   climate is emergent.*

### Act 4 — Cataclysm (0:42–0:58)
9. **0:42–0:47 (5s)** — The ground **glows**. Low **geosync** near a seabed vent, pressure building,
   music to a rumble, a crack of red. *Hook: the volcano is about to emerge from physics.*
10. **0:47–0:54 (7s)** — **VOLCANO ERUPTS**: **lava ejecta arcing** (real ballistic momentum), ash,
    a shockwave, creatures fleeing every direction, **lightning** cracking in the ash cloud. Dynamic
    **fly-cam** pulling back through the chaos. Peak music + stings. *Hook: destruction & chaos, all
    emergent from one substrate — nothing hand-scripted.*
11. **0:54–0:58 (4s)** — The eruption **builds land** — lava quenches into new rock, an **island rises**;
    (optional) a **meteor** streaks in for extra chaos. Wide. *Hook: creation from destruction.*

### Act 5 — Reveal & title (0:58–1:10)
12. **0:58–1:04 (6s)** — Camera pulls **way back** — the whole **living planet** turning (terminator,
    storms, the eruption still glowing) — then the **solar-system view** snaps out (the campaign's
    capstone unlock): the planet among others, lit by its sun. *Hook: scale — a whole world, and more.*
13. **1:04–1:10 (6s)** — **Title card**: **LOCAL AGENTS**. Tagline: *"A living world driven by local
    AI. Fully offline."* Sub-line: *"Every creature thinks on your machine — no cloud."* Then
    **"Created by Adam Mikulis"** + **"Play it on itch.io"**. Music resolves.

### Optional stinger (1:10–1:15)
14. **(5s)** — A single rabbit pokes from the new island's cooling ash; thought bubble: *"…safe?"* — cut
    to black. A small smile to end on.

---

## On-screen text (keep minimal — let the world speak)
- Only the two thought bubbles that carry the story (rabbit calm → "Run!"), the fox/villager beats, and
  the end card. No lower-third captions cluttering the action.
- End-card lines, in order: **LOCAL AGENTS** · *A living world driven by local AI. Fully offline.* ·
  *Every creature thinks on your machine — no cloud.* · **Created by Adam Mikulis** · *Play it on itch.io*.

## Capture checklist (for the trailer pass)
- [ ] Peaceful rabbit open (fly-cam, golden hour) — shots 1–2, thought bubble legible
- [ ] Rabbit family + kinship line (orbit) — shot 3
- [ ] Fox stalk + thought (geosync) — shot 4
- [ ] Emergent stampede (geosync tracking) — shots 5–6
- [ ] Villagers + huts reveal (orbit) — shot 7
- [ ] Spawn-brush forest + `--fast` day/night — shot 8
- [ ] Volcano build + eruption (ejecta, lightning) (geosync→fly) — shots 9–11
- [ ] Planet turn → solar-system pull-out — shot 12
- [ ] Title card + CTA — shot 13
- [ ] (optional) island-ash stinger — shot 14
- Assemble to the music arc; export 1080p60 (down-res for itch), plus 2–3 looping GIFs (stampede,
  eruption, thought bubble) for the itch page + README.
