package main

import "core:math"

// Vertical links (stairs, switchbacks, ramps, drops, slides): placement and surface profile.

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
	// Walkable stairs and ramps: the lower storey opens at both ends, but the
	// upper storey opens only where the flight arrives. An open entry edge up
	// there would be an unguarded hole into the stairwell.
	if role == .Upper do return side == l.direction
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
	// Flatten a 2-cell apron around the footprint. Terrain steps and valley
	// depth would otherwise leave the room floor above or below the first tread
	// / landing, so stairs and chutes would not meet the floor they serve.
	for z in l.z - 2 ..< l.z + l.d + 2 {
		for x in l.x - 2 ..< l.x + l.w + 2 {
			if x < r.x0 || x >= r.x0 + r.w || z < r.z0 || z >= r.z0 + r.h do continue
			i := region_idx(r, x, z)
			if r.cell_link_id[i] >= 0 do continue
			r.cell_flg[i] &= ~u8(CELL_PILLAR | CELL_POOL)
			r.cell_flg[i] |= CELL_LINK_RING
			r.cell_floor[i] = 0
		}
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
		if role == .Upper {
			half := opening_axis / 2
			opening_width = half
			opening_offset = 0 if entry == 3 else half
		}
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
