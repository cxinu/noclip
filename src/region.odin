package main

// Region storage: the per-floor generation tiles, their caches, RNG and lookup.

REG_PITCH :: 48

REG_JIT :: 16

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

region_cache: [WORLD_FLOOR_COUNT]^Region

region_cache_clear :: proc() {
	last_region = nil
	for i in 0 ..< WORLD_FLOOR_COUNT do region_cache[i] = nil
}

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
	if current_floor >= 0 && current_floor < WORLD_FLOOR_COUNT {
		if rc := region_cache[current_floor];
		   rc != nil && rc.theme == current_level && x >= rc.x0 && x < rc.x0 + rc.w && z >= rc.z0 && z < rc.z0 + rc.h {
			last_region = rc
			return rc
		}
	}
	i := reg_col_of(x)
	j := reg_row_of(i, z)
	key := [4]i32{current_floor, current_level, i, j}
	if found, ok := regions[key]; ok {
		last_region = found
		if current_floor >= 0 && current_floor < WORLD_FLOOR_COUNT do region_cache[current_floor] = found
		return found
	}
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
	if current_floor >= 0 && current_floor < WORLD_FLOOR_COUNT do region_cache[current_floor] = r
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
			abs(key[0] - current_floor) <= VERTICAL_VIEW_RADIUS &&
			key[1] == key[0] &&
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
	region_cache_clear()
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
