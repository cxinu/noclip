package main

import "core:math"
import rl "vendor:raylib"
import "vendor:raylib/rlgl"

World :: struct {
	chunks:   map[Chunk_Coord]rl.Mesh,
	material: rl.Material,
}

west_wall_height :: proc(x, z: i32) -> f32 {return max(corner_h(x, z), corner_h(x, z + 1)) + 0.05}
north_wall_height :: proc(x, z: i32) -> f32 {return max(corner_h(x, z), corner_h(x + 1, z)) + 0.05}
west_wall_base :: proc(x, z: i32) -> f32 {return min(floor_h(x, z), floor_h(x - 1, z))}
north_wall_base :: proc(x, z: i32) -> f32 {return min(floor_h(x, z), floor_h(x, z - 1))}

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
	}
}

shade :: proc(c: rl.Color, k: i32) -> rl.Color {
	return {
		u8(clamp(i32(c.r) + k, 0, 255)),
		u8(clamp(i32(c.g) + k, 0, 255)),
		u8(clamp(i32(c.b) + k, 0, 255)),
		255,
	}
}

world_init :: proc(shader: rl.Shader) -> World {
	w: World
	w.material = rl.LoadMaterialDefault()
	w.material.shader = shader
	return w
}

world_destroy :: proc(w: ^World) {
	for _, m in w.chunks do rl.UnloadMesh(m)
	delete(w.chunks)
}

world_update :: proc(w: ^World, pos: rl.Vector3) {
	pc := Chunk_Coord{i32(math.floor(pos.x / CHUNK_W)), i32(math.floor(pos.z / CHUNK_W))}
	if pc not_in w.chunks do w.chunks[pc] = build_chunk(pc)

	// Build the closest missing neighbour first. The old nested-loop order
	// could spend a frame generating a farther diagonal chunk while a nearer
	// chunk was still missing.
	best_chunk: Chunk_Coord
	best_distance: i32 = 0x7fffffff
	has_missing := false
	for dz in -VIEW_RADIUS ..= VIEW_RADIUS do for dx in -VIEW_RADIUS ..= VIEW_RADIUS {
		c := pc + {i32(dx), i32(dz)}
		if c in w.chunks do continue
		distance := i32(dx * dx + dz * dz)
		if !has_missing || distance < best_distance {
			best_chunk = c
			best_distance = distance
			has_missing = true
		}
	}
	if has_missing do w.chunks[best_chunk] = build_chunk(best_chunk)

	stale := make([dynamic]Chunk_Coord, context.temp_allocator)
	for c in w.chunks {
		if abs(c.x - pc.x) > VIEW_RADIUS + 1 || abs(c.y - pc.y) > VIEW_RADIUS + 1 do append(&stale, c)
	}
	for c in stale {rl.UnloadMesh(w.chunks[c]); delete_key(&w.chunks, c)}

}

world_draw :: proc(w: ^World) {
	rlgl.DisableBackfaceCulling()
	for _, m in w.chunks do rl.DrawMesh(m, w.material, rl.Matrix(1))
	rlgl.EnableBackfaceCulling()
}

Verts :: struct {
	pos: [dynamic]f32,
	col: [dynamic]u8,
}

quad :: proc(v: ^Verts, a, b, c, d: [3]f32, col: rl.Color) {
	for p in ([6][3]f32{a, b, c, a, c, d}) {
		append(&v.pos, p.x, p.y, p.z)
		append(&v.col, col.r, col.g, col.b, 255)
	}
}

quad_colored :: proc(
	v: ^Verts,
	a: [3]f32,
	ca: rl.Color,
	b: [3]f32,
	cb: rl.Color,
	c: [3]f32,
	cc: rl.Color,
	d: [3]f32,
	cd: rl.Color,
) {
	pts := [6][3]f32{a, b, c, a, c, d}
	cols := [6]rl.Color{ca, cb, cc, ca, cc, cd}
	for i in 0 ..< 6 {
		append(&v.pos, pts[i].x, pts[i].y, pts[i].z)
		append(&v.col, cols[i].r, cols[i].g, cols[i].b, 255)
	}
}

