package main

// World / floor constants, edge + cell flags, and the active-floor context.

CELL :: 4.0

WALL_H :: 3.0

WALL_T :: 0.6

CHUNK_SIZE :: 16

CHUNK_W :: CHUNK_SIZE * CELL

VIEW_RADIUS :: 1

// The 24 storeys are one continuous world-space volume. Each storey is meshed
// in local coordinates, then translated by its physical Y offset.
FLOOR_SPACING :: 6.0

FLOOR_STEP :: 0.35

MAX_FLOOR_LEVELS :: 3 // small local terrain steps; not the world floor count

WORLD_FLOOR_COUNT :: 24

VERTICAL_VIEW_RADIUS :: 2

// ── NEW: level-transition architecture ──
STAIR_RISE :: 1.0 // metres climbed across one stair cell

STAIR_STEPS :: 6 // keeps the tallest tread rise below the player step-up limit

LINK_SHELL_THICKNESS :: 0.18

LINK_RAIL_HEIGHT :: 0.85

HOLE_DEPTH :: 3.0 // visible shaft depth below the floor

WORLD_SEED: u32 = 1337

NUM_LEVELS :: 24

// current_floor is the player's current storey context. current_level follows
// it: LEVELS[floor] supplies that storey's biome bias, while the geometry itself
// lives in one shared world-space coordinate system.
current_floor: i32

current_level: i32

floor_world_offset :: proc(floor: i32) -> f32 {
	return f32(floor) * FLOOR_SPACING
}

floor_mod :: proc(v, n: i32) -> i32 {return ((v %% n) + n) %% n}

level_seed :: proc() -> u32 {return WORLD_SEED + u32(current_level) * 2246822519}

set_current_floor :: proc(f: i32) {
	next := clamp(f, 0, WORLD_FLOOR_COUNT - 1)
	if next == current_floor && next == current_level do return
	current_floor = next
	current_level = next
	region_cache_clear()
}

// Kept for the dev-map/debug controls; selecting a level now selects a physical
// storey in the continuous 24-floor world rather than swapping a separate scene.
set_level :: proc(l: i32) {
	set_current_floor(l)
}

Chunk_Coord :: [2]i32

EDGE_OPEN :: 0

EDGE_WALL :: 1

EDGE_DOOR :: 2

CELL_PILLAR :: 1

CELL_POOL :: 2

CELL_STAIR :: 4 // legacy debug flag; new links use CELL_LINK

CELL_HOLE :: 8 // legacy debug flag; new links use CELL_LINK

CELL_LINK :: 16

CELL_LINK_RING :: 32 // flat apron around a vertical link

SPAWN_CLEAR :: 2

fdiv :: proc(a, b: i32) -> i32 {return (a - a %% b) / b}
