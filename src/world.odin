package main

import "core:math"
import rl "vendor:raylib"
import "vendor:raylib/rlgl"

World :: struct {
	chunks:   map[Chunk_Coord]rl.Mesh,
	material: rl.Material,
}

west_wall_height :: proc(x, z: i32) -> f32 {
	return max(corner_h(x, z), corner_h(x, z + 1)) + 0.05
}

north_wall_height :: proc(x, z: i32) -> f32 {
	return max(corner_h(x, z), corner_h(x + 1, z)) + 0.05
}

wall_cap_x :: proc(v: ^Verts, x, z0, z1, y0, y1: f32, col: rl.Color) {
	if y1 <= y0 do return
	lit_quad(v, {x, y0, z0}, {x, y1, z0}, {x, y1, z1}, {x, y0, z1}, col)
}

wall_box :: proc(v: ^Verts, lo, hi: [2]f32, col: rl.Color, h: f32) {
	dark := shade(col, -14)
	lit_quad(v, {lo.x, 0, lo.y}, {lo.x, h, lo.y}, {lo.x, h, hi.y}, {lo.x, 0, hi.y}, col)
	lit_quad(v, {hi.x, 0, lo.y}, {hi.x, h, lo.y}, {hi.x, h, hi.y}, {hi.x, 0, hi.y}, col)
	lit_quad(v, {lo.x, 0, lo.y}, {hi.x, 0, lo.y}, {hi.x, h, lo.y}, {lo.x, h, lo.y}, dark)
	lit_quad(v, {lo.x, 0, hi.y}, {hi.x, 0, hi.y}, {hi.x, h, hi.y}, {lo.x, h, hi.y}, dark)
}

wall_cap_z :: proc(v: ^Verts, z, x0, x1, y0, y1: f32, col: rl.Color) {
	if y1 <= y0 do return
	pa := [3]f32{x0, y0, z}
	pb := [3]f32{x1, y0, z}
	pc := [3]f32{x1, y1, z}
	pd := [3]f32{x0, y1, z}
	lit_quad(v, pa, pb, pc, pd, col, Z_FACE_K)
}

