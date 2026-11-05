package main

import "core:math"
import "core:time"
import rl "vendor:raylib"
import "vendor:raylib/rlgl"

Verts :: struct {
	pos: [dynamic]f32,
	col: [dynamic]u8,
}

Chunk_Build_Stage :: enum {
	Idle,
	Light_Cache,
	Geometry,
	Upload,
}

Chunk_Builder :: struct {
	active:      bool,
	coord:       Chunk_Coord,
	level:       i32,
	stage:       Chunk_Build_Stage,
	cache_index: int,
	cell_index:  int,
	verts:       Verts,
}

World :: struct {
	chunks:   map[Chunk_Coord]rl.Mesh,
	material: rl.Material,
	builder:  Chunk_Builder,
	level:    i32,
}

// CPU generation is time-sliced. A single cell is the smallest indivisible unit.
CHUNK_BUILD_BUDGET_US :: f64(1500.0)
PLAYER_CHUNK_BUDGET_US :: f64(3500.0)

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
	w.chunks = make(map[Chunk_Coord]rl.Mesh)
	w.material = rl.LoadMaterialDefault()
	w.material.shader = shader
	w.level = current_level
	return w
}

// Build the complete initial view before gameplay starts. This intentionally
// moves the initial generation cost to startup so the player never sees a
// partially populated spawn area. Subsequent movement still streams chunks.
world_preload :: proc(w: ^World, pos: rl.Vector3) {
	pc := Chunk_Coord{
		i32(math.floor(pos.x / CHUNK_W)),
		i32(math.floor(pos.z / CHUNK_W)),
	}

	// Cancel any pending incremental job before synchronous preloading.
	chunk_builder_cancel(&w.builder)

	for radius in 0 ..= VIEW_RADIUS {
		for dz in -radius ..= radius {
			for dx in -radius ..= radius {
				// Build concentric square rings, nearest chunks first.
				if radius > 0 && max(abs(dx), abs(dz)) != radius do continue
				c := pc + {i32(dx), i32(dz)}
				if c in w.chunks do continue
				w.chunks[c] = build_chunk(c)
			}
		}
	}
}

chunk_builder_cancel :: proc(b: ^Chunk_Builder) {
	delete(b.verts.pos)
	delete(b.verts.col)
	b^ = Chunk_Builder{}
}

world_destroy :: proc(w: ^World) {
	chunk_builder_cancel(&w.builder)
	for _, m in w.chunks {
		rl.UnloadMesh(m)
	}
	delete(w.chunks)
}

world_update :: proc(w: ^World, pos: rl.Vector3) {
	pc := Chunk_Coord{i32(math.floor(pos.x / CHUNK_W)), i32(math.floor(pos.z / CHUNK_W))}

	// A level transition invalidates both finished meshes and pending CPU work.
	if w.level != current_level {
		chunk_builder_cancel(&w.builder)
		for _, m in w.chunks {
			rl.UnloadMesh(m)
		}
		delete(w.chunks)
		w.chunks = make(map[Chunk_Coord]rl.Mesh)
		w.level = current_level
	}

	uploaded_this_frame := false

	// Preempt a neighbour job if the player's current chunk is still missing.
	if w.builder.active {
		outside :=
			(abs(w.builder.coord.x - pc.x) > VIEW_RADIUS + 1 ||
				abs(w.builder.coord.y - pc.y) > VIEW_RADIUS + 1)
		is_player_chunk := w.builder.coord.x == pc.x && w.builder.coord.y == pc.y
		player_chunk_missing := pc not_in w.chunks

		if outside ||
		   (player_chunk_missing && !is_player_chunk) ||
		   w.builder.level != current_level {
			chunk_builder_cancel(&w.builder)
		}
	}

	// Upload only a completed mesh, and give that upload its own update frame.
	if w.builder.active && w.builder.stage == .Upload {
		completed_coord := w.builder.coord
		completed_mesh := chunk_builder_upload(&w.builder)
		w.chunks[completed_coord] = completed_mesh
		chunk_builder_cancel(&w.builder)
		uploaded_this_frame = true
	}

	// Start one job at a time. The player's chunk takes priority.
	if !w.builder.active && !uploaded_this_frame {
		target := pc
		has_target := pc not_in w.chunks

		if !has_target {
			best_distance: i32 = 0x7fffffff
			for dz in -VIEW_RADIUS ..= VIEW_RADIUS {
				for dx in -VIEW_RADIUS ..= VIEW_RADIUS {
					c := pc + {i32(dx), i32(dz)}
					if c in w.chunks do continue
					distance := i32(dx * dx + dz * dz)
					if !has_target || distance < best_distance {
						target = c
						best_distance = distance
						has_target = true
					}
				}
			}
		}

		if has_target {
			chunk_builder_begin(&w.builder, target)
		}
	}

	// Do bounded CPU work. Each cache cell or world cell is atomic, so a single
	// expensive cell can exceed the budget slightly, but work resumes next frame.
	if w.builder.active && !uploaded_this_frame && w.builder.stage != .Upload {
		budget_us := CHUNK_BUILD_BUDGET_US
		if w.builder.coord.x == pc.x && w.builder.coord.y == pc.y {
			budget_us = PLAYER_CHUNK_BUDGET_US
		}

		start_tick := time.tick_now()
		did_work := false

		for w.builder.stage != .Upload {
			elapsed_us := time.duration_microseconds(time.tick_since(start_tick))
			if did_work && elapsed_us >= budget_us do break
			chunk_builder_step(&w.builder)
			did_work = true
		}
	}

	// Unload at most one stale mesh in a frame. Do not combine it with a GPU upload.
	if !uploaded_this_frame {
		stale: Chunk_Coord
		has_stale := false

		for c in w.chunks {
			if abs(c.x - pc.x) > VIEW_RADIUS + 1 || abs(c.y - pc.y) > VIEW_RADIUS + 1 {
				stale = c
				has_stale = true
				break
			}
		}

		if has_stale {
			rl.UnloadMesh(w.chunks[stale])
			delete_key(&w.chunks, stale)
		}
	}
}

