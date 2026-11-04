package main

import "core:fmt"
import "core:math"
import rl "vendor:raylib"

TEX_W :: 384 // biome texture size in cells; big enough for 1920 wide at zoom 6
TEX_H :: 224

HUD_W :: 310
HUD_H :: 330

Dev_Map :: struct {
	open:   bool,
	zoom:   f32, // pixels per cell
	cx, cz: f32, // view centre, in cells
	tex:    rl.Texture2D,
	pixels: []rl.Color,
}

MAP_COLORS := [Biome_Type]rl.Color {
	.Mono_Yellow       = {200, 180, 60, 255},
	.Fluorescent_White = {225, 228, 222, 255},
	.Poolrooms         = {90, 150, 170, 255},
	.Concrete_Maze     = {110, 110, 115, 255},
	.Parking_Garage    = {128, 130, 136, 255},
	.Red_Rooms         = {168, 78, 68, 255},
	.Warehouse         = {142, 122, 96, 255},
	.Hotel_Corridor    = {162, 142, 116, 255},
	.Arcade_Night      = {92, 62, 122, 255},
	.Sub_Basement      = {102, 94, 81, 255},
}

// call after the window is created (it makes a GPU texture)
devmap_init :: proc() -> Dev_Map {
	m := Dev_Map {
		zoom = 12,
	}
	img := rl.GenImageColor(TEX_W, TEX_H, rl.BLACK)
	defer rl.UnloadImage(img)
	m.tex = rl.LoadTextureFromImage(img)
	rl.SetTextureFilter(m.tex, .POINT)
	m.pixels = make([]rl.Color, TEX_W * TEX_H)
	return m
}

devmap_destroy :: proc(m: ^Dev_Map) {
	rl.UnloadTexture(m.tex)
	delete(m.pixels)
}

// round a cell-edge position to a whole pixel so neighbouring cells tile with no seams
snap :: proc(o, s: f32, c: i32) -> i32 {
	return i32(math.round(o + f32(c) * s))
}

devmap_update :: proc(m: ^Dev_Map, player: ^Player) {
	if rl.IsKeyPressed(.F5) {
		m.open = !m.open
		if m.open {
			rl.EnableCursor()
			m.cx, m.cz = player.cam.position.x / CELL, player.cam.position.z / CELL
		} else {
			rl.DisableCursor()
		}
	}
	if !m.open do return

	m.zoom = clamp(m.zoom * (1 + rl.GetMouseWheelMove() * 0.1), 4, 40)

	if rl.IsMouseButtonDown(.RIGHT) {
		d := rl.GetMouseDelta()
		m.cx -= d.x / m.zoom
		m.cz -= d.y / m.zoom
	}
	if rl.IsKeyPressed(.C) {
		m.cx, m.cz = player.cam.position.x / CELL, player.cam.position.z / CELL
	}

	mp := rl.GetMousePosition()
	over_hud := mp.x < HUD_W && mp.y < HUD_H
	if rl.IsMouseButtonPressed(.LEFT) && !over_hud {
		sw, sh := f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight())
		wx := (mp.x - (sw / 2 - m.cx * m.zoom)) / m.zoom
		wz := (mp.y - (sh / 2 - m.cz * m.zoom)) / m.zoom
		player.cam.position.x = (math.floor(wx) + 0.5) * CELL
		player.cam.position.z = (math.floor(wz) + 0.5) * CELL
	}
}

// 0 none, 1 wall, 2 door, 3 sealed side that has a wide gap elsewhere
edge_kind :: proc(x, z: i32, north: bool) -> int {
	s, _ := lat_edge(x, z, north)
	if !s.wall do return 0
	if has_door(x, z, north) do return 2
	if s.gap do return 3
	return 1
}

edge_color :: proc(kind: int) -> rl.Color {
	switch kind {
	case 2:
		return {100, 200, 255, 220}
	case 3:
		return {200, 200, 200, 120}
	}
	return {20, 20, 25, 255}
}

// one merged run of wall. a..b are pixel extents along the wall, p is the line position.
draw_run :: proc(horizontal: bool, a, b, p, t: i32, kind: int) {
	h := t / 2
	col := edge_color(kind)
	ext: i32 = kind == 1 ? h : 0 // solid walls overshoot so corners join
	if horizontal {
		rl.DrawRectangle(a - ext, p - h, (b - a) + 2 * ext + (kind == 1 ? t - 2 * h : 0), t, col)
	} else {
		rl.DrawRectangle(p - h, a - ext, t, (b - a) + 2 * ext + (kind == 1 ? t - 2 * h : 0), col)
	}
}

