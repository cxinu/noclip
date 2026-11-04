package main

import "core:fmt"
import "core:math"
import rl "vendor:raylib"

CELL :: 4.0
WALL_H :: 3.0
WALL_T :: 0.6
CHUNK_SIZE :: 16
CHUNK_W :: CHUNK_SIZE * CELL
VIEW_RADIUS :: 1

// Floor verticality (unchanged)
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
NUM_BIOMES :: 10

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

current_level: i32
level_dirty: bool

level_seed :: proc() -> u32 {return WORLD_SEED + u32(current_level) * 2246822519}

set_level :: proc(l: i32) {
	nl := ((l %% NUM_LEVELS) + NUM_LEVELS) %% NUM_LEVELS
	if nl == current_level do return
	current_level = nl
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

biome_info_raw :: proc(x, z: i32) -> Biome_Info {
	px, pz := f32(x) + 0.5, f32(z) + 0.5
	wx := px + (bnoise(px * 0.022, pz * 0.022, 91) - 0.5) * 36
	wz := pz + (bnoise(px * 0.022 + 40.1, pz * 0.022 - 17.7, 92) - 0.5) * 36
	fa := bfbm(wx / BIOME_SCALE, wz / BIOME_SCALE, 11)
	fb := bfbm(wx / BIOME_SCALE + 31.7, wz / BIOME_SCALE - 12.9, 13)
	fa = clamp(0.5 + (fa - 0.5) * BIOME_CONTRAST, 0, 1)
	fb = clamp(0.5 + (fb - 0.5) * BIOME_CONTRAST, 0, 1)

	lv := LEVELS[current_level]
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

BIOME_CACHE_N :: 16384
Biome_Cache_Entry :: struct {
	x, z, lvl: i32,
	valid:     bool,
	info:      Biome_Info,
}
biome_cache: [BIOME_CACHE_N]Biome_Cache_Entry

biome_info :: proc(x, z: i32) -> Biome_Info {
	lvl := current_level
	e := &biome_cache[raw_hash(x, z + lvl * 7717) & (BIOME_CACHE_N - 1)]
	if e.valid && e.x == x && e.z == z && e.lvl == lvl do return e.info
	e.x, e.z, e.lvl, e.valid = x, z, lvl, true
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
// NEW: transition flags
CELL_STAIR :: 4
CELL_HOLE :: 8

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
	level:                    i32,
	x0, z0, w, h:             i32,
	edge_w, edge_n, cell_flg: []u8,
	cell_floor:               []i8,
	cell_stair:               []u8, // NEW: 0=N, 1=S, 2=E, 3=W direction of ascent
}

regions: map[[3]i32]^Region
last_region: ^Region

fdiv :: proc(a, b: i32) -> i32 {return (a - a %% b) / b}
lh :: proc(a, b: i32) -> u32 {return raw_hash(a, b ~ i32(level_seed() * 2654435761))}

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
	if lr := last_region;
	   lr != nil &&
	   lr.level == current_level &&
	   x >= lr.x0 &&
	   x < lr.x0 + lr.w &&
	   z >= lr.z0 &&
	   z < lr.z0 + lr.h {
		return lr
	}
	i := reg_col_of(x)
	j := reg_row_of(i, z)
	key := [3]i32{current_level, i, j}
	if found, ok := regions[key]; ok {last_region = found; return found}
	r := new(Region)
	r.level = current_level
	r.x0 = reg_col_line(i)
	r.z0 = reg_row_line(i, j)
	r.w = reg_col_line(i + 1) - r.x0
	r.h = reg_row_line(i, j + 1) - r.z0
	n := int(r.w * r.h)
	r.edge_w = make([]u8, n)
	r.edge_n = make([]u8, n)
	r.cell_flg = make([]u8, n)
	r.cell_floor = make([]i8, n)
	r.cell_stair = make([]u8, n) // NEW
	generate_region(r, i, j)
	regions[key] = r
	last_region = r
	return r
}

regions_trim :: proc() {
	if len(regions) < 200 do return
	for _, r in regions {
		delete(r.edge_w)
		delete(r.edge_n)
		delete(r.cell_flg)
		delete(r.cell_floor)
		delete(r.cell_stair)
		free(r)
	}
	clear(&regions)
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

// ───────────────────────── NEW: transition architecture ─────────────────────────

// Seeded from WORLD_SEED only — the same (x, z) is a stairwell / hole on every
// floor. That's what makes vertical travel through the backrooms *feel* like a
// real building.
stair_site :: proc(ri, rj: i32) -> bool {
	return raw_hash(ri + i32(WORLD_SEED), rj - i32(WORLD_SEED * 7)) % 5 == 0
}
hole_site :: proc(ri, rj: i32) -> bool {
	return raw_hash(ri - i32(WORLD_SEED * 3), rj + i32(WORLD_SEED)) % 7 == 0
}
stair_dir_for :: proc(ri, rj: i32) -> u8 {
	return u8(raw_hash(ri + 91, rj + 17) & 3)
}

// Clear a 3×3 neighbourhood's walls so the stair/hole reads as a landing that
// merges into the surrounding BSP structure.
clear_walls_3x3 :: proc(r: ^Region, sx, sz: i32) {
	for dz in -1 ..= 1 do for dx in -1 ..= 1 {
		set_edge(r, true, sx + i32(dx), sz + i32(dz), EDGE_OPEN)
		set_edge(r, false, sx + i32(dx), sz + i32(dz), EDGE_OPEN)
	}
}

place_stairwell :: proc(r: ^Region, ri, rj: i32) {
	cx_rel := i32(4 + raw_hash(ri, rj + 5) % 8)
	cz_rel := i32(4 + raw_hash(ri + 3, rj) % 8)
	sx := r.x0 + cx_rel
	sz := r.z0 + cz_rel
	if sx >= r.x0 + r.w - 2 || sz >= r.z0 + r.h - 2 do return
	if abs(sx) <= SPAWN_CLEAR + 4 && abs(sz) <= SPAWN_CLEAR + 4 do return

	clear_walls_3x3(r, sx, sz)
	i := region_idx(r, sx, sz)
	r.cell_flg[i] &= ~u8(CELL_PILLAR | CELL_POOL)
	r.cell_flg[i] |= CELL_STAIR
	r.cell_floor[i] = 0
	r.cell_stair[i] = stair_dir_for(ri, rj)
}

place_hole :: proc(r: ^Region, ri, rj: i32) {
	cx_rel := i32(4 + raw_hash(ri + 11, rj) % 8)
	cz_rel := i32(4 + raw_hash(ri, rj + 13) % 8)
	sx := r.x0 + cx_rel
	sz := r.z0 + cz_rel
	if sx >= r.x0 + r.w - 2 || sz >= r.z0 + r.h - 2 do return
	if abs(sx) <= SPAWN_CLEAR + 4 && abs(sz) <= SPAWN_CLEAR + 4 do return
	// Never overlap a stairwell
	if r.cell_flg[region_idx(r, sx, sz)] & CELL_STAIR != 0 do return

	clear_walls_3x3(r, sx, sz)
	i := region_idx(r, sx, sz)
	r.cell_flg[i] &= ~u8(CELL_PILLAR | CELL_POOL)
	r.cell_flg[i] |= CELL_HOLE
	r.cell_floor[i] = 0
}

generate_region :: proc(r: ^Region, ri, rj: i32) {
	rng := Rng {
		s = lh(ri * 4099 + 17, rj * 8191 + 23) | 1,
	}
	for _ in 0 ..< 4 do rng_u32(&rng)
	punch_border(r, &rng, true)
	punch_border(r, &rng, false)
	bsp(r, &rng, r.x0, r.z0, r.w, r.h)
	// NEW: vertical connectivity
	if stair_site(ri, rj) do place_stairwell(r, ri, rj)
	if hole_site(ri, rj) do place_hole(r, ri, rj)
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

// ── NEW ──
stair_at :: proc(wx, wz: i32) -> bool {
	if abs(wx) <= SPAWN_CLEAR && abs(wz) <= SPAWN_CLEAR do return false
	r := region_at(wx, wz)
	return (r.cell_flg[region_idx(r, wx, wz)] & CELL_STAIR) != 0
}
hole_at :: proc(wx, wz: i32) -> bool {
	if abs(wx) <= SPAWN_CLEAR && abs(wz) <= SPAWN_CLEAR do return false
	r := region_at(wx, wz)
	return (r.cell_flg[region_idx(r, wx, wz)] & CELL_HOLE) != 0
}
stair_dir_at :: proc(wx, wz: i32) -> u8 {
	r := region_at(wx, wz)
	return r.cell_stair[region_idx(r, wx, wz)]
}

floor_level :: proc(x, z: i32) -> i8 {
	if abs(x) <= SPAWN_CLEAR && abs(z) <= SPAWN_CLEAR do return 0
	r := region_at(x, z)
	return r.cell_floor[region_idx(r, x, z)]
}
floor_h :: proc(x, z: i32) -> f32 {
	return f32(floor_level(x, z)) * FLOOR_STEP
}

// NEW: continuous ground at a world position, including stair ramps and shafts.
ground_at :: proc(wx, wz: f32) -> f32 {
	cx := i32(math.floor(wx / CELL))
	cz := i32(math.floor(wz / CELL))
	if abs(cx) <= SPAWN_CLEAR && abs(cz) <= SPAWN_CLEAR do return 0

	r := region_at(cx, cz)
	i := region_idx(r, cx, cz)
	flag := r.cell_flg[i]
	base := f32(r.cell_floor[i]) * FLOOR_STEP

	// Hole: return a very deep "ground" so the player falls
	if flag & CELL_HOLE != 0 do return base - HOLE_DEPTH - 5.0

	// Stair: ramp, snapped to the nearest discrete tread
	if flag & CELL_STAIR != 0 {
		d := r.cell_stair[i]
		lx := (wx - f32(cx) * CELL) / CELL
		lz := (wz - f32(cz) * CELL) / CELL
		t: f32
		switch d {
		case 0:
			t = 1 - lz // ascends north
		case 1:
			t = lz // ascends south
		case 2:
			t = lx // ascends east
		case 3:
			t = 1 - lx // ascends west
		}
		step_idx := clamp(i32(math.floor(t * f32(STAIR_STEPS))), 0, STAIR_STEPS - 1)
		return base + STAIR_RISE * (f32(step_idx) + 0.5) / f32(STAIR_STEPS)
	}

	return base
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

biome_debug_stats :: proc() {
	counts: [Biome_Type]int
	total := 0
	for z := i32(-400); z < 400; z += 4 do for x := i32(-400); x < 400; x += 4 {
		counts[biome_at(x, z)] += 1; total += 1
	}
	for b in Biome_Type do fmt.printf("%v: %.1f%%\n", b, f32(counts[b]) * 100 / f32(total))
}
