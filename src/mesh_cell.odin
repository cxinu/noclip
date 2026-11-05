package main

import rl "vendor:raylib"

// Assembles the geometry of one world cell.

// Emit geometry for exactly one world cell. The resumable builder calls this
// after the complete lighting cache for the target chunk has been prepared.
build_chunk_cell :: proc(v: ^Verts, c: Chunk_Coord, x, z: i32) {
	wx, wz := c.x * CHUNK_SIZE + x, c.y * CHUNK_SIZE + z
	x0, z0 := f32(wx) * CELL, f32(wz) * CELL
	x1, z1 := x0 + CELL, z0 + CELL
	light_center = {x0 + CELL * 0.5, z0 + CELL * 0.5}

	biome := biome_at(wx, wz)
	pal := PALETTES[biome]
	k := i32((raw_hash(wx, wz) >> 4) % 3) * 8 - 8

	h_nw := corner_h(wx, wz)
	h_ne := corner_h(wx + 1, wz)
	h_se := corner_h(wx + 1, wz + 1)
	h_sw := corner_h(wx, wz + 1)
	fh := ground_local_at(x0 + CELL * 0.5, z0 + CELL * 0.5)
	link, has_link, link_role := vertical_link_at(wx, wz)

	// Floor or reserved vertical-link footprint.
	if has_link {
		emit_link_cell(v, wx, wz, link, link_role, pal.floor, k)
	} else if pool_at(wx, wz) {
		water_col := rl.Color{50, 160, 190, 255}
		flat_lit(
			v,
			{x0, floor_corner_h(wx, wz), z0},
			{x1, floor_corner_h(wx + 1, wz), z0},
			{x1, floor_corner_h(wx + 1, wz + 1), z1},
			{x0, floor_corner_h(wx, wz + 1), z1},
			water_col,
		)
	} else {
		flat_lit(
			v,
			{x0, floor_corner_h(wx, wz), z0},
			{x1, floor_corner_h(wx + 1, wz), z0},
			{x1, floor_corner_h(wx + 1, wz + 1), z1},
			{x0, floor_corner_h(wx, wz + 1), z1},
			shade(pal.floor, k),
		)
	}

	// Vertical links are open to the storey above/below; their ceilings are removed.
	if !has_link || link_role == .Upper {
		flat_lit(v, {x0, h_nw, z0}, {x1, h_ne, z0}, {x1, h_se, z1}, {x0, h_sw, z1}, shade(pal.ceil, k))
	}

	if !has_link do emit_decals(v, wx, wz, biome, fh)

	// Light fixture.
	if pw := light_power(wx, wz); pw > 0 {
		lx0, lz0 := x0 + CELL * 0.25, z0 + CELL * 0.25
		lx1, lz1 := x0 + CELL * 0.75, z0 + CELL * 0.75
		y00 := bilerp4(h_nw, h_ne, h_se, h_sw, 0.25, 0.25) - 0.02
		y10 := bilerp4(h_nw, h_ne, h_se, h_sw, 0.75, 0.25) - 0.02
		y11 := bilerp4(h_nw, h_ne, h_se, h_sw, 0.75, 0.75) - 0.02
		y01 := bilerp4(h_nw, h_ne, h_se, h_sw, 0.25, 0.75) - 0.02
		base_lcol := light_color(wx, wz)
		quad(v, {lx0, y00, lz0}, {lx1, y10, lz0}, {lx1, y11, lz1}, {lx0, y01, lz1}, base_lcol)

		// Housing: a dark mitred frame around the panel. It is coplanar with the
		// panel and does not overlap it (no depth fighting), and follows the
		// ceiling surface so it stays flush on sloped, biome-blended ceilings.
		fu: f32 = 0.21
		fw: f32 = 0.79
		fx0, fz0 := x0 + CELL * fu, z0 + CELL * fu
		fx1, fz1 := x0 + CELL * fw, z0 + CELL * fw
		o00 := [3]f32{fx0, bilerp4(h_nw, h_ne, h_se, h_sw, fu, fu) - 0.02, fz0}
		o10 := [3]f32{fx1, bilerp4(h_nw, h_ne, h_se, h_sw, fw, fu) - 0.02, fz0}
		o11 := [3]f32{fx1, bilerp4(h_nw, h_ne, h_se, h_sw, fw, fw) - 0.02, fz1}
		o01 := [3]f32{fx0, bilerp4(h_nw, h_ne, h_se, h_sw, fu, fw) - 0.02, fz1}
		i00 := [3]f32{lx0, y00, lz0}
		i10 := [3]f32{lx1, y10, lz0}
		i11 := [3]f32{lx1, y11, lz1}
		i01 := [3]f32{lx0, y01, lz1}
		frame := rl.Color{22, 22, 24, 255}
		quad(v, o00, o10, i10, i00, frame)
		quad(v, o10, o11, i11, i10, frame)
		quad(v, o11, o01, i01, i11, frame)
		quad(v, o01, o00, i00, i01, frame)
	}

	// Pillar.
	if pillar_at(wx, wz) {
		i :: CELL * 0.3
		ph := max(h_nw, h_ne, h_se, h_sw) + 0.05
		wall_box(v, {x0 + i, z0 + i}, {x1 - i, z1 - i}, pal.wall, fh, ph)
	}

	// West wall.
	if has_wall(wx, wz, false) && !link_owns_lower_perimeter_edge(wx, wz, false) && !link_owns_upper_edge(wx, wz, false) {
		if l, ok, role := vertical_link_at(wx, wz);
		   ok && role == .Lower && l.kind == .Switchback && l.direction < 2 && wx == l.x + l.w / 2 {
			emit_switchback_divider_w(v, wx, wz, l, role, pal.wall)
		} else {
			wall_h := west_wall_height(wx, wz)
			base_w := west_wall_base(wx, wz)
			start_h: f32 = 0
			end_h: f32 = 0
			if has_wall(wx, wz - 1, false) do start_h = west_wall_height(wx, wz - 1)
			if has_wall(wx, wz + 1, false) do end_h = west_wall_height(wx, wz + 1)
			emit_wall(v, wx, wz, false, pal.wall, base_w, wall_h, start_h, end_h)
		}
	}

	// North wall.
	if has_wall(wx, wz, true) && !link_owns_lower_perimeter_edge(wx, wz, true) && !link_owns_upper_edge(wx, wz, true) {
		if l, ok, role := vertical_link_at(wx, wz);
		   ok && role == .Lower && l.kind == .Switchback && l.direction >= 2 && wz == l.z + l.d / 2 {
			emit_switchback_divider_n(v, wx, wz, l, role, pal.wall)
		} else {
			wall_h := north_wall_height(wx, wz)
			base_n := north_wall_base(wx, wz)
			start_h: f32 = 0
			end_h: f32 = 0
			if has_wall(wx - 1, wz, true) do start_h = north_wall_height(wx - 1, wz)
			if has_wall(wx + 1, wz, true) do end_h = north_wall_height(wx + 1, wz)
			emit_wall(v, wx, wz, true, pal.wall, base_n, wall_h, start_h, end_h)
		}
	}

	// Exposed floor and ceiling discontinuities become visible cliff faces.
	emit_step_w(v, wx, wz)
	emit_step_n(v, wx, wz)
	emit_ceiling_cliff_w(v, wx, wz, pal.ceil)
	emit_ceiling_cliff_n(v, wx, wz, pal.ceil)
}
