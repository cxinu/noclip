package main

import "core:math"
import rl "vendor:raylib"

// Baked vertex lighting.
//
// Lights sit on a global lattice (see biome.odin:light_power). For each chunk we
// snapshot the lights and the solid wall edges around it, then every emitted
// vertex sums only the lights it can actually see. light_blocked walks the cell
// grid with a DDA and tests the actual vertical wall span and doorway aperture.

LIGHT_PAD :: 4
LIGHT_GRID_N :: CHUNK_SIZE + 2 * LIGHT_PAD
LIGHT_RADIUS :: 10.0
LIGHT_CULL_R :: i32(3)

AMBIENT :: 0.22
LIGHT_GAIN :: 2.4

CEIL_SLACK :: 0.35

Door_Opening :: struct {
	min, max: f32,
	top:      f32,
}

Light_Grid :: struct {
	ox, oz:      i32,
	top:         [LIGHT_GRID_N][LIGHT_GRID_N]f32,
	power:       [LIGHT_GRID_N][LIGHT_GRID_N]f32,
	color:       [LIGHT_GRID_N][LIGHT_GRID_N][3]f32,

	// Wall vertical spans.
	wall_w:      [LIGHT_GRID_N][LIGHT_GRID_N]f32,
	wall_n:      [LIGHT_GRID_N][LIGHT_GRID_N]f32,
	wall_w_base: [LIGHT_GRID_N][LIGHT_GRID_N]f32,
	wall_n_base: [LIGHT_GRID_N][LIGHT_GRID_N]f32,
	ceil:        [LIGHT_GRID_N][LIGHT_GRID_N]f32,

	// Doorway apertures in absolute world coordinates.
	door_w_min:  [LIGHT_GRID_N][LIGHT_GRID_N]f32,
	door_w_max:  [LIGHT_GRID_N][LIGHT_GRID_N]f32,
	door_w_top:  [LIGHT_GRID_N][LIGHT_GRID_N]f32,
	door_n_min:  [LIGHT_GRID_N][LIGHT_GRID_N]f32,
	door_n_max:  [LIGHT_GRID_N][LIGHT_GRID_N]f32,
	door_n_top:  [LIGHT_GRID_N][LIGHT_GRID_N]f32,
}

light_grid: Light_Grid

// Begin preparing the cache for one chunk. The cache is populated incrementally
// by light_grid_fill_cell so chunk generation can yield between frames.
light_grid_begin :: proc(c: Chunk_Coord) {
	light_grid.ox = c.x * CHUNK_SIZE - LIGHT_PAD
	light_grid.oz = c.y * CHUNK_SIZE - LIGHT_PAD
}

// Populate one cache cell at (i, j), where i and j are indices within Light_Grid.
light_grid_fill_cell :: proc(i, j: int) {
	g := &light_grid
	wx := g.ox + i32(i)
	wz := g.oz + i32(j)

	p := light_power(wx, wz)
	g.power[j][i] = p

	if p > 0 {
		g.top[j][i] = ceil_h(wx, wz) - 0.05
		lc := rl.ColorNormalize(light_color(wx, wz))
		g.color[j][i] = {lc.x, lc.y, lc.z}
	} else {
		g.top[j][i] = 0
		g.color[j][i] = {}
	}

	// West-facing wall edge.
	if has_wall(wx, wz, false) {
		wall_top := west_wall_height(wx, wz)
		g.wall_w[j][i] = wall_top
		g.wall_w_base[j][i] = west_wall_base(wx, wz)

		if has_door(wx, wz, false) {
			l, r := door_span(wx, wz, false)
			g.door_w_min[j][i] = f32(wz) * CELL + l
			g.door_w_max[j][i] = f32(wz) * CELL + r
			g.door_w_top[j][i] = door_top(wx, wz, false, wall_top)
		} else {
			g.door_w_min[j][i] = 0
			g.door_w_max[j][i] = 0
			g.door_w_top[j][i] = 0
		}
	} else {
		g.wall_w[j][i] = 0
		g.wall_w_base[j][i] = 0
		g.door_w_min[j][i] = 0
		g.door_w_max[j][i] = 0
		g.door_w_top[j][i] = 0
	}

	// North-facing wall edge.
	if has_wall(wx, wz, true) {
		wall_top := north_wall_height(wx, wz)
		g.wall_n[j][i] = wall_top
		g.wall_n_base[j][i] = north_wall_base(wx, wz)

		if has_door(wx, wz, true) {
			l, r := door_span(wx, wz, true)
			g.door_n_min[j][i] = f32(wx) * CELL + l
			g.door_n_max[j][i] = f32(wx) * CELL + r
			g.door_n_top[j][i] = door_top(wx, wz, true, wall_top)
		} else {
			g.door_n_min[j][i] = 0
			g.door_n_max[j][i] = 0
			g.door_n_top[j][i] = 0
		}
	} else {
		g.wall_n[j][i] = 0
		g.wall_n_base[j][i] = 0
		g.door_n_min[j][i] = 0
		g.door_n_max[j][i] = 0
		g.door_n_top[j][i] = 0
	}

	// Use the highest ceiling corner in the cell.
	g.ceil[j][i] = max(
		max(corner_h(wx, wz), corner_h(wx + 1, wz)),
		max(corner_h(wx, wz + 1), corner_h(wx + 1, wz + 1)),
	)
}

