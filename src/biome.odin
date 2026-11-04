package main

import "core:fmt"
import "core:math"
import rl "vendor:raylib"

CELL :: 4.0
WALL_H :: 3.0 // legacy default; actual ceiling height is per-biome (WALL_HEIGHT)
WALL_T :: 0.6 // wall thickness
CHUNK_SIZE :: 16
CHUNK_W :: CHUNK_SIZE * CELL
VIEW_RADIUS :: 1 // 3x3 chunks

Biome_Type :: enum {
	Mono_Yellow, // classic level 0: damp mono-yellow
	Fluorescent_White, // sterile white service corridors
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

// change at startup (e.g. from time) for a fresh layout every run
WORLD_SEED: u32 = 1337

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

// ceiling height per biome. Walls rise to the TALLEST neighbouring ceiling so
// height changes never leave gaps (see build_chunk).
WALL_HEIGHT := [Biome_Type]f32 {
	.Mono_Yellow       = 3.0,
	.Fluorescent_White = 3.2,
	.Poolrooms         = 4.5,
	.Concrete_Maze     = 3.0,
	.Parking_Garage    = 4.2,
	.Red_Rooms         = 2.8,
	.Warehouse         = 5.0,
	.Hotel_Corridor    = 2.7,
	.Arcade_Night      = 3.0,
	.Sub_Basement      = 2.4,
}

raw_hash :: proc(x, y: i32) -> u32 {
	h: u32 = u32(x) * 374761393 + u32(y) * 668265263
	h = (h ~ (h >> 13)) * 1274126177
	return h ~ (h >> 16)
}

DOOR_MIN_W :: 1.4
DOOR_MAX_W :: CELL - 0.6
DOOR_MARGIN :: 0.3 // keep clear of the perpendicular walls at the corners

// how many of the cell's 4 edges are walls
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
	w := DOOR_MIN_W + t * t * (DOOR_MAX_W - DOOR_MIN_W) // squared: mostly narrow, some wide
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

// ───────────────────────── biome field ─────────────────────────

BIOME_SCALE :: 60.0 // cells per noise lattice step, so regions are ~40-80 wide
BIOME_CONTRAST :: 2.0
BLEND_MARGIN :: 0.35 // wider = softer borders

Biome_Info :: struct {
	b, b2: Biome_Type, // nearest and second-nearest biome
	w:     f32, // weight of b, 1.0 deep inside, 0.5 exactly on a border
}

// where each biome lives in (a, b) noise space. Yellow is the middle, the rest form a ring.
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

// positive = bigger share of the map
BIOME_BIAS := [Biome_Type]f32 {
	.Mono_Yellow       = 0.20,
	.Fluorescent_White = 0.0,
	.Poolrooms         = 0.0,
	.Concrete_Maze     = 0.0,
	.Parking_Garage    = 0.0,
	.Red_Rooms         = 0.0,
	.Warehouse         = 0.0,
	.Hotel_Corridor    = 0.0,
	.Arcade_Night      = 0.0,
	.Sub_Basement      = 0.0,
}

hash01 :: proc(x, y, seed: i32) -> f32 {
	return f32(raw_hash(x + seed * 7919, y - seed * 104729 + i32(WORLD_SEED)) >> 8) / 16777216.0
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

	// domain warp bends the borders into organic blobs
	wx := px + (bnoise(px * 0.022, pz * 0.022, 91) - 0.5) * 36
	wz := pz + (bnoise(px * 0.022 + 40.1, pz * 0.022 - 17.7, 92) - 0.5) * 36

	fa := bfbm(wx / BIOME_SCALE, wz / BIOME_SCALE, 11)
	fb := bfbm(wx / BIOME_SCALE + 31.7, wz / BIOME_SCALE - 12.9, 13)
	fa = clamp(0.5 + (fa - 0.5) * BIOME_CONTRAST, 0, 1)
	fb = clamp(0.5 + (fb - 0.5) * BIOME_CONTRAST, 0, 1)

	// keep the spawn area classic yellow
	spawn := clamp(1 - math.sqrt(px * px + pz * pz) / 40, 0, 1)

	best, second: f32 = 1e9, 1e9
	bi, si := Biome_Type.Mono_Yellow, Biome_Type.Mono_Yellow
	for t in Biome_Type {
		p := BIOME_PROTO[t]
		da, db := fa - p[0], fb - p[1]
		d := math.sqrt(da * da + db * db) - BIOME_BIAS[t]
		if t == .Mono_Yellow do d -= spawn * 0.6
		if d < best {
			second, si = best, bi
			best, bi = d, t
		} else if d < second {
			second, si = d, t
		}
	}

	m := clamp((second - best) / BLEND_MARGIN, 0, 1)
	m = m * m * (3 - 2 * m)
	return Biome_Info{b = bi, b2 = si, w = 0.5 + 0.5 * m}
}

// direct-mapped cache. Chunk building is single-threaded, so a global is fine.
BIOME_CACHE_N :: 16384
Biome_Cache_Entry :: struct {
	x, z:  i32,
	valid: bool,
	info:  Biome_Info,
}
biome_cache: [BIOME_CACHE_N]Biome_Cache_Entry

biome_info :: proc(x, z: i32) -> Biome_Info {
	e := &biome_cache[raw_hash(x, z) & (BIOME_CACHE_N - 1)]
	if e.valid && e.x == x && e.z == z do return e.info
	e.x = x
	e.z = z
	e.valid = true
	e.info = biome_info_raw(x, z)
	return e.info
}

biome_at :: proc(x, z: i32) -> Biome_Type {
	return biome_info(x, z).b
}

// ceiling height of a cell, blended across biome borders
ceil_h :: proc(x, z: i32) -> f32 {
	i := biome_info(x, z)
	return WALL_HEIGHT[i.b] * i.w + WALL_HEIGHT[i.b2] * (1 - i.w)
}

// height of a ceiling corner, shared by the 4 cells around it so the ceiling is watertight
corner_h :: proc(cx, cz: i32) -> f32 {
	return(
		(ceil_h(cx - 1, cz - 1) + ceil_h(cx, cz - 1) + ceil_h(cx - 1, cz) + ceil_h(cx, cz)) *
		0.25 \
	)
}

// ───────────────────────── wall lattice ─────────────────────────

ROW_PITCH :: 3
ROW_JIT :: 2 // High jitter creates chaotic room heights (2 to 5 cells)
COL_PITCH :: 2
COL_JIT :: 2 // High jitter creates chaotic room widths (2 to 5 cells)
CORR_WIN :: 12
GAP_CHANCE :: 120 // Slightly fewer gaps to keep it tight and maze-like

// out of 256: chance that a room side is solid
SIDE_SOLID := [Biome_Type]u32 {
	.Mono_Yellow       = 215,
	.Fluorescent_White = 180,
	.Poolrooms         = 90,
	.Concrete_Maze     = 245,
	.Parking_Garage    = 60,
	.Red_Rooms         = 215,
	.Warehouse         = 70,
	.Hotel_Corridor    = 225,
	.Arcade_Night      = 195,
	.Sub_Basement      = 220,
}

// out of 256: chance that a 20-cell stretch of a row line becomes a corridor
CORRIDOR_CHANCE := [Biome_Type]u32 {
	.Mono_Yellow       = 70,
	.Fluorescent_White = 110,
	.Poolrooms         = 20,
	.Concrete_Maze     = 120,
	.Parking_Garage    = 10,
	.Red_Rooms         = 90,
	.Warehouse         = 15,
	.Hotel_Corridor    = 210,
	.Arcade_Night      = 80,
	.Sub_Basement      = 100,
}

// out of 256: chance that a sealed side gets a door
DOOR_CHANCE := [Biome_Type]u32 {
	.Mono_Yellow       = 150,
	.Fluorescent_White = 170,
	.Poolrooms         = 90,
	.Concrete_Maze     = 80,
	.Parking_Garage    = 40,
	.Red_Rooms         = 140,
	.Warehouse         = 60,
	.Hotel_Corridor    = 220,
	.Arcade_Night      = 140,
	.Sub_Basement      = 120,
}

fdiv :: proc(a, b: i32) -> i32 {
	return (a - a %% b) / b
}

// seeded hash for the lattice
lh :: proc(a, b: i32) -> u32 {
	return raw_hash(a, b ~ i32(WORLD_SEED * 2654435761))
}

row_line :: proc(k: i32) -> i32 {
	return k * ROW_PITCH + i32(lh(k, 4001) % ROW_JIT)
}

// which row contains cell index v
row_of :: proc(v: i32) -> i32 {
	k := fdiv(v, ROW_PITCH)
	if v < row_line(k) do k -= 1
	return k
}

// column lines are jittered per row, so rooms are staggered like bricks
col_line :: proc(k, i: i32) -> i32 {
	return i * COL_PITCH + i32(lh(i, k + 5003) % COL_JIT)
}

col_of :: proc(k, u: i32) -> i32 {
	i := fdiv(u, COL_PITCH)
	if u < col_line(k, i) do i -= 1
	return i
}

// 48-cell regions flip the lattice's axes, so corridors run both ways
lat_swap :: proc(x, z: i32) -> bool {
	return lh(fdiv(x, 48), fdiv(z, 48) + 6007) & 1 == 1
}

// biome sample in lattice coordinates (u, v) = (x, z), or (z, x) when swapped
lat_biome :: proc(u, v: i32, swap: bool) -> Biome_Info {
	if swap do return biome_info(v, u)
	return biome_info(u, v)
}

corridor_on :: proc(k, u, vline: i32, swap: bool) -> bool {
	win := fdiv(u, CORR_WIN)
	b := lat_biome(win * CORR_WIN, vline, swap).b
	return (lh(k * 31 + win, 8101) & 0xFF) < CORRIDOR_CHANCE[b]
}

side_solid :: proc(bi: Biome_Info) -> f32 {
	return f32(SIDE_SOLID[bi.b]) * bi.w + f32(SIDE_SOLID[bi.b2]) * (1 - bi.w)
}

// the wide opening of a side, if it has one: cells [g0, g1)
side_gap :: proc(h: u32, s0, s1: i32) -> (g0, g1: i32, ok: bool) {
	if (h >> 8) & 0xFF >= GAP_CHANCE do return
	n := s1 - s0
	if n < 4 do return // Safety check preventing panics/illegal instruction on tiny cells
	g := min(1 + i32((h >> 16) & 1), n - 2)
	g0 = s0 + 1 + i32((h >> 18) % u32(max(1, n - g - 1)))
	return g0, g0 + g, true
}

// one room side: a stretch of wall between two junctions
Lat_Side :: struct {
	wall:   bool, // wall present at this cell
	gap:    bool, // the side has a wide opening somewhere
	h:      u32, // stable hash for the whole side
	s0, s1: i32, // side extent along the wall, cells [s0, s1)
	bi:     Biome_Info,
}

// wall running along u, on line v, covering cell u
lat_row_wall :: proc(u, v: i32, swap: bool) -> (s: Lat_Side) {
	k := fdiv(v, ROW_PITCH)
	salt: i32 = 0
	if v != row_line(k) {
		// not a row line, but it can be a corridor's second wall one line below
		k = fdiv(v - 1, ROW_PITCH)
		if v - 1 != row_line(k) || !corridor_on(k, u, v - 1, swap) do return
		salt = 1
	}
	i := col_of(k, u)
	s.s0, s.s1 = col_line(k, i), col_line(k, i + 1)
	s.bi = lat_biome(s.s0, v, swap)
	s.h = lh(k * 977 + i, 6011 + salt)
	if f32(s.h & 0xFF) >= side_solid(s.bi) do return
	g0, g1, ok := side_gap(s.h, s.s0, s.s1)
	s.gap = ok
	s.wall = !(ok && u >= g0 && u < g1)
	return
}

// wall running along v, on line u, covering cell v
lat_col_wall :: proc(u, v: i32, swap: bool) -> (s: Lat_Side) {
	k := row_of(v)
	i := fdiv(u, COL_PITCH)
	if u != col_line(k, i) do return
	s.s0, s.s1 = row_line(k), row_line(k + 1)
	// the corridor strip must stay open end to end
	if v == s.s0 && corridor_on(k, u, s.s0, swap) do return
	s.bi = lat_biome(u, s.s0, swap)
	s.h = lh(k * 1013 + i, 7019)
	if f32(s.h & 0xFF) >= side_solid(s.bi) do return
	g0, g1, ok := side_gap(s.h, s.s0, s.s1)
	s.gap = ok
	s.wall = !(ok && v >= g0 && v < g1)
	return
}

// maps a world edge onto the lattice. c = the cell's coordinate along the wall.
lat_edge :: proc(x, z: i32, north: bool) -> (s: Lat_Side, c: i32) {
	if abs(x) <= 1 && abs(z) <= 1 do return // keep the spawn clear
	swap := lat_swap(x, z)
	u, v := x, z
	if swap do u, v = z, x
	if north != swap {
		return lat_row_wall(u, v, swap), u
	}
	return lat_col_wall(u, v, swap), v
}

has_wall :: proc(x, z: i32, north: bool) -> bool {
	s, _ := lat_edge(x, z, north)
	return s.wall
}

// Doors go on sealed sides only (sides with a wide gap are already open), at most one per
// side, never in the end cells, and long sides get them more often.
has_door :: proc(x, z: i32, north: bool) -> bool {
	s, c := lat_edge(x, z, north)
	if !s.wall || s.gap do return false

	n := s.s1 - s.s0
	if n <= 2 do return false
	dh := lh(i32(s.h >> 1), 9001 + s.s0)
	if c != s.s0 + 1 + i32(dh % u32(n - 2)) do return false

	a, b: [2]i32
	if north {
		a, b = {x, z - 1}, {x, z}
	} else {
		a, b = {x - 1, z}, {x, z}
	}
	if pillar_at(a.x, a.y) || pillar_at(b.x, b.y) do return false

	chance := f32(DOOR_CHANCE[s.bi.b]) * s.bi.w + f32(DOOR_CHANCE[s.bi.b2]) * (1 - s.bi.w)
	chance *= f32(n) / 5
	if cell_enclosure(a.x, a.y) + cell_enclosure(b.x, b.y) >= 5 {
		chance *= 1.5
	}
	return f32((dh >> 8) & 0xFF) < chance
}

// grids in garages and warehouses, sparse in the rest
pillar_at :: proc(wx, wz: i32) -> bool {
	if abs(wx) <= 1 && abs(wz) <= 1 do return false
	#partial switch biome_at(wx, wz) {
	case .Parking_Garage:
		return wx %% 3 == 1 && wz %% 3 == 1 && (raw_hash(wx, wz) >> 9) % 12 != 0
	case .Warehouse:
		return wx %% 4 == 2 && wz %% 4 == 2 && (raw_hash(wx, wz) >> 9) % 8 != 0
	case .Fluorescent_White, .Hotel_Corridor:
		return (raw_hash(wx, wz) >> 9) % 19 == 0
	}
	return false
}

