package main

import rl "vendor:raylib"

// Meshing for vertical links: risers, headers, cheeks, shells, ownership rules.

link_boundary_open :: proc(l: Vertical_Link, role: Link_Role, side: u8, wx, wz: i32) -> bool {
	if !link_side_open(l, role, side) do return false
	return link_open_offset(l, side, wx, wz)
}

emit_link_divider_x :: proc(v: ^Verts, x, z0, z1, top0, top1: f32, col: rl.Color) {
	half: f32 = WALL_T * 0.5
	xa, xb := x - half, x + half
	dark := shade(col, -26)
	// Both broad faces, a sloped top, a bottom and two end closures.
	lit_quad(v, {xa, 0, z0}, {xa, 0, z1}, {xa, top1, z1}, {xa, top0, z0}, col)
	lit_quad(v, {xb, 0, z0}, {xb, 0, z1}, {xb, top1, z1}, {xb, top0, z0}, col)
	flat_lit(v, {xa, top0, z0}, {xb, top0, z0}, {xb, top1, z1}, {xa, top1, z1}, shade(col, 4))
	flat_lit(v, {xa, 0, z0}, {xb, 0, z0}, {xb, 0, z1}, {xa, 0, z1}, dark)
	lit_quad(v, {xa, 0, z0}, {xb, 0, z0}, {xb, top0, z0}, {xa, top0, z0}, dark)
	lit_quad(v, {xa, 0, z1}, {xb, 0, z1}, {xb, top1, z1}, {xa, top1, z1}, dark)
}

emit_link_divider_z :: proc(v: ^Verts, z, x0, x1, top0, top1: f32, col: rl.Color) {
	half: f32 = WALL_T * 0.5
	za, zb := z - half, z + half
	dark := shade(col, -26)
	lit_quad(v, {x0, 0, za}, {x1, 0, za}, {x1, top1, za}, {x0, top0, za}, col)
	lit_quad(v, {x0, 0, zb}, {x1, 0, zb}, {x1, top1, zb}, {x0, top0, zb}, col)
	flat_lit(v, {x0, top0, za}, {x0, top0, zb}, {x1, top1, zb}, {x1, top1, za}, shade(col, 4))
	flat_lit(v, {x0, 0, za}, {x0, 0, zb}, {x1, 0, zb}, {x1, 0, za}, dark)
	lit_quad(v, {x0, 0, za}, {x0, 0, zb}, {x0, top0, zb}, {x0, top0, za}, dark)
	lit_quad(v, {x1, 0, za}, {x1, 0, zb}, {x1, top1, zb}, {x1, top1, za}, dark)
}

emit_switchback_divider_w :: proc(v: ^Verts, wx, wz: i32, l: Vertical_Link, role: Link_Role, col: rl.Color) {
	if role != .Lower do return
	x := f32(wx) * CELL
	z0, z1 := f32(wz) * CELL, f32(wz + 1) * CELL
	eps: f32 = 0.02
	left0 := link_surface_local(l, role, x - eps, z0 + eps)
	right0 := link_surface_local(l, role, x + eps, z0 + eps)
	left1 := link_surface_local(l, role, x - eps, z1 - eps)
	right1 := link_surface_local(l, role, x + eps, z1 - eps)
	top0, top1 := max(left0, right0) + 0.05, max(left1, right1) + 0.05
	if max(top0, top1) > 0.02 {
		emit_link_divider_x(v, x, z0, z1, top0, top1, shade(col, -28))
	}
}

emit_switchback_divider_n :: proc(v: ^Verts, wx, wz: i32, l: Vertical_Link, role: Link_Role, col: rl.Color) {
	if role != .Lower do return
	z := f32(wz) * CELL
	x0, x1 := f32(wx) * CELL, f32(wx + 1) * CELL
	eps: f32 = 0.02
	north0 := link_surface_local(l, role, x0 + eps, z - eps)
	south0 := link_surface_local(l, role, x0 + eps, z + eps)
	north1 := link_surface_local(l, role, x1 - eps, z - eps)
	south1 := link_surface_local(l, role, x1 - eps, z + eps)
	top0, top1 := max(north0, south0) + 0.05, max(north1, south1) + 0.05
	if max(top0, top1) > 0.02 {
		emit_link_divider_z(v, z, x0, x1, top0, top1, shade(col, -28))
	}
}

