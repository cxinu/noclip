package main

import "core:math"

// Hashing and value-noise primitives (2D, per-floor, and 3D).

raw_hash :: proc(x, y: i32) -> u32 {
	h: u32 = u32(x) * 374761393 + u32(y) * 668265263
	h = (h ~ (h >> 13)) * 1274126177
	return h ~ (h >> 16)
}

hash01 :: proc(x, y, seed: i32) -> f32 {
	return f32(raw_hash(x + seed * 7919, y - seed * 104729 + i32(level_seed())) >> 8) / 16777216.0
}

bnoise :: proc(x, y: f32, seed: i32) -> f32 {
	xf, yf := math.floor(x), math.floor(y)
	xi, yi := i32(xf), i32(yf)
	fx, fy := x - xf, y - yf
	sx := fx * fx * (3 - 2 * fx)
	sy := fy * fy * (3 - 2 * fy)
	top := hash01(xi, yi, seed) + (hash01(xi + 1, yi, seed) - hash01(xi, yi, seed)) * sx
	bot :=
		hash01(xi, yi + 1, seed) + (hash01(xi + 1, yi + 1, seed) - hash01(xi, yi + 1, seed)) * sx
	return top + (bot - top) * sy
}

bfbm :: proc(x, y: f32, seed: i32) -> f32 {
	sum, amp, norm: f32 = 0, 1, 0
	fx, fy := x, y
	for o in 0 ..< 3 {
		sum += amp * bnoise(fx, fy, seed + i32(o))
		norm += amp
		amp *= 0.5
		fx *= 2.1
		fy *= 2.1
	}
	return sum / norm
}

hash01_for_floor :: proc(x, y, seed, floor, theme: i32) -> f32 {
	world_seed := i32(WORLD_SEED + u32(floor) * 2246822519 + u32(theme) * 3266489917)
	return f32(raw_hash(x + seed * 7919, y - seed * 104729 + world_seed) >> 8) / 16777216.0
}

bnoise_for_floor :: proc(x, y: f32, seed, floor, theme: i32) -> f32 {
	xf, yf := math.floor(x), math.floor(y)
	xi, yi := i32(xf), i32(yf)
	fx, fy := x - xf, y - yf
	sx := fx * fx * (3 - 2 * fx)
	sy := fy * fy * (3 - 2 * fy)
	n00 := hash01_for_floor(xi, yi, seed, floor, theme)
	n10 := hash01_for_floor(xi + 1, yi, seed, floor, theme)
	n01 := hash01_for_floor(xi, yi + 1, seed, floor, theme)
	n11 := hash01_for_floor(xi + 1, yi + 1, seed, floor, theme)
	top := n00 + (n10 - n00) * sx
	bot := n01 + (n11 - n01) * sx
	return top + (bot - top) * sy
}

bfbm_for_floor :: proc(x, y: f32, seed, floor, theme: i32) -> f32 {
	sum, amp, norm: f32 = 0, 1, 0
	fx, fy := x, y
	for o in 0 ..< 3 {
		sum += amp * bnoise_for_floor(fx, fy, seed + i32(o), floor, theme)
		norm += amp
		amp *= 0.5
		fx *= 2.1
		fy *= 2.1
	}
	return sum / norm
}

// 3D value-noise lattice. X/Z are horizontal world coordinates and Y is the
// fractional floor axis. Sampling Y continuously makes biome regions bend and
// drift through the stack instead of being independently regenerated per floor.
hash01_3d :: proc(x, z, y, seed: i32) -> f32 {
	h := u32(x) * 374761393
	h = h ~ (u32(z) * 668265263)
	h = h ~ (u32(y) * 2246822519)
	h = h ~ (u32(seed) * 3266489917)
	h = (h ~ (h >> 13)) * 1274126177
	h = h ~ (h >> 16)
	return f32(h >> 8) / 16777216.0
}

bnoise_3d :: proc(x, z, y: f32, seed: i32) -> f32 {
	xf, zf, yf := math.floor(x), math.floor(z), math.floor(y)
	xi, zi, yi := i32(xf), i32(zf), i32(yf)
	fx, fz, fy := x - xf, z - zf, y - yf
	fx = fx * fx * (3 - 2 * fx)
	fz = fz * fz * (3 - 2 * fz)
	fy = fy * fy * (3 - 2 * fy)

	c000 := hash01_3d(xi, zi, yi, seed)
	c100 := hash01_3d(xi + 1, zi, yi, seed)
	c010 := hash01_3d(xi, zi + 1, yi, seed)
	c110 := hash01_3d(xi + 1, zi + 1, yi, seed)
	c001 := hash01_3d(xi, zi, yi + 1, seed)
	c101 := hash01_3d(xi + 1, zi, yi + 1, seed)
	c011 := hash01_3d(xi, zi + 1, yi + 1, seed)
	c111 := hash01_3d(xi + 1, zi + 1, yi + 1, seed)

	z0a := c000 + (c100 - c000) * fx
	z0b := c010 + (c110 - c010) * fx
	z1a := c001 + (c101 - c001) * fx
	z1b := c011 + (c111 - c011) * fx
	a := z0a + (z0b - z0a) * fz
	b := z1a + (z1b - z1a) * fz
	return a + (b - a) * fy
}

bfbm_3d :: proc(x, z, y: f32, seed: i32) -> f32 {
	sum, amp, norm: f32 = 0, 1, 0
	fx, fz, fy := x, z, y
	for o in 0 ..< 4 {
		sum += amp * bnoise_3d(fx, fz, fy, seed + i32(o) * 17)
		norm += amp
		amp *= 0.5
		fx *= 2.03
		fz *= 2.03
		fy *= 2.03
	}
	return sum / norm
}
