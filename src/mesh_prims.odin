package main

import "core:math"
import rl "vendor:raylib"

// Mesh primitives: vertex buffers, quads, and the lit/subdivided quad emitter.

Verts :: struct {
	pos: [dynamic]f32,
	col: [dynamic]u8,
}

shade :: proc(c: rl.Color, k: i32) -> rl.Color {
	return {
		u8(clamp(i32(c.r) + k, 0, 255)),
		u8(clamp(i32(c.g) + k, 0, 255)),
		u8(clamp(i32(c.b) + k, 0, 255)),
		255,
	}
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

LIGHT_STEP :: 2

FLAT_STEP :: 2

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
	normal := quad_normal(a, b, c, d)
	pts: [17 * 17][3]f32
	cols: [17 * 17]rl.Color
	stride := nu + 1
	for j in 0 ..= nv do for i in 0 ..= nu {
		p := bil(a, b, c, d, f32(i) / f32(nu), f32(j) / f32(nv))
		pts[j * stride + i] = p
		cols[j * stride + i] = compute_vertex_lighting(p, col, k, inset, shift, normal)
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

cross3 :: proc(a, b: [3]f32) -> [3]f32 {
	return {a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x}
}

// Unit normal of a quad (either winding; lighting treats surfaces as two-sided).
quad_normal :: proc(a, b, c, d: [3]f32) -> [3]f32 {
	n := cross3(b - a, d - a)
	l := linalg_len(n)
	if l < 1e-5 {
		n = cross3(c - b, c - d)
		l = linalg_len(n)
		if l < 1e-5 do return {0, 1, 0}
	}
	return n / l
}

flat_lit :: proc(v: ^Verts, a, b, c, d: [3]f32, col: rl.Color) {
	lit_quad(v, a, b, c, d, col, 1.0, FLAT_STEP, {true, true})
}

bilerp4 :: proc(nw, ne, se, sw, u, w: f32) -> f32 {
	top := nw + (ne - nw) * u
	bot := sw + (se - sw) * u
	return top + (bot - top) * w
}

// ───────────────────────── NEW: stair + hole rendering ─────────────────────────
