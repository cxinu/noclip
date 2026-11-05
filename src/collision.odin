package main

import "core:math"

// xz footprint of a wall, used by both the mesher and collision
wall_rect :: proc(x, z: i32, north: bool) -> (lo, hi: [2]f32) {
	x0, z0 := f32(x) * CELL, f32(z) * CELL
	h: f32 = WALL_T / 2

	if north {
		return {x0, z0 - h}, {x0 + CELL, z0 + h}
	}

	return {x0 - h, z0}, {x0 + h, z0 + CELL}
}

Wall_Box :: struct {
	lo, hi: [2]f32, // xz footprint
	y0, y1: f32,
}

wall_pieces :: proc(x, z: i32, north: bool, wall_h: f32) -> (boxes: [3]Wall_Box, n: int) {
	lo, hi := wall_rect(x, z, north)
	if !has_door(x, z, north) {
		boxes[0] = {lo, hi, 0, wall_h}
		return boxes, 1
	}

	ax := 0 if north else 1 // axis the wall runs along
	start := lo[ax]
	l, r := door_span(x, z, north)
	dl, dr := start + l, start + r
	top := door_top(x, z, north, wall_h)

	j1_lo, j1_hi := lo, hi
	j1_hi[ax] = dl
	j2_lo, j2_hi := lo, hi
	j2_lo[ax] = dr
	l_lo, l_hi := lo, hi
	l_lo[ax] = dl
	l_hi[ax] = dr

	boxes[0] = {j1_lo, j1_hi, 0, wall_h}
	boxes[1] = {j2_lo, j2_hi, 0, wall_h}
	boxes[2] = {l_lo, l_hi, top, wall_h} // lintel
	return boxes, 3
}

push_out :: proc(p, lo, hi: [2]f32, r: f32) -> [2]f32 {
	c := [2]f32{clamp(p.x, lo.x, hi.x), clamp(p.y, lo.y, hi.y)}
	d := p - c
	d2 := d.x * d.x + d.y * d.y
	if d2 >= r * r do return p

	if d2 > 0.000001 {
		return c + d * (r / math.sqrt(d2))
	}

	l, rt, t, b := p.x - lo.x, hi.x - p.x, p.y - lo.y, hi.y - p.y
	m := min(l, rt, t, b)
	if m == l do return {lo.x - r, p.y}
	if m == rt do return {hi.x + r, p.y}
	if m == t do return {p.x, lo.y - r}
	return {p.x, hi.y + r}
}

// Circle (x, z) vs nearby walls, with vertical overlap. The same wall spans
// used by the renderer are used here, including the 6 m cheeks around lower
// stair flights and the raised lintels above doors.
collide_walls :: proc(pos: [2]f32, r: f32, feet_world, body_height: f32) -> [2]f32 {
	p := pos
	cx, cz := i32(math.floor(p.x / CELL)), i32(math.floor(p.y / CELL))
	feet_local := feet_world - floor_world_offset(current_floor)
	head_local := feet_local + body_height

	for _ in 0 ..< 2 {
		for z in cz - 1 ..= cz + 1 {
			for x in cx - 1 ..= cx + 1 {
				for north in ([2]bool{false, true}) {
					if link_owns_upper_slide_edge(x, z, north) do continue
					if !has_wall(x, z, north) do continue
					wall_top := north_wall_height(x, z)
					wall_base := north_wall_base(x, z)
					if !north {
						wall_top = west_wall_height(x, z)
						wall_base = west_wall_base(x, z)
					}
					boxes, n := wall_pieces(x, z, north, wall_top)
					for i in 0 ..< n {
						box_bottom := wall_base + boxes[i].y0
						box_top := wall_top
						if i >= 2 {
							// Door lintels use absolute local heights in the wall mesher.
							box_bottom = boxes[i].y0
							box_top = boxes[i].y1
						}
						if box_top <= feet_local || box_bottom >= head_local do continue
						p = push_out(p, boxes[i].lo, boxes[i].hi, r)
					}
				}
				if pillar_at(x, z) {
					pillar_base := floor_h(x, z)
					pillar_top :=
						max(
							corner_h(x, z),
							corner_h(x + 1, z),
							corner_h(x, z + 1),
							corner_h(x + 1, z + 1),
						) +
						0.05
					if pillar_top > feet_local && pillar_base < head_local {
						inset: f32 = CELL * 0.3
						x0, z0 := f32(x) * CELL, f32(z) * CELL
						p = push_out(
							p,
							{x0 + inset, z0 + inset},
							{x0 + CELL - inset, z0 + CELL - inset},
							r,
						)
					}
				}
			}
		}
	}
	return p
}