emit_link_step_riser_z :: proc(
	v: ^Verts, x0, x1, z: f32, a0, b0, a1, b1: f32, col: rl.Color,
) {
	lo0, hi0 := min(a0, b0), max(a0, b0)
	lo1, hi1 := min(a1, b1), max(a1, b1)
	if max(hi0 - lo0, hi1 - lo1) <= 0.001 do return
	lit_quad(v, {x0, lo0, z}, {x1, lo1, z}, {x1, hi1, z}, {x0, hi0, z}, col)
}

emit_link_step_riser_x :: proc(
	v: ^Verts, x, z0, z1: f32, a0, b0, a1, b1: f32, col: rl.Color,
) {
	lo0, hi0 := min(a0, b0), max(a0, b0)
	lo1, hi1 := min(a1, b1), max(a1, b1)
	if max(hi0 - lo0, hi1 - lo1) <= 0.001 do return
	lit_quad(v, {x, lo0, z0}, {x, lo1, z1}, {x, hi1, z1}, {x, hi0, z0}, col)
}

same_link_instance :: proc(a, b: Vertical_Link) -> bool {
	return a.x == b.x && a.z == b.z && a.w == b.w && a.d == b.d &&
		a.lower_floor == b.lower_floor && a.kind == b.kind &&
		a.direction == b.direction && a.entry_side == b.entry_side &&
		a.opening_width == b.opening_width && a.opening_offset == b.opening_offset
}

// Emit a single riser only at an internal link-cell boundary. Comparing the
// actual profile on both sides handles normal stairs and both switchback lanes
// without guessing which side is the high side.
emit_link_internal_boundary_risers :: proc(
	v: ^Verts, wx, wz: i32, l: Vertical_Link, role: Link_Role, col: rl.Color,
) {
	if role != .Lower || (l.kind != .Stairs && l.kind != .Switchback) do return
	x0, z0 := f32(wx) * CELL, f32(wz) * CELL
	x1, z1 := x0 + CELL, z0 + CELL
	eps: f32 = 0.025

	// East edge: this cell owns the shared boundary, so it is emitted once.
	if next, ok, next_role := vertical_link_at(wx + 1, wz); ok && next_role == role && same_link_instance(l, next) && !has_wall(wx + 1, wz, false) {
		outside0 := link_surface_local(l, role, x1 + eps, z0 + eps)
		inside0 := link_surface_local(l, role, x1 - eps, z0 + eps)
		outside1 := link_surface_local(l, role, x1 + eps, z1 - eps)
		inside1 := link_surface_local(l, role, x1 - eps, z1 - eps)
		emit_link_step_riser_x(v, x1, z0, z1, inside0, outside0, inside1, outside1, shade(col, -22))
	}

	// South edge, likewise emitted only by the northern cell.
	if next, ok, next_role := vertical_link_at(wx, wz + 1); ok && next_role == role && same_link_instance(l, next) && !has_wall(wx, wz + 1, true) {
		outside0 := link_surface_local(l, role, x0 + eps, z1 + eps)
		inside0 := link_surface_local(l, role, x0 + eps, z1 - eps)
		outside1 := link_surface_local(l, role, x1 - eps, z1 + eps)
		inside1 := link_surface_local(l, role, x1 - eps, z1 - eps)
		emit_link_step_riser_z(v, x0, x1, z1, inside0, outside0, inside1, outside1, shade(col, -22))
	}
}