LIGHT_STEP :: 1.0
FLAT_STEP :: 1.0
Z_FACE_K :: 0.93
WALL_EPS :: 0.08
STEP_EPS :: 0.03

lit_quad :: proc(
	v: ^Verts,
	a, b, c, d: [3]f32,
	col: rl.Color,
	k: f32 = 1.0,
	step: f32 = LIGHT_STEP,
	inset: [2]bool = {},
	shift: [2]f32 = {},
) {
	len_u := max(linalg_len(b - a), linalg_len(c - d))
	len_v := max(linalg_len(d - a), linalg_len(c - b))
	nu := clamp(int(math.ceil(len_u / step)), 1, 16)
	nv := clamp(int(math.ceil(len_v / step)), 1, 16)

	bil :: proc(a, b, c, d: [3]f32, u, w: f32) -> [3]f32 {
		return a * ((1 - u) * (1 - w)) + b * (u * (1 - w)) + c * (u * w) + d * ((1 - u) * w)
	}
	pts: [17 * 17][3]f32
	cols: [17 * 17]rl.Color
	stride := nu + 1
	for j in 0 ..= nv do for i in 0 ..= nu {
		p := bil(a, b, c, d, f32(i) / f32(nu), f32(j) / f32(nv))
		pts[j * stride + i] = p
		cols[j * stride + i] = compute_vertex_lighting(p, col, k, inset, shift)
	}
	for j in 0 ..< nv do for i in 0 ..< nu {
		i00 := j * stride + i
		i10 := i00 + 1
		i01 := i00 + stride
		i11 := i01 + 1
		quad_colored(v, pts[i00], cols[i00], pts[i10], cols[i10], pts[i11], cols[i11], pts[i01], cols[i01])
	}
}

linalg_len :: proc(p: [3]f32) -> f32 {return math.sqrt(p.x * p.x + p.y * p.y + p.z * p.z)}

flat_lit :: proc(v: ^Verts, a, b, c, d: [3]f32, col: rl.Color) {
	lit_quad(v, a, b, c, d, col, 1.0, FLAT_STEP, {true, true})
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

bilerp4 :: proc(nw, ne, se, sw, u, w: f32) -> f32 {
	top := nw + (ne - nw) * u
	bot := sw + (se - sw) * u
	return top + (bot - top) * w
}

// ───────────────────────── NEW: stair + hole rendering ─────────────────────────

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
	lvl := floor_level(wx, wz)
	nlvl := floor_level(wx - 1, wz)
	if lvl == nlvl do return
	col := shade(PALETTES[biome_at(wx, wz)].floor, -28)
	x0 := f32(wx) * CELL
	z0 := f32(wz) * CELL - STEP_EPS
	z1 := f32(wz) * CELL + CELL + STEP_EPS
	y_lo := min(f32(lvl), f32(nlvl)) * FLOOR_STEP
	y_hi := max(f32(lvl), f32(nlvl)) * FLOOR_STEP
	lit_quad(v, {x0, y_lo, z0}, {x0, y_hi, z0}, {x0, y_hi, z1}, {x0, y_lo, z1}, col)
}

emit_step_n :: proc(v: ^Verts, wx, wz: i32) {
	lvl := floor_level(wx, wz)
	nlvl := floor_level(wx, wz - 1)
	if lvl == nlvl do return
	col := shade(PALETTES[biome_at(wx, wz)].floor, -28)
	x0 := f32(wx) * CELL - STEP_EPS
	x1 := f32(wx) * CELL + CELL + STEP_EPS
	z0 := f32(wz) * CELL
	y_lo := min(f32(lvl), f32(nlvl)) * FLOOR_STEP
	y_hi := max(f32(lvl), f32(nlvl)) * FLOOR_STEP
	lit_quad(v, {x0, y_lo, z0}, {x1, y_lo, z0}, {x1, y_hi, z0}, {x0, y_hi, z0}, col)
}