// replaces the normal frame while open
devmap_draw :: proc(m: ^Dev_Map, pos: rl.Vector3, yaw: f32) {
	rl.BeginDrawing()
	rl.ClearBackground({15, 15, 20, 255})

	sw, sh := f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight())
	s := m.zoom
	ox, oy := sw / 2 - m.cx * s, sh / 2 - m.cz * s

	// below zoom 6 sample every nth cell, so far-out views stay cheap
	step := max(i32(1), i32(math.ceil(6.0 / s)))
	x0 := fdiv(i32(math.floor(-ox / s)), step) * step
	z0 := fdiv(i32(math.floor(-oy / s)), step) * step
	x1 := i32(math.ceil((sw - ox) / s))
	z1 := i32(math.ceil((sh - oy) / s))
	tw := min(i32(TEX_W), (x1 - x0) / step + 1)
	th := min(i32(TEX_H), (z1 - z0) / step + 1)
	xe, ze := x0 + tw * step, z0 + th * step

	// 1. Biome layer: one texture, one draw call
	counts: [Biome_Type]int
	total := 0
	for j in 0 ..< th {
		for i in 0 ..< tw {
			b := biome_at(x0 + i * step, z0 + j * step)
			counts[b] += 1
			total += 1
			m.pixels[int(j) * TEX_W + int(i)] = MAP_COLORS[b]
		}
	}
	rl.UpdateTexture(m.tex, raw_data(m.pixels))
	dx, dy := snap(ox, s, x0), snap(oy, s, z0)
	dw, dh := snap(ox, s, xe) - dx, snap(oy, s, ze) - dy
	rl.DrawTexturePro(
		m.tex,
		{0, 0, f32(tw), f32(th)},
		{f32(dx), f32(dy), f32(dw), f32(dh)},
		{0, 0},
		0,
		rl.WHITE,
	)

	// 2. Walls, merged into runs (only when cells are big enough to read)
	if s >= 6.0 {
		t := max(i32(1), i32(math.round(s * 0.15)))

		// north edges: runs along x
		for cz in z0 ..< ze {
			y := snap(oy, s, cz)
			run_k, run_start := 0, x0
			for cx in x0 ..= xe {
				k := 0
				if cx < xe do k = edge_kind(cx, cz, true)
				if k != run_k {
					if run_k != 0 {
						draw_run(true, snap(ox, s, run_start), snap(ox, s, cx), y, t, run_k)
					}
					run_k, run_start = k, cx
				}
			}
		}

		// west edges: runs along z
		for cx in x0 ..< xe {
			px := snap(ox, s, cx)
			run_k, run_start := 0, z0
			for cz in z0 ..= ze {
				k := 0
				if cz < ze do k = edge_kind(cx, cz, false)
				if k != run_k {
					if run_k != 0 {
						draw_run(false, snap(oy, s, run_start), snap(oy, s, cz), px, t, run_k)
					}
					run_k, run_start = k, cz
				}
			}
		}
	}

	// 3. Chunk borders
	for cx := fdiv(x0, CHUNK_SIZE) * CHUNK_SIZE; cx <= xe; cx += CHUNK_SIZE {
		rl.DrawRectangle(snap(ox, s, cx), 0, 1, i32(sh), {255, 255, 255, 50})
	}
	for cz := fdiv(z0, CHUNK_SIZE) * CHUNK_SIZE; cz <= ze; cz += CHUNK_SIZE {
		rl.DrawRectangle(0, snap(oy, s, cz), i32(sw), 1, {255, 255, 255, 50})
	}

	// 4. Player + facing indicator (at the player's real position, not the view centre)
	pc := rl.Vector2{ox + pos.x / CELL * s, oy + pos.z / CELL * s}
	rl.DrawCircleV(pc, 5, rl.RED)
	rl.DrawLineEx(pc, pc + {math.sin(yaw), math.cos(yaw)} * 18, 2, rl.RED)

	// 5. HUD, drawn last
	pcx, pcz := pos.x / CELL, pos.z / CELL
	pcell := [2]i32{i32(math.floor(pcx)), i32(math.floor(pcz))}
	rl.DrawRectangle(0, 0, HUD_W, HUD_H, {10, 10, 15, 230})
	rl.DrawText(
		"F5 close | wheel zoom | RMB pan | C recentre | LMB teleport",
		10,
		10,
		10,
		rl.WHITE,
	)
	rl.DrawText(
		fmt.ctprintf(
			"cell %d, %d  chunk %d, %d",
			pcell.x,
			pcell.y,
			fdiv(pcell.x, CHUNK_SIZE),
			fdiv(pcell.y, CHUNK_SIZE),
		),
		10,
		28,
		10,
		rl.WHITE,
	)
	rl.DrawText(fmt.ctprintf("in: %v", biome_at(pcell.x, pcell.y)), 10, 46, 10, rl.WHITE)

	y := i32(68)
	for b in Biome_Type {
		if total > 0 {
			pct := f32(counts[b]) * 100 / f32(total)
			rl.DrawRectangle(10, y + 2, 10, 10, MAP_COLORS[b])
			rl.DrawText(fmt.ctprintf("%v  %.1f%%", b, pct), 28, y, 10, rl.WHITE)
			y += 19
		}
	}

	// hover info for the cell under the mouse
	mp := rl.GetMousePosition()
	hx := i32(math.floor((mp.x - ox) / s))
	hz := i32(math.floor((mp.y - oy) / s))
	y += 6
	rl.DrawText(fmt.ctprintf("hover %d, %d: %v", hx, hz, biome_at(hx, hz)), 10, y, 10, rl.WHITE)
	rl.DrawText(
		fmt.ctprintf("enclosure %d  ceiling %.2f", cell_enclosure(hx, hz), ceil_h(hx, hz)),
		10,
		y + 16,
		10,
		rl.WHITE,
	)

	rl.EndDrawing()
}
