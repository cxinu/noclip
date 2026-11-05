package main

import "core:math"
import rl "vendor:raylib"

CELL :: 4.0
WALL_H :: 3.0
WALL_T :: 0.6
CHUNK_SIZE :: 16
CHUNK_W :: CHUNK_SIZE * CELL
VIEW_RADIUS :: 1

// Vertical floors are generated in local coordinates and separated in world space.
FLOOR_SPACING :: 6.0
FLOOR_STEP :: 0.35
MAX_FLOOR_LEVELS :: 3

// ── NEW: level-transition architecture ──
STAIR_RISE :: 1.0 // metres climbed across one stair cell
STAIR_STEPS :: 5 // discrete treads (0.2m each)
HOLE_DEPTH :: 3.0 // visible shaft depth below the floor

Biome_Type :: enum {
	Mono_Yellow,
	Fluorescent_White,
	Poolrooms,
	Concrete_Maze,
	Parking_Garage,
	Red_Rooms,
	Warehouse,
	Hotel_Corridor,
	Arcade_Night,
	Sub_Basement,
}
WORLD_SEED: u32 = 1337

NUM_LEVELS :: 24

Level_Def :: struct {
	name:     string,
	dominant: Biome_Type,
	bias:     f32,
}

LEVELS := [NUM_LEVELS]Level_Def {
	{"Lobby", .Mono_Yellow, 0.20},
	{"Habitable Zone", .Warehouse, 0.25},
	{"Pipe Dreams", .Sub_Basement, 0.25},
	{"Electrical Station", .Concrete_Maze, 0.25},
	{"Abandoned Office", .Fluorescent_White, 0.25},
	{"Terror Hotel", .Hotel_Corridor, 0.30},
	{"Lights Out", .Sub_Basement, 0.30},
	{"Thalassophobia", .Poolrooms, 0.30},
	{"Cave System", .Concrete_Maze, 0.30},
	{"The Suburbs", .Mono_Yellow, 0.15},
	{"Level 10", .Warehouse, 0.25},
	{"Level 11", .Concrete_Maze, 0.25},
	{"Level 12", .Parking_Garage, 0.25},
	{"Level 13", .Red_Rooms, 0.25},
	{"Level 14", .Arcade_Night, 0.25},
	{"Level 15", .Fluorescent_White, 0.25},
	{"Level 16", .Poolrooms, 0.25},
	{"Level 17", .Hotel_Corridor, 0.25},
	{"Level 18", .Sub_Basement, 0.25},
	{"Level 19", .Parking_Garage, 0.25},
	{"Level 20", .Warehouse, 0.25},
	{"Level 21", .Red_Rooms, 0.25},
	{"Level 22", .Arcade_Night, 0.25},
	{"Level 23", .Concrete_Maze, 0.25},
}

// current_floor is an unbounded physical floor index. current_level selects
// the biome/theme profile and cycles through LEVELS independently.
current_floor: i32
current_level: i32
level_dirty: bool

floor_world_offset :: proc(floor: i32) -> f32 {
	return f32(floor) * FLOOR_SPACING
}

floor_mod :: proc(v, n: i32) -> i32 {return ((v %% n) + n) %% n}

level_seed :: proc() -> u32 {return WORLD_SEED + u32(current_level) * 2246822519}

set_current_floor :: proc(f: i32) {
	if f == current_floor do return
	current_floor = f
	last_region = nil
	level_dirty = true
}

// Backrooms theme selection remains independent of physical floor movement.
set_level :: proc(l: i32) {
	next := floor_mod(l, NUM_LEVELS)
	if next == current_level do return
	current_level = next
	last_region = nil
	level_dirty = true
}

Chunk_Coord :: [2]i32

Palette :: struct {
	floor, wall, ceil: rl.Color,
}

PALETTES := [Biome_Type]Palette {
	.Mono_Yellow       = {{62, 57, 34, 255}, {85, 78, 48, 255}, {45, 42, 26, 255}},
	.Fluorescent_White = {{50, 53, 50, 255}, {72, 77, 72, 255}, {35, 38, 35, 255}},
	.Poolrooms         = {{35, 55, 58, 255}, {68, 92, 95, 255}, {24, 38, 40, 255}},
	.Concrete_Maze     = {{32, 33, 35, 255}, {55, 57, 61, 255}, {20, 21, 23, 255}},
	.Parking_Garage    = {{28, 29, 31, 255}, {48, 51, 56, 255}, {18, 19, 21, 255}},
	.Red_Rooms         = {{55, 22, 20, 255}, {84, 36, 33, 255}, {32, 12, 11, 255}},
	.Warehouse         = {{42, 38, 30, 255}, {66, 59, 47, 255}, {26, 23, 18, 255}},
	.Hotel_Corridor    = {{48, 40, 31, 255}, {74, 63, 50, 255}, {30, 25, 19, 255}},
	.Arcade_Night      = {{22, 20, 28, 255}, {45, 38, 55, 255}, {14, 12, 18, 255}},
	.Sub_Basement      = {{26, 24, 21, 255}, {46, 42, 37, 255}, {16, 14, 12, 255}},
}

WALL_HEIGHT := [Biome_Type]f32 {
	.Mono_Yellow       = 3.2,
	.Fluorescent_White = 3.4,
	.Poolrooms         = 4.8,
	.Concrete_Maze     = 3.2,
	.Parking_Garage    = 4.4,
	.Red_Rooms         = 3.0,
	.Warehouse         = 5.2,
	.Hotel_Corridor    = 2.9,
	.Arcade_Night      = 3.2,
	.Sub_Basement      = 2.6,
}

raw_hash :: proc(x, y: i32) -> u32 {
	h: u32 = u32(x) * 374761393 + u32(y) * 668265263
	h = (h ~ (h >> 13)) * 1274126177
	return h ~ (h >> 16)
}

DOOR_MIN_W :: 1.4
DOOR_MAX_W :: CELL - 0.6
DOOR_MARGIN :: 0.3

cell_enclosure :: proc(x, z: i32) -> u32 {
	n: u32 = 0
	if has_wall(x, z, false) do n += 1
	if has_wall(x + 1, z, false) do n += 1
	if has_wall(x, z, true) do n += 1
	if has_wall(x, z + 1, true) do n += 1
	return n
}

door_span :: proc(x, z: i32, north: bool) -> (l, r: f32) {
	h := raw_hash(x * 57 + 13, z * 3 + i32(north) + 9000)
	t := f32((h >> 4) & 0xFF) / 255
	w := DOOR_MIN_W + t * t * (DOOR_MAX_W - DOOR_MIN_W)
	slack := CELL - 2 * DOOR_MARGIN - w
	o := f32((h >> 12) & 0xFF) / 255
	l = DOOR_MARGIN + o * slack
	return l, l + w
}