// Close the short vertical transitions at the two open mouths of a stair flight.
// The outside height is selected per edge endpoint: switchbacks can join the
// lower and upper landings along different halves of the same broad opening.
emit_link_mouth_risers :: proc(
	v: ^Verts, wx, wz: i32, l: Vertical_Link, role: Link_Role, col: rl.Color,
) {
	if role != .Lower || (l.kind != .Stairs && l.kind != .Switchback && l.kind != .Ramp) do return
	if !(wx == l.x || wx == l.x + l.w - 1 || wz == l.z || wz == l.z + l.d - 1) do return
	x0, z0 := f32(wx) * CELL, f32(wz) * CELL
	x1, z1 := x0 + CELL, z0 + CELL
	eps: f32 = 0.025
	opening_col := shade(col, -22)
	riser := l.kind != .Ramp // ramps are continuous; only stairs have a last riser
	base: f32 = -0.02

	if wz == l.z && link_boundary_open(l, role, 0, wx, wz) {
		i0 := link_surface_local(l, role, x0 + eps, z0 + eps)
		i1 := link_surface_local(l, role, x1 - eps, z0 + eps)
		o0, o1: f32 = 0, 0
		if i0 > FLOOR_SPACING * 0.5 do o0 = FLOOR_SPACING
		if i1 > FLOOR_SPACING * 0.5 do o1 = FLOOR_SPACING
		if riser do emit_link_step_riser_z(v, x0, x1, z0, i0, o0, i1, o1, opening_col)
		// Solid back of the flight, seen from outside the opening.
		if i0 > 0.05 || i1 > 0.05 do emit_link_step_riser_z(v, x0, x1, z0, base, i0, base, i1, opening_col)
	}
	if wz == l.z + l.d - 1 && link_boundary_open(l, role, 1, wx, wz) {
		i0 := link_surface_local(l, role, x0 + eps, z1 - eps)
		i1 := link_surface_local(l, role, x1 - eps, z1 - eps)
		o0, o1: f32 = 0, 0
		if i0 > FLOOR_SPACING * 0.5 do o0 = FLOOR_SPACING
		if i1 > FLOOR_SPACING * 0.5 do o1 = FLOOR_SPACING
		if riser do emit_link_step_riser_z(v, x0, x1, z1, i0, o0, i1, o1, opening_col)
		if i0 > 0.05 || i1 > 0.05 do emit_link_step_riser_z(v, x0, x1, z1, base, i0, base, i1, opening_col)
	}
	if wx == l.x && link_boundary_open(l, role, 3, wx, wz) {
		i0 := link_surface_local(l, role, x0 + eps, z0 + eps)
		i1 := link_surface_local(l, role, x0 + eps, z1 - eps)
		o0, o1: f32 = 0, 0
		if i0 > FLOOR_SPACING * 0.5 do o0 = FLOOR_SPACING
		if i1 > FLOOR_SPACING * 0.5 do o1 = FLOOR_SPACING
		if riser do emit_link_step_riser_x(v, x0, z0, z1, i0, o0, i1, o1, opening_col)
		if i0 > 0.05 || i1 > 0.05 do emit_link_step_riser_x(v, x0, z0, z1, base, i0, base, i1, opening_col)
	}
	if wx == l.x + l.w - 1 && link_boundary_open(l, role, 2, wx, wz) {
		i0 := link_surface_local(l, role, x1 - eps, z0 + eps)
		i1 := link_surface_local(l, role, x1 - eps, z1 - eps)
		o0, o1: f32 = 0, 0
		if i0 > FLOOR_SPACING * 0.5 do o0 = FLOOR_SPACING
		if i1 > FLOOR_SPACING * 0.5 do o1 = FLOOR_SPACING
		if riser do emit_link_step_riser_x(v, x1, z0, z1, i0, o0, i1, o1, opening_col)
		if i0 > 0.05 || i1 > 0.05 do emit_link_step_riser_x(v, x1, z0, z1, base, i0, base, i1, opening_col)
	}
}

// Close the void between the outside room's ceiling and the storey above at
// every low-level opening of a lower-storey link (stair/ramp entrances, slide
// landings, drop exits). Without it the gap is visible from inside the link.
emit_link_open_header :: proc(
	v: ^Verts, wx, wz: i32, l: Vertical_Link, role: Link_Role, col: rl.Color,
) {
	if role != .Lower do return
	x0, z0 := f32(wx) * CELL, f32(wz) * CELL
	x1, z1 := x0 + CELL, z0 + CELL
	eps: f32 = 0.025
	top := f32(FLOOR_SPACING)
	hc := shade(col, -22)
	walk := l.kind == .Stairs || l.kind == .Switchback || l.kind == .Ramp

	if wz == l.z && link_boundary_open(l, role, 0, wx, wz) {
		i0 := link_surface_local(l, role, x0 + eps, z0 + eps)
		i1 := link_surface_local(l, role, x1 - eps, z0 + eps)
		if !walk || (i0 <= top * 0.5 && i1 <= top * 0.5) {
			emit_link_step_riser_z(v, x0, x1, z0, corner_h(wx, wz), top, corner_h(wx + 1, wz), top, hc)
		}
	}
	if wz == l.z + l.d - 1 && link_boundary_open(l, role, 1, wx, wz) {
		i0 := link_surface_local(l, role, x0 + eps, z1 - eps)
		i1 := link_surface_local(l, role, x1 - eps, z1 - eps)
		if !walk || (i0 <= top * 0.5 && i1 <= top * 0.5) {
			emit_link_step_riser_z(v, x0, x1, z1, corner_h(wx, wz + 1), top, corner_h(wx + 1, wz + 1), top, hc)
		}
	}
	if wx == l.x && link_boundary_open(l, role, 3, wx, wz) {
		i0 := link_surface_local(l, role, x0 + eps, z0 + eps)
		i1 := link_surface_local(l, role, x0 + eps, z1 - eps)
		if !walk || (i0 <= top * 0.5 && i1 <= top * 0.5) {
			emit_link_step_riser_x(v, x0, z0, z1, corner_h(wx, wz), top, corner_h(wx, wz + 1), top, hc)
		}
	}
	if wx == l.x + l.w - 1 && link_boundary_open(l, role, 2, wx, wz) {
		i0 := link_surface_local(l, role, x1 - eps, z0 + eps)
		i1 := link_surface_local(l, role, x1 - eps, z1 - eps)
		if !walk || (i0 <= top * 0.5 && i1 <= top * 0.5) {
			emit_link_step_riser_x(v, x1, z0, z1, corner_h(wx + 1, wz), top, corner_h(wx + 1, wz + 1), top, hc)
		}
	}
}