// Synchronous convenience wrapper for callers that still need a complete cache.
light_grid_fill :: proc(c: Chunk_Coord) {
	light_grid_begin(c)
	for j in 0 ..< LIGHT_GRID_N {
		for i in 0 ..< LIGHT_GRID_N {
			light_grid_fill_cell(i, j)
		}
	}
}

// Door aperture lookup.
edge_door_w :: proc(x, z: i32) -> Door_Opening {
	i, j := x - light_grid.ox, z - light_grid.oz

	if i < 0 || i >= LIGHT_GRID_N || j < 0 || j >= LIGHT_GRID_N {
		return Door_Opening{}
	}

	return Door_Opening {
		min = light_grid.door_w_min[j][i],
		max = light_grid.door_w_max[j][i],
		top = light_grid.door_w_top[j][i],
	}
}

edge_door_n :: proc(x, z: i32) -> Door_Opening {
	i, j := x - light_grid.ox, z - light_grid.oz

	if i < 0 || i >= LIGHT_GRID_N || j < 0 || j >= LIGHT_GRID_N {
		return Door_Opening{}
	}

	return Door_Opening {
		min = light_grid.door_n_min[j][i],
		max = light_grid.door_n_max[j][i],
		top = light_grid.door_n_top[j][i],
	}
}

// Wall heights.

edge_top_w :: proc(x, z: i32) -> f32 {
	i, j := x - light_grid.ox, z - light_grid.oz
	if i < 0 || i >= LIGHT_GRID_N || j < 0 || j >= LIGHT_GRID_N do return 1e9
	return light_grid.wall_w[j][i]
}

edge_top_n :: proc(x, z: i32) -> f32 {
	i, j := x - light_grid.ox, z - light_grid.oz
	if i < 0 || i >= LIGHT_GRID_N || j < 0 || j >= LIGHT_GRID_N do return 1e9
	return light_grid.wall_n[j][i]
}

// Ceiling height.

ceil_top :: proc(x, z: i32) -> f32 {
	i, j := x - light_grid.ox, z - light_grid.oz
	if i < 0 || i >= LIGHT_GRID_N || j < 0 || j >= LIGHT_GRID_N do return -1e9
	return light_grid.ceil[j][i]
}

// Wall base heights.

edge_base_w :: proc(x, z: i32) -> f32 {
	i, j := x - light_grid.ox, z - light_grid.oz
	if i < 0 || i >= LIGHT_GRID_N || j < 0 || j >= LIGHT_GRID_N do return -1e9
	return light_grid.wall_w_base[j][i]
}

edge_base_n :: proc(x, z: i32) -> f32 {
	i, j := x - light_grid.ox, z - light_grid.oz
	if i < 0 || i >= LIGHT_GRID_N || j < 0 || j >= LIGHT_GRID_N do return -1e9
	return light_grid.wall_n_base[j][i]
}

// Test a ray against a wall segment.
// If the crossing point is inside a doorway and below its lintel,
// the ray passes through.

