package main

import "core:math"

// Floor height field: valley terrain, steps, and ground sampling.

VALLEY_CACHE_N :: 16384

Valley_Cache_Entry :: struct {
	x, z, floor, theme: i32,
	valid:              bool,
	v:                  f32,
}

valley_cache: [VALLEY_CACHE_N]Valley_Cache_Entry

valley_depth :: proc(x, z: i32) -> f32 {
	e := &valley_cache[raw_hash(x + 77, z + current_floor * 7717 + current_level * 131071) & (VALLEY_CACHE_N - 1)]
	if e.valid && e.x == x && e.z == z && e.floor == current_floor && e.theme == current_level do return e.v
	v := valley_depth_raw(x, z)
	e.x, e.z, e.floor, e.theme, e.valid, e.v = x, z, current_floor, current_level, true, v
	return v
}

valley_depth_raw :: proc(x, z: i32) -> f32 {
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
	fy := f32(current_floor) * 0.31
	n := bfbm_3d(f32(x) * 0.035, f32(z) * 0.035, fy, 811)
	t := clamp((n - 0.56) / 0.34, 0, 1)
	t = t * t * (3 - 2 * t)
	// Depth is low-frequency continuous noise too; hashing 12-cell blocks here
	// would introduce visible cliffs along the valley floor.
	depth_noise := bfbm_3d(f32(x) * 0.012, f32(z) * 0.012, fy, 813)
	depth := 1.0 + 2.0 * depth_noise
	return -depth * t * biome_weight * spawn_fade
}

floor_h :: proc(x, z: i32) -> f32 {
	if abs(x) <= SPAWN_CLEAR && abs(z) <= SPAWN_CLEAR do return 0
	r := region_at(x, z)
	i := region_idx(r, x, z)
	if r.cell_flg[i] & (CELL_LINK | CELL_LINK_RING) != 0 do return 0
	return f32(r.cell_floor[i]) * FLOOR_STEP + valley_depth(x, z)
}

floor_corner_h :: proc(cx, cz: i32) -> f32 {
	return(
		(floor_h(cx - 1, cz - 1) + floor_h(cx, cz - 1) + floor_h(cx - 1, cz) + floor_h(cx, cz)) *
		0.25 \
	)
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