door_top :: proc(x, z: i32, north: bool, wall_h: f32) -> f32 {
	h := raw_hash(x * 91 + 5, z * 5 + i32(north) + 12000)
	t := f32((h >> 8) & 0xFF) / 255
	return min(1.9 + t * 0.9, wall_h - 0.25)
}

BIOME_SCALE :: 60.0
BIOME_CONTRAST :: 2.0
BLEND_MARGIN :: 0.35

Biome_Info :: struct {
	b, b2: Biome_Type,
	w:     f32,
}

BIOME_PROTO := [Biome_Type][2]f32 {
	.Mono_Yellow       = {0.50, 0.50},
	.Hotel_Corridor    = {0.92, 0.50},
	.Red_Rooms         = {0.82, 0.77},
	.Arcade_Night      = {0.57, 0.91},
	.Sub_Basement      = {0.29, 0.86},
	.Concrete_Maze     = {0.11, 0.64},
	.Poolrooms         = {0.11, 0.36},
	.Parking_Garage    = {0.29, 0.14},
	.Warehouse         = {0.57, 0.09},
	.Fluorescent_White = {0.82, 0.23},
}

BIOME_BIAS := [Biome_Type]f32 {
	.Mono_Yellow       = 0,
	.Fluorescent_White = 0,
	.Poolrooms         = 0,
	.Concrete_Maze     = 0,
	.Parking_Garage    = 0,
	.Red_Rooms         = 0,
	.Warehouse         = 0,
	.Hotel_Corridor    = 0,
	.Arcade_Night      = 0,
	.Sub_Basement      = 0,
}

hash01 :: proc(x, y, seed: i32) -> f32 {
	return f32(raw_hash(x + seed * 7919, y - seed * 104729 + i32(level_seed())) >> 8) / 16777216.0
}

bnoise :: proc(x, y: f32, seed: i32) -> f32 {
	xf, yf := math.floor(x), math.floor(y)
	xi, yi := i32(xf), i32(yf)
	fx, fy := x - xf, y - yf
	sx := fx * fx * (3 - 2 * fx)
	sy := fy * fy * (3 - 2 * fy)
	top := hash01(xi, yi, seed) + (hash01(xi + 1, yi, seed) - hash01(xi, yi, seed)) * sx
	bot :=
		hash01(xi, yi + 1, seed) + (hash01(xi + 1, yi + 1, seed) - hash01(xi, yi + 1, seed)) * sx
	return top + (bot - top) * sy
}

bfbm :: proc(x, y: f32, seed: i32) -> f32 {
	sum, amp, norm: f32 = 0, 1, 0
	fx, fy := x, y
	for o in 0 ..< 3 {
		sum += amp * bnoise(fx, fy, seed + i32(o))
		norm += amp
		amp *= 0.5
		fx *= 2.1
		fy *= 2.1
	}
	return sum / norm
}

hash01_for_floor :: proc(x, y, seed, floor, theme: i32) -> f32 {
	world_seed := i32(WORLD_SEED + u32(floor) * 2246822519 + u32(theme) * 3266489917)
	return f32(raw_hash(x + seed * 7919, y - seed * 104729 + world_seed) >> 8) / 16777216.0
}

bnoise_for_floor :: proc(x, y: f32, seed, floor, theme: i32) -> f32 {
	xf, yf := math.floor(x), math.floor(y)
	xi, yi := i32(xf), i32(yf)
	fx, fy := x - xf, y - yf
	sx := fx * fx * (3 - 2 * fx)
	sy := fy * fy * (3 - 2 * fy)
	n00 := hash01_for_floor(xi, yi, seed, floor, theme)
	n10 := hash01_for_floor(xi + 1, yi, seed, floor, theme)
	n01 := hash01_for_floor(xi, yi + 1, seed, floor, theme)
	n11 := hash01_for_floor(xi + 1, yi + 1, seed, floor, theme)
	top := n00 + (n10 - n00) * sx
	bot := n01 + (n11 - n01) * sx
	return top + (bot - top) * sy
}

bfbm_for_floor :: proc(x, y: f32, seed, floor, theme: i32) -> f32 {
	sum, amp, norm: f32 = 0, 1, 0
	fx, fy := x, y
	for o in 0 ..< 3 {
		sum += amp * bnoise_for_floor(fx, fy, seed + i32(o), floor, theme)
		norm += amp
		amp *= 0.5
		fx *= 2.1
		fy *= 2.1
	}
	return sum / norm
}

biome_info_raw_for_level :: proc(x, z, floor, theme: i32, bleed_depth: i32 = 0) -> Biome_Info {
	// Roughly one patch in five inherits the biome map of the floor below.
	// Patch coordinates are deliberately coarser than biome cells.
	patch_x, patch_z := fdiv(x, 18), fdiv(z, 18)
	bleed_hash := raw_hash(patch_x + i32(WORLD_SEED), patch_z + floor * 7919 + theme * 104729)
	if bleed_depth < 16 && bleed_hash %% 5 == 0 {
		return biome_info_raw_for_level(x, z, floor - 1, theme, bleed_depth + 1)
	}

	px, pz := f32(x) + 0.5, f32(z) + 0.5
	wx := px + (bnoise_for_floor(px * 0.022, pz * 0.022, 91, floor, theme) - 0.5) * 36
	wz :=
		pz + (bnoise_for_floor(px * 0.022 + 40.1, pz * 0.022 - 17.7, 92, floor, theme) - 0.5) * 36
	fa := bfbm_for_floor(wx / BIOME_SCALE, wz / BIOME_SCALE, 11, floor, theme)
	fb := bfbm_for_floor(wx / BIOME_SCALE + 31.7, wz / BIOME_SCALE - 12.9, 13, floor, theme)
	fa = clamp(0.5 + (fa - 0.5) * BIOME_CONTRAST, 0, 1)
	fb = clamp(0.5 + (fb - 0.5) * BIOME_CONTRAST, 0, 1)

	lv := LEVELS[floor_mod(theme, NUM_LEVELS)]
	spawn := clamp(1 - math.sqrt(px * px + pz * pz) / 40, 0, 1)

	best, second: f32 = 1e9, 1e9
	bi, si := lv.dominant, lv.dominant
	for t in Biome_Type {
		p := BIOME_PROTO[t]
		da, db := fa - p[0], fb - p[1]
		d := math.sqrt(da * da + db * db) - BIOME_BIAS[t]
		if t == lv.dominant {
			d -= lv.bias
			d -= spawn * 0.6
		}
		if d < best {second, si = best, bi; best, bi = d, t} else if d < second {second, si = d, t}
	}

	m := clamp((second - best) / BLEND_MARGIN, 0, 1)
	m = m * m * (3 - 2 * m)
	return Biome_Info{b = bi, b2 = si, w = 0.5 + 0.5 * m}
}