edge_blocks :: proc(
	y, along, bottom, top: f32,
	door: Door_Opening,
	along_margin, height_margin: f32,
) -> bool {
	if top <= bottom || y < bottom || y >= top do return false

	in_door_width :=
		door.top > 0 && along > door.min + along_margin && along < door.max - along_margin

	in_door_height := door.top > 0 && y - height_margin >= bottom && y + height_margin < door.top

	if in_door_width && in_door_height do return false

	return true
}

// DDA visibility ray traversal.

light_blocked :: proc(ax, ay, az, bx, by, bz: f32) -> bool {
	pax, paz := ax / CELL, az / CELL
	pbx, pbz := bx / CELL, bz / CELL

	cx := i32(math.floor(pax))
	cz := i32(math.floor(paz))
	tx := i32(math.floor(pbx))
	tz := i32(math.floor(pbz))

	if cx == tx && cz == tz do return false

	dx := pbx - pax
	dz := pbz - paz

	step_x := dx > 0 ? i32(1) : (dx < 0 ? i32(-1) : i32(0))
	step_z := dz > 0 ? i32(1) : (dz < 0 ? i32(-1) : i32(0))

	inf: f32 = 1e30

	t_max_x, t_max_z := inf, inf
	t_delta_x, t_delta_z := inf, inf

	if step_x != 0 {
		next_x := f32(cx + (step_x > 0 ? 1 : 0))
		t_max_x = (next_x - pax) / dx
		t_delta_x = 1.0 / math.abs(dx)
	}

	if step_z != 0 {
		next_z := f32(cz + (step_z > 0 ? 1 : 0))
		t_max_z = (next_z - paz) / dz
		t_delta_z = 1.0 / math.abs(dz)
	}

	for _ in 0 ..< 2 * LIGHT_PAD + 2 {
		cross_x := t_max_x <= t_max_z
		cross_z := t_max_z <= t_max_x

		t := min(t_max_x, t_max_z)
		if t > 1.0 do break

		// Ray height at this boundary.
		y := ay + (by - ay) * t

		if y > ceil_top(cx, cz) + CEIL_SLACK do return true

		// Exact world-space ray intersection.
		hit_x := ax + (bx - ax) * t
		hit_z := az + (bz - az) * t
		ray_dx := bx - ax
		ray_dy := by - ay
		ray_dz := bz - az

		half_wall: f32 = WALL_T * 0.5

		// Ray movement through the wall's thickness.
		west_den := max(abs(ray_dx), 0.0001)
		north_den := max(abs(ray_dz), 0.0001)

		// West-facing wall: X is the wall normal.
		west_along_margin := half_wall * abs(ray_dz) / west_den + 0.02

		west_height_margin := half_wall * abs(ray_dy) / west_den + 0.02

		// North-facing wall: Z is the wall normal.
		north_along_margin := half_wall * abs(ray_dx) / north_den + 0.02

		north_height_margin := half_wall * abs(ray_dy) / north_den + 0.02

		nx := cx + (cross_x ? step_x : 0)
		nz := cz + (cross_z ? step_z : 0)

		// Vertical wall boundary.
		if cross_x {
			edge_x := step_x > 0 ? nx : nx + 1

			door := edge_door_w(edge_x, cz)
			blocked := edge_blocks(
				y,
				hit_z,
				edge_base_w(edge_x, cz),
				edge_top_w(edge_x, cz),
				door,
				west_along_margin,
				west_height_margin,
			)
			if blocked do return true

			// Check the diagonal neighbour on exact corner crossings.
			if cross_z {
				door = edge_door_w(edge_x, nz)
				blocked = edge_blocks(
					y,
					hit_z,
					edge_base_w(edge_x, nz),
					edge_top_w(edge_x, nz),
					door,
					west_along_margin,
					west_height_margin,
				)
				if blocked do return true
			}
		}

		// Horizontal wall boundary.
		if cross_z {
			edge_z := step_z > 0 ? nz : nz + 1

			door := edge_door_n(cx, edge_z)
			blocked := edge_blocks(
				y,
				hit_x,
				edge_base_n(cx, edge_z),
				edge_top_n(cx, edge_z),
				door,
				north_along_margin,
				north_height_margin,
			)
			if blocked do return true

			// Check the diagonal neighbour on exact corner crossings.
			if cross_x {
				door = edge_door_n(nx, edge_z)
				blocked = edge_blocks(
					y,
					hit_x,
					edge_base_n(nx, edge_z),
					edge_top_n(nx, edge_z),
					door,
					north_along_margin,
					north_height_margin,
				)
				if blocked do return true
			}
		}

		cx, cz = nx, nz

		if cx == tx && cz == tz do return false

		if cross_x do t_max_x += t_delta_x
		if cross_z do t_max_z += t_delta_z
	}

	return false
}

