package main

import "core:math"
import rl "vendor:raylib"

// Baked vertex lighting.
//
// Lights sit on a global lattice (see biome.odin:light_power). For each chunk we
// snapshot the lights and the solid wall edges around it, then every emitted
// vertex sums only the lights it can actually see. `light_blocked` walks the cell
// grid with a DDA and rejects any light hidden behind a wall, which stops light
// bleeding into neighbouring rooms and lighting up empty ones.

LIGHT_PAD :: 4
LIGHT_GRID_N :: CHUNK_SIZE + 2 * LIGHT_PAD
LIGHT_RADIUS :: 10.0 // world units; light dies well before it reaches distant walls
LIGHT_CULL_R :: i32(3) // cells searched around a vertex

AMBIENT :: 0.0 // no light => pure black; no muddy base glow
LIGHT_GAIN :: 2.4

CEIL_SLACK :: 0.35 // ignore tiny interpolation differences at ceiling corners

Light_Grid :: struct {
	ox, oz: i32, // world cell of top[0][0]
	top:    [LIGHT_GRID_N][LIGHT_GRID_N]f32, // light height, 0 = no light here
	power:  [LIGHT_GRID_N][LIGHT_GRID_N]f32,
	color:  [LIGHT_GRID_N][LIGHT_GRID_N][3]f32,
	// Solid edge height per cell edge (0 = open, doors are opaque).
	wall_w: [LIGHT_GRID_N][LIGHT_GRID_N]f32,
	wall_n: [LIGHT_GRID_N][LIGHT_GRID_N]f32,
	// Ceiling height per cell; a sight ray above it is inside/through the slab.
	ceil: [LIGHT_GRID_N][LIGHT_GRID_N]f32,
}

light_grid: Light_Grid // chunk building is single-threaded, so a global is fine

light_grid_fill :: proc(c: Chunk_Coord) {
	g := &light_grid
	g.ox = c.x * CHUNK_SIZE - LIGHT_PAD
	g.oz = c.y * CHUNK_SIZE - LIGHT_PAD

	for j in 0 ..< LIGHT_GRID_N {
		for i in 0 ..< LIGHT_GRID_N {
			wx, wz := g.ox + i32(i), g.oz + i32(j)

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

			// Any wall blocks light, even if it has a door. The grid is one cell
			// wide, so treating a doored edge as fully open would flood the whole
			// neighbouring room through the wall. Real open gaps (no wall at all)
			// stay open, so light still spills through archways.
			// Store the wall's height so sight rays can pass over a low wall
			// instead of being blocked or leaking through it.
			g.wall_w[j][i] = has_wall(wx, wz, false) ? west_wall_height(wx, wz) : 0
			g.wall_n[j][i] = has_wall(wx, wz, true) ? north_wall_height(wx, wz) : 0
			g.ceil[j][i] = ceil_h(wx, wz)
		}
	}
}

// Height of the wall on a cell edge (0 when open). Outside the cached grid we
// return a tall barrier so a stray ray can never escape into unseen sectors.
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

// Ceiling height of a cell. Outside the cached grid: impossible ceiling, which
// makes any ray entering that region count as blocked.
ceil_top :: proc(x, z: i32) -> f32 {
	i, j := x - light_grid.ox, z - light_grid.oz
	if i < 0 || i >= LIGHT_GRID_N || j < 0 || j >= LIGHT_GRID_N do return -1e9
	return light_grid.ceil[j][i]
}

// True when a wall, or a solid height barrier, sits between a surface point and
// a light. The ray's height is checked at every cell edge, so a low wall only
// blocks light below its top instead of either leaking or blocking everything.
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
		// Which cell boundaries does the ray cross next? On an exact corner both
		// are crossed at the same time. Check all four wall segments touching that
		// corner, otherwise a ray can slip diagonally between two rooms and light
		// up an unlit corner.
		cross_x := t_max_x <= t_max_z
		cross_z := t_max_z <= t_max_x
		t := min(t_max_x, t_max_z)
		if t > 1.0 do break

		// Height of the sight ray where it leaves the current cell. If that is
		// above the cell ceiling, the ray is passing through the slab above a
		// closed sector, so reject it.
		y := ay + (by - ay) * t
		if y > ceil_top(cx, cz) + CEIL_SLACK do return true

		nx := cx + (cross_x ? step_x : 0)
		nz := cz + (cross_z ? step_z : 0)

		if cross_x {
			edge_x := step_x > 0 ? nx : nx + 1
			if y < edge_top_w(edge_x, cz) do return true
			if cross_z && y < edge_top_w(edge_x, nz) do return true
		}
		if cross_z {
			edge_z := step_z > 0 ? nz : nz + 1
			if y < edge_top_n(cx, edge_z) do return true
			if cross_x && y < edge_top_n(nx, edge_z) do return true
		}

		cx, cz = nx, nz
		if cx == tx && cz == tz do return false

		if cross_x do t_max_x += t_delta_x
		if cross_z do t_max_z += t_delta_z
	}
	return false
}

// xz center of the cell currently being built (set in build_chunk)
light_center: [2]f32

// fraction of a light panel visible from (sx, sy, sz): 4 samples, refined to 9
// on the penumbra so wall edges get a soft gradient instead of a hard cutoff
light_visibility :: proc(sx, sy, sz, lx, ly, lz: f32) -> f32 {
	so :: CELL * 0.2
	vis: f32
	for o in ([4][2]f32{{-so, -so}, {so, -so}, {so, so}, {-so, so}}) {
		if !light_blocked(sx, sy, sz, lx + o.x, ly, lz + o.y) do vis += 1
	}
	if vis == 0 || vis == 4 do return vis / 4

	for o in ([5][2]f32{{0, 0}, {-so, 0}, {so, 0}, {0, -so}, {0, so}}) {
		if !light_blocked(sx, sy, sz, lx + o.x, ly, lz + o.y) do vis += 1
	}
	return vis / 9
}

// Soft filmic-ish shoulder. No shadow lift: tiny values stay tiny.
tone :: proc(x: f32) -> f32 {
	return 1.0 - math.exp(-x)
}

compute_vertex_lighting :: proc(
	pos: [3]f32,
	base_col: rl.Color,
	k: f32 = 1.0,
	inset := false,
) -> rl.Color {
	g := &light_grid
	cx := i32(math.floor(pos.x / CELL))
	cz := i32(math.floor(pos.z / CELL))

	// Vertices on a cell boundary would otherwise start the shadow ray inside the
	// neighbouring cell and be blocked by their own room's wall. Pull the sample
	// point a hair toward the owning cell's center.
	sx, sz := pos.x, pos.z
	if inset {
		sx += (light_center.x - pos.x) * 0.03
		sz += (light_center.y - pos.z) * 0.03
	}

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

			// Linear-to-zero falloff, then squared: a tight pool under the
			// fixture that reaches true zero at the radius (no long flat tail).
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
