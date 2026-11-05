package main

import rl "vendor:raylib"

// Per-chunk light cache: lights, wall spans, doors and ceilings for the 3 resident storeys.

// Baked vertex lighting.
//
// Lights sit on a global lattice (see biome.odin:light_power). For each chunk we
// snapshot the lights and the solid wall edges around it, then every emitted
// vertex sums only the lights it can actually see. light_blocked walks the cell
// grid with a DDA and tests the actual vertical wall span and doorway aperture.
LIGHT_PAD :: 4

LIGHT_GRID_N :: CHUNK_SIZE + 2 * LIGHT_PAD

LIGHT_FLOOR_PAD :: 1

LIGHT_FLOOR_COUNT :: 3

Door_Opening :: struct {
	min, max: f32,
	top:      f32,
	valid:    bool,
}

Light_Grid :: struct {
	ox, oz:      i32,
	top:         [LIGHT_FLOOR_COUNT][LIGHT_GRID_N][LIGHT_GRID_N]f32,
	power:       [LIGHT_FLOOR_COUNT][LIGHT_GRID_N][LIGHT_GRID_N]f32,
	color:       [LIGHT_FLOOR_COUNT][LIGHT_GRID_N][LIGHT_GRID_N][3]f32,

	// Wall/door/ceiling data is cached independently for each neighboring floor.
	wall_w:      [LIGHT_FLOOR_COUNT][LIGHT_GRID_N][LIGHT_GRID_N]f32,
	wall_n:      [LIGHT_FLOOR_COUNT][LIGHT_GRID_N][LIGHT_GRID_N]f32,
	wall_w_base: [LIGHT_FLOOR_COUNT][LIGHT_GRID_N][LIGHT_GRID_N]f32,
	wall_n_base: [LIGHT_FLOOR_COUNT][LIGHT_GRID_N][LIGHT_GRID_N]f32,
	ceil:        [LIGHT_FLOOR_COUNT][LIGHT_GRID_N][LIGHT_GRID_N]f32,

	door_w_min:  [LIGHT_FLOOR_COUNT][LIGHT_GRID_N][LIGHT_GRID_N]f32,
	door_w_max:  [LIGHT_FLOOR_COUNT][LIGHT_GRID_N][LIGHT_GRID_N]f32,
	door_w_top:  [LIGHT_FLOOR_COUNT][LIGHT_GRID_N][LIGHT_GRID_N]f32,
	door_w_valid:[LIGHT_FLOOR_COUNT][LIGHT_GRID_N][LIGHT_GRID_N]bool,
	door_n_min:  [LIGHT_FLOOR_COUNT][LIGHT_GRID_N][LIGHT_GRID_N]f32,
	door_n_max:  [LIGHT_FLOOR_COUNT][LIGHT_GRID_N][LIGHT_GRID_N]f32,
	door_n_top:  [LIGHT_FLOOR_COUNT][LIGHT_GRID_N][LIGHT_GRID_N]f32,
	door_n_valid:[LIGHT_FLOOR_COUNT][LIGHT_GRID_N][LIGHT_GRID_N]bool,
}

light_grid: Light_Grid

// Begin preparing the cache for one chunk. The cache is populated incrementally
// by light_grid_fill_cell so chunk generation can yield between frames.
light_grid_begin :: proc(c: Chunk_Coord) {
	light_grid.ox = c.x * CHUNK_SIZE - LIGHT_PAD
	light_grid.oz = c.y * CHUNK_SIZE - LIGHT_PAD
}

// Light-only wall bases include the below-floor portions of upper link walls.
// The geometry and lighting caches both use the same link-side profile.
light_wall_base_w :: proc(x, z: i32) -> f32 {
	base := west_wall_base(x, z)
	if l, ok, role := vertical_link_at(x, z); ok && role == .Upper && x == l.x {
		base = min(base, link_wall_bottom(l, role, 3, x, z))
	}
	if l, ok, role := vertical_link_at(x - 1, z); ok && role == .Upper && x == l.x + l.w {
		base = min(base, link_wall_bottom(l, role, 2, x - 1, z))
	}
	return base
}