biome_info_raw :: proc(x, z: i32) -> Biome_Info {
	return biome_info_raw_for_level(x, z, current_floor, current_level)
}

BIOME_CACHE_N :: 16384
Biome_Cache_Entry :: struct {
	x, z, floor, theme: i32,
	valid:              bool,
	info:               Biome_Info,
}
biome_cache: [BIOME_CACHE_N]Biome_Cache_Entry

biome_info :: proc(x, z: i32) -> Biome_Info {
	floor, theme := current_floor, current_level
	e := &biome_cache[raw_hash(x, z + floor * 7717 + theme * 131071) & (BIOME_CACHE_N - 1)]
	if e.valid && e.x == x && e.z == z && e.floor == floor && e.theme == theme do return e.info
	e.x, e.z, e.floor, e.theme, e.valid = x, z, floor, theme, true
	e.info = biome_info_raw(x, z)
	return e.info
}

biome_at :: proc(x, z: i32) -> Biome_Type {return biome_info(x, z).b}

ceil_h :: proc(x, z: i32) -> f32 {
	i := biome_info(x, z)
	return WALL_HEIGHT[i.b] * i.w + WALL_HEIGHT[i.b2] * (1 - i.w)
}

corner_h :: proc(cx, cz: i32) -> f32 {
	return(
		(ceil_h(cx - 1, cz - 1) + ceil_h(cx, cz - 1) + ceil_h(cx - 1, cz) + ceil_h(cx, cz)) *
		0.25 \
	)
}

// ───────────────────────── floor plan generator ─────────────────────────

EDGE_OPEN :: 0
EDGE_WALL :: 1
EDGE_DOOR :: 2

CELL_PILLAR :: 1
CELL_POOL :: 2
CELL_STAIR :: 4 // legacy debug flag; new links use CELL_LINK
CELL_HOLE :: 8 // legacy debug flag; new links use CELL_LINK
CELL_LINK :: 16

Link_Kind :: enum {
	Stairs,
	Switchback,
	Ramp,
	Drop,
	Slide,
}
Link_Role :: enum {
	None,
	Lower,
	Upper,
}

Vertical_Link :: struct {
	x, z:           i32,
	w, d:           i32,
	lower_floor:    i32,
	kind:           Link_Kind,
	direction:      u8, // 0=N, 1=S, 2=E, 3=W: direction of ascent
	entry_side:     u8,
	opening_width:  i32,
	opening_offset: i32,
}

SPAWN_CLEAR :: 2

REG_PITCH :: 48
REG_JIT :: 16
HALL_MAX :: 28

Gen_Params :: struct {
	min_side:  i32,
	room_max:  i32,
	stop:      u32,
	hall:      u32,
	corridor:  u32,
	open_wall: u32,
	closet:    u32,
	pillars:   u32,
	pool:      u32,
	pillar_sp: i32,
	step:      u32,
	step_max:  i32,
}

GEN := [Biome_Type]Gen_Params {
	.Mono_Yellow       = {3, 9, 70, 40, 60, 50, 90, 60, 0, 0, 40, 1},
	.Fluorescent_White = {3, 8, 60, 20, 110, 30, 40, 60, 0, 2, 20, 1},
	.Poolrooms         = {4, 10, 80, 160, 10, 120, 20, 40, 200, 3, 120, 2},
	.Concrete_Maze     = {2, 6, 20, 0, 140, 8, 60, 0, 0, 0, 20, 1},
	.Parking_Garage    = {5, 12, 90, 200, 10, 140, 0, 230, 0, 3, 140, 2},
	.Red_Rooms         = {3, 7, 60, 10, 80, 20, 90, 40, 0, 0, 60, 1},
	.Warehouse         = {5, 14, 80, 220, 10, 150, 0, 230, 0, 4, 160, 2},
	.Hotel_Corridor    = {3, 8, 50, 0, 220, 10, 40, 30, 0, 2, 30, 1},
	.Arcade_Night      = {3, 9, 80, 60, 60, 60, 60, 120, 0, 0, 100, 1},
	.Sub_Basement      = {2, 6, 30, 5, 100, 20, 100, 30, 0, 0, 180, 2},
}

Region :: struct {
	floor, theme:             i32,
	x0, z0, w, h:             i32,
	edge_w, edge_n, cell_flg: []u8,
	cell_floor:               []i8,
	cell_stair:               []u8, // legacy compatibility
	cell_link_id:             []i16,
	cell_link_role:           []u8,
	links:                    [2]Vertical_Link,
	link_count:               int,
}

regions: map[[4]i32]^Region
last_region: ^Region

fdiv :: proc(a, b: i32) -> i32 {return (a - a %% b) / b}
layout_hash :: proc(a, b: i32) -> u32 {return raw_hash(
		a + i32(WORLD_SEED),
		b ~ i32(WORLD_SEED * 2654435761),
	)}
lh :: proc(a, b: i32) -> u32 {return layout_hash(a, b)}

Rng :: struct {
	s: u32,
}
rng_u32 :: proc(r: ^Rng) -> u32 {r.s ~= r.s << 13; r.s ~= r.s >> 17; r.s ~= r.s << 5; return r.s}
rng_range :: proc(r: ^Rng, lo, hi: i32) -> i32 {
	if hi <= lo do return lo
	return lo + i32(rng_u32(r) % u32(hi - lo + 1))
}
rng_chance :: proc(r: ^Rng, p: u32) -> bool {return (rng_u32(r) & 0xFF) < p}
rng_bit :: proc(r: ^Rng) -> bool {return ((rng_u32(r) >> 7) & 1) == 1}

reg_col_line :: proc(i: i32) -> i32 {return i * REG_PITCH + i32(lh(i, 12011) % REG_JIT)}
reg_row_line :: proc(i, j: i32) -> i32 {return(
		j * REG_PITCH +
		i32(lh(i, j * 31 + 12013) % REG_JIT) \
	)}
reg_col_of :: proc(x: i32) -> i32 {
	i := fdiv(x, REG_PITCH)
	if x < reg_col_line(i) do i -= 1
	return i
}
reg_row_of :: proc(i, z: i32) -> i32 {
	j := fdiv(z, REG_PITCH)
	if z < reg_row_line(i, j) do j -= 1
	return j
}