link_open_at_position :: proc(
	l: Vertical_Link,
	role: Link_Role,
	side: u8,
	p: [2]f32,
	radius: f32,
) -> bool {
	if !link_side_open(l, role, side) do return false
	start: f32
	finish: f32
	if side < 2 {
		start = f32(l.x + l.opening_offset) * CELL
		finish = f32(l.x + l.opening_offset + l.opening_width) * CELL
		return p.x > start + radius && p.x < finish - radius
	}
	start = f32(l.z + l.opening_offset) * CELL
	finish = f32(l.z + l.opening_offset + l.opening_width) * CELL
	return p.y > start + radius && p.y < finish - radius
}

link_side_vertical_span :: proc(
	l: Vertical_Link,
	role: Link_Role,
	side: u8,
	wx, wz: i32,
	pos: [2]f32,
	radius: f32,
) -> (
	bottom, top: f32,
	active: bool,
) {
	if role == .Lower {
		if l.kind == .Stairs || l.kind == .Switchback || l.kind == .Ramp {
			return 0, f32(FLOOR_SPACING), true
		}
		return 0, 0, false
	}
	if role != .Upper do return 0, 0, false
	if l.kind == .Drop || l.kind == .Stairs || l.kind == .Switchback || l.kind == .Ramp {
		return -f32(FLOOR_SPACING), 0, true
	}
	if l.kind == .Slide {
		x0, z0 := f32(wx) * CELL, f32(wz) * CELL
		x1, z1 := x0 + CELL, z0 + CELL
		// Bound the wall at the player's current along-edge footprint, not the
		// lowest point of the entire cell. This avoids invisible overblocking
		// near the shallow end of a sloping chute.
		a, b: f32 = 0, 0
		switch side {
		case 0:
			// north
			lo := clamp(pos.x - radius, x0, x1)
			hi := clamp(pos.x + radius, x0, x1)
			a, b = link_surface_local(l, role, lo, z0), link_surface_local(l, role, hi, z0)
		case 1:
			// south
			lo := clamp(pos.x - radius, x0, x1)
			hi := clamp(pos.x + radius, x0, x1)
			a, b = link_surface_local(l, role, lo, z1), link_surface_local(l, role, hi, z1)
		case 2:
			// east
			lo := clamp(pos.y - radius, z0, z1)
			hi := clamp(pos.y + radius, z0, z1)
			a, b = link_surface_local(l, role, x1, lo), link_surface_local(l, role, x1, hi)
		case 3:
			// west
			lo := clamp(pos.y - radius, z0, z1)
			hi := clamp(pos.y + radius, z0, z1)
			a, b = link_surface_local(l, role, x0, lo), link_surface_local(l, role, x0, hi)
		}
		// The slide mesh owns these perimeter edges; ordinary room walls are
		// suppressed there. Keep collision bounded to the actual cheek/rail
		// volume instead of extending an invisible wall to the room wall height.
		bottom = min(a, b) - LINK_SHELL_THICKNESS
		top = max(a, b) + LINK_RAIL_HEIGHT
		// The mesh fills the cheek above the rail to the neighboring room-wall
		// height. Collision must include that visible extension too.
		switch side {
		case 0:
			top = max(top, north_wall_height(wx, wz))
		case 1:
			top = max(top, north_wall_height(wx, wz + 1))
		case 2:
			top = max(top, west_wall_height(wx + 1, wz))
		case 3:
			top = max(top, west_wall_height(wx, wz))
		}
		return bottom, top, true
	}
	return 0, 0, false
}

// The lower storey has a landing floor beneath the upper-storey slide.
// The slide shell above that landing acts as a real ceiling: prevent the
// player from walking or jumping through its 18 cm underside.
slide_underside_world_at :: proc(wx, wz: f32) -> (height: f32, ok: bool) {
	cx, cz := i32(math.floor(wx / CELL)), i32(math.floor(wz / CELL))
	l, found, role := vertical_link_at(cx, cz)
	if !found || l.kind != .Slide || role != .Lower || current_floor + 1 >= WORLD_FLOOR_COUNT {
		return 0, false
	}
	upper_floor := current_floor + 1
	return floor_world_offset(upper_floor) +
		link_surface_local(l, .Upper, wx, wz) -
		LINK_SHELL_THICKNESS,
		true
}

slide_underside_clearance :: proc(pos: [2]f32, radius: f32) -> f32 {
	best: f32 = 1e9
	diag := radius * 0.70710678
	// Sample the circle centre, cardinal points and diagonals so the player's
	// full footprint clears the sloped shell, not just its centre point.
	for o in ([9][2]f32 {
			{0, 0},
			{radius, 0},
			{-radius, 0},
			{0, radius},
			{0, -radius},
			{diag, diag},
			{-diag, diag},
			{diag, -diag},
			{-diag, -diag},
		}) {
		if h, ok := slide_underside_world_at(pos.x + o.x, pos.y + o.y); ok do best = min(best, h)
	}
	return best
}