// XZ center of the cell currently being built.
light_center: [2]f32

// Fraction of the light panel visible from a surface point.
// Four corner samples are refined with five interior samples when partially
// occluded. A blocked centre ray does not discard the entire light source.

light_visibility :: proc(sx, sy, sz, lx, ly, lz: f32) -> f32 {
	// The centre ray must have a clear path.
	// Prevents panel samples from leaking around wall corners.
	if light_blocked(sx, sy, sz, lx, ly, lz) do return 0

	so :: CELL * 0.2

	vis: f32 = 0

	for o in ([4][2]f32{{-so, -so}, {so, -so}, {so, so}, {-so, so}}) {
		if !light_blocked(sx, sy, sz, lx + o.x, ly, lz + o.y) {
			vis += 1
		}
	}

	if vis == 4 do return 1.0

	for o in ([5][2]f32{{0, 0}, {-so, 0}, {so, 0}, {0, -so}, {0, so}}) {
		if !light_blocked(sx, sy, sz, lx + o.x, ly, lz + o.y) {
			vis += 1
		}
	}

	return vis / 9.0
}

// Soft filmic-ish shoulder.
tone :: proc(x: f32) -> f32 {
	return 1.0 - math.exp(-x)
}

// Baked lighting at each mesh vertex.

compute_vertex_lighting :: proc(
	pos: [3]f32,
	base_col: rl.Color,
	k: f32 = 1.0,
	inset: [2]bool = {},
	shift: [2]f32 = {},
) -> rl.Color {
	g := &light_grid

	// Pull boundary vertices slightly toward their owning cell.
	sx, sz := pos.x + shift.x, pos.z + shift.y

	if inset[0] do sx += (light_center.x - pos.x) * 0.03
	if inset[1] do sz += (light_center.y - pos.z) * 0.03

	// Search lights around the corrected sample cell.
	cx := i32(math.floor(sx / CELL))
	cz := i32(math.floor(sz / CELL))

	sum_r, sum_g, sum_b: f32

	for dz in -LIGHT_CULL_R ..= LIGHT_CULL_R {
		gj := cz + dz - g.oz
		if gj < 0 || gj >= LIGHT_GRID_N do continue

		for dx in -LIGHT_CULL_R ..= LIGHT_CULL_R {
			gi := cx + dx - g.ox
			if gi < 0 || gi >= LIGHT_GRID_N do continue

			p := g.power[gj][gi]
			if p == 0 do continue

			ly := g.top[gj][gi]
			lx := (f32(cx + dx) + 0.5) * CELL
			lz := (f32(cz + dz) + 0.5) * CELL

			ex, ey, ez := pos.x - lx, pos.y - ly, pos.z - lz
			d2 := ex * ex + ey * ey + ez * ez

			if d2 >= LIGHT_RADIUS * LIGHT_RADIUS do continue

			vis := light_visibility(sx, pos.y, sz, lx, ly, lz)
			if vis == 0 do continue

			// Squared falloff gives a tight light pool.
			f := clamp(1.0 - math.sqrt(d2) / LIGHT_RADIUS, 0.0, 1.0)
			w := p * f * f * vis

			lc := g.color[gj][gi]

			sum_r += w * lc[0]
			sum_g += w * lc[1]
			sum_b += w * lc[2]
		}
	}

	return rl.Color {
		u8(clamp(f32(base_col.r) * tone(AMBIENT + LIGHT_GAIN * sum_r) * k, 0, 255)),
		u8(clamp(f32(base_col.g) * tone(AMBIENT + LIGHT_GAIN * sum_g) * k, 0, 255)),
		u8(clamp(f32(base_col.b) * tone(AMBIENT + LIGHT_GAIN * sum_b) * k, 0, 255)),
		255,
	}
}