light_wall_base_n :: proc(x, z: i32) -> f32 {
	base := north_wall_base(x, z)
	if l, ok, role := vertical_link_at(x, z); ok && role == .Upper && z == l.z {
		base = min(base, link_wall_bottom(l, role, 0, x, z))
	}
	if l, ok, role := vertical_link_at(x, z - 1); ok && role == .Upper && z == l.z + l.d {
		base = min(base, link_wall_bottom(l, role, 1, x, z - 1))
	}
	return base
}

// Populate one cache cell at (i, j) for the current and adjacent storeys.
light_grid_fill_cell :: proc(i, j: int) {
	g := &light_grid
	wx := g.ox + i32(i)
	wz := g.oz + i32(j)
	build_floor, build_theme := current_floor, current_level

	for layer in 0 ..< LIGHT_FLOOR_COUNT {
		source_floor := build_floor + i32(layer) - LIGHT_FLOOR_PAD
		if source_floor < 0 || source_floor >= WORLD_FLOOR_COUNT {
			g.power[layer][j][i] = 0
			g.top[layer][j][i] = 0
			g.color[layer][j][i] = {}
			g.wall_w[layer][j][i] = 0
			g.wall_n[layer][j][i] = 0
			g.wall_w_base[layer][j][i] = 0
			g.wall_n_base[layer][j][i] = 0
			g.ceil[layer][j][i] = 1e9
			g.door_w_valid[layer][j][i] = false
			g.door_n_valid[layer][j][i] = false
			continue
		}

		current_floor, current_level = source_floor, source_floor
		y_offset := floor_world_offset(source_floor) - floor_world_offset(build_floor)

		p := light_power(wx, wz)
		g.power[layer][j][i] = p
		if p > 0 {
			g.top[layer][j][i] = y_offset + ceil_h(wx, wz) - 0.05
			lc := rl.ColorNormalize(light_color(wx, wz))
			g.color[layer][j][i] = {lc.x, lc.y, lc.z}
		} else {
			g.top[layer][j][i] = 0
			g.color[layer][j][i] = {}
		}

		if has_wall(wx, wz, false) {
			g.wall_w[layer][j][i] = y_offset + west_wall_height(wx, wz)
			g.wall_w_base[layer][j][i] = y_offset + light_wall_base_w(wx, wz)
			if has_door(wx, wz, false) {
				l, r := door_span(wx, wz, false)
				g.door_w_min[layer][j][i] = f32(wz) * CELL + l
				g.door_w_max[layer][j][i] = f32(wz) * CELL + r
				g.door_w_top[layer][j][i] = y_offset + door_top(wx, wz, false, west_wall_height(wx, wz))
				g.door_w_valid[layer][j][i] = true
			} else {
				g.door_w_min[layer][j][i] = 0
				g.door_w_max[layer][j][i] = 0
				g.door_w_top[layer][j][i] = 0
				g.door_w_valid[layer][j][i] = false
			}
		} else {
			g.wall_w[layer][j][i] = 0
			g.wall_w_base[layer][j][i] = 0
			g.door_w_min[layer][j][i] = 0
			g.door_w_max[layer][j][i] = 0
			g.door_w_top[layer][j][i] = 0
			g.door_w_valid[layer][j][i] = false
		}

		if has_wall(wx, wz, true) {
			g.wall_n[layer][j][i] = y_offset + north_wall_height(wx, wz)
			g.wall_n_base[layer][j][i] = y_offset + light_wall_base_n(wx, wz)
			if has_door(wx, wz, true) {
				l, r := door_span(wx, wz, true)
				g.door_n_min[layer][j][i] = f32(wx) * CELL + l
				g.door_n_max[layer][j][i] = f32(wx) * CELL + r
				g.door_n_top[layer][j][i] = y_offset + door_top(wx, wz, true, north_wall_height(wx, wz))
				g.door_n_valid[layer][j][i] = true
			} else {
				g.door_n_min[layer][j][i] = 0
				g.door_n_max[layer][j][i] = 0
				g.door_n_top[layer][j][i] = 0
				g.door_n_valid[layer][j][i] = false
			}
		} else {
			g.wall_n[layer][j][i] = 0
			g.wall_n_base[layer][j][i] = 0
			g.door_n_min[layer][j][i] = 0
			g.door_n_max[layer][j][i] = 0
			g.door_n_top[layer][j][i] = 0
			g.door_n_valid[layer][j][i] = false
		}

		if _, has_link, link_role := vertical_link_at(wx, wz); has_link && link_role == .Lower {
			g.ceil[layer][j][i] = y_offset + 1e9
		} else {
			g.ceil[layer][j][i] = y_offset + ceil_h(wx, wz)
		}
	}
	current_floor, current_level = build_floor, build_theme
}