wall_segment :: proc(
	v: ^Verts,
	lo, hi: [2]f32,
	col: rl.Color,
	y0, h: f32,
	north: bool,
	start_neighbor_h, end_neighbor_h: f32,
) {
	if north {
		lit_quad(
			v,
			{lo.x, y0, lo.y},
			{hi.x, y0, lo.y},
			{hi.x, h, lo.y},
			{lo.x, h, lo.y},
			col,
			Z_FACE_K,
		)
		lit_quad(
			v,
			{lo.x, y0, hi.y},
			{hi.x, y0, hi.y},
			{hi.x, h, hi.y},
			{lo.x, h, hi.y},
			col,
			Z_FACE_K,
		)
		wall_cap_x(v, lo.x, lo.y, hi.y, start_neighbor_h, h, col)
		wall_cap_x(v, hi.x, lo.y, hi.y, end_neighbor_h, h, col)
	} else {
		lit_quad(v, {lo.x, y0, lo.y}, {lo.x, h, lo.y}, {lo.x, h, hi.y}, {lo.x, y0, hi.y}, col)
		lit_quad(v, {hi.x, y0, lo.y}, {hi.x, h, lo.y}, {hi.x, h, hi.y}, {hi.x, y0, hi.y}, col)
		wall_cap_z(v, lo.y, lo.x, hi.x, start_neighbor_h, h, col)
		wall_cap_z(v, hi.y, lo.x, hi.x, end_neighbor_h, h, col)
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

	// the chunk we're standing in must exist; everything else builds one per frame
	if pc not_in w.chunks do w.chunks[pc] = build_chunk(pc)

	built := false
	for dz in -VIEW_RADIUS ..= VIEW_RADIUS {
		for dx in -VIEW_RADIUS ..= VIEW_RADIUS {
			if built do continue
			c := pc + {i32(dx), i32(dz)}
			if c in w.chunks do continue
			w.chunks[c] = build_chunk(c)
			built = true
		}
	}

	stale := make([dynamic]Chunk_Coord, context.temp_allocator)
	for c in w.chunks {
		if abs(c.x - pc.x) > VIEW_RADIUS + 1 || abs(c.y - pc.y) > VIEW_RADIUS + 1 {
			append(&stale, c)
		}
	}
	for c in stale {
		rl.UnloadMesh(w.chunks[c])
		delete_key(&w.chunks, c)
	}
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

LIGHT_STEP :: 1.0 // walls / pillars
FLAT_STEP :: 1.0 // floors / ceilings (raise to 2.0 if chunk builds hitch)
Z_FACE_K :: 0.93

lit_quad :: proc(
	v: ^Verts,
	a, b, c, d: [3]f32,
	col: rl.Color,
	k: f32 = 1.0,
	step: f32 = LIGHT_STEP,
	inset := false,
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
	for j in 0 ..= nv {
		for i in 0 ..= nu {
			p := bil(a, b, c, d, f32(i) / f32(nu), f32(j) / f32(nv))
			pts[j * stride + i] = p
			cols[j * stride + i] = compute_vertex_lighting(p, col, k, inset)
		}
	}

	for j in 0 ..< nv {
		for i in 0 ..< nu {
			i00 := j * stride + i
			i10 := i00 + 1
			i01 := i00 + stride
			i11 := i01 + 1
			quad_colored(
				v,
				pts[i00],
				cols[i00],
				pts[i10],
				cols[i10],
				pts[i11],
				cols[i11],
				pts[i01],
				cols[i01],
			)
		}
	}
}

linalg_len :: proc(p: [3]f32) -> f32 {
	return math.sqrt(p.x * p.x + p.y * p.y + p.z * p.z)
}

flat_lit :: proc(v: ^Verts, a, b, c, d: [3]f32, col: rl.Color) {
	lit_quad(v, a, b, c, d, col, 1.0, FLAT_STEP)
}

Wall_Box_Def :: struct {
	lo, hi: [2]f32,
	y0:     f32,
}

emit_wall :: proc(v: ^Verts, wx, wz: i32, north: bool, col: rl.Color, h, start_h, end_h: f32) {
	boxes, n := wall_pieces(wx, wz, north, h)

	if n == 1 {
		wall_segment(v, boxes[0].lo, boxes[0].hi, col, 0, h, north, start_h, end_h)
		return
	}

	wall_segment(v, boxes[0].lo, boxes[0].hi, col, 0, h, north, start_h, 0)
	wall_segment(v, boxes[1].lo, boxes[1].hi, col, 0, h, north, 0, end_h)

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
	)
}

bilerp4 :: proc(nw, ne, se, sw, u, w: f32) -> f32 {
	top := nw + (ne - nw) * u
	bot := sw + (se - sw) * u
	return top + (bot - top) * w
}

emit_decals :: proc(v: ^Verts, wx, wz: i32, biome: Biome_Type) {
	x0, z0 := f32(wx) * CELL, f32(wz) * CELL
	h := raw_hash(wx * 13 + 1, wz * 7 + 2)
	#partial switch biome {
	case .Parking_Garage:
		flat_lit(
			v,
			{x0, 0.02, z0 + 0.6},
			{x0 + 0.12, 0.02, z0 + 0.6},
			{x0 + 0.12, 0.02, z0 + 3.4},
			{x0, 0.02, z0 + 3.4},
			{110, 110, 100, 255},
		)
	case .Warehouse:
		if wz %% 6 == 0 {
			flat_lit(
				v,
				{x0, 0.02, z0},
				{x0 + CELL, 0.02, z0},
				{x0 + CELL, 0.02, z0 + 0.15},
				{x0, 0.02, z0 + 0.15},
				{120, 100, 25, 255},
			)
		}
	case .Poolrooms, .Concrete_Maze, .Sub_Basement:
		if (h >> 5) % 37 == 0 {
			flat_lit(
				v,
				{x0 + 1.7, 0.02, z0 + 1.7},
				{x0 + 2.3, 0.02, z0 + 1.7},
				{x0 + 2.3, 0.02, z0 + 2.3},
				{x0 + 1.7, 0.02, z0 + 2.3},
				{8, 8, 8, 255},
			)
		}
	}
}