// The slide is a thin opaque shell. Its mouth caps close the exposed 18 cm
// cross-section without blocking the walkable surface above it.
emit_slide_mouth_cap :: proc(
	v: ^Verts, l: Vertical_Link, col: rl.Color,
	x0, x1, z0, z1: f32, side: u8,
) {
	under: f32 = LINK_SHELL_THICKNESS
	dark := shade(col, -38)
	// Sample the exact edge where the cap vertices are placed. Sampling inward
	// while placing the cap on the boundary created a thin wedge-shaped seam.
	switch side {
	case 0: // north
		t0 := link_surface_local(l, .Upper, x0, z0)
		t1 := link_surface_local(l, .Upper, x1, z0)
		lit_quad(v, {x0, t0, z0}, {x1, t1, z0}, {x1, t1-under, z0}, {x0, t0-under, z0}, dark)
	case 1: // south
		t0 := link_surface_local(l, .Upper, x0, z1)
		t1 := link_surface_local(l, .Upper, x1, z1)
		lit_quad(v, {x0, t0, z1}, {x1, t1, z1}, {x1, t1-under, z1}, {x0, t0-under, z1}, dark)
	case 2: // east
		t0 := link_surface_local(l, .Upper, x1, z0)
		t1 := link_surface_local(l, .Upper, x1, z1)
		lit_quad(v, {x1, t0, z0}, {x1, t1, z1}, {x1, t1-under, z1}, {x1, t0-under, z0}, dark)
	case 3: // west
		t0 := link_surface_local(l, .Upper, x0, z0)
		t1 := link_surface_local(l, .Upper, x0, z1)
		lit_quad(v, {x0, t0, z0}, {x0, t1, z1}, {x0, t1-under, z1}, {x0, t0-under, z0}, dark)
	}
}

emit_link_cheek_x :: proc(
	v: ^Verts,
	x: f32,
	z0, z1: f32,
	top0, top1, bottom0, bottom1: f32,
	col: rl.Color,
) {
	half: f32 = WALL_T * 0.5
	xa, xb := x - half, x + half
	dark := shade(col, -24)
	// Two broad faces, a sloped top rail, a sloped underside, and closed ends.
	lit_quad(v, {xa, top0, z0}, {xa, top1, z1}, {xa, bottom1, z1}, {xa, bottom0, z0}, col)
	lit_quad(v, {xb, top0, z0}, {xb, top1, z1}, {xb, bottom1, z1}, {xb, bottom0, z0}, col)
	flat_lit(v, {xa, top0, z0}, {xb, top0, z0}, {xb, top1, z1}, {xa, top1, z1}, shade(col, 4))
	flat_lit(v, {xa, bottom0, z0}, {xb, bottom0, z0}, {xb, bottom1, z1}, {xa, bottom1, z1}, dark)
	lit_quad(v, {xa, top0, z0}, {xb, top0, z0}, {xb, bottom0, z0}, {xa, bottom0, z0}, dark)
	lit_quad(v, {xa, top1, z1}, {xb, top1, z1}, {xb, bottom1, z1}, {xa, bottom1, z1}, dark)
}

emit_link_cheek_z :: proc(
	v: ^Verts,
	z: f32,
	x0, x1: f32,
	top0, top1, bottom0, bottom1: f32,
	col: rl.Color,
) {
	half: f32 = WALL_T * 0.5
	za, zb := z - half, z + half
	dark := shade(col, -24)
	lit_quad(v, {x0, top0, za}, {x1, top1, za}, {x1, bottom1, za}, {x0, bottom0, za}, col)
	lit_quad(v, {x0, top0, zb}, {x1, top1, zb}, {x1, bottom1, zb}, {x0, bottom0, zb}, col)
	flat_lit(v, {x0, top0, za}, {x0, top0, zb}, {x1, top1, zb}, {x1, top1, za}, shade(col, 4))
	flat_lit(v, {x0, bottom0, za}, {x0, bottom0, zb}, {x1, bottom1, zb}, {x1, bottom1, za}, dark)
	lit_quad(v, {x0, top0, za}, {x0, top0, zb}, {x0, bottom0, zb}, {x0, bottom0, za}, dark)
	lit_quad(v, {x1, top1, za}, {x1, top1, zb}, {x1, bottom1, zb}, {x1, bottom1, za}, dark)
}

