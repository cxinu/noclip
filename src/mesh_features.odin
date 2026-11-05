package main

import "core:math"
import rl "vendor:raylib"

// Per-cell floor/ceiling features: legacy stairs/holes, decals, steps, ceiling cliffs.

// 5 discrete treads + risers per stair cell. Steps face the direction of
// ascent; player feet are snapped to the tread centre by ground_at.
emit_stair :: proc(v: ^Verts, wx, wz: i32, base_y: f32, col: rl.Color, k: i32) {
	x0, z0 := f32(wx) * CELL, f32(wz) * CELL
	d := stair_dir_at(wx, wz)
	tread_col := shade(col, k)
	riser_col := shade(col, k - 22)

	N :: STAIR_STEPS

	for i in 0 ..< N {
		t0 := f32(i) / f32(N)
		t1 := f32(i + 1) / f32(N)
		y := base_y + STAIR_RISE * (f32(i) + 0.5) / f32(N)

		a, b, c, dd: [3]f32
		switch d {
		case 0:
			// ascends north, top at z0
			a = {x0, y, z0 + (1 - t1) * CELL}
			b = {x0 + CELL, y, z0 + (1 - t1) * CELL}
			c = {x0 + CELL, y, z0 + (1 - t0) * CELL}
			dd = {x0, y, z0 + (1 - t0) * CELL}
		case 1:
			// south
			a = {x0, y, z0 + t0 * CELL}
			b = {x0 + CELL, y, z0 + t0 * CELL}
			c = {x0 + CELL, y, z0 + t1 * CELL}
			dd = {x0, y, z0 + t1 * CELL}
		case 2:
			// east
			a = {x0 + t0 * CELL, y, z0}
			b = {x0 + t0 * CELL, y, z0 + CELL}
			c = {x0 + t1 * CELL, y, z0 + CELL}
			dd = {x0 + t1 * CELL, y, z0}
		case 3:
			// west
			a = {x0 + (1 - t1) * CELL, y, z0}
			b = {x0 + (1 - t1) * CELL, y, z0 + CELL}
			c = {x0 + (1 - t0) * CELL, y, z0 + CELL}
			dd = {x0 + (1 - t0) * CELL, y, z0}
		}
		flat_lit(v, a, b, c, dd, tread_col)

		// Riser facing the descending direction, at t = (i+1)/N
		y_next := base_y + STAIR_RISE * (f32(i + 1) + 0.5) / f32(N)
		ra, rb, rc, rd: [3]f32
		switch d {
		case 0:
			rz := z0 + (1 - t1) * CELL
			ra = {x0, y_next, rz}; rb = {x0 + CELL, y_next, rz}
			rc = {x0 + CELL, y, rz}; rd = {x0, y, rz}
		case 1:
			rz := z0 + t1 * CELL
			ra = {x0, y_next, rz}; rb = {x0 + CELL, y_next, rz}
			rc = {x0 + CELL, y, rz}; rd = {x0, y, rz}
		case 2:
			rx := x0 + t1 * CELL
			ra = {rx, y_next, z0}; rb = {rx, y_next, z0 + CELL}
			rc = {rx, y, z0 + CELL}; rd = {rx, y, z0}
		case 3:
			rx := x0 + (1 - t1) * CELL
			ra = {rx, y_next, z0}; rb = {rx, y_next, z0 + CELL}
			rc = {rx, y, z0 + CELL}; rd = {rx, y, z0}
		}
		quad(v, ra, rb, rc, rd, riser_col)
	}
	// Lowest riser (from base floor to step 0's tread)
	tread0_y := base_y + STAIR_RISE * 0.5 / f32(N)
	ra, rb, rc, rd: [3]f32
	switch d {
	case 0:
		rz := z0 + CELL
		ra = {x0, tread0_y, rz}; rb = {x0 + CELL, tread0_y, rz}
		rc = {x0 + CELL, base_y, rz}; rd = {x0, base_y, rz}
	case 1:
		rz := z0
		ra = {x0, tread0_y, rz}; rb = {x0 + CELL, tread0_y, rz}
		rc = {x0 + CELL, base_y, rz}; rd = {x0, base_y, rz}
	case 2:
		rx := x0
		ra = {rx, tread0_y, z0}; rb = {rx, tread0_y, z0 + CELL}
		rc = {rx, base_y, z0 + CELL}; rd = {rx, base_y, z0}
	case 3:
		rx := x0 + CELL
		ra = {rx, tread0_y, z0}; rb = {rx, tread0_y, z0 + CELL}
		rc = {rx, base_y, z0 + CELL}; rd = {rx, base_y, z0}
	}
	quad(v, ra, rb, rc, rd, riser_col)
}

// Shaft: no floor, 4 short walls going down, black bottom.
emit_hole :: proc(v: ^Verts, wx, wz: i32, base_y: f32) {
	x0, z0 := f32(wx) * CELL, f32(wz) * CELL
	x1, z1 := x0 + CELL, z0 + CELL
	y_bot := base_y - HOLE_DEPTH - 1
	dark := rl.Color{4, 4, 6, 255}
	quad(v, {x0, y_bot, z0}, {x1, y_bot, z0}, {x1, y_bot, z1}, {x0, y_bot, z1}, dark)

	wall_col := rl.Color{38, 38, 42, 255}
	quad(v, {x0, base_y, z0}, {x0, base_y, z1}, {x0, y_bot, z1}, {x0, y_bot, z0}, wall_col) // W
	quad(v, {x1, base_y, z0}, {x1, base_y, z1}, {x1, y_bot, z1}, {x1, y_bot, z0}, wall_col) // E
	quad(v, {x0, base_y, z0}, {x1, base_y, z0}, {x1, y_bot, z0}, {x0, y_bot, z0}, wall_col) // N
	quad(v, {x0, base_y, z1}, {x1, base_y, z1}, {x1, y_bot, z1}, {x0, y_bot, z1}, wall_col) // S
}