region_idx :: proc(r: ^Region, x, z: i32) -> int {
	return int((z - r.z0) * r.w + (x - r.x0))
}

region_at :: proc(x, z: i32) -> ^Region {
	if regions == nil do regions = make(map[[4]i32]^Region)
	if lr := last_region;
	   lr != nil &&
	   lr.floor == current_floor &&
	   lr.theme == current_level &&
	   x >= lr.x0 &&
	   x < lr.x0 + lr.w &&
	   z >= lr.z0 &&
	   z < lr.z0 + lr.h {
		return lr
	}
	i := reg_col_of(x)
	j := reg_row_of(i, z)
	key := [4]i32{current_floor, current_level, i, j}
	if found, ok := regions[key]; ok {last_region = found; return found}
	r := new(Region)
	r.floor = current_floor
	r.theme = current_level
	r.x0 = reg_col_line(i)
	r.z0 = reg_row_line(i, j)
	r.w = reg_col_line(i + 1) - r.x0
	r.h = reg_row_line(i, j + 1) - r.z0
	n := int(r.w * r.h)
	r.edge_w = make([]u8, n)
	r.edge_n = make([]u8, n)
	r.cell_flg = make([]u8, n)
	r.cell_floor = make([]i8, n)
	r.cell_stair = make([]u8, n) // legacy compatibility
	r.cell_link_id = make([]i16, n)
	r.cell_link_role = make([]u8, n)
	for k in 0 ..< n do r.cell_link_id[k] = -1
	generate_region(r, i, j)
	regions[key] = r
	last_region = r
	return r
}

// Keep only regions near the player on the active physical floor. The world is
// deterministic, so evicted regions can be regenerated without state loss.
// This bounds memory use during long exploratory sessions.
regions_trim :: proc(cell_x, cell_z: i32, radius: i32 = 2) {
	center_i := reg_col_of(cell_x)
	center_j := reg_row_of(center_i, cell_z)
	stale := make([dynamic][4]i32, context.temp_allocator)

	for key in regions {
		nearby :=
			key[0] == current_floor &&
			key[1] == current_level &&
			abs(key[2] - center_i) <= radius &&
			abs(key[3] - center_j) <= radius
		if !nearby do append(&stale, key)
	}

	for key in stale {
		if r, ok := regions[key]; ok {
			delete(r.edge_w)
			delete(r.edge_n)
			delete(r.cell_flg)
			delete(r.cell_floor)
			delete(r.cell_stair)
			delete(r.cell_link_id)
			delete(r.cell_link_role)
			free(r)
			delete_key(&regions, key)
		}
	}

	// The one-entry fast path may otherwise point at an evicted region.
	last_region = nil
}

set_w :: proc(r: ^Region, x, z: i32, v: u8) {
	if x < r.x0 || x >= r.x0 + r.w || z < r.z0 || z >= r.z0 + r.h do return
	r.edge_w[region_idx(r, x, z)] = v
}
set_n :: proc(r: ^Region, x, z: i32, v: u8) {
	if x < r.x0 || x >= r.x0 + r.w || z < r.z0 || z >= r.z0 + r.h do return
	r.edge_n[region_idx(r, x, z)] = v
}
set_cell :: proc(r: ^Region, x, z: i32, flag: u8) {
	if x < r.x0 || x >= r.x0 + r.w || z < r.z0 || z >= r.z0 + r.h do return
	r.cell_flg[region_idx(r, x, z)] |= flag
}
set_floor :: proc(r: ^Region, x, z: i32, lvl: i8) {
	if x < r.x0 || x >= r.x0 + r.w || z < r.z0 || z >= r.z0 + r.h do return
	r.cell_floor[region_idx(r, x, z)] = lvl
}
set_edge :: proc(r: ^Region, vertical: bool, line, t: i32, v: u8) {
	if vertical {set_w(r, line, t, v)} else {set_n(r, t, line, v)}
}

portal_width :: proc(rng: ^Rng) -> i32 {
	v := rng_u32(rng) & 0xFF
	if v < 140 do return 1
	if v < 200 do return 2
	if v < 235 do return 3
	return 5
}

punch :: proc(r: ^Region, vertical: bool, line, pos, width: i32) {
	code: u8 = EDGE_DOOR if width == 1 else EDGE_OPEN
	for t in pos ..< pos + width do set_edge(r, vertical, line, t, code)
}

punch_border :: proc(r: ^Region, rng: ^Rng, vertical: bool) {
	a := r.z0 if vertical else r.x0
	n := r.h if vertical else r.w
	b := a + n
	line := r.x0 if vertical else r.z0
	for t in a ..< b do set_edge(r, vertical, line, t, EDGE_WALL)
	pw := portal_width(rng)
	punch(r, vertical, line, rng_range(rng, a + 2, b - 2 - pw), pw)
	for s := a; s < b; s += 12 {
		e := min(s + 12, b)
		mid := (s + e) / 2
		gp: Gen_Params
		if vertical {gp = GEN[biome_at(r.x0, mid)]} else {gp = GEN[biome_at(mid, r.z0)]}
		roll := rng_u32(rng) & 0xFF
		if roll < gp.open_wall / 2 {
			for t in s ..< e do set_edge(r, vertical, line, t, EDGE_OPEN)
		} else if roll < gp.open_wall / 2 + 70 {
			w2 := min(portal_width(rng), e - s)
			punch(r, vertical, line, rng_range(rng, s, e - w2), w2)
		}
	}
}

split_wall :: proc(r: ^Region, rng: ^Rng, vertical: bool, line, a, b, doors: i32, wide: bool) {
	n := b - a
	for t in a ..< b do set_edge(r, vertical, line, t, EDGE_WALL)
	if wide && n >= 5 {
		hi := n - 2
		if !rng_bit(rng) do hi = min(hi, 6)
		ow := rng_range(rng, 3, hi)
		g0 := rng_range(rng, a + 1, b - ow - 1)
		for t in g0 ..< g0 + ow do set_edge(r, vertical, line, t, EDGE_OPEN)
		return
	}
	nd := clamp(doors, 1, n)
	seg := max(1, n / nd)
	lo_c, hi_c := a, b - 1
	if n >= 4 do lo_c, hi_c = a + 1, b - 2
	for k in 0 ..< nd {
		lo := a + k * seg
		hi := min(a + (k + 1) * seg, b) - 1
		t := clamp(rng_range(rng, lo, hi), lo_c, hi_c)
		set_edge(r, vertical, line, t, EDGE_DOOR)
	}
}