// pool basins or water pits in the poolrooms biome
pool_at :: proc(wx, wz: i32) -> bool {
	if abs(wx) <= 1 && abs(wz) <= 1 do return false
	#partial switch biome_at(wx, wz) {
	case .Poolrooms:
		h := raw_hash(wx * 31, wz * 37)
		return (h >> 8) % 7 == 0 && cell_enclosure(wx, wz) <= 1
	}
	return false
}

// ceiling lights on a regular lattice, with dead and failing tubes
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

// 0 = no light here, 0.5 = failing, 1 = normal
light_power :: proc(x, z: i32) -> f32 {
	sp := LIGHT_SPACING[biome_at(x, z)]
	if x %% sp.x != 0 || z %% sp.y != 0 do return 0
	if pillar_at(x, z) do return 0 // don't bury a light inside a pillar
	r := (raw_hash(x, z + 3001) >> 8) & 0xFF
	if r < 20 do return 0
	if r < 70 do return 0.5
	return 1
}

// custom light color per biome (e.g., blood red in Red Rooms)
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

// call once at startup to see biome area shares (needs `import "core:fmt"`)
biome_debug_stats :: proc() {
	counts: [Biome_Type]int
	total := 0
	for z := i32(-400); z < 400; z += 4 {
		for x := i32(-400); x < 400; x += 4 {
			counts[biome_at(x, z)] += 1
			total += 1
		}
	}
	for b in Biome_Type {
		fmt.printf("%v: %.1f%%\n", b, f32(counts[b]) * 100 / f32(total))
	}
}