emit_decals :: proc(v: ^Verts, wx, wz: i32, biome: Biome_Type, floor_y: f32) {
	x0, z0 := f32(wx) * CELL, f32(wz) * CELL
	y := floor_y + 0.02
	h := raw_hash(wx * 13 + 1, wz * 7 + 2)
	#partial switch biome {
	case .Parking_Garage:
		flat_lit(
			v,
			{x0, y, z0 + 0.6},
			{x0 + 0.12, y, z0 + 0.6},
			{x0 + 0.12, y, z0 + 3.4},
			{x0, y, z0 + 3.4},
			{110, 110, 100, 255},
		)
	case .Warehouse:
		if wz %% 6 == 0 {
			flat_lit(
				v,
				{x0, y, z0},
				{x0 + CELL, y, z0},
				{x0 + CELL, y, z0 + 0.15},
				{x0, y, z0 + 0.15},
				{120, 100, 25, 255},
			)
		}
	case .Poolrooms, .Concrete_Maze, .Sub_Basement:
		if (h >> 5) % 37 == 0 {
			flat_lit(
				v,
				{x0 + 1.7, y, z0 + 1.7},
				{x0 + 2.3, y, z0 + 1.7},
				{x0 + 2.3, y, z0 + 2.3},
				{x0 + 1.7, y, z0 + 2.3},
				{8, 8, 8, 255},
			)
		}
	}
}

emit_step_w :: proc(v: ^Verts, wx, wz: i32) {
	if has_wall(wx, wz, false) do return
	if _, link_here, _ := vertical_link_at(wx, wz); link_here do return
	if _, link_west, _ := vertical_link_at(wx - 1, wz); link_west do return
	if floor_level(wx, wz) == floor_level(wx - 1, wz) do return
	y0 := floor_h(wx, wz)
	y1 := floor_h(wx - 1, wz)
	if math.abs(y0 - y1) < 0.08 do return
	col := shade(PALETTES[biome_at(wx, wz)].floor, -34)
	x := f32(wx) * CELL
	z0 := f32(wz) * CELL - STEP_EPS
	z1 := f32(wz) * CELL + CELL + STEP_EPS
	lo, hi := min(y0, y1), max(y0, y1)
	lit_quad(v, {x, lo, z0}, {x, hi, z0}, {x, hi, z1}, {x, lo, z1}, col)
}

emit_step_n :: proc(v: ^Verts, wx, wz: i32) {
	if has_wall(wx, wz, true) do return
	if _, link_here, _ := vertical_link_at(wx, wz); link_here do return
	if _, link_north, _ := vertical_link_at(wx, wz - 1); link_north do return
	if floor_level(wx, wz) == floor_level(wx, wz - 1) do return
	y0 := floor_h(wx, wz)
	y1 := floor_h(wx, wz - 1)
	if math.abs(y0 - y1) < 0.08 do return
	col := shade(PALETTES[biome_at(wx, wz)].floor, -34)
	x0 := f32(wx) * CELL - STEP_EPS
	x1 := f32(wx) * CELL + CELL + STEP_EPS
	z := f32(wz) * CELL
	lo, hi := min(y0, y1), max(y0, y1)
	lit_quad(v, {x0, lo, z}, {x1, lo, z}, {x1, hi, z}, {x0, hi, z}, col)
}

emit_ceiling_cliff_w :: proc(v: ^Verts, wx, wz: i32, col: rl.Color) {
	if has_wall(wx, wz, false) do return
	if _, link_here, _ := vertical_link_at(wx, wz); link_here do return
	if _, link_west, _ := vertical_link_at(wx - 1, wz); link_west do return
	d0, d1 := ceil_h(wx, wz), ceil_h(wx - 1, wz)
	if math.abs(d0 - d1) < 0.12 do return
	x := f32(wx) * CELL
	z0, z1 := f32(wz) * CELL, f32(wz + 1) * CELL
	lo, hi := min(d0, d1), max(d0, d1)
	quad(v, {x, lo, z0}, {x, hi, z0}, {x, hi, z1}, {x, lo, z1}, shade(col, -18))
}

emit_ceiling_cliff_n :: proc(v: ^Verts, wx, wz: i32, col: rl.Color) {
	if has_wall(wx, wz, true) do return
	if _, link_here, _ := vertical_link_at(wx, wz); link_here do return
	if _, link_north, _ := vertical_link_at(wx, wz - 1); link_north do return
	d0, d1 := ceil_h(wx, wz), ceil_h(wx, wz - 1)
	if math.abs(d0 - d1) < 0.12 do return
	z := f32(wz) * CELL
	x0, x1 := f32(wx) * CELL, f32(wx + 1) * CELL
	lo, hi := min(d0, d1), max(d0, d1)
	quad(v, {x0, lo, z}, {x1, lo, z}, {x1, hi, z}, {x0, hi, z}, shade(col, -18))
}