door_count :: proc(rng: ^Rng, n: i32) -> i32 {
	c := 1 + n / 10
	if rng_chance(rng, 90) do c += 1
	return c
}

place_hall_building :: proc(r: ^Region, rng: ^Rng, x, z, w, h: i32) {
	if w < 9 || h < 9 do return
	bw := rng_range(rng, 2, min(4, w - 6))
	bh := rng_range(rng, 2, min(4, h - 6))
	if bw < 2 || bh < 2 do return
	bx := rng_range(rng, x + 2, x + w - bw - 2)
	bz := rng_range(rng, z + 2, z + h - bh - 2)

	for zz in bz ..< bz + bh {
		for xx in bx ..< bx +
			bw {r.cell_flg[region_idx(r, xx, zz)] &= ~u8(CELL_PILLAR | CELL_POOL)}
		set_w(r, bx, zz, EDGE_WALL)
		set_w(r, bx + bw, zz, EDGE_WALL)
	}
	for xx in bx ..< bx + bw {
		set_n(r, xx, bz, EDGE_WALL)
		set_n(r, xx, bz + bh, EDGE_WALL)
	}

	// One generated doorway; some variants have one or two collapsed wall gaps.
	door_side := rng_range(rng, 0, 3)
	if door_side == 0 {set_n(r, rng_range(rng, bx, bx + bw - 1), bz, EDGE_DOOR)}
	if door_side == 1 {set_n(r, rng_range(rng, bx, bx + bw - 1), bz + bh, EDGE_DOOR)}
	if door_side == 2 {set_w(r, bx + bw, rng_range(rng, bz, bz + bh - 1), EDGE_DOOR)}
	if door_side == 3 {set_w(r, bx, rng_range(rng, bz, bz + bh - 1), EDGE_DOOR)}
	if rng_chance(rng, 92) {
		ruin_side := (door_side + 1 + rng_range(rng, 0, 2)) %% 4
		if ruin_side == 0 {set_n(r, bx + rng_range(rng, 0, bw - 1), bz, EDGE_OPEN)}
		if ruin_side == 1 {set_n(r, bx + rng_range(rng, 0, bw - 1), bz + bh, EDGE_OPEN)}
		if ruin_side == 2 {set_w(r, bx + bw, bz + rng_range(rng, 0, bh - 1), EDGE_OPEN)}
		if ruin_side == 3 {set_w(r, bx, bz + rng_range(rng, 0, bh - 1), EDGE_OPEN)}
	}
}

finish_leaf :: proc(r: ^Region, rng: ^Rng, x, z, w, h: i32, gp: Gen_Params) {
	hall := w >= 6 && h >= 6
	base: i8 = 0
	if gp.step_max > 0 && rng_chance(rng, gp.step) {
		mag := i8(rng_range(rng, 1, gp.step_max))
		if mag > i8(MAX_FLOOR_LEVELS) do mag = i8(MAX_FLOOR_LEVELS)
		base = -mag if rng_bit(rng) else mag
	}
	for zz in z ..< z + h do for xx in x ..< x + w do set_floor(r, xx, zz, base)

	if hall && rng_chance(rng, gp.pool) {
		pw := rng_range(rng, max(2, (w - 2) / 2), w - 2)
		ph := rng_range(rng, max(2, (h - 2) / 2), h - 2)
		px := rng_range(rng, x + 1, x + w - 1 - pw)
		pz := rng_range(rng, z + 1, z + h - 1 - ph)
		pbase := base - 1
		if pbase < -i8(MAX_FLOOR_LEVELS) do pbase = -i8(MAX_FLOOR_LEVELS)
		for zz in pz ..< pz + ph do for xx in px ..< px + pw {
			set_cell(r, xx, zz, CELL_POOL)
			set_floor(r, xx, zz, pbase)
		}
		return
	}
	if hall && rng_chance(rng, gp.pillars) {
		sp := gp.pillar_sp
		if sp == 0 do sp = rng_range(rng, 2, 3)
		for lz := i32(1); lz <= h - 2; lz += sp do for lx := i32(1); lx <= w - 2; lx += sp {
			if rng_u32(rng) % 12 == 0 do continue
			set_cell(r, x + lx, z + lz, CELL_PILLAR)
		}
		if rng_chance(rng, 45) do place_hall_building(r, rng, x, z, w, h)
		return
	}
	if w >= 4 && h >= 4 && rng_chance(rng, gp.closet) {
		cw := rng_range(rng, 1, min(3, w - 3))
		ch := rng_range(rng, 1, min(3, h - 3))
		left := rng_bit(rng); top := rng_bit(rng)
		cx0 := x if left else x + w - cw
		cz0 := z if top else z + h - ch
		vx := cx0 + cw if left else cx0
		hz := cz0 + ch if top else cz0
		for t in cz0 ..< cz0 + ch do set_w(r, vx, t, EDGE_WALL)
		for t in cx0 ..< cx0 + cw do set_n(r, t, hz, EDGE_WALL)
		if rng_bit(
			rng,
		) {set_w(r, vx, rng_range(rng, cz0, cz0 + ch - 1), EDGE_DOOR)} else {set_n(r, rng_range(rng, cx0, cx0 + cw - 1), hz, EDGE_DOOR)}
	}
	if hall && rng_chance(rng, 45) do place_hall_building(r, rng, x, z, w, h)
}

corridor_split :: proc(r: ^Region, rng: ^Rng, x, z, w, h: i32, gp: Gen_Params) -> bool {
	ms := gp.min_side
	cw: i32 = 1
	if rng_chance(rng, 90) do cw = 2
	can_along_z := w >= 2 * ms + cw
	can_along_x := h >= 2 * ms + cw
	along_z: bool
	switch {
	case can_along_z && can_along_x:
		along_z = h >= w
	case can_along_z:
		along_z = true
	case can_along_x:
		along_z = false
	case:
		return false
	}
	if along_z {
		p := rng_range(rng, x + ms, x + w - ms - cw)
		nd := max(2, h / 6)
		split_wall(r, rng, true, p, z, z + h, nd, false)
		split_wall(r, rng, true, p + cw, z, z + h, nd, false)
		bsp(r, rng, x, z, p - x, h)
		bsp(r, rng, p + cw, z, x + w - p - cw, h)
	} else {
		p := rng_range(rng, z + ms, z + h - ms - cw)
		nd := max(2, w / 6)
		split_wall(r, rng, false, p, x, x + w, nd, false)
		split_wall(r, rng, false, p + cw, x, x + w, nd, false)
		bsp(r, rng, x, z, w, p - z)
		bsp(r, rng, x, p + cw, w, z + h - p - cw)
	}
	return true
}