collide_link_underside_horizontal :: proc(
	pos, previous: [2]f32,
	radius, feet_world, body_height: f32,
) -> [2]f32 {
	next_ceiling := slide_underside_clearance(pos, radius)
	prev_ceiling := slide_underside_clearance(previous, radius)
	head := feet_world + body_height
	// Allow movement out of a low-clearance region, but reject movement that
	// would newly place the player's head inside the chute underside.
	if next_ceiling < head - 0.02 && next_ceiling < prev_ceiling - 0.001 do return previous
	return pos
}

resolve_link_underside_vertical :: proc(
	x, z, previous_feet, next_feet, velocity, body_height, radius: f32,
) -> (
	feet, vel: f32,
) {
	if velocity <= 0 do return next_feet, velocity
	ceiling := slide_underside_clearance({x, z}, radius)
	if ceiling >= 1e8 do return next_feet, velocity
	previous_head := previous_feet + body_height
	next_head := next_feet + body_height
	if previous_head <= ceiling + 0.01 && next_head > ceiling {
		return ceiling - body_height - 0.01, 0
	}
	return next_feet, velocity
}

// Collision follows the actual vertical span of the link cheeks. This matters
// while falling through an upper-floor shaft: ordinary wall collision only
// sees walls above that floor's y=0 plane.
collide_link_sides :: proc(pos: [2]f32, r: f32, feet_world, body_height: f32) -> [2]f32 {
	p := pos
	feet_local := feet_world - floor_world_offset(current_floor)
	head_local := feet_local + body_height
	for _ in 0 ..< 2 {
		cx, cz := i32(math.floor(p.x / CELL)), i32(math.floor(p.y / CELL))
		for z in cz - 1 ..= cz + 1 {
			for x in cx - 1 ..= cx + 1 {
				l, ok, role := vertical_link_at(x, z)
				if !ok do continue
				x0, z0 := f32(l.x) * CELL, f32(l.z) * CELL
				x1, z1 := f32(l.x + l.w) * CELL, f32(l.z + l.d) * CELL
				if p.x < x0 - r || p.x > x1 + r || p.y < z0 - r || p.y > z1 + r do continue

				// Resolve against the side slab from whichever side the player
				// approached. The old one-way push moved an outside player into
				// the footprint when they hit a closed cheek from outside.
				half_wall: f32 = WALL_T * 0.5

				// West edge segment.
				if x == l.x && p.y >= f32(z) * CELL - r && p.y <= f32(z + 1) * CELL + r {
					bottom, top, active := link_side_vertical_span(l, role, 3, x, z, p, r)
					if active &&
					   head_local > bottom &&
					   feet_local < top &&
					   !link_open_at_position(l, role, 3, p, r) {
						lo, hi := x0 - half_wall - r, x0 + half_wall + r
						if p.x > lo && p.x < hi {
							if p.x < x0 {p.x = lo} else {p.x = hi}
						}
					}
				}
				// East edge segment.
				if x == l.x + l.w - 1 && p.y >= f32(z) * CELL - r && p.y <= f32(z + 1) * CELL + r {
					bottom, top, active := link_side_vertical_span(l, role, 2, x, z, p, r)
					if active &&
					   head_local > bottom &&
					   feet_local < top &&
					   !link_open_at_position(l, role, 2, p, r) {
						lo, hi := x1 - half_wall - r, x1 + half_wall + r
						if p.x > lo && p.x < hi {
							if p.x > x1 {p.x = hi} else {p.x = lo}
						}
					}
				}
				// North edge segment.
				if z == l.z && p.x >= f32(x) * CELL - r && p.x <= f32(x + 1) * CELL + r {
					bottom, top, active := link_side_vertical_span(l, role, 0, x, z, p, r)
					if active &&
					   head_local > bottom &&
					   feet_local < top &&
					   !link_open_at_position(l, role, 0, p, r) {
						lo, hi := z0 - half_wall - r, z0 + half_wall + r
						if p.y > lo && p.y < hi {
							if p.y < z0 {p.y = lo} else {p.y = hi}
						}
					}
				}
				// South edge segment.
				if z == l.z + l.d - 1 && p.x >= f32(x) * CELL - r && p.x <= f32(x + 1) * CELL + r {
					bottom, top, active := link_side_vertical_span(l, role, 1, x, z, p, r)
					if active &&
					   head_local > bottom &&
					   feet_local < top &&
					   !link_open_at_position(l, role, 1, p, r) {
						lo, hi := z1 - half_wall - r, z1 + half_wall + r
						if p.y > lo && p.y < hi {
							if p.y > z1 {p.y = hi} else {p.y = lo}
						}
					}
				}
			}
		}
	}
	return p
}