// Synchronous convenience wrapper for callers that still need a complete cache.
light_grid_fill :: proc(c: Chunk_Coord) {
	light_grid_begin(c)
	for j in 0 ..< LIGHT_GRID_N {
		for i in 0 ..< LIGHT_GRID_N {
			light_grid_fill_cell(i, j)
		}
	}
}

// Door/wall accessors for one of the cached physical floor layers.
edge_door_w :: proc(x, z: i32, layer: int) -> Door_Opening {
	i, j := x - light_grid.ox, z - light_grid.oz
	if i < 0 || i >= LIGHT_GRID_N || j < 0 || j >= LIGHT_GRID_N || layer < 0 || layer >= LIGHT_FLOOR_COUNT {
		return Door_Opening{}
	}
	return Door_Opening {
		min = light_grid.door_w_min[layer][j][i],
		max = light_grid.door_w_max[layer][j][i],
		top = light_grid.door_w_top[layer][j][i],
		valid = light_grid.door_w_valid[layer][j][i],
	}
}

edge_door_n :: proc(x, z: i32, layer: int) -> Door_Opening {
	i, j := x - light_grid.ox, z - light_grid.oz
	if i < 0 || i >= LIGHT_GRID_N || j < 0 || j >= LIGHT_GRID_N || layer < 0 || layer >= LIGHT_FLOOR_COUNT {
		return Door_Opening{}
	}
	return Door_Opening {
		min = light_grid.door_n_min[layer][j][i],
		max = light_grid.door_n_max[layer][j][i],
		top = light_grid.door_n_top[layer][j][i],
		valid = light_grid.door_n_valid[layer][j][i],
	}
}

edge_top_w :: proc(x, z: i32, layer: int) -> f32 {
	i, j := x - light_grid.ox, z - light_grid.oz
	if i < 0 || i >= LIGHT_GRID_N || j < 0 || j >= LIGHT_GRID_N || layer < 0 || layer >= LIGHT_FLOOR_COUNT do return 1e9
	return light_grid.wall_w[layer][j][i]
}

edge_top_n :: proc(x, z: i32, layer: int) -> f32 {
	i, j := x - light_grid.ox, z - light_grid.oz
	if i < 0 || i >= LIGHT_GRID_N || j < 0 || j >= LIGHT_GRID_N || layer < 0 || layer >= LIGHT_FLOOR_COUNT do return 1e9
	return light_grid.wall_n[layer][j][i]
}

ceil_top :: proc(x, z: i32, layer: int) -> f32 {
	i, j := x - light_grid.ox, z - light_grid.oz
	if i < 0 || i >= LIGHT_GRID_N || j < 0 || j >= LIGHT_GRID_N || layer < 0 || layer >= LIGHT_FLOOR_COUNT do return 1e9
	return light_grid.ceil[layer][j][i]
}

edge_base_w :: proc(x, z: i32, layer: int) -> f32 {
	i, j := x - light_grid.ox, z - light_grid.oz
	if i < 0 || i >= LIGHT_GRID_N || j < 0 || j >= LIGHT_GRID_N || layer < 0 || layer >= LIGHT_FLOOR_COUNT do return -1e9
	return light_grid.wall_w_base[layer][j][i]
}

edge_base_n :: proc(x, z: i32, layer: int) -> f32 {
	i, j := x - light_grid.ox, z - light_grid.oz
	if i < 0 || i >= LIGHT_GRID_N || j < 0 || j >= LIGHT_GRID_N || layer < 0 || layer >= LIGHT_FLOOR_COUNT do return -1e9
	return light_grid.wall_n_base[layer][j][i]
}