bsp :: proc(r: ^Region, rng: ^Rng, x, z, w, h: i32) {
	gp := GEN[biome_at(x + w / 2, z + h / 2)]
	ms := gp.min_side
	size := max(w, h)
	can_x := w >= 2 * ms
	can_z := h >= 2 * ms
	if !can_x && !can_z {finish_leaf(r, rng, x, z, w, h, gp); return}
	if size <= gp.room_max {
		if rng_chance(rng, gp.stop) {finish_leaf(r, rng, x, z, w, h, gp); return}
	} else if size <= HALL_MAX && rng_chance(rng, gp.hall) {
		finish_leaf(r, rng, x, z, w, h, gp); return
	}
	if size >= 12 && rng_chance(rng, gp.corridor) {
		if corridor_split(r, rng, x, z, w, h, gp) do return
	}
	vertical: bool
	switch {
	case can_x && can_z:
		if w * 10 >
		   h *
			   12 {vertical = true} else if h * 10 > w * 12 {vertical = false} else {vertical = rng_bit(rng)}
	case can_x:
		vertical = true
	case:
		vertical = false
	}
	wide := rng_chance(rng, gp.open_wall)
	if vertical {
		p := rng_range(rng, x + ms, x + w - ms)
		split_wall(r, rng, true, p, z, z + h, door_count(rng, h), wide)
		bsp(r, rng, x, z, p - x, h); bsp(r, rng, p, z, x + w - p, h)
	} else {
		p := rng_range(rng, z + ms, z + h - ms)
		split_wall(r, rng, false, p, x, x + w, door_count(rng, w), wide)
		bsp(r, rng, x, z, w, p - z); bsp(r, rng, x, p, w, z + h - p)
	}
}

// ───────────────────────── shared vertical-link layout ─────────────────────────

link_hash :: proc(ri, rj, pair_floor, salt: i32) -> u32 {
	return raw_hash(
		ri * 4099 + pair_floor * 7919 + salt + i32(WORLD_SEED),
		rj * 8191 - pair_floor * 104729,
	)
}

link_rect_free :: proc(r: ^Region, x, z, w, d: i32) -> bool {
	if x < r.x0 + 2 || z < r.z0 + 2 || x + w >= r.x0 + r.w - 2 || z + d >= r.z0 + r.h - 2 do return false
	for zz in z ..< z + d do for xx in x ..< x + w {
		i := region_idx(r, xx, zz)
		if r.cell_link_id[i] >= 0 do return false
	}
	return true
}

link_side_open :: proc(l: Vertical_Link, role: Link_Role, side: u8) -> bool {
	if l.kind == .Drop {
		return side == (l.direction if role == .Upper else l.entry_side)
	}
	if l.kind == .Slide {
		if role == .Lower do return side == l.entry_side
		return side == l.direction || side == l.entry_side
	}
	if l.kind == .Switchback do return side == l.entry_side
	// Walkable stairs and ramps need an entry and a seam opening at the far end.
	return side == l.entry_side || side == l.direction
}

link_open_offset :: proc(l: Vertical_Link, side: u8, wx, wz: i32) -> bool {
	offset := wx - l.x if side < 2 else wz - l.z
	return offset >= l.opening_offset && offset < l.opening_offset + l.opening_width
}

link_clear_rect :: proc(r: ^Region, l: Vertical_Link, role: Link_Role, id: i16) {
	// Internal edges are open; the rectangle perimeter is enclosed except for
	// the entry/exit apertures dictated by the link type.
	for z in l.z ..< l.z + l.d do for x in l.x ..< l.x + l.w {
		i := region_idx(r, x, z)
		r.cell_flg[i] &= ~u8(CELL_PILLAR | CELL_POOL | CELL_STAIR | CELL_HOLE)
		r.cell_flg[i] |= CELL_LINK
		r.cell_floor[i] = 0
		r.cell_link_id[i] = id
		r.cell_link_role[i] = u8(role)
		if x > l.x do set_w(r, x, z, EDGE_OPEN)
		if z > l.z do set_n(r, x, z, EDGE_OPEN)
	}
	// A switchback is two parallel flights joined by a one-cell landing.
	// Keep a divider between the flights, ending it before the turn so the
	// player can walk around the U at the far end.
	if l.kind == .Switchback {
		if l.direction < 2 {
			divider_x := l.x + l.w / 2
			for z in l.z ..< l.z + l.d {
				at_turn :=
					(l.direction == 0 && z == l.z) || (l.direction == 1 && z == l.z + l.d - 1)
				if !at_turn do set_w(r, divider_x, z, EDGE_WALL)
			}
		} else {
			divider_z := l.z + l.d / 2
			for x in l.x ..< l.x + l.w {
				at_turn :=
					(l.direction == 2 && x == l.x + l.w - 1) || (l.direction == 3 && x == l.x)
				if !at_turn do set_n(r, x, divider_z, EDGE_WALL)
			}
		}
	}
	for z in l.z ..< l.z + l.d {
		set_w(r, l.x, z, EDGE_WALL)
		set_w(r, l.x + l.w, z, EDGE_WALL)
	}
	for x in l.x ..< l.x + l.w {
		set_n(r, x, l.z, EDGE_WALL)
		set_n(r, x, l.z + l.d, EDGE_WALL)
	}
	for side in 0 ..< 4 {
		s := u8(side)
		if !link_side_open(l, role, s) do continue
		for q in l.opening_offset ..< l.opening_offset + l.opening_width {
			switch s {
			case 0:
				set_n(r, l.x + q, l.z, EDGE_OPEN) // north
			case 1:
				set_n(r, l.x + q, l.z + l.d, EDGE_OPEN) // south
			case 2:
				set_w(r, l.x + l.w, l.z + q, EDGE_OPEN) // east
			case 3:
				set_w(r, l.x, l.z + q, EDGE_OPEN) // west
			}
		}
	}
}