emit_upper_link_side :: proc(
	v: ^Verts,
	wx, wz: i32,
	l: Vertical_Link,
	role: Link_Role,
	col: rl.Color,
	x0, x1, z0, z1: f32,
) {
	if role != .Upper do return
	wall := shade(col, -28)

	// Drop walls are full-depth shaft cheeks. Slide cheeks follow the actual
	// chute profile and rise above it as a continuous safety rail.
	slide := l.kind == .Slide
	rail: f32 = 0
	if slide do rail = LINK_RAIL_HEIGHT

	if wx == l.x && !link_boundary_open(l, role, 3, wx, wz) {
		t0, t1: f32 = 0, 0
		b0, b1: f32 = -f32(FLOOR_SPACING), -f32(FLOOR_SPACING)
		if slide {
			t0 = link_surface_local(l, role, x0, z0) + rail
			t1 = link_surface_local(l, role, x0, z1) + rail
			b0 = link_surface_local(l, role, x0, z0) - LINK_SHELL_THICKNESS
			b1 = link_surface_local(l, role, x0, z1) - LINK_SHELL_THICKNESS
		}
		emit_link_cheek_x(v, x0, z0, z1, t0, t1, b0, b1, wall)
		if slide {
			room_top := west_wall_height(wx, wz)
			if room_top > max(t0, t1) do emit_link_cheek_x(v, x0, z0, z1, room_top, room_top, t0, t1, shade(wall, -5))
		}
	}
	if wx == l.x + l.w - 1 && !link_boundary_open(l, role, 2, wx, wz) {
		t0, t1: f32 = 0, 0
		b0, b1: f32 = -f32(FLOOR_SPACING), -f32(FLOOR_SPACING)
		if slide {
			t0 = link_surface_local(l, role, x1, z0) + rail
			t1 = link_surface_local(l, role, x1, z1) + rail
			b0 = link_surface_local(l, role, x1, z0) - LINK_SHELL_THICKNESS
			b1 = link_surface_local(l, role, x1, z1) - LINK_SHELL_THICKNESS
		}
		emit_link_cheek_x(v, x1, z0, z1, t0, t1, b0, b1, wall)
		if slide {
			room_top := west_wall_height(wx + 1, wz)
			if room_top > max(t0, t1) do emit_link_cheek_x(v, x1, z0, z1, room_top, room_top, t0, t1, shade(wall, -5))
		}
	}
	if wz == l.z && !link_boundary_open(l, role, 0, wx, wz) {
		t0, t1: f32 = 0, 0
		b0, b1: f32 = -f32(FLOOR_SPACING), -f32(FLOOR_SPACING)
		if slide {
			t0 = link_surface_local(l, role, x0, z0) + rail
			t1 = link_surface_local(l, role, x1, z0) + rail
			b0 = link_surface_local(l, role, x0, z0) - LINK_SHELL_THICKNESS
			b1 = link_surface_local(l, role, x1, z0) - LINK_SHELL_THICKNESS
		}
		emit_link_cheek_z(v, z0, x0, x1, t0, t1, b0, b1, wall)
		if slide {
			room_top := north_wall_height(wx, wz)
			if room_top > max(t0, t1) do emit_link_cheek_z(v, z0, x0, x1, room_top, room_top, t0, t1, shade(wall, -5))
		}
	}
	if wz == l.z + l.d - 1 && !link_boundary_open(l, role, 1, wx, wz) {
		t0, t1: f32 = 0, 0
		b0, b1: f32 = -f32(FLOOR_SPACING), -f32(FLOOR_SPACING)
		if slide {
			t0 = link_surface_local(l, role, x0, z1) + rail
			t1 = link_surface_local(l, role, x1, z1) + rail
			b0 = link_surface_local(l, role, x0, z1) - LINK_SHELL_THICKNESS
			b1 = link_surface_local(l, role, x1, z1) - LINK_SHELL_THICKNESS
		}
		emit_link_cheek_z(v, z1, x0, x1, t0, t1, b0, b1, wall)
		if slide {
			room_top := north_wall_height(wx, wz + 1)
			if room_top > max(t0, t1) do emit_link_cheek_z(v, z1, x0, x1, room_top, room_top, t0, t1, shade(wall, -5))
		}
	}

	// Seal the joint where two closed chute cheeks meet. Without this small
	// corner post, their perpendicular thicknesses meet only along an edge;
	// oblique views can expose a pinhole into the chute wall.
	west_corner := wx == l.x
	east_corner := wx == l.x + l.w - 1
	north_corner := wz == l.z
	south_corner := wz == l.z + l.d - 1
	if (west_corner || east_corner) && (north_corner || south_corner) {
		xc := x0
		if east_corner {xc = x1}
		zc := z0
		if south_corner {zc = z1}
		x_side := u8(3)
		if east_corner {x_side = 2}
		z_side := u8(0)
		if south_corner {z_side = 1}
		if !link_boundary_open(l, role, x_side, wx, wz) && !link_boundary_open(l, role, z_side, wx, wz) {
			base: f32 = -f32(FLOOR_SPACING)
			top: f32 = 0
			if slide {
				base = link_surface_local(l, role, xc, zc) - LINK_SHELL_THICKNESS
				top = link_surface_local(l, role, xc, zc) + rail
				if west_corner {top = max(top, west_wall_height(wx, wz))}
				if east_corner {top = max(top, west_wall_height(wx + 1, wz))}
				if north_corner {top = max(top, north_wall_height(wx, wz))}
				if south_corner {top = max(top, north_wall_height(wx, wz + 1))}
			}
			half: f32 = WALL_T * 0.5
			wall_box(v, {xc-half, zc-half}, {xc+half, zc+half}, wall, base, top)
		}
	}

	// Seal only the thin chute shell at an open mouth. The rail stays open so
	// the player can enter/leave the chute without hitting a transverse wall.
	if slide {
		if wz == l.z && link_boundary_open(l, role, 0, wx, wz) {
			emit_slide_mouth_cap(v, l, col, x0, x1, z0, z1, 0)
		}
		if wz == l.z + l.d - 1 && link_boundary_open(l, role, 1, wx, wz) {
			emit_slide_mouth_cap(v, l, col, x0, x1, z0, z1, 1)
		}
		if wx == l.x && link_boundary_open(l, role, 3, wx, wz) {
			emit_slide_mouth_cap(v, l, col, x0, x1, z0, z1, 3)
		}
		if wx == l.x + l.w - 1 && link_boundary_open(l, role, 2, wx, wz) {
			emit_slide_mouth_cap(v, l, col, x0, x1, z0, z1, 2)
		}
	}
}