build_chunk :: proc(c: Chunk_Coord) -> rl.Mesh {
	v: Verts
	defer {delete(v.pos); delete(v.col)}
	light_grid_fill(c)

	for z in 0 ..< i32(CHUNK_SIZE) do for x in 0 ..< i32(CHUNK_SIZE) {
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
		fh := floor_h(wx, wz)

		// ── floor: stair / hole / pool / flat ──
		if stair_at(wx, wz) {
			emit_stair(&v, wx, wz, fh, pal.floor, k)
		} else if hole_at(wx, wz) {
			emit_hole(&v, wx, wz, fh)
		} else if pool_at(wx, wz) {
			water_col := rl.Color{50, 160, 190, 255}
			flat_lit(&v, {x0, fh, z0}, {x1, fh, z0}, {x1, fh, z1}, {x0, fh, z1}, water_col)
		} else {
			flat_lit(&v, {x0, fh, z0}, {x1, fh, z0}, {x1, fh, z1}, {x0, fh, z1}, shade(pal.floor, k))
		}

		// ── ceiling ──
		flat_lit(&v, {x0, h_nw, z0}, {x1, h_ne, z0}, {x1, h_se, z1}, {x0, h_sw, z1}, shade(pal.ceil, k))

		emit_decals(&v, wx, wz, biome, fh)

		// ── light ──
		if pw := light_power(wx, wz); pw > 0 {
			lx0, lz0 := x0 + CELL * 0.25, z0 + CELL * 0.25
			lx1, lz1 := x0 + CELL * 0.75, z0 + CELL * 0.75
			y00 := bilerp4(h_nw, h_ne, h_se, h_sw, 0.25, 0.25) - 0.02
			y10 := bilerp4(h_nw, h_ne, h_se, h_sw, 0.75, 0.25) - 0.02
			y11 := bilerp4(h_nw, h_ne, h_se, h_sw, 0.75, 0.75) - 0.02
			y01 := bilerp4(h_nw, h_ne, h_se, h_sw, 0.25, 0.75) - 0.02
			base_lcol := light_color(wx, wz)
			quad(&v, {lx0, y00, lz0}, {lx1, y10, lz0}, {lx1, y11, lz1}, {lx0, y01, lz1}, base_lcol)
		}

		// ── pillar ──
		if pillar_at(wx, wz) {
			i :: CELL * 0.3
			ph := max(h_nw, h_ne, h_se, h_sw) + 0.05
			wall_box(&v, {x0 + i, z0 + i}, {x1 - i, z1 - i}, pal.wall, fh, ph)
		}

		// ── walls ──
		if has_wall(wx, wz, false) {
			wall_h := west_wall_height(wx, wz)
			base_w := west_wall_base(wx, wz)
			start_h: f32 = 0; end_h: f32 = 0
			if has_wall(wx, wz - 1, false) do start_h = west_wall_height(wx, wz - 1)
			if has_wall(wx, wz + 1, false) do end_h = west_wall_height(wx, wz + 1)
			emit_wall(&v, wx, wz, false, pal.wall, base_w, wall_h, start_h, end_h)
		}
		if has_wall(wx, wz, true) {
			wall_h := north_wall_height(wx, wz)
			base_n := north_wall_base(wx, wz)
			start_h: f32 = 0; end_h: f32 = 0
			if has_wall(wx - 1, wz, true) do start_h = north_wall_height(wx - 1, wz)
			if has_wall(wx + 1, wz, true) do end_h = north_wall_height(wx + 1, wz)
			emit_wall(&v, wx, wz, true, pal.wall, base_n, wall_h, start_h, end_h)
		}

		// ── floor step risers ──
		emit_step_w(&v, wx, wz)
		emit_step_n(&v, wx, wz)
	}

	n := len(v.col) / 4
	m := rl.Mesh {
		vertexCount   = i32(n),
		triangleCount = i32(n / 3),
	}
	m.vertices = cast([^]f32)rl.MemAlloc(u32(len(v.pos) * size_of(f32)))
	m.colors = cast([^]u8)rl.MemAlloc(u32(len(v.col)))
	copy(m.vertices[:len(v.pos)], v.pos[:])
	copy(m.colors[:len(v.col)], v.col[:])
	rl.UploadMesh(&m, false)
	return m
}
