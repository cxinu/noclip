package main

import "core:math"

// Biome lookup (cached) and the ceiling-height field derived from it.

biome_info_raw_for_level :: proc(x, z, floor, theme: i32, bleed_depth: i32 = 0) -> Biome_Info {
	// About 20% of coarse patches inherit the map directly below. The rest use
	// the same continuous 3D noise field, so adjacent storeys remain correlated.
	patch_x, patch_z := fdiv(x, 18), fdiv(z, 18)
	bleed_hash := raw_hash(patch_x + i32(WORLD_SEED), patch_z + floor * 7919 + theme * 104729)
	if floor > 0 && bleed_depth < 16 && bleed_hash %% 5 == 0 {
		return biome_info_raw_for_level(x, z, floor - 1, floor - 1, bleed_depth + 1)
	}

	px, pz := f32(x) + 0.5, f32(z) + 0.5
	fy := f32(floor) * 0.31
	wx := px + (bnoise_3d(px * 0.022, pz * 0.022, fy * 0.70, 91) - 0.5) * 36
	wz := pz + (bnoise_3d(px * 0.022 + 40.1, pz * 0.022 - 17.7, fy * 0.70, 92) - 0.5) * 36
	fa := bfbm_3d(wx / BIOME_SCALE, wz / BIOME_SCALE, fy, 11)
	fb := bfbm_3d(wx / BIOME_SCALE + 31.7, wz / BIOME_SCALE - 12.9, fy, 13)
	fa = clamp(0.5 + (fa - 0.5) * BIOME_CONTRAST, 0, 1)
	fb = clamp(0.5 + (fb - 0.5) * BIOME_CONTRAST, 0, 1)

	lv := LEVELS[floor_mod(theme, NUM_LEVELS)]
	spawn := clamp(1 - math.sqrt(px * px + pz * pz) / 40, 0, 1)

	best, second: f32 = 1e9, 1e9
	bi, si := lv.dominant, lv.dominant
	for t in Biome_Type {
		p := BIOME_PROTO[t]
		da, db := fa - p[0], fb - p[1]
		d := math.sqrt(da * da + db * db) - BIOME_BIAS[t]
		if t == lv.dominant {
			d -= lv.bias
			d -= spawn * 0.6
		}
		if d < best {second, si = best, bi; best, bi = d, t} else if d < second {second, si = d, t}
	}

	m := clamp((second - best) / BLEND_MARGIN, 0, 1)
	m = m * m * (3 - 2 * m)
	return Biome_Info{b = bi, b2 = si, w = 0.5 + 0.5 * m}
}

biome_info_raw :: proc(x, z: i32) -> Biome_Info {
	return biome_info_raw_for_level(x, z, current_floor, current_level)
}

BIOME_CACHE_N :: 16384

Biome_Cache_Entry :: struct {
	x, z, floor, theme: i32,
	valid:              bool,
	info:               Biome_Info,
}

biome_cache: [BIOME_CACHE_N]Biome_Cache_Entry

biome_info :: proc(x, z: i32) -> Biome_Info {
	floor, theme := current_floor, current_level
	e := &biome_cache[raw_hash(x, z + floor * 7717 + theme * 131071) & (BIOME_CACHE_N - 1)]
	if e.valid && e.x == x && e.z == z && e.floor == floor && e.theme == theme do return e.info
	e.x, e.z, e.floor, e.theme, e.valid = x, z, floor, theme, true
	e.info = biome_info_raw(x, z)
	return e.info
}

biome_at :: proc(x, z: i32) -> Biome_Type {return biome_info(x, z).b}

ceil_h :: proc(x, z: i32) -> f32 {
	i := biome_info(x, z)
	return WALL_HEIGHT[i.b] * i.w + WALL_HEIGHT[i.b2] * (1 - i.w)
}

corner_h :: proc(cx, cz: i32) -> f32 {
	return(
		(ceil_h(cx - 1, cz - 1) + ceil_h(cx, cz - 1) + ceil_h(cx - 1, cz) + ceil_h(cx, cz)) *
		0.25 \
	)
}

// ───────────────────────── floor plan generator ─────────────────────────