world_draw :: proc(w: ^World) {
	rlgl.DisableBackfaceCulling()
	for _, m in w.chunks do rl.DrawMesh(m, w.material, rl.Matrix(1))
	rlgl.EnableBackfaceCulling()
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

LIGHT_STEP :: 1
FLAT_STEP :: 1
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


chunk_builder_begin :: proc(b: ^Chunk_Builder, c: Chunk_Coord) {
	chunk_builder_cancel(b)
	b.active = true
	b.coord = c
	b.level = current_level
	b.stage = .Light_Cache
	b.cache_index = 0
	b.cell_index = 0
	light_grid_begin(c)
}

chunk_builder_step :: proc(b: ^Chunk_Builder) {
	switch b.stage {
	case .Light_Cache:
		i := b.cache_index % LIGHT_GRID_N
		j := b.cache_index / LIGHT_GRID_N
		light_grid_fill_cell(i, j)
		b.cache_index += 1
		if b.cache_index >= LIGHT_GRID_N * LIGHT_GRID_N {
			b.stage = .Geometry
		}

	case .Geometry:
		x := i32(b.cell_index % int(CHUNK_SIZE))
		z := i32(b.cell_index / int(CHUNK_SIZE))
		build_chunk_cell(&b.verts, b.coord, x, z)
		b.cell_index += 1
		if b.cell_index >= int(CHUNK_SIZE * CHUNK_SIZE) {
			b.stage = .Upload
		}

	case .Idle, .Upload:
	// Nothing to do in these stages.
	}
}

chunk_builder_upload :: proc(b: ^Chunk_Builder) -> rl.Mesh {
	v := &b.verts
	n := len(v.col) / 4
	m := rl.Mesh {
		vertexCount   = i32(n),
		triangleCount = i32(n / 3),
	}

	if n > 0 {
		m.vertices = cast([^]f32)rl.MemAlloc(u32(len(v.pos) * size_of(f32)))
		m.colors = cast([^]u8)rl.MemAlloc(u32(len(v.col)))
		copy(m.vertices[:len(v.pos)], v.pos[:])
		copy(m.colors[:len(v.col)], v.col[:])
		rl.UploadMesh(&m, false)
	}

	return m
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
	fh := floor_h(wx, wz)

	// Floor.
	if stair_at(wx, wz) {
		emit_stair(v, wx, wz, fh, pal.floor, k)
	} else if hole_at(wx, wz) {
		emit_hole(v, wx, wz, fh)
	} else if pool_at(wx, wz) {
		water_col := rl.Color{50, 160, 190, 255}
		flat_lit(v, {x0, fh, z0}, {x1, fh, z0}, {x1, fh, z1}, {x0, fh, z1}, water_col)
	} else {
		flat_lit(v, {x0, fh, z0}, {x1, fh, z0}, {x1, fh, z1}, {x0, fh, z1}, shade(pal.floor, k))
	}

	// Ceiling.
	flat_lit(v, {x0, h_nw, z0}, {x1, h_ne, z0}, {x1, h_se, z1}, {x0, h_sw, z1}, shade(pal.ceil, k))

	emit_decals(v, wx, wz, biome, fh)

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
	}

	// Pillar.
	if pillar_at(wx, wz) {
		i :: CELL * 0.3
		ph := max(h_nw, h_ne, h_se, h_sw) + 0.05
		wall_box(v, {x0 + i, z0 + i}, {x1 - i, z1 - i}, pal.wall, fh, ph)
	}

	// West wall.
	if has_wall(wx, wz, false) {
		wall_h := west_wall_height(wx, wz)
		base_w := west_wall_base(wx, wz)
		start_h: f32 = 0
		end_h: f32 = 0
		if has_wall(wx, wz - 1, false) do start_h = west_wall_height(wx, wz - 1)
		if has_wall(wx, wz + 1, false) do end_h = west_wall_height(wx, wz + 1)
		emit_wall(v, wx, wz, false, pal.wall, base_w, wall_h, start_h, end_h)
	}

	// North wall.
	if has_wall(wx, wz, true) {
		wall_h := north_wall_height(wx, wz)
		base_n := north_wall_base(wx, wz)
		start_h: f32 = 0
		end_h: f32 = 0
		if has_wall(wx - 1, wz, true) do start_h = north_wall_height(wx - 1, wz)
		if has_wall(wx + 1, wz, true) do end_h = north_wall_height(wx + 1, wz)
		emit_wall(v, wx, wz, true, pal.wall, base_n, wall_h, start_h, end_h)
	}

	// Floor step risers.
	emit_step_w(v, wx, wz)
	emit_step_n(v, wx, wz)
}

// Compatibility helper for tools that still request a fully built mesh directly.
// Normal gameplay should use world_update's time-sliced Chunk_Builder instead.
build_chunk :: proc(c: Chunk_Coord) -> rl.Mesh {
	b: Chunk_Builder
	chunk_builder_begin(&b, c)

	for b.stage != .Upload {
		chunk_builder_step(&b)
	}

	m := chunk_builder_upload(&b)
	chunk_builder_cancel(&b)
	return m
}
