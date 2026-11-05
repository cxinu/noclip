package main

import rl "vendor:raylib"

// Wall heights/bases and wall mesh emitters.

// Lowest point of an upper-storey link cheek on one perimeter cell. Values are
// in that storey's local coordinates and are consumed by the light DDA only.
link_wall_bottom :: proc(l: Vertical_Link, role: Link_Role, side: u8, wx, wz: i32) -> f32 {
	if role != .Upper do return 0
	if l.kind == .Drop do return -f32(FLOOR_SPACING)
	if l.kind != .Slide do return -f32(FLOOR_SPACING)
	x0, z0 := f32(wx) * CELL, f32(wz) * CELL
	x1, z1 := x0 + CELL, z0 + CELL
	a, b: f32 = 0, 0
	switch side {
	case 0: // north
		a = link_surface_local(l, role, x0, z0)
		b = link_surface_local(l, role, x1, z0)
	case 1: // south
		a = link_surface_local(l, role, x0, z1)
		b = link_surface_local(l, role, x1, z1)
	case 2: // east
		a = link_surface_local(l, role, x1, z0)
		b = link_surface_local(l, role, x1, z1)
	case 3: // west
		a = link_surface_local(l, role, x0, z0)
		b = link_surface_local(l, role, x0, z1)
	}
	return min(a, b) - LINK_SHELL_THICKNESS
}

west_wall_height :: proc(x, z: i32) -> f32 {
	h := max(corner_h(x, z), corner_h(x, z + 1)) + 0.05

	// Lower-floor outer cheeks rise to the adjacent storey.
	if l, ok, role := vertical_link_at(x, z); ok && role == .Lower && x == l.x do h = max(h, FLOOR_SPACING)
	if l, ok, role := vertical_link_at(x - 1, z); ok && role == .Lower && x == l.x + l.w do h = max(h, FLOOR_SPACING)

	// The switchback divider exists in both floor contexts. The lower mesh
	// owns the actual solid; upper-floor queries see its top profile below y=0.
	if l, ok, role := vertical_link_at(x, z); ok && l.kind == .Switchback && l.direction < 2 && x == l.x + l.w / 2 {
		eps: f32 = 0.02
		z0, z1 := f32(z) * CELL + eps, f32(z + 1) * CELL - eps
		left0 := link_surface_local(l, role, f32(x) * CELL - eps, z0)
		right0 := link_surface_local(l, role, f32(x) * CELL + eps, z0)
		left1 := link_surface_local(l, role, f32(x) * CELL - eps, z1)
		right1 := link_surface_local(l, role, f32(x) * CELL + eps, z1)
		profile_top := max(max(left0, right0), max(left1, right1)) + 0.05
		if role == .Upper {h = profile_top} else {h = max(h, profile_top)}
	}
	return h
}

north_wall_height :: proc(x, z: i32) -> f32 {
	h := max(corner_h(x, z), corner_h(x + 1, z)) + 0.05
	if l, ok, role := vertical_link_at(x, z); ok && role == .Lower && z == l.z do h = max(h, FLOOR_SPACING)
	if l, ok, role := vertical_link_at(x, z - 1); ok && role == .Lower && z == l.z + l.d do h = max(h, FLOOR_SPACING)

	if l, ok, role := vertical_link_at(x, z); ok && l.kind == .Switchback && l.direction >= 2 && z == l.z + l.d / 2 {
		eps: f32 = 0.02
		x0, x1 := f32(x) * CELL + eps, f32(x + 1) * CELL - eps
		north0 := link_surface_local(l, role, x0, f32(z) * CELL - eps)
		south0 := link_surface_local(l, role, x0, f32(z) * CELL + eps)
		north1 := link_surface_local(l, role, x1, f32(z) * CELL - eps)
		south1 := link_surface_local(l, role, x1, f32(z) * CELL + eps)
		profile_top := max(max(north0, south0), max(north1, south1)) + 0.05
		if role == .Upper {h = profile_top} else {h = max(h, profile_top)}
	}
	return h
}

west_wall_base :: proc(x, z: i32) -> f32 {
	base := min(floor_h(x, z), floor_h(x - 1, z))
	if l, ok, role := vertical_link_at(x, z); ok && role == .Upper && l.kind == .Switchback && l.direction < 2 && x == l.x + l.w / 2 {base = min(base, -f32(FLOOR_SPACING))}
	return base
}

north_wall_base :: proc(x, z: i32) -> f32 {
	base := min(floor_h(x, z), floor_h(x, z - 1))
	if l, ok, role := vertical_link_at(x, z); ok && role == .Upper && l.kind == .Switchback && l.direction >= 2 && z == l.z + l.d / 2 {base = min(base, -f32(FLOOR_SPACING))}
	return base
}

wall_cap_x :: proc(v: ^Verts, x, z0, z1, y0, y1: f32, col: rl.Color, shift: [2]f32) {
	if y1 <= y0 do return
	lit_quad(
		v,
		{x, y0, z0},
		{x, y1, z0},
		{x, y1, z1},
		{x, y0, z1},
		col,
		1.0,
		LIGHT_STEP,
		{},
		shift,
	)
}

