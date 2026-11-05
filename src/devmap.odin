package main

import "core:fmt"
import "core:math"
import rl "vendor:raylib"

TEX_W :: 384
TEX_H :: 224
HUD_W :: 310
HUD_H :: 380 // grew for stair/hole info

Dev_Map :: struct {
	open:       bool,
	zoom:       f32,
	cx, cz:     f32,
	view_level: i32,
	tex:        rl.Texture2D,
	pixels:     []rl.Color,
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

devmap_destroy :: proc(m: ^Dev_Map) {rl.UnloadTexture(m.tex); delete(m.pixels)}

snap :: proc(o, s: f32, c: i32) -> i32 {return i32(math.round(o + f32(c) * s))}

devmap_update :: proc(m: ^Dev_Map, player: ^Player) {
	if rl.IsKeyPressed(.F5) {
		m.open = !m.open
		if m.open {
			rl.EnableCursor()
			m.cx, m.cz = player.cam.position.x / CELL, player.cam.position.z / CELL
			m.view_level = current_floor
		} else {rl.DisableCursor()}
	}
	if !m.open do return

	m.zoom = clamp(m.zoom * (1 + rl.GetMouseWheelMove() * 0.1), 4, 40)
	if rl.IsMouseButtonDown(.RIGHT) {
		d := rl.GetMouseDelta()
		m.cx -= d.x / m.zoom
		m.cz -= d.y / m.zoom
	}
	if rl.IsKeyPressed(
		.C,
	) {m.cx, m.cz = player.cam.position.x / CELL, player.cam.position.z / CELL}
	if rl.IsKeyPressed(.RIGHT_BRACKET) || rl.IsKeyPressed(.PAGE_UP) {
		m.view_level += 1
	}
	if rl.IsKeyPressed(.LEFT_BRACKET) || rl.IsKeyPressed(.PAGE_DOWN) {
		m.view_level -= 1
	}
	if rl.IsKeyPressed(.ENTER) {
		set_current_floor(m.view_level)
		player.feet_y = ground_at(player.cam.position.x, player.cam.position.z)
		player.eye_y = player.feet_y + EYE_H
		player.cam.position.y = player.eye_y
		player.grounded = true
		player.vel_y = 0
	}

	mp := rl.GetMousePosition()
	over_hud := mp.x < HUD_W && mp.y < HUD_H
	if rl.IsMouseButtonPressed(.LEFT) && !over_hud {
		sw, sh := f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight())
		wx := (mp.x - (sw / 2 - m.cx * m.zoom)) / m.zoom
		wz := (mp.y - (sh / 2 - m.cz * m.zoom)) / m.zoom
		set_current_floor(m.view_level)
		player.cam.position.x = (math.floor(wx) + 0.5) * CELL
		player.cam.position.z = (math.floor(wz) + 0.5) * CELL
		player.feet_y = ground_at(player.cam.position.x, player.cam.position.z)
		player.eye_y = player.feet_y + EYE_H
		player.cam.position.y = player.eye_y
		player.grounded = true
		player.vel_y = 0
	}
}

edge_kind :: proc(x, z: i32, north: bool) -> int {
	switch edge_at(x, z, north) {
	case EDGE_WALL:
		return 1
	case EDGE_DOOR:
		return 2
	}
	return 0
}
edge_color :: proc(kind: int) -> rl.Color {
	switch kind {case 2:
		return {100, 200, 255, 220}}
	return {20, 20, 25, 255}
}
draw_run :: proc(horizontal: bool, a, b, p, t: i32, kind: int) {
	h := t / 2
	col := edge_color(kind)
	ext: i32 = kind == 1 ? h : 0
	if horizontal {
		rl.DrawRectangle(a - ext, p - h, (b - a) + 2 * ext + (kind == 1 ? t - 2 * h : 0), t, col)
	} else {
		rl.DrawRectangle(p - h, a - ext, t, (b - a) + 2 * ext + (kind == 1 ? t - 2 * h : 0), col)
	}
}