place_vertical_link :: proc(r: ^Region, ri, rj, pair_floor: i32, role: Link_Role) {
	h := link_hash(ri, rj, pair_floor, 17)
	if h %% 4 != 0 || r.link_count >= 2 do return
	kind := Link_Kind((h >> 4) %% 5)
	w, d: i32
	switch kind {
	case .Stairs:
		w, d = 2 + i32((h >> 8) & 1), 3 + i32((h >> 9) & 3)
	case .Switchback:
		// Even lane counts keep the U divider exactly on a cell boundary.
		w, d = 4, 4 + 2 * i32((h >> 8) & 1)
	case .Ramp:
		w, d = 3, 4 + i32((h >> 9) & 3)
	case .Drop:
		w, d = 3 + i32((h >> 8) & 7), 3 + i32((h >> 12) & 7)
	case .Slide:
		w, d = 2 + i32((h >> 8) & 1), 3 + i32((h >> 9) & 3)
	}
	// Keep ordinary link footprints compact; drops may expand into atriums up to 10x10.
	w = min(w, min(r.w - 8, 10))
	d = min(d, min(r.h - 8, 10))
	if w < 2 || d < 2 do return
	// Adjacent link pairs occupy opposite sides of the region. This guarantees
	// that lower/upper pair footprints agree even though adjacent pairs coexist.
	span_z := max(r.h - d - 6, 1)
	z := r.z0 + 3 + i32((h >> 20) % u32(span_z))
	x: i32
	if pair_floor %% 2 == 0 {
		x_lo, x_hi := r.x0 + 3, r.x0 + r.w / 2 - w - 2
		span_x := max(x_hi - x_lo + 1, 1)
		x = x_lo + i32((h >> 16) % u32(span_x))
	} else {
		x_lo, x_hi := r.x0 + r.w / 2 + 2, r.x0 + r.w - w - 3
		span_x := max(x_hi - x_lo + 1, 1)
		x = x_lo + i32((h >> 16) % u32(span_x))
	}
	if abs(x + w / 2) <= SPAWN_CLEAR + 4 && abs(z + d / 2) <= SPAWN_CLEAR + 4 do return
	if !link_rect_free(r, x, z, w, d) do return
	entry := u8((h >> 24) & 3)
	opening_axis := w if entry < 2 else d
	opening_width := 1 + i32((h >> 27) & 1)
	opening_offset: i32
	if kind == .Switchback {
		// The two stair flights return to the same side; leave a broad shared
		// opening for both lanes instead of a single narrow doorway.
		opening_width = opening_axis
		opening_offset = 0
	} else {
		opening_width = min(opening_width, opening_axis)
		opening_offset = i32((h >> 29) % u32(max(opening_axis - opening_width + 1, 1)))
	}
	// direction is the ascending direction; entry is normally its opposite.
	direction := entry ~ 1
	l := Vertical_Link {
		x              = x,
		z              = z,
		w              = w,
		d              = d,
		lower_floor    = pair_floor,
		kind           = kind,
		direction      = direction,
		entry_side     = entry,
		opening_width  = opening_width,
		opening_offset = opening_offset,
	}
	id := i16(r.link_count)
	r.links[r.link_count] = l
	r.link_count += 1
	link_clear_rect(r, l, role, id)
}

generate_region :: proc(r: ^Region, ri, rj: i32) {
	rng := Rng {
		s = lh(ri * 4099 + 17, rj * 8191 + 23) | 1,
	}
	for _ in 0 ..< 4 do rng_u32(&rng)
	punch_border(r, &rng, true)
	punch_border(r, &rng, false)
	bsp(r, &rng, r.x0, r.z0, r.w, r.h)
	// Each region reserves deterministic link footprints for the floor below
	// and above. The same pair seed yields identical rectangles on both floors.
	place_vertical_link(r, ri, rj, current_floor - 1, .Upper)
	place_vertical_link(r, ri, rj, current_floor, .Lower)
}

// ───────────────────────── queries ─────────────────────────

edge_at :: proc(x, z: i32, north: bool) -> u8 {
	if abs(x) <= SPAWN_CLEAR && abs(z) <= SPAWN_CLEAR do return EDGE_OPEN
	r := region_at(x, z)
	i := region_idx(r, x, z)
	return r.edge_n[i] if north else r.edge_w[i]
}
has_wall :: proc(x, z: i32, north: bool) -> bool {return edge_at(x, z, north) != EDGE_OPEN}
has_door :: proc(x, z: i32, north: bool) -> bool {return edge_at(x, z, north) == EDGE_DOOR}

pillar_at :: proc(wx, wz: i32) -> bool {
	if abs(wx) <= SPAWN_CLEAR && abs(wz) <= SPAWN_CLEAR do return false
	r := region_at(wx, wz)
	return (r.cell_flg[region_idx(r, wx, wz)] & CELL_PILLAR) != 0
}
pool_at :: proc(wx, wz: i32) -> bool {
	if abs(wx) <= SPAWN_CLEAR && abs(wz) <= SPAWN_CLEAR do return false
	r := region_at(wx, wz)
	return (r.cell_flg[region_idx(r, wx, wz)] & CELL_POOL) != 0
}

// Compatibility queries used by the dev map and old debug overlays.
stair_at :: proc(wx, wz: i32) -> bool {
	l, ok, _ := vertical_link_at(wx, wz)
	return ok && (l.kind == .Stairs || l.kind == .Switchback || l.kind == .Ramp)
}
hole_at :: proc(wx, wz: i32) -> bool {
	l, ok, _ := vertical_link_at(wx, wz)
	return ok && (l.kind == .Drop || l.kind == .Slide)
}
stair_dir_at :: proc(wx, wz: i32) -> u8 {
	l, ok, _ := vertical_link_at(wx, wz)
	return l.direction if ok else 0
}

floor_level :: proc(x, z: i32) -> i8 {
	if abs(x) <= SPAWN_CLEAR && abs(z) <= SPAWN_CLEAR do return 0
	r := region_at(x, z)
	return r.cell_floor[region_idx(r, x, z)]
}

valley_depth :: proc(x, z: i32) -> f32 {
	distance_from_spawn := math.sqrt(f32(x) * f32(x) + f32(z) * f32(z))
	if distance_from_spawn <= 20 do return 0
	spawn_fade := clamp((distance_from_spawn - 20) / 20, 0, 1)
	spawn_fade = spawn_fade * spawn_fade * (3 - 2 * spawn_fade)
	info := biome_info(x, z)
	biome_weight: f32 = 0
	if info.b == .Warehouse || info.b == .Parking_Garage || info.b == .Sub_Basement {
		biome_weight += info.w
	}
	if info.b2 == .Warehouse || info.b2 == .Parking_Garage || info.b2 == .Sub_Basement {
		biome_weight += 1 - info.w
	}
	if biome_weight <= 0 do return 0
	// Broad, smoothly blended bowls. Thresholding creates separated valley patches.
	n := bfbm_for_floor(f32(x) * 0.035, f32(z) * 0.035, 811, current_floor, current_level)
	t := clamp((n - 0.56) / 0.34, 0, 1)
	t = t * t * (3 - 2 * t)
	// Depth is low-frequency continuous noise too; hashing 12-cell blocks here
	// would introduce visible cliffs along the valley floor.
	depth_noise := bfbm_for_floor(
		f32(x) * 0.012,
		f32(z) * 0.012,
		813,
		current_floor,
		current_level,
	)
	depth := 1.0 + 2.0 * depth_noise
	return -depth * t * biome_weight * spawn_fade
}