// The link footprint is shared by the two adjacent floors. One mesh owns each
// physical surface: lower-floor geometry owns upward stairs/ramps; the upper
// floor owns downward slides and drop shafts. The closed cheek meshes include
// both exposed faces, the top/bottom caps, and end caps; no neighboring chunk
// is required to complete a link side.
emit_lower_link_sides :: proc(v: ^Verts, wx, wz: i32, l: Vertical_Link, role: Link_Role, col: rl.Color) {
	if role != .Lower || (l.kind != .Stairs && l.kind != .Switchback && l.kind != .Ramp) do return
	x0, z0 := f32(wx) * CELL, f32(wz) * CELL
	x1, z1 := x0 + CELL, z0 + CELL
	wall := shade(col, -28)
	half: f32 = WALL_T * 0.5
	if wx == l.x && !link_boundary_open(l, role, 3, wx, wz) {
		wall_box(v, {x0-half, z0}, {x0+half, z1}, wall, 0, FLOOR_SPACING)
	}
	if wx == l.x + l.w - 1 && !link_boundary_open(l, role, 2, wx, wz) {
		wall_box(v, {x1-half, z0}, {x1+half, z1}, wall, 0, FLOOR_SPACING)
	}
	if wz == l.z && !link_boundary_open(l, role, 0, wx, wz) {
		wall_box(v, {x0, z0-half}, {x1, z0+half}, wall, 0, FLOOR_SPACING)
	}
	if wz == l.z + l.d - 1 && !link_boundary_open(l, role, 1, wx, wz) {
		wall_box(v, {x0, z1-half}, {x1, z1+half}, wall, 0, FLOOR_SPACING)
	}
}