tint_by_floor :: proc(c: rl.Color, lvl: i8) -> rl.Color {
	if lvl == 0 do return c
	d := i32(lvl) * 14
	return {
		u8(clamp(i32(c.r) + (d if lvl > 0 else 0), 0, 255)),
		u8(clamp(i32(c.g) + (d / 2 if lvl > 0 else 0), 0, 255)),
		u8(clamp(i32(c.b) + (d if lvl < 0 else 0), 0, 255)),
		255,
	}
}

devmap_draw :: proc(m: ^Dev_Map, pos: rl.Vector3, yaw: f32) {
	player_floor := current_floor
	current_floor = m.view_level
	last_region = nil
	defer {
		current_floor = player_floor
		last_region = nil
	}

	rl.BeginDrawing()
	rl.ClearBackground({15, 15, 20, 255})

	sw, sh := f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight())
	s := m.zoom
	ox, oy := sw / 2 - m.cx * s, sh / 2 - m.cz * s

	step := max(i32(1), i32(math.ceil(6.0 / s)))
	x0 := fdiv(i32(math.floor(-ox / s)), step) * step
	z0 := fdiv(i32(math.floor(-oy / s)), step) * step
	x1 := i32(math.ceil((sw - ox) / s))
	z1 := i32(math.ceil((sh - oy) / s))
	tw := min(i32(TEX_W), (x1 - x0) / step + 1)
	th := min(i32(TEX_H), (z1 - z0) / step + 1)
	xe, ze := x0 + tw * step, z0 + th * step

	counts: [Biome_Type]int
	total := 0
	for j in 0 ..< th do for i in 0 ..< tw {
		cx, cz := x0 + i * step, z0 + j * step
		b := biome_at(cx, cz)
		lvl := floor_level(cx, cz)
		counts[b] += 1
		total += 1
		m.pixels[int(j) * TEX_W + int(i)] = tint_by_floor(MAP_COLORS[b], lvl)
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

	// Pillars, pools, stairs, holes
	if s >= 6.0 {
		for cz in z0 ..< ze do for cx in x0 ..< xe {
			px, py := snap(ox, s, cx), snap(oy, s, cz)
			pw := snap(ox, s, cx + 1) - px
			ph := snap(oy, s, cz + 1) - py
			if stair_at(cx, cz) {
				d := stair_dir_at(cx, cz)
				cx_c := f32(px) + f32(pw) / 2
				cy_c := f32(py) + f32(ph) / 2
				arx, ary: f32 = 0, 0
				switch d {
				case 0:
					ary = -1
				case 1:
					ary = 1
				case 2:
					arx = 1
				case 3:
					arx = -1
				}
				rl.DrawCircleV({cx_c, cy_c}, 3, rl.YELLOW)
				rl.DrawLineEx({cx_c, cy_c}, {cx_c + arx * f32(pw) * 0.4, cy_c + ary * f32(ph) * 0.4}, 2, rl.YELLOW)
			} else if hole_at(cx, cz) {
				rl.DrawRectangle(px + pw / 4, py + ph / 4, pw / 2, ph / 2, rl.BLACK)
				rl.DrawRectangleLines(px + pw / 4, py + ph / 4, pw / 2, ph / 2, rl.Color{200, 80, 80, 255})
			} else if pool_at(cx, cz) {
				rl.DrawRectangle(px, py, pw, ph, {50, 160, 190, 160})
			} else if pillar_at(cx, cz) {
				rl.DrawRectangle(px + pw / 3, py + ph / 3, max(pw / 3, 1), max(ph / 3, 1), {20, 20, 25, 255})
			}
		}
	}

	// Walls
	if s >= 6.0 {
		t := max(i32(1), i32(math.round(s * 0.15)))
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

	// Chunk borders
	for cx := fdiv(x0, CHUNK_SIZE) * CHUNK_SIZE; cx <= xe; cx += CHUNK_SIZE {
		rl.DrawRectangle(snap(ox, s, cx), 0, 1, i32(sh), {255, 255, 255, 50})
	}
	for cz := fdiv(z0, CHUNK_SIZE) * CHUNK_SIZE; cz <= ze; cz += CHUNK_SIZE {
		rl.DrawRectangle(0, snap(oy, s, cz), i32(sw), 1, {255, 255, 255, 50})
	}

	// Player
	pc := rl.Vector2{ox + pos.x / CELL * s, oy + pos.z / CELL * s}
	pcol := rl.RED if player_floor == m.view_level else rl.Color{160, 160, 160, 255}
	rl.DrawCircleV(pc, 5, pcol)
	rl.DrawLineEx(pc, pc + {math.sin(yaw), math.cos(yaw)} * 18, 2, pcol)

	// HUD
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
	rl.DrawText("[ ] PgUp/PgDn: browse floors | ENTER: go to floor", 10, 22, 10, rl.WHITE)
	rl.DrawText(
		fmt.ctprintf(
			"cell %d, %d  chunk %d, %d",
			pcell.x,
			pcell.y,
			fdiv(pcell.x, CHUNK_SIZE),
			fdiv(pcell.y, CHUNK_SIZE),
		),
		10,
		40,
		10,
		rl.WHITE,
	)
	rl.DrawText(
		fmt.ctprintf(
			"viewing floor %d: %s%s",
			m.view_level,
			LEVELS[current_level].name,
			" (you are here)" if player_floor == m.view_level else "",
		),
		10,
		56,
		10,
		rl.YELLOW if player_floor != m.view_level else rl.WHITE,
	)
	if player_floor != m.view_level {
		rl.DrawText(
			fmt.ctprintf("you are on floor %d: %s", player_floor, LEVELS[current_level].name),
			10,
			68,
			10,
			{160, 160, 160, 255},
		)
	}
	rl.DrawText(fmt.ctprintf("in: %v", biome_at(pcell.x, pcell.y)), 10, 80, 10, rl.WHITE)

	y := i32(100)
	for b in Biome_Type {
		if total > 0 {
			pct := f32(counts[b]) * 100 / f32(total)
			rl.DrawRectangle(10, y + 2, 10, 10, MAP_COLORS[b])
			rl.DrawText(fmt.ctprintf("%v  %.1f%%", b, pct), 28, y, 10, rl.WHITE)
			y += 19
		}
	}

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
	lvl := floor_level(hx, hz)
	rl.DrawText(
		fmt.ctprintf(
			"floor L%d (%.2fm)%s",
			lvl,
			floor_h(hx, hz),
			"  [raised]" if lvl > 0 else ("  [sunken]" if lvl < 0 else ""),
		),
		10,
		y + 32,
		10,
		{255, 200, 120, 255} if lvl > 0 else ({120, 200, 255, 255} if lvl < 0 else rl.WHITE),
	)
	// Vertical-link information for the hovered cell.
	if link, has_link, role := vertical_link_at(hx, hz); has_link {
		kind_name := "STAIRS"
		switch link.kind {
		case .Stairs:
			kind_name = "STAIRS"
		case .Switchback:
			kind_name = "SWITCHBACK"
		case .Ramp:
			kind_name = "RAMP"
		case .Drop:
			kind_name = "DROP"
		case .Slide:
			kind_name = "SLIDE"
		}
		message: cstring = ""
		color := rl.YELLOW
		if role == .Upper {
			message = fmt.ctprintf("%s down to floor %d", kind_name, m.view_level - 1)
			color = {240, 130, 130, 255}
		} else if link.kind == .Stairs || link.kind == .Switchback || link.kind == .Ramp {
			message = fmt.ctprintf("%s up to floor %d", kind_name, m.view_level + 1)
		} else {
			message = fmt.ctprintf("%s landing from floor %d", kind_name, m.view_level + 1)
			color = {160, 190, 255, 255}
		}
		rl.DrawText(message, 10, y + 48, 10, color)
	}

	// While inspecting the map, retain regions around the map viewport rather
	// than the player's (possibly distant) position.
	regions_trim(i32(math.floor(m.cx)), i32(math.floor(m.cz)))
	rl.EndDrawing()
}
