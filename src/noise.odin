package main

import "core:math"

hash :: proc(x, y: i32) -> f32 {
	h: u32 = u32(x) * 374761393 + u32(y) * 668265263
	h = (h ~ (h >> 13)) * 1274126177
	h = h ~ (h >> 16)

	// Cast the mask explicitly to u32
	masked := h & u32(0xFFFF)
	return f32(masked) / 65535.0
}

vnoise :: proc(x, y: f32) -> f32 {
	xf := math.floor(x)
	yf := math.floor(y)
	xi := i32(xf)
	yi := i32(yf)
	fx := x - xf
	fy := y - yf
	sx := fx * fx * (3 - 2 * fx)
	sy := fy * fy * (3 - 2 * fy)
	n00 := hash(xi, yi)
	n10 := hash(xi + 1, yi)
	n01 := hash(xi, yi + 1)
	n11 := hash(xi + 1, yi + 1)
	return math.lerp(math.lerp(n00, n10, sx), math.lerp(n01, n11, sx), sy)
}

smoothstep :: proc(e0, e1, v: f32) -> f32 {
	t := clamp((v - e0) / (e1 - e0), 0, 1)
	return t * t * (3 - 2 * t)
}