// Link-owned edges are emitted by the corresponding link mesh, not the
// ordinary room-wall mesher. This is important on the upper storey: the wall
// physically lives below y=0, so emitting a second room wall above y=0 creates
// a false cap and a lighting/collision mismatch.
link_owns_lower_perimeter_edge :: proc(wx, wz: i32, north: bool) -> bool {
	if north {
		if l, ok, role := vertical_link_at(wx, wz); ok && role == .Lower && (l.kind == .Stairs || l.kind == .Switchback || l.kind == .Ramp) && wz == l.z do return true
		if l, ok, role := vertical_link_at(wx, wz - 1); ok && role == .Lower && (l.kind == .Stairs || l.kind == .Switchback || l.kind == .Ramp) && wz == l.z + l.d do return true
	} else {
		if l, ok, role := vertical_link_at(wx, wz); ok && role == .Lower && (l.kind == .Stairs || l.kind == .Switchback || l.kind == .Ramp) && wx == l.x do return true
		if l, ok, role := vertical_link_at(wx - 1, wz); ok && role == .Lower && (l.kind == .Stairs || l.kind == .Switchback || l.kind == .Ramp) && wx == l.x + l.w do return true
	}
	return false
}

// An upper-floor switchback divider is physically emitted by the lower
// stair mesh. Suppress only this internal duplicate; the ordinary room wall
// still continues upward from y=0 around the outside of a link opening.
link_owns_upper_edge :: proc(wx, wz: i32, north: bool) -> bool {
	if north {
		if l, ok, role := vertical_link_at(wx, wz); ok && role == .Upper {
			if l.kind == .Switchback && l.direction >= 2 && wz == l.z + l.d / 2 do return true
			if l.kind == .Slide && l.z == wz && !link_boundary_open(l, role, 0, wx, wz) do return true
		}
		if l, ok, role := vertical_link_at(wx, wz - 1); ok && role == .Upper && l.kind == .Slide && l.z + l.d == wz && !link_boundary_open(l, role, 1, wx, wz - 1) do return true
	} else {
		if l, ok, role := vertical_link_at(wx, wz); ok && role == .Upper {
			if l.kind == .Switchback && l.direction < 2 && wx == l.x + l.w / 2 do return true
			if l.kind == .Slide && l.x == wx && !link_boundary_open(l, role, 3, wx, wz) do return true
		}
		if l, ok, role := vertical_link_at(wx - 1, wz); ok && role == .Upper && l.kind == .Slide && l.x + l.w == wx && !link_boundary_open(l, role, 2, wx - 1, wz) do return true
	}
	return false
}

link_owns_upper_slide_edge :: proc(wx, wz: i32, north: bool) -> bool {
	if north {
		if l, ok, role := vertical_link_at(wx, wz); ok && role == .Upper && l.kind == .Slide && l.z == wz && !link_boundary_open(l, role, 0, wx, wz) do return true
		if l, ok, role := vertical_link_at(wx, wz - 1); ok && role == .Upper && l.kind == .Slide && l.z + l.d == wz && !link_boundary_open(l, role, 1, wx, wz - 1) do return true
	} else {
		if l, ok, role := vertical_link_at(wx, wz); ok && role == .Upper && l.kind == .Slide && l.x == wx && !link_boundary_open(l, role, 3, wx, wz) do return true
		if l, ok, role := vertical_link_at(wx - 1, wz); ok && role == .Upper && l.kind == .Slide && l.x + l.w == wx && !link_boundary_open(l, role, 2, wx - 1, wz) do return true
	}
	return false
}