wall_box :: proc(v: ^Verts, lo, hi: [2]f32, col: rl.Color, base, top: f32) {
	if top <= base do return
	dark := shade(col, -14)
	lit_quad(v, {lo.x, base, lo.y}, {lo.x, top, lo.y}, {lo.x, top, hi.y}, {lo.x, base, hi.y}, col)
	lit_quad(v, {hi.x, base, lo.y}, {hi.x, top, lo.y}, {hi.x, top, hi.y}, {hi.x, base, hi.y}, col)
	lit_quad(v, {lo.x, base, lo.y}, {hi.x, base, lo.y}, {hi.x, top, lo.y}, {lo.x, top, lo.y}, dark)
	lit_quad(v, {lo.x, base, hi.y}, {hi.x, base, hi.y}, {hi.x, top, hi.y}, {lo.x, top, hi.y}, dark)
	// Close the cap: open tops were visible when looking down into pillars and
	// when link meshes met at chunk boundaries.
	flat_lit(v, {lo.x, top, lo.y}, {hi.x, top, lo.y}, {hi.x, top, hi.y}, {lo.x, top, hi.y}, shade(col, 5))
	flat_lit(v, {lo.x, base, hi.y}, {hi.x, base, hi.y}, {hi.x, base, lo.y}, {lo.x, base, lo.y}, shade(col, -26))
}

wall_cap_z :: proc(v: ^Verts, z, x0, x1, y0, y1: f32, col: rl.Color, shift: [2]f32) {
	if y1 <= y0 do return
	lit_quad(
		v,
		{x0, y0, z},
		{x1, y0, z},
		{x1, y1, z},
		{x0, y1, z},
		col,
		Z_FACE_K,
		LIGHT_STEP,
		{},
		shift,
	)
}

wall_segment :: proc(
	v: ^Verts,
	lo, hi: [2]f32,
	col: rl.Color,
	base, h: f32,
	north: bool,
	start_neighbor_h, end_neighbor_h: f32,
) {
	if north {
		lit_quad(
			v,
			{lo.x, base, lo.y},
			{hi.x, base, lo.y},
			{hi.x, h, lo.y},
			{lo.x, h, lo.y},
			col,
			Z_FACE_K,
			LIGHT_STEP,
			{true, false},
		)
		lit_quad(
			v,
			{lo.x, base, hi.y},
			{hi.x, base, hi.y},
			{hi.x, h, hi.y},
			{lo.x, h, hi.y},
			col,
			Z_FACE_K,
			LIGHT_STEP,
			{true, true},
		)
		wall_cap_x(v, lo.x, lo.y, hi.y, start_neighbor_h, h, col, {-WALL_EPS, 0})
		wall_cap_x(v, hi.x, lo.y, hi.y, end_neighbor_h, h, col, {WALL_EPS, 0})
		flat_lit(v, {lo.x, h, lo.y}, {hi.x, h, lo.y}, {hi.x, h, hi.y}, {lo.x, h, hi.y}, shade(col, 5))
	} else {
		lit_quad(
			v,
			{lo.x, base, lo.y},
			{lo.x, h, lo.y},
			{lo.x, h, hi.y},
			{lo.x, base, hi.y},
			col,
			1.0,
			LIGHT_STEP,
			{false, true},
		)
		lit_quad(
			v,
			{hi.x, base, lo.y},
			{hi.x, h, lo.y},
			{hi.x, h, hi.y},
			{hi.x, base, hi.y},
			col,
			1.0,
			LIGHT_STEP,
			{true, true},
		)
		wall_cap_z(v, lo.y, lo.x, hi.x, start_neighbor_h, h, col, {0, -WALL_EPS})
		wall_cap_z(v, hi.y, lo.x, hi.x, end_neighbor_h, h, col, {0, WALL_EPS})
		flat_lit(v, {lo.x, h, lo.y}, {hi.x, h, lo.y}, {hi.x, h, hi.y}, {lo.x, h, hi.y}, shade(col, 5))
	}
}

emit_wall :: proc(
	v: ^Verts,
	wx, wz: i32,
	north: bool,
	col: rl.Color,
	base, h, start_h, end_h: f32,
) {
	boxes, n := wall_pieces(wx, wz, north, h)
	if n == 1 {
		wall_segment(v, boxes[0].lo, boxes[0].hi, col, base, h, north, start_h, end_h)
		return
	}
	wall_segment(v, boxes[0].lo, boxes[0].hi, col, base, h, north, start_h, 0)
	wall_segment(v, boxes[1].lo, boxes[1].hi, col, base, h, north, 0, end_h)
	l := boxes[2]
	wall_segment(v, l.lo, l.hi, col, l.y0, h, north, h, h)
	y := l.y0
	lit_quad(
		v,
		{l.lo.x, y, l.lo.y},
		{l.hi.x, y, l.lo.y},
		{l.hi.x, y, l.hi.y},
		{l.lo.x, y, l.hi.y},
		col,
		0.8,
		LIGHT_STEP,
		{true, true},
	)
}
