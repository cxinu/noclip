package main

// Procedural floor plans: BSP rooms, corridors, halls, doors.

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

generate_region :: proc(r: ^Region, ri, rj: i32) {
	// Same region lattice, different deterministic room contents per storey.
	floor_salt := current_floor * 104729 + current_level * 7919
	rng := Rng {
		s = lh(ri * 4099 + 17 + floor_salt, rj * 8191 + 23 - floor_salt) | 1,
	}
	for _ in 0 ..< 4 do rng_u32(&rng)
	punch_border(r, &rng, true)
	punch_border(r, &rng, false)
	bsp(r, &rng, r.x0, r.z0, r.w, r.h)
	// Each region reserves deterministic link footprints for the floor below
	// and above. The same pair seed yields identical rectangles on both floors.
	if current_floor > 0 {
		place_vertical_link(r, ri, rj, current_floor - 1, .Upper)
	}
	if current_floor < WORLD_FLOOR_COUNT - 1 {
		place_vertical_link(r, ri, rj, current_floor, .Lower)
	}
}

// ───────────────────────── queries ─────────────────────────