emit_link_cell :: proc(v: ^Verts, wx, wz: i32, l: Vertical_Link, role: Link_Role, col: rl.Color, k: i32) {
	x0, z0 := f32(wx) * CELL, f32(wz) * CELL
	x1, z1 := x0 + CELL, z0 + CELL
	emit_lower_link_sides(v, wx, wz, l, role, col)
	emit_link_open_header(v, wx, wz, l, role, col)

	if l.kind == .Drop {
		if role == .Lower {
			flat_lit(v, {x0, 0, z0}, {x1, 0, z0}, {x1, 0, z1}, {x0, 0, z1}, shade(col, k))
			return
		}
		if role == .Upper {
			emit_upper_link_side(v, wx, wz, l, role, col, x0, x1, z0, z1)
		}
		return
	}

	// A lower landing is the end cap for a one-way slide.
	if l.kind == .Slide && role == .Lower {
		flat_lit(v, {x0, 0, z0}, {x1, 0, z0}, {x1, 0, z1}, {x0, 0, z1}, shade(col, k))
		return
	}

	// Upward stairs, switchbacks and ramps are rendered once by the lower
	// floor. Their upper-floor counterpart is an opening above the same mesh.
	if role == .Upper && (l.kind == .Stairs || l.kind == .Switchback || l.kind == .Ramp) do return

	if l.kind == .Stairs || l.kind == .Switchback {
		for q in 0 ..< STAIR_STEPS {
			f0 := f32(q) / f32(STAIR_STEPS)
			f1 := f32(q + 1) / f32(STAIR_STEPS)
			f_mid := (f0 + f1) * 0.5
			sample_x, sample_z := (x0 + x1) * 0.5, (z0 + z1) * 0.5
			if l.direction < 2 {sample_z = z0 + f_mid * CELL} else {sample_x = x0 + f_mid * CELL}
			y := link_surface_local(l, role, sample_x, sample_z)
			if l.direction < 2 {
				z_a, z_b := z0 + f0 * CELL, z0 + f1 * CELL
				flat_lit(v, {x0, y, z_a}, {x1, y, z_a}, {x1, y, z_b}, {x0, y, z_b}, shade(col, k))
				if q > 0 {
					prev_mid := (f32(q - 1) + f32(q)) * 0.5 / f32(STAIR_STEPS)
					prev_z, curr_z := z0 + prev_mid * CELL, z0 + f_mid * CELL
					eps: f32 = 0.02
					prev0 := link_surface_local(l, role, x0 + eps, prev_z)
					curr0 := link_surface_local(l, role, x0 + eps, curr_z)
					prev1 := link_surface_local(l, role, x1 - eps, prev_z)
					curr1 := link_surface_local(l, role, x1 - eps, curr_z)
					z_edge := z0 + f0 * CELL
					emit_link_step_riser_z(v, x0, x1, z_edge, prev0, curr0, prev1, curr1, shade(col, k - 22))
				}
			} else {
				x_a, x_b := x0 + f0 * CELL, x0 + f1 * CELL
				flat_lit(v, {x_a, y, z0}, {x_b, y, z0}, {x_b, y, z1}, {x_a, y, z1}, shade(col, k))
				if q > 0 {
					prev_mid := (f32(q - 1) + f32(q)) * 0.5 / f32(STAIR_STEPS)
					prev_x, curr_x := x0 + prev_mid * CELL, x0 + f_mid * CELL
					eps: f32 = 0.02
					prev0 := link_surface_local(l, role, prev_x, z0 + eps)
					curr0 := link_surface_local(l, role, curr_x, z0 + eps)
					prev1 := link_surface_local(l, role, prev_x, z1 - eps)
					curr1 := link_surface_local(l, role, curr_x, z1 - eps)
					x_edge := x0 + f0 * CELL
					emit_link_step_riser_x(v, x_edge, z0, z1, prev0, curr0, prev1, curr1, shade(col, k - 22))
				}
			}
		}
		emit_link_internal_boundary_risers(v, wx, wz, l, role, col)
		emit_link_mouth_risers(v, wx, wz, l, role, col)
	} else {
		// Ramps and slides use a four-corner plane so the surface is continuous
		// across cells and the player collision samples the exact same function.
		y00 := link_surface_local(l, role, x0, z0)
		y10 := link_surface_local(l, role, x1, z0)
		y11 := link_surface_local(l, role, x1, z1)
		y01 := link_surface_local(l, role, x0, z1)
		flat_lit(v, {x0, y00, z0}, {x1, y10, z0}, {x1, y11, z1}, {x0, y01, z1}, shade(col, k))
		if l.kind == .Ramp do emit_link_mouth_risers(v, wx, wz, l, role, col)
	}

	if role == .Lower {
		// Closed backing beneath upward stairs/ramps; this prevents seeing
		// through the stair body from a lower/oblique camera angle.
		if l.kind == .Stairs || l.kind == .Switchback || l.kind == .Ramp {
			bottom: f32 = -0.02
			flat_lit(v, {x0, bottom, z0}, {x1, bottom, z0}, {x1, bottom, z1}, {x0, bottom, z1}, shade(col, -34))
		}
	} else if role == .Upper && l.kind == .Slide {
		// The slide is a shallow solid chute. The perimeter emitter below adds
		// thick, closed cheek wedges whose lower edge follows this same profile.
		under: f32 = LINK_SHELL_THICKNESS
		// The underside uses the same four XZ coordinates as the top plane.
		// Matching samples keep the shell thickness constant all the way to
		// cell and chunk boundaries instead of tapering to a hairline gap.
		u00 := link_surface_local(l, role, x0, z0) - under
		u10 := link_surface_local(l, role, x1, z0) - under
		u11 := link_surface_local(l, role, x1, z1) - under
		u01 := link_surface_local(l, role, x0, z1) - under
		flat_lit(v, {x0, u00, z0}, {x1, u10, z0}, {x1, u11, z1}, {x0, u01, z1}, shade(col, -38))
		emit_upper_link_side(v, wx, wz, l, role, col, x0, x1, z0, z1)
	}
}