floor_h :: proc(x, z: i32) -> f32 {
	if abs(x) <= SPAWN_CLEAR && abs(z) <= SPAWN_CLEAR do return 0
	r := region_at(x, z)
	i := region_idx(r, x, z)
	if r.cell_flg[i] & CELL_LINK != 0 do return 0
	return f32(r.cell_floor[i]) * FLOOR_STEP + valley_depth(x, z)
}

floor_corner_h :: proc(cx, cz: i32) -> f32 {
	return(
		(floor_h(cx - 1, cz - 1) + floor_h(cx, cz - 1) + floor_h(cx - 1, cz) + floor_h(cx, cz)) *
		0.25 \
	)
}

link_progress :: proc(l: Vertical_Link, wx, wz: f32) -> f32 {
	x0, z0 := f32(l.x) * CELL, f32(l.z) * CELL
	lx := clamp((wx - x0) / (f32(l.w) * CELL), 0, 1)
	lz := clamp((wz - z0) / (f32(l.d) * CELL), 0, 1)
	if l.kind == .Switchback {
		// Two parallel lanes joined at their far end create a U-shaped run.
		across, along := lx, 1 - lz
		if l.direction == 1 {along = lz}
		if l.direction == 2 {across, along = 1 - lz, lx}
		if l.direction == 3 {across, along = lz, 1 - lx}
		run := l.d if l.direction < 2 else l.w
		turn_start := 1.0 - 1.0 / f32(max(run, 2))
		if along >= turn_start do return 0.5
		u := clamp(along / turn_start, 0, 1)
		if across < 0.5 {return u * 0.5}
		return 0.5 + (1 - u) * 0.5
	}
	switch l.direction {
	case 0:
		return 1 - lz
	case 1:
		return lz
	case 2:
		return lx
	case 3:
		return 1 - lx
	}
	return 0
}

link_surface_local :: proc(l: Vertical_Link, role: Link_Role, wx, wz: f32) -> f32 {
	if role == .Lower {
		if l.kind == .Drop || l.kind == .Slide do return 0
		t := link_progress(l, wx, wz)
		if l.kind == .Stairs || l.kind == .Switchback {
			run := l.d if l.direction < 2 else l.w
			if l.kind == .Switchback do run *= 2
			steps := max(1, run * STAIR_STEPS)
			t = f32(i32(math.floor(t * f32(steps)))) / f32(steps)
		}
		return FLOOR_SPACING * t
	}
	if role != .Upper do return 0
	if l.kind == .Drop do return -FLOOR_SPACING
	t := link_progress(l, wx, wz)
	if l.kind == .Stairs || l.kind == .Switchback {
		run := l.d if l.direction < 2 else l.w
		if l.kind == .Switchback do run *= 2
		steps := max(1, run * STAIR_STEPS)
		t = f32(i32(math.floor(t * f32(steps)))) / f32(steps)
	}
	return FLOOR_SPACING * (t - 1)
}

vertical_link_at :: proc(wx, wz: i32) -> (link: Vertical_Link, ok: bool, role: Link_Role) {
	r := region_at(wx, wz)
	i := region_idx(r, wx, wz)
	id := r.cell_link_id[i]
	if id < 0 || int(id) >= r.link_count do return {}, false, .None
	return r.links[id], true, Link_Role(r.cell_link_role[i])
}

link_local_feet :: proc(wx, wz: f32) -> (bool, Vertical_Link, Link_Role, f32) {
	cx, cz := i32(math.floor(wx / CELL)), i32(math.floor(wz / CELL))
	l, ok, role := vertical_link_at(cx, cz)
	if !ok do return false, {}, .None, 0
	return true, l, role, link_surface_local(l, role, wx, wz)
}

ground_local_at :: proc(wx, wz: f32) -> f32 {
	cx := i32(math.floor(wx / CELL))
	cz := i32(math.floor(wz / CELL))
	if on_link, _, _, h := link_local_feet(wx, wz); on_link {
		return h
	}
	if abs(cx) <= SPAWN_CLEAR && abs(cz) <= SPAWN_CLEAR do return 0
	// Bilinear interpolation of the shared corner heightfield keeps valleys smooth.
	x0, z0 := f32(cx) * CELL, f32(cz) * CELL
	u := clamp((wx - x0) / CELL, 0, 1)
	v := clamp((wz - z0) / CELL, 0, 1)
	nw := floor_corner_h(cx, cz)
	ne := floor_corner_h(cx + 1, cz)
	se := floor_corner_h(cx + 1, cz + 1)
	sw := floor_corner_h(cx, cz + 1)
	return bilerp4(nw, ne, se, sw, u, v)
}

ground_at :: proc(wx, wz: f32) -> f32 {
	return floor_world_offset(current_floor) + ground_local_at(wx, wz)
}

// ───────────────────────── lights ─────────────────────────

LIGHT_SPACING := [Biome_Type][2]i32 {
	.Mono_Yellow       = {2, 2},
	.Fluorescent_White = {2, 2},
	.Poolrooms         = {3, 3},
	.Concrete_Maze     = {3, 2},
	.Parking_Garage    = {2, 3},
	.Red_Rooms         = {3, 3},
	.Warehouse         = {4, 4},
	.Hotel_Corridor    = {3, 2},
	.Arcade_Night      = {2, 3},
	.Sub_Basement      = {3, 3},
}

light_power :: proc(x, z: i32) -> f32 {
	if _, has_link, _ := vertical_link_at(x, z); has_link do return 0
	sp := LIGHT_SPACING[biome_at(x, z)]
	if x %% sp.x != 0 || z %% sp.y != 0 do return 0
	if pillar_at(x, z) do return 0
	r := (raw_hash(x, z + 3001) >> 8) & 0xFF
	if r < 20 do return 0
	if r < 70 do return 0.5
	return 1
}

light_color :: proc(x, z: i32) -> rl.Color {
	b := biome_at(x, z)
	#partial switch b {
	case .Red_Rooms:
		return rl.Color{173, 30, 30, 255}
	case .Poolrooms:
		return rl.Color{180, 240, 255, 255}
	case .Arcade_Night:
		return rl.Color{255, 100, 255, 255}
	}
	return rl.Color{255, 245, 220, 255}
}
