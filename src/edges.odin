package main

// Wall / door / pillar / pool queries over the generated layout.

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