build_chunk :: proc(c: Chunk_Coord) -> rl.Mesh {
	v: Verts
	defer {
		delete(v.pos)
		delete(v.col)
	}
	light_grid_fill(c)

	for z in 0 ..< i32(CHUNK_SIZE) {
		for x in 0 ..< i32(CHUNK_SIZE) {
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

			// Floor generation (with recessed Poolrooms water basins)
			if pool_at(wx, wz) {
				pool_depth :: 0.15
				water_col := rl.Color{50, 160, 190, 255}
				flat_lit(
					&v,
					{x0, -pool_depth, z0},
					{x1, -pool_depth, z0},
					{x1, -pool_depth, z1},
					{x0, -pool_depth, z1},
					water_col,
				)
			} else {
				flat_lit(
					&v,
					{x0, 0, z0},
					{x1, 0, z0},
					{x1, 0, z1},
					{x0, 0, z1},
					shade(pal.floor, k),
				)
			}

			flat_lit(
				&v,
				{x0, h_nw, z0},
				{x1, h_ne, z0},
				{x1, h_se, z1},
				{x0, h_sw, z1},
				shade(pal.ceil, k),
			)

			emit_decals(&v, wx, wz, biome)

			// Ceiling lights (using biome custom colors like Red Rooms emergency red)
			if pw := light_power(wx, wz); pw > 0 {
				lx0, lz0 := x0 + CELL * 0.25, z0 + CELL * 0.25
				lx1, lz1 := x0 + CELL * 0.75, z0 + CELL * 0.75
				y00 := bilerp4(h_nw, h_ne, h_se, h_sw, 0.25, 0.25) - 0.02
				y10 := bilerp4(h_nw, h_ne, h_se, h_sw, 0.75, 0.25) - 0.02
				y11 := bilerp4(h_nw, h_ne, h_se, h_sw, 0.75, 0.75) - 0.02
				y01 := bilerp4(h_nw, h_ne, h_se, h_sw, 0.25, 0.75) - 0.02

				base_lcol := light_color(wx, wz)
				quad(
					&v,
					{lx0, y00, lz0},
					{lx1, y10, lz0},
					{lx1, y11, lz1},
					{lx0, y01, lz1},
					base_lcol,
				)
			}

			// pillars
			if pillar_at(wx, wz) {
				i :: CELL * 0.3
				ph := max(h_nw, h_ne, h_se, h_sw) + 0.05
				wall_box(&v, {x0 + i, z0 + i}, {x1 - i, z1 - i}, pal.wall, ph)
			}

			// West wall
			if has_wall(wx, wz, false) {
				wall_h := west_wall_height(wx, wz)

				start_h: f32 = 0
				end_h: f32 = 0
				if has_wall(wx, wz - 1, false) do start_h = west_wall_height(wx, wz - 1)
				if has_wall(wx, wz + 1, false) do end_h = west_wall_height(wx, wz + 1)

				emit_wall(&v, wx, wz, false, pal.wall, wall_h, start_h, end_h)
			}

			// North wall
			if has_wall(wx, wz, true) {
				wall_h := north_wall_height(wx, wz)

				start_h: f32 = 0
				end_h: f32 = 0
				if has_wall(wx - 1, wz, true) do start_h = north_wall_height(wx - 1, wz)
				if has_wall(wx + 1, wz, true) do end_h = north_wall_height(wx + 1, wz)

				emit_wall(&v, wx, wz, true, pal.wall, wall_h, start_h, end_h)
			}
		}
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
