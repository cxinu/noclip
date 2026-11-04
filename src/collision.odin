package main

import "core:math"

// xz footprint of a wall, used by both the mesher and collision
wall_rect :: proc(x, z: i32, north: bool) -> (lo, hi: [2]f32) {
	x0, z0 := f32(x) * CELL, f32(z) * CELL
	h: f32 = WALL_T / 2

	if north {
		return {x0, z0 - h}, {x0 + CELL, z0 + h}
	}

	return {x0 - h, z0}, {x0 + h, z0 + CELL}
}

Wall_Box :: struct {
	lo, hi: [2]f32, // xz footprint
	y0, y1: f32,
}

wall_pieces :: proc(x, z: i32, north: bool, wall_h: f32) -> (boxes: [3]Wall_Box, n: int) {
	lo, hi := wall_rect(x, z, north)
	if !has_door(x, z, north) {
		boxes[0] = {lo, hi, 0, wall_h}
		return boxes, 1
	}

	ax := 0 if north else 1 // axis the wall runs along
	start := lo[ax]
	l, r := door_span(x, z, north)
	dl, dr := start + l, start + r
	top := door_top(x, z, north, wall_h)

	j1_lo, j1_hi := lo, hi
	j1_hi[ax] = dl
	j2_lo, j2_hi := lo, hi
	j2_lo[ax] = dr
	l_lo, l_hi := lo, hi
	l_lo[ax] = dl
	l_hi[ax] = dr

	boxes[0] = {j1_lo, j1_hi, 0, wall_h}
	boxes[1] = {j2_lo, j2_hi, 0, wall_h}
	boxes[2] = {l_lo, l_hi, top, wall_h} // lintel
	return boxes, 3
}

push_out :: proc(p, lo, hi: [2]f32, r: f32) -> [2]f32 {
	c := [2]f32{clamp(p.x, lo.x, hi.x), clamp(p.y, lo.y, hi.y)}
	d := p - c
	d2 := d.x * d.x + d.y * d.y
	if d2 >= r * r do return p

	if d2 > 0.000001 {
		return c + d * (r / math.sqrt(d2))
	}

	l, rt, t, b := p.x - lo.x, hi.x - p.x, p.y - lo.y, hi.y - p.y
	m := min(l, rt, t, b)
	if m == l do return {lo.x - r, p.y}
	if m == rt do return {hi.x + r, p.y}
	if m == t do return {p.x, lo.y - r}
	return {p.x, hi.y + r}
}

// circle (x, z) vs every nearby wall. Pure function of world coords, no chunk lookup.
collide_walls :: proc(pos: [2]f32, r: f32) -> [2]f32 {
	p := pos
	cx, cz := i32(math.floor(p.x / CELL)), i32(math.floor(p.y / CELL))
	for _ in 0 ..< 2 {
		for z in cz - 1 ..= cz + 1 {
			for x in cx - 1 ..= cx + 1 {
				for north in ([2]bool{false, true}) {
					if !has_wall(x, z, north) do continue
					boxes, n := wall_pieces(x, z, north, WALL_H)
					for i in 0 ..< n {
						if boxes[i].y0 > 0 do continue // lintel, player walks under it
						p = push_out(p, boxes[i].lo, boxes[i].hi, r)
					}
				}
				if pillar_at(x, z) {
					inset: f32 : CELL * 0.3
					x0, z0 := f32(x) * CELL, f32(z) * CELL
					p = push_out(
						p,
						{x0 + inset, z0 + inset},
						{x0 + CELL - inset, z0 + CELL - inset},
						r,
					)
				}
			}
		}
	}
	return p
}
