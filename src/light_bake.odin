package main

import "core:math"
import rl "vendor:raylib"

// Baked per-vertex lighting: falloff, soft light visibility, shading and ambient occlusion.

LIGHT_RADIUS :: 10.0

LIGHT_CULL_R :: i32(3)

AMBIENT :: 0.22

// Surface-orientation term: lit = WRAP_MIN + (1 - WRAP_MIN) * |N.L|. Keeps
// floors/ceilings from looking identical to walls without hard terminators.
WRAP_MIN :: 0.6

// Contact darkening where floors and ceilings meet walls.
AO_RADIUS :: 1.8
AO_STRENGTH :: 0.32

LIGHT_GAIN :: 2.4

// XZ center of the cell currently being built.
light_center: [2]f32

// Fraction of the light panel visible from a surface point.
// Four corner samples are refined with five interior samples when partially
// occluded. A blocked centre ray does not discard the entire light source.

light_visibility :: proc(sx, sy, sz, lx, ly, lz: f32) -> f32 {
	// The centre ray must have a clear path.
	if light_blocked(sx, sy, sz, lx, ly, lz) do return 0

	so :: CELL * 0.2
	vis: f32 = 0
	for o in ([4][2]f32{{-so, -so}, {so, -so}, {so, so}, {-so, so}}) {
		if !light_blocked(sx, sy, sz, lx + o.x, ly, lz + o.y) {vis += 1}
	}
	if vis == 4 do return 1.0

	// Partially occluded: refine with the four edge midpoints.
	for o in ([4][2]f32{{-so, 0}, {so, 0}, {0, -so}, {0, so}}) {
		if !light_blocked(sx, sy, sz, lx + o.x, ly, lz + o.y) {vis += 1}
	}
	return (vis + 1) / 9.0
}

// Cheap ambient occlusion for horizontal surfaces: distance from the sample to
// the nearest cached wall segment around it. Reads only the light cache.
vertex_ao :: proc(sx, sz: f32) -> f32 {
	cx := i32(math.floor(sx / CELL))
	cz := i32(math.floor(sz / CELL))
	best: f32 = AO_RADIUS

	// West-edge walls: lines x = xg, spanning cell row zc.
	for zc in cz - 1 ..= cz + 1 {
		for xg in cx ..= cx + 1 {
			top := edge_top_w(xg, zc, LIGHT_FLOOR_PAD)
			if top <= 0 || top > 1e8 do continue
			z0 := f32(zc) * CELL
			dx := sx - f32(xg) * CELL
			dz := sz - clamp(sz, z0, z0 + CELL)
			d := math.sqrt(dx * dx + dz * dz)
			if edge_door_w(xg, zc, LIGHT_FLOOR_PAD).valid do d += AO_RADIUS * 0.5
			best = min(best, d)
		}
	}
	// North-edge walls: lines z = zg, spanning cell column xc.
	for zg in cz ..= cz + 1 {
		for xc in cx - 1 ..= cx + 1 {
			top := edge_top_n(xc, zg, LIGHT_FLOOR_PAD)
			if top <= 0 || top > 1e8 do continue
			x0 := f32(xc) * CELL
			dx := sx - clamp(sx, x0, x0 + CELL)
			dz := sz - f32(zg) * CELL
			d := math.sqrt(dx * dx + dz * dz)
			if edge_door_n(xc, zg, LIGHT_FLOOR_PAD).valid do d += AO_RADIUS * 0.5
			best = min(best, d)
		}
	}
	t := 1.0 - best / AO_RADIUS
	return 1.0 - AO_STRENGTH * t * t
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
	normal: [3]f32 = {0, 1, 0},
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

			lx := (f32(cx + dx) + 0.5) * CELL
			lz := (f32(cz + dz) + 0.5) * CELL
			for layer in 0 ..< LIGHT_FLOOR_COUNT {
				p := g.power[layer][gj][gi]
				if p == 0 do continue

				ly := g.top[layer][gj][gi]
				ex, ey, ez := pos.x - lx, pos.y - ly, pos.z - lz
				d2 := ex * ex + ey * ey + ez * ez
				if d2 >= LIGHT_RADIUS * LIGHT_RADIUS do continue

				// Squared falloff gives a tight light pool. Evaluate it first and
				// skip the expensive visibility rays for negligible contributions.
				f := clamp(1.0 - math.sqrt(d2) / LIGHT_RADIUS, 0.0, 1.0)
				if p * f * f < 0.01 do continue

				vis := light_visibility(sx, pos.y, sz, lx, ly, lz)
				if vis == 0 do continue
				dist := math.sqrt(d2)
				ndl := abs(normal.x * ex + normal.y * ey + normal.z * ez) / max(dist, 0.001)
				w := p * f * f * vis * (WRAP_MIN + (1.0 - WRAP_MIN) * ndl)
				lc := g.color[layer][gj][gi]
				sum_r += w * lc[0]
				sum_g += w * lc[1]
				sum_b += w * lc[2]
			}
		}
	}

	// Only horizontal surfaces get contact AO; walls keep their gradient from lights.
	ao: f32 = 1.0
	if abs(normal.y) > 0.7 do ao = vertex_ao(sx, sz)
	k_: f32 = k * ao

	return rl.Color {
		u8(clamp(f32(base_col.r) * tone(AMBIENT + LIGHT_GAIN * sum_r) * k_, 0, 255)),
		u8(clamp(f32(base_col.g) * tone(AMBIENT + LIGHT_GAIN * sum_g) * k_, 0, 255)),
		u8(clamp(f32(base_col.b) * tone(AMBIENT + LIGHT_GAIN * sum_b) * k_, 0, 255)),
		255,
	}
}
