package main

import "core:fmt"
import "core:math"
import rl "vendor:raylib"

// ───────────────────────── dev map layout / cache ─────────────────────────

MIN_ZOOM :: 4
MAX_ZOOM :: 40

TOP_BAR_H :: 30
LEFT_W :: 286
RIGHT_W :: 292

// The map is rasterised once per 32×32-cell tile and uploaded into a small
// atlas. Panning and zooming only redraw cached tiles, so the expensive
// biome/region generation never runs on the critical path.
TILE_CELLS :: 32
TILE_PIXELS :: TILE_CELLS * TILE_CELLS
TILE_SLOTS :: 256
ATLAS_COLS :: 16
ATLAS_ROWS :: 16
ATLAS_W :: ATLAS_COLS * TILE_CELLS
ATLAS_H :: ATLAS_ROWS * TILE_CELLS

TILE_BUDGET :: 0.006 // seconds of tile generation per frame

FLAG_WALL_N :: u16(1 << 0)
FLAG_WALL_W :: u16(1 << 1)
FLAG_DOOR_N :: u16(1 << 2)
FLAG_DOOR_W :: u16(1 << 3)
FLAG_PILLAR :: u16(1 << 4)
FLAG_POOL :: u16(1 << 5)
FLAG_STAIR :: u16(1 << 6)
FLAG_HOLE :: u16(1 << 7)
FLAG_LOOP :: u16(1 << 8)
FLAG_GLITCH :: u16(1 << 9)
FLAG_STAIR_DIR_SHIFT :: u16(10)

BIOME_COUNT :: 10

Tile_Key :: struct {
	level, tx, tz: i32,
}

Tile_Slot :: struct {
	key:   Tile_Key,
	used:  u64,
	valid: bool,
}

rect_i :: struct {
	x, y, w, h: i32,
}

point_in_rect :: proc(p: rl.Vector2, r: rect_i) -> bool {
	return p.x >= f32(r.x) && p.x < f32(r.x + r.w) && p.y >= f32(r.y) && p.y < f32(r.y + r.h)
}

Panel_Mode :: enum {
	Auto,
	Both,
	Inspector,
	Status,
}

Dev_Map :: struct {
	open:       bool,
	zoom:       f32,
	cx, cz:     f32,
	view_level: i32,
	panning:    bool,

	tex:   rl.Texture2D,
	tiles: map[Tile_Key]int,
	slots: [TILE_SLOTS]Tile_Slot,
	flags: []u16,
	counts: [][Biome_Type]u16,
	tick:  u64,

	wheel_accum: f32,
	panel_mode:  Panel_Mode,
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

Legend_Item :: struct {
	col:   rl.Color,
	label: cstring,
}

LEGEND_ITEMS := []Legend_Item {
	{{100, 220, 255, 255}, "loop room"},
	{{255, 80, 255, 255}, "glitch wall"},
	{{255, 230, 80, 255}, "stair up"},
	{{230, 90, 90, 255}, "shaft down"},
	{{80, 255, 130, 255}, "floor / task exit"},
	{{220, 80, 80, 255}, "entity"},
	{{190, 130, 255, 255}, "phantom"},
	{{255, 215, 0, 255}, "key"},
	{{255, 140, 80, 255}, "walkie"},
	{{90, 220, 255, 255}, "battery"},
	{{235, 235, 245, 255}, "water"},
	{{255, 130, 60, 255}, "fuse"},
	{{220, 200, 70, 255}, "valve"},
	{{80, 120, 220, 255}, "tape"},
	{{80, 255, 130, 255}, "phantom door"},
	{{180, 180, 190, 255}, "flashlight"},
	{{255, 80, 255, 255}, "FAKE item"},
}

devmap_init :: proc() -> Dev_Map {
	m := Dev_Map {
		zoom       = 12,
		panel_mode = .Auto,
	}
	img := rl.GenImageColor(ATLAS_W, ATLAS_H, rl.Color{0, 0, 0, 0})
	defer rl.UnloadImage(img)
	m.tex = rl.LoadTextureFromImage(img)
	rl.SetTextureFilter(m.tex, .POINT)
	m.tiles = make(map[Tile_Key]int)
	m.flags = make([]u16, TILE_SLOTS * TILE_PIXELS)
	m.counts = make([][Biome_Type]u16, TILE_SLOTS)
	return m
}

devmap_destroy :: proc(m: ^Dev_Map) {
	rl.UnloadTexture(m.tex)
	delete(m.flags)
	delete(m.counts)
	delete(m.tiles)
}

devmap_origin :: proc(m: ^Dev_Map, sw, sh: f32) -> (f32, f32) {
	// Integer zoom plus a pixel-snapped origin means every cell edge lands on
	// an exact pixel: no shimmering, seams, or resolution pops while zooming.
	ox := i32(math.round(sw / 2 - m.cx * m.zoom))
	oy := i32(math.round(sh / 2 - m.cz * m.zoom))
	return f32(ox), f32(oy)
}

legend_item_width :: proc(it: Legend_Item) -> i32 {
	return 12 + rl.MeasureText(it.label, 10) + 16
}

legend_rows :: proc(sw: i32) -> i32 {
	x: i32 = 10
	rows: i32 = 1
	for it in LEGEND_ITEMS {
		w := legend_item_width(it)
		if x + w > sw - 10 && x > 10 {
			rows += 1
			x = 10
		}
		x += w
	}
	return rows
}

Dev_Layout :: struct {
	show_left, show_right: bool,
	left, right:          rect_i,
	topbar, legend:       rect_i,
}

devmap_layout :: proc(m: ^Dev_Map, sw, sh: i32) -> Dev_Layout {
	l := Dev_Layout{}

	legend_h: i32
	if sh >= 300 {
		legend_h = legend_rows(sw) * 13 + 9
	}

	both_fit := sw >= LEFT_W + RIGHT_W + 220
	mode := m.panel_mode
	if mode == .Auto {
		mode = both_fit ? .Both : .Status
	}

	l.show_left = mode == .Both || mode == .Inspector
	l.show_right = mode == .Both || mode == .Status

	pt := i32(TOP_BAR_H + 6)
	pb := sh - legend_h - 6
	if pb > pt {
		lh := min(LEFT_W, sw - 16)
		rh := min(RIGHT_W, sw - 16)
		l.left = {8, pt, lh, pb - pt}
		l.right = {sw - rh - 8, pt, rh, pb - pt}
	}

	l.topbar = {0, 0, sw, TOP_BAR_H}
	l.legend = {0, sh - legend_h, sw, legend_h}
	return l
}

// ───────────────────────── tile cache ─────────────────────────

devmap_tile_slot :: proc(m: ^Dev_Map, key: Tile_Key) -> (int, bool) {
	if slot, ok := m.tiles[key]; ok do return slot, true
	return 0, false
}

devmap_alloc_slot :: proc(m: ^Dev_Map, key: Tile_Key) -> int {
	pick := 0
	oldest := max(u64)
	for i in 0 ..< TILE_SLOTS {
		if !m.slots[i].valid {
			pick = i
			break
		}
		if m.slots[i].used < oldest {
			oldest = m.slots[i].used
			pick = i
		}
	}

	if m.slots[pick].valid do delete_key(&m.tiles, m.slots[pick].key)
	m.slots[pick] = {key = key, used = m.tick, valid = true}
	m.tiles[key] = pick
	return pick
}

generate_tile :: proc(m: ^Dev_Map, slot: int, tx, tz: i32) {
	col := slot % ATLAS_COLS
	row := slot / ATLAS_COLS
	px0 := col * TILE_CELLS
	py0 := row * TILE_CELLS

	buf: [TILE_PIXELS]rl.Color
	counts: [Biome_Type]u16
	base := slot * TILE_PIXELS

	for j in 0 ..< TILE_CELLS {
		cz := tz * TILE_CELLS + i32(j)
		for i in 0 ..< TILE_CELLS {
			cx := tx * TILE_CELLS + i32(i)

			b := biome_at(cx, cz)
			counts[b] += 1
			lvl := floor_level(cx, cz)
			buf[j * TILE_CELLS + i] = tint_by_floor(MAP_COLORS[b], lvl)

			fl: u16
			if !(abs(cx) <= SPAWN_CLEAR && abs(cz) <= SPAWN_CLEAR) {
				r := region_at(cx, cz)
				idx := region_idx(r, cx, cz)

				switch r.edge_n[idx] {
				case EDGE_WALL:
					fl |= FLAG_WALL_N
				case EDGE_DOOR:
					fl |= FLAG_DOOR_N
				}
				switch r.edge_w[idx] {
				case EDGE_WALL:
					fl |= FLAG_WALL_W
				case EDGE_DOOR:
					fl |= FLAG_DOOR_W
				}

				cf := r.cell_flg[idx]
				if cf & CELL_PILLAR != 0 do fl |= FLAG_PILLAR
				if cf & CELL_POOL != 0 do fl |= FLAG_POOL
				if cf & CELL_HOLE != 0 do fl |= FLAG_HOLE
				if cf & CELL_STAIR != 0 {
					fl |= FLAG_STAIR
					fl |= u16(r.cell_stair[idx] & 3) << FLAG_STAIR_DIR_SHIFT
				}
			}

			// These are rare hash hits, so the extra checks are cheap.
			if is_loop_cell(cx, cz) do fl |= FLAG_LOOP
			if is_glitch_cell(cx, cz) do fl |= FLAG_GLITCH
			m.flags[base + j * TILE_CELLS + i] = fl
		}
	}

	m.counts[slot] = counts
	rl.UpdateTextureRec(
		m.tex,
		{f32(px0), f32(py0), TILE_CELLS, TILE_CELLS},
		raw_data(buf[:]),
	)
}

// Generate only the tiles that are visible (plus a one-tile margin) and stop
// after a small time budget, so a fast pan never stalls a frame.
devmap_stream_tiles :: proc(m: ^Dev_Map, sw, sh: f32) {
	m.tick += 1
	s := m.zoom
	ox, oy := devmap_origin(m, sw, sh)

	x0 := i32(math.floor(-ox / s)) - TILE_CELLS
	x1 := i32(math.ceil((sw - ox) / s)) + TILE_CELLS
	z0 := i32(math.floor(-oy / s)) - TILE_CELLS
	z1 := i32(math.ceil((sh - oy) / s)) + TILE_CELLS

	tx0, tx1 := fdiv(x0, TILE_CELLS), fdiv(x1, TILE_CELLS)
	tz0, tz1 := fdiv(z0, TILE_CELLS), fdiv(z1, TILE_CELLS)

	// Touch every visible/needed tile for LRU.
	for tz in tz0 ..= tz1 do for tx in tx0 ..= tx1 {
		key := Tile_Key{m.view_level, tx, tz}
		if slot, ok := m.tiles[key]; ok {
			m.slots[slot].used = m.tick
		}
	}

	start := rl.GetTime()
	for tz in tz0 ..= tz1 do for tx in tx0 ..= tx1 {
		key := Tile_Key{m.view_level, tx, tz}
		if _, ok := m.tiles[key]; ok do continue

		slot := devmap_alloc_slot(m, key)
		generate_tile(m, slot, tx, tz)
		if rl.GetTime() - start >= TILE_BUDGET do return
	}
}

Flags_Cache :: struct {
	tx, tz: i32,
	base:   int,
	ok:     bool,
}

flags_at :: proc(m: ^Dev_Map, c: ^Flags_Cache, cx, cz: i32) -> u16 {
	tx := fdiv(cx, TILE_CELLS)
	tz := fdiv(cz, TILE_CELLS)
	if !c.ok || c.tx != tx || c.tz != tz {
		c.tx, c.tz = tx, tz
		c.ok = false
		if slot, found := m.tiles[Tile_Key{m.view_level, tx, tz}]; found {
			c.base = slot * TILE_PIXELS
			c.ok = true
		}
	}
	if !c.ok do return 0
	lx := cx - tx * TILE_CELLS
	lz := cz - tz * TILE_CELLS
	return m.flags[c.base + int(lz) * TILE_CELLS + int(lx)]
}

// ───────────────────────── input ─────────────────────────

devmap_update :: proc(m: ^Dev_Map, player: ^Player) {
	if rl.IsKeyPressed(.F5) {
		m.open = !m.open
		if m.open {
			m.cx, m.cz = player.cam.position.x / CELL, player.cam.position.z / CELL
			m.view_level = current_level
			m.wheel_accum = 0
			m.panning = false
		}
	}
	if !m.open do return

	swf, shf := f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight())
	sw, sh := i32(swf), i32(shf)
	layout := devmap_layout(m, sw, sh)

	if rl.IsKeyPressed(.TAB) {
		m.panel_mode = Panel_Mode(
			(int(m.panel_mode) + 1) % len(Panel_Mode),
		)
	}

	mp := rl.GetMousePosition()
	over_panel :=
		(layout.show_left && point_in_rect(mp, layout.left)) ||
		(layout.show_right && point_in_rect(mp, layout.right)) ||
		point_in_rect(mp, layout.topbar) ||
		point_in_rect(mp, layout.legend)

	// Integer zoom keeps texels pixel-aligned at every zoom level.
	wheel := rl.GetMouseWheelMove()
	if wheel != 0 {
		m.wheel_accum = clamp(m.wheel_accum + wheel, -6, 6)
		dz := i32(m.wheel_accum)
		if dz != 0 {
			m.wheel_accum -= f32(dz)
			dz = clamp(dz, -4, 4)
			old := m.zoom
			m.zoom = clamp(m.zoom + f32(dz), MIN_ZOOM, MAX_ZOOM)
			if m.zoom != old && !over_panel {
				// Keep the world point under the cursor anchored while zooming.
				m.cx += (mp.x - swf / 2) * (1 / old - 1 / m.zoom)
				m.cz += (mp.y - shf / 2) * (1 / old - 1 / m.zoom)
			}
		}
	}

	if rl.IsMouseButtonPressed(.RIGHT) && !over_panel do m.panning = true
	if rl.IsMouseButtonReleased(.RIGHT) || !rl.IsMouseButtonDown(.RIGHT) do m.panning = false
	if m.panning {
		d := rl.GetMouseDelta()
		m.cx -= d.x / m.zoom
		m.cz -= d.y / m.zoom
	}

	if rl.IsKeyPressed(.C) {
		m.cx, m.cz = player.cam.position.x / CELL, player.cam.position.z / CELL
	}
	if rl.IsKeyPressed(.RIGHT_BRACKET) || rl.IsKeyPressed(.PAGE_UP) {
		m.view_level = (m.view_level + 1) %% NUM_LEVELS
	}
	if rl.IsKeyPressed(.LEFT_BRACKET) || rl.IsKeyPressed(.PAGE_DOWN) {
		m.view_level = (m.view_level - 1) %% NUM_LEVELS
	}
	if rl.IsKeyPressed(.ENTER) do set_level(m.view_level)

	// Developer cheats: finish the current floor task or grant the level key.
	if rl.IsKeyPressed(.T) &&
	   current_objective.kind != .None &&
	   !current_objective.done {
		current_objective.progress = current_objective.target
		objective_reward()
		objective_update_exit(player)
		set_event("DEV: FLOOR TASK COMPLETED", 2.0)
	}
	if rl.IsKeyPressed(.K) && !has_key {
		has_key = true
		key_item.active = false
		set_event("DEV: KEY GRANTED", 2.0)
	}

	if rl.IsMouseButtonPressed(.LEFT) && !over_panel {
		ox, oy := devmap_origin(m, swf, shf)
		wx := (mp.x - ox) / m.zoom
		wz := (mp.y - oy) / m.zoom
		set_level(m.view_level)
		player.cam.position.x = (math.floor(wx) + 0.5) * CELL
		player.cam.position.z = (math.floor(wz) + 0.5) * CELL
	}
}

// ───────────────────────── drawing helpers ─────────────────────────

edge_kind :: proc(x, z: i32, north: bool, m: ^Dev_Map, cache: ^Flags_Cache) -> int {
	fl := flags_at(m, cache, x, z)
	if north {
		if fl & FLAG_WALL_N != 0 do return 1
		if fl & FLAG_DOOR_N != 0 do return 2
	} else {
		if fl & FLAG_WALL_W != 0 do return 1
		if fl & FLAG_DOOR_W != 0 do return 2
	}
	return 0
}

edge_color :: proc(kind: int) -> rl.Color {
	switch kind {
	case 2:
		return {100, 200, 255, 220}
	}
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

mode_name :: proc(m: Game_Mode) -> string {
	switch m {
	case .Easy:
		return "Easy"
	case .Normal:
		return "Normal"
	case .Hard:
		return "Hard"
	}
	return "?"
}

entity_state_name :: proc(s: Entity_State) -> string {
	switch s {
	case .Idle:
		return "idle"
	case .Patrol:
		return "patrol"
	case .Chase:
		return "CHASE"
	case .Investigate:
		return "investigate"
	}
	return "?"
}

biome_short :: proc(b: Biome_Type) -> string {
	switch b {
	case .Mono_Yellow:
		return "Mono"
	case .Fluorescent_White:
		return "White"
	case .Poolrooms:
		return "Pool"
	case .Concrete_Maze:
		return "Concrete"
	case .Parking_Garage:
		return "Garage"
	case .Red_Rooms:
		return "Red"
	case .Warehouse:
		return "Warehouse"
	case .Hotel_Corridor:
		return "Hotel"
	case .Arcade_Night:
		return "Arcade"
	case .Sub_Basement:
		return "Basement"
	}
	return "?"
}

// Distance in metres from a world position to the centre of a cell.
cell_dist :: proc(pos: rl.Vector3, cx, cz: i32) -> f32 {
	dx := (f32(cx) + 0.5) * CELL - pos.x
	dz := (f32(cz) + 0.5) * CELL - pos.z
	return math.sqrt(dx * dx + dz * dz)
}

nearest_entity_info :: proc(pos: rl.Vector3) -> (dist: f32, state: Entity_State, phantom: bool) {
	dist = 9999.0
	for i in 0 ..< MAX_ENTITIES {
		e := &entities[i]
		if !e.active do continue
		dx := pos.x - e.pos[0]
		dz := pos.z - e.pos[2]
		d := math.sqrt(dx * dx + dz * dz)
		if d < dist {
			dist = d
			state = e.state
			phantom = e.phantom
		}
	}
	return
}

Panel :: struct {
	x, y, w: i32,
	bottom:  i32,
	clipped: bool,
}

panel_begin :: proc(r: rect_i, title: cstring, accent: rl.Color) -> Panel {
	rl.DrawRectangle(r.x, r.y, r.w, r.h, {12, 13, 19, 240})
	rl.DrawRectangle(r.x, r.y, r.w, 21, {22, 24, 34, 255})
	rl.DrawRectangleLines(r.x, r.y, r.w, r.h, {60, 68, 84, 255})
	rl.DrawText(title, r.x + 8, r.y + 6, 10, accent)
	return Panel{x = r.x + 9, y = r.y + 28, w = r.w - 18, bottom = r.y + r.h - 7}
}

panel_text :: proc(p: ^Panel, text: cstring, col: rl.Color) -> bool {
	if p.y + 11 > p.bottom {
		p.clipped = true
		return false
	}
	rl.DrawText(text, p.x, p.y, 10, col)
	p.y += 13
	return true
}

panel_head :: proc(p: ^Panel, text: cstring, col: rl.Color) {
	p.y += 2
	if p.y + 11 > p.bottom {
		p.clipped = true
		return
	}
	rl.DrawText(text, p.x, p.y, 10, col)
	p.y += 13
	rl.DrawRectangle(p.x, p.y - 3, p.w, 1, {48, 54, 68, 255})
}

panel_bar :: proc(p: ^Panel, frac: f32, col: rl.Color) {
	if p.y + 8 > p.bottom {
		p.clipped = true
		return
	}
	w := p.w
	rl.DrawRectangle(p.x, p.y, w, 6, {36, 38, 46, 255})
	fw := i32(clamp(frac, 0, 1) * f32(w))
	if fw > 0 do rl.DrawRectangle(p.x, p.y, fw, 6, col)
	rl.DrawRectangleLines(p.x, p.y, w, 6, {110, 116, 130, 255})
	p.y += 10
}

draw_stat_bar :: proc(x, y, w, h: i32, frac: f32, col: rl.Color) {
	rl.DrawRectangle(x, y, w, h, {40, 40, 48, 255})
	fw := i32(clamp(frac, 0, 1) * f32(w))
	if fw > 0 do rl.DrawRectangle(x, y, fw, h, col)
	rl.DrawRectangleLines(x, y, w, h, {200, 200, 210, 140})
}

// ───────────────────────── main draw ─────────────────────────

devmap_draw :: proc(m: ^Dev_Map, pos: rl.Vector3, yaw: f32) {
	player_level := current_level
	same_floor := player_level == m.view_level
	current_level = m.view_level
	defer current_level = player_level

	swf, shf := f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight())
	sw, sh := i32(swf), i32(shf)
	layout := devmap_layout(m, sw, sh)

	// Textures are streamed before the draw call begins.
	devmap_stream_tiles(m, swf, shf)

	rl.BeginDrawing()
	rl.ClearBackground({12, 12, 16, 255})

	s := m.zoom
	ox, oy := devmap_origin(m, swf, shf)

	x0 := i32(math.floor(-ox / s))
	z0 := i32(math.floor(-oy / s))
	x1 := i32(math.ceil((swf - ox) / s))
	z1 := i32(math.ceil((shf - oy) / s))

	tx0, tx1 := fdiv(x0, TILE_CELLS), fdiv(x1 - 1, TILE_CELLS)
	tz0, tz1 := fdiv(z0, TILE_CELLS), fdiv(z1 - 1, TILE_CELLS)

	coverage: [Biome_Type]i32
	coverage_total: i32

	// Cached raster tiles.
	for tz in tz0 ..= tz1 do for tx in tx0 ..= tx1 {
		key := Tile_Key{m.view_level, tx, tz}
		slot, ok := devmap_tile_slot(m, key)
		if !ok do continue

		for b in Biome_Type {
			coverage[b] += i32(m.counts[slot][b])
			coverage_total += i32(m.counts[slot][b])
		}

		col := slot % ATLAS_COLS
		row := slot / ATLAS_COLS
		dx := ox + f32(tx * TILE_CELLS) * s
		dy := oy + f32(tz * TILE_CELLS) * s
		dw := f32(TILE_CELLS) * s
		rl.DrawTexturePro(
			m.tex,
			{f32(col * TILE_CELLS), f32(row * TILE_CELLS), TILE_CELLS, TILE_CELLS},
			{dx, dy, dw, dw},
			{0, 0},
			0,
			rl.WHITE,
		)
	}

	// Stairs, shafts, pools, pillars and the hidden-loop/glitch overlays all
	// read the cached tile flags. No procedural scans happen while drawing.
	if s >= 6 {
		cache: Flags_Cache
		for cz in z0 ..< z1 {
			cache = {}
			for cx in x0 ..< x1 {
				fl := flags_at(m, &cache, cx, cz)
				if fl == 0 do continue

				px := i32(ox + f32(cx) * s)
				py := i32(oy + f32(cz) * s)
				pw := i32(s)
				ph := i32(s)

				if fl & FLAG_STAIR != 0 {
					d := u8((fl >> FLAG_STAIR_DIR_SHIFT) & 3)
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
					rl.DrawCircleV({cx_c, cy_c}, max(3, f32(pw) * 0.12), rl.YELLOW)
					rl.DrawLineEx(
						{cx_c, cy_c},
						{cx_c + arx * f32(pw) * 0.4, cy_c + ary * f32(ph) * 0.4},
						2,
						rl.YELLOW,
					)
				} else if fl & FLAG_HOLE != 0 {
					rl.DrawRectangle(px + pw / 4, py + ph / 4, pw / 2, ph / 2, rl.BLACK)
					rl.DrawRectangleLines(
						px + pw / 4,
						py + ph / 4,
						pw / 2,
						ph / 2,
						{200, 80, 80, 255},
					)
				} else if fl & FLAG_POOL != 0 {
					rl.DrawRectangle(px, py, pw, ph, {50, 160, 190, 160})
				} else if fl & FLAG_PILLAR != 0 {
					rl.DrawRectangle(
						px + pw / 3,
						py + ph / 3,
						max(pw / 3, 1),
						max(ph / 3, 1),
						{20, 20, 25, 255},
					)
				}

				if fl & FLAG_LOOP != 0 && !loop_is_solved(cx, cz) {
					rl.DrawCircleV(
						{f32(px) + f32(pw) / 2, f32(py) + f32(ph) / 2},
						max(3, f32(pw) * 0.3),
						{100, 220, 255, 220},
					)
				}
				if fl & FLAG_GLITCH != 0 {
					rl.DrawRectangleLines(px, py, pw, ph, {255, 80, 255, 255})
					rl.DrawText("G", px + 2, py + 1, 10, {255, 150, 255, 255})
				}
			}
		}
	}

	if task_exit_active && same_floor {
		ex := ox + (f32(task_exit_cell[0]) + 0.5) * s
		ey := oy + (f32(task_exit_cell[1]) + 0.5) * s
		rl.DrawCircleV({ex, ey}, 7, {80, 255, 130, 255})
		rl.DrawText("TASK EXIT", i32(ex) + 9, i32(ey) - 5, 10, {120, 255, 170, 255})
	}
	if same_floor {
		for i in 0 ..< exit_cell_count {
			ex := ox + (f32(exit_cells[i][0]) + 0.5) * s
			ey := oy + (f32(exit_cells[i][1]) + 0.5) * s
			rl.DrawCircleV({ex, ey}, 7, {80, 255, 130, 255})
			rl.DrawText("LEVEL EXIT", i32(ex) + 9, i32(ey) - 5, 10, {120, 255, 170, 255})
		}
	}

	// Live entities and pickups. This is a cheat map; show them all. They are
	// only meaningful on the floor the player is actually standing on.
	if same_floor {
		for i in 0 ..< MAX_ENTITIES {
			e := &entities[i]
			if !e.active do continue
			ex := ox + e.pos[0] / CELL * s
			ey := oy + e.pos[2] / CELL * s
			col := rl.Color{220, 80, 80, 255}
			if e.phantom {
				col = {190, 130, 255, 255}
			} else if e.state == .Chase {
				col = {255, 30, 30, 255}
			} else if e.state == .Investigate {
				col = {255, 170, 80, 255}
			}
			rl.DrawCircleV({ex, ey}, 5, col)
			rl.DrawCircleLines(i32(ex), i32(ey), 7, col)
		}
		if key_item.active {
			ex := ox + key_item.pos[0] / CELL * s
			ey := oy + key_item.pos[2] / CELL * s
			rl.DrawCircleV({ex, ey}, 5, {255, 215, 0, 255})
			rl.DrawText("KEY", i32(ex) + 7, i32(ey) - 5, 10, {255, 230, 100, 255})
		}
		for i in 0 ..< MAX_ITEMS {
			it := &items[i]
			if !it.active do continue
			ex := ox + it.pos[0] / CELL * s
			ey := oy + it.pos[2] / CELL * s
			col := rl.Color{235, 235, 245, 255}
			label: cstring = "?"
			switch it.typ {
			case .Battery:
				col = {90, 220, 255, 255}
				label = "B"
			case .Almond_Water:
				col = {235, 235, 245, 255}
				label = "W"
			case .Fuse:
				col = {255, 130, 60, 255}
				label = "F"
			case .Valve:
				col = {220, 200, 70, 255}
				label = "V"
			case .Tape:
				col = {80, 120, 220, 255}
				label = "T"
			case .Phantom_Door:
				col = {80, 255, 130, 255}
				label = "D"
			case .Flashlight:
				col = {180, 180, 190, 255}
				label = "L"
			case .Key:
				col = {255, 215, 0, 255}
				label = "K"
			}
			if it.fake {
				col = {255, 80, 255, 255}
				label = "FAKE"
			}
			rl.DrawCircleV({ex, ey}, 5, col)
			rl.DrawText(label, i32(ex) + 6, i32(ey) - 5, 10, col)
		}
		if walkie_dropped {
			ex := ox + walkie_pos[0] / CELL * s
			ey := oy + walkie_pos[2] / CELL * s
			col := walkie_active ? rl.Color{255, 140, 80, 255} : rl.Color{150, 150, 160, 255}
			rl.DrawCircleV({ex, ey}, 5, col)
			rl.DrawCircleLines(i32(ex), i32(ey), 8, col)
		}
	}

	// Walls, using the same cached flags.
	if s >= 6 {
		t := max(i32(1), i32(math.round(s * 0.18)))
		for cz in z0 ..< z1 {
			y := i32(oy + f32(cz) * s)
			run_k, run_start := 0, x0
			cache: Flags_Cache
			for cx in x0 ..= x1 {
				k := 0
				if cx < x1 {
					k = edge_kind(cx, cz, true, m, &cache)
				}
				if k != run_k {
					if run_k != 0 {
						draw_run(
							true,
							i32(ox + f32(run_start) * s),
							i32(ox + f32(cx) * s),
							y,
							t,
							run_k,
						)
					}
					run_k, run_start = k, cx
				}
			}
		}
		for cx in x0 ..< x1 {
			px := i32(ox + f32(cx) * s)
			run_k, run_start := 0, z0
			cache: Flags_Cache
			for cz in z0 ..= z1 {
				k := 0
				if cz < z1 {
					k = edge_kind(cx, cz, false, m, &cache)
				}
				if k != run_k {
					if run_k != 0 {
						draw_run(
							false,
							i32(oy + f32(run_start) * s),
							i32(oy + f32(cz) * s),
							px,
							t,
							run_k,
						)
					}
					run_k, run_start = k, cz
				}
			}
		}
	}

	// Chunk borders.
	for cx := fdiv(x0, CHUNK_SIZE) * CHUNK_SIZE; cx <= x1; cx += CHUNK_SIZE {
		rl.DrawRectangle(i32(ox + f32(cx) * s), 0, 1, sh, {255, 255, 255, 50})
	}
	for cz := fdiv(z0, CHUNK_SIZE) * CHUNK_SIZE; cz <= z1; cz += CHUNK_SIZE {
		rl.DrawRectangle(0, i32(oy + f32(cz) * s), sw, 1, {255, 255, 255, 50})
	}

	// Hovered cell outline.
	mp := rl.GetMousePosition()
	mouse_over_map :=
		mp.x >= 0 &&
		mp.y >= f32(TOP_BAR_H) &&
		mp.y < f32(sh - layout.legend.h) &&
		!(layout.show_left && point_in_rect(mp, layout.left)) &&
		!(layout.show_right && point_in_rect(mp, layout.right))

	pcx, pcz := pos.x / CELL, pos.z / CELL
	pcell := [2]i32{i32(math.floor(pcx)), i32(math.floor(pcz))}
	hx, hz := pcell.x, pcell.y
	if mouse_over_map {
		hx = i32(math.floor((mp.x - ox) / s))
		hz = i32(math.floor((mp.y - oy) / s))
		hp := i32(ox + f32(hx) * s)
		hpy := i32(oy + f32(hz) * s)
		rl.DrawRectangleLines(hp, hpy, i32(s), i32(s), {255, 255, 255, 150})
	}

	// Player.
	pc := rl.Vector2{ox + pos.x / CELL * s, oy + pos.z / CELL * s}
	pcol := rl.RED if same_floor else rl.Color{160, 160, 160, 255}
	rl.DrawCircleV(pc, 5, pcol)
	rl.DrawLineEx(pc, pc + {math.sin(yaw), math.cos(yaw)} * 18, 2, pcol)

	// ── bottom legend ──
	if layout.legend.h > 0 {
		rl.DrawRectangle(0, layout.legend.y, sw, layout.legend.h, {10, 11, 16, 235})
		rl.DrawRectangle(0, layout.legend.y, sw, 1, {48, 54, 68, 255})
		lx: i32 = 10
		ly := layout.legend.y + 5
		for it in LEGEND_ITEMS {
			w := legend_item_width(it)
			if lx + w > sw - 10 && lx > 10 {
				lx = 10
				ly += 13
			}
			rl.DrawRectangle(lx, ly + 2, 8, 8, it.col)
			rl.DrawText(it.label, lx + 12, ly, 10, {205, 210, 220, 255})
			lx += w
		}
	}

	// ── left panel: cell inspector + coverage + controls ──
	if layout.show_left && layout.left.h > 80 {
		p := panel_begin(layout.left, "CELL INSPECTOR", {140, 200, 255, 255})

		panel_text(&p, fmt.ctprintf("cell %d, %d   chunk %d, %d", pcell.x, pcell.y, fdiv(pcell.x, CHUNK_SIZE), fdiv(pcell.y, CHUNK_SIZE)), rl.WHITE)
		view_col := same_floor ? rl.Color{120, 255, 170, 255} : rl.Color{255, 210, 110, 255}
		panel_text(&p, fmt.ctprintf("view L%02d  %s%s", m.view_level, LEVELS[m.view_level].name, "  (you)" if same_floor else ""), view_col)
		if !same_floor {
			panel_text(&p, fmt.ctprintf("you are on L%02d  %s", player_level, LEVELS[player_level].name), {170, 170, 180, 255})
		}

		hb := biome_at(hx, hz)
		hl := floor_level(hx, hz)
		panel_text(&p, fmt.ctprintf("biome %v   floor L%d (%.2fm)", hb, hl, floor_h(hx, hz)), rl.WHITE)
		panel_text(&p, fmt.ctprintf("enclosure %d   ceiling %.2fm", cell_enclosure(hx, hz), ceil_h(hx, hz)), {200, 205, 215, 255})
		lp := light_power(hx, hz)
		panel_text(&p, fmt.ctprintf("light %.2f %s   in_light %s", lp, "ON" if lp > 0 else "off", "yes" if in_light(hx, hz) else "no"), lp > 0 ? rl.Color{255, 240, 190, 255} : rl.Color{130, 130, 140, 255})

		feat_col := rl.Color{140, 230, 255, 255}
		featured := false
		if stair_at(hx, hz) {
			dirs := [4]string{"N", "S", "E", "W"}
			dir_name := dirs[stair_dir_at(hx, hz) & 3]
			panel_text(&p, fmt.ctprintf("STAIR up to L%02d (dir %s)", (m.view_level + 1) %% NUM_LEVELS, dir_name), rl.YELLOW)
			featured = true
		} else if hole_at(hx, hz) {
			panel_text(&p, fmt.ctprintf("SHAFT down to L%02d", ((m.view_level - 1) %% NUM_LEVELS + NUM_LEVELS) %% NUM_LEVELS), {240, 120, 120, 255})
			featured = true
		} else if pillar_at(hx, hz) {
			panel_text(&p, "PILLAR (solid)", {180, 180, 190, 255})
			featured = true
		} else if pool_at(hx, hz) {
			panel_text(&p, "POOL (shallow water)", {110, 210, 235, 255})
			featured = true
		}
		if is_loop_cell(hx, hz) {
			panel_text(&p, loop_is_solved(hx, hz) ? "LOOP ROOM (solved)" : "LOOP ROOM (unsolved - stare at beacon)", feat_col)
			featured = true
		}
		if is_glitch_cell(hx, hz) {
			panel_text(&p, "GLITCH WALL (E: no-clip down)", feat_col)
			featured = true
		}
		if exit_at(hx, hz) {
			panel_text(&p, "FINAL LEVEL EXIT (needs Key)", {120, 255, 170, 255})
			featured = true
		}
		if task_exit_active && same_floor && hx == task_exit_cell[0] && hz == task_exit_cell[1] {
			panel_text(&p, "TASK EXIT DOOR (E: descend)", {120, 255, 170, 255})
			featured = true
		}
		if !featured {
			panel_text(&p, "no special features", {130, 135, 145, 255})
		}

		panel_head(&p, "BIOME COVERAGE (visible)", {120, 140, 165, 255})
		cov_y := p.y
		col_w := p.w / 2
		for b, i in Biome_Type {
			pct: f32 = 0
			if coverage_total > 0 do pct = f32(coverage[b]) * 100 / f32(coverage_total)
			cx := p.x + i32(i % 2) * col_w
			cy := cov_y + i32(i / 2) * 13
			if cy + 11 > p.bottom do break
			rl.DrawRectangle(cx, cy + 2, 9, 9, MAP_COLORS[b])
			rl.DrawText(fmt.ctprintf("%s %.1f%%", biome_short(b), pct), cx + 13, cy, 10, {205, 210, 220, 255})
		}
		p.y = cov_y + i32((BIOME_COUNT + 1) / 2) * 13

		panel_head(&p, "MAP CONTROLS", {120, 140, 165, 255})
		panel_text(&p, "F5 close    wheel zoom", {175, 180, 190, 255})
		panel_text(&p, "RMB drag pan    C recentre", {175, 180, 190, 255})
		panel_text(&p, "LMB teleport    Tab panels", {175, 180, 190, 255})
		panel_text(&p, "[ ] PgUp/PgDn floor    ENTER go", {175, 180, 190, 255})
		panel_text(&p, "T finish task    K give key", {175, 180, 190, 255})
		if p.clipped {
			rl.DrawText("…", p.x, p.bottom - 10, 10, {150, 150, 160, 255})
		}
	}

	// ── right panel: live run status ──
	if layout.show_right && layout.right.h > 80 {
		p := panel_begin(layout.right, "LIVE STATUS (dev)", {255, 210, 100, 255})

		panel_text(&p, fmt.ctprintf("mode %s   state %v", mode_name(current_game_mode), current_state), rl.WHITE)
		panel_text(&p, fmt.ctprintf("player L%02d  %s", player_level, LEVELS[player_level].name), rl.WHITE)
		panel_text(&p, fmt.ctprintf("pos %.2f, %.2f   cell %d, %d", pos.x, pos.z, pcell.x, pcell.y), {190, 195, 205, 255})
		lit := in_light(pcell.x, pcell.y)
		panel_text(&p, fmt.ctprintf("room %s   torch %s", "LIT" if lit else "DARK", "ON" if flashlight_on else "OFF"), lit ? rl.Color{120, 240, 160, 255} : rl.Color{255, 170, 120, 255})

		panel_head(&p, "VITALS", {120, 140, 165, 255})
		panel_text(&p, fmt.ctprintf("sanity %d / %d", i32(sanity), i32(SANITY_MAX)), rl.WHITE)
		panel_bar(&p, sanity / SANITY_MAX, {200, 70, 70, 255})
		panel_text(&p, fmt.ctprintf("battery %d%%   drain x%.1f", i32(flashlight_battery), torch_drain_mult), rl.WHITE)
		panel_bar(&p, flashlight_battery / flashlight_max_battery, {90, 220, 255, 255})
		if sanity_is_low() {
			panel_text(&p, "STATE: LOW SANITY (hallucinating)", {255, 120, 255, 255})
		} else {
			panel_text(&p, "STATE: stable", {150, 190, 170, 255})
		}

		panel_head(&p, "OBJECTIVE (your floor)", {120, 140, 165, 255})
		if current_objective.kind != .None {
			obj_col := current_objective.done ? rl.Color{120, 255, 170, 255} : rl.Color{255, 220, 130, 255}
			panel_text(&p, objective_hud_text(), obj_col)
			if current_objective.done && task_exit_active {
				d := cell_dist(pos, task_exit_cell[0], task_exit_cell[1])
				panel_text(&p, fmt.ctprintf("task exit %.1f m at %d, %d", d, task_exit_cell[0], task_exit_cell[1]), {120, 255, 170, 255})
			} else if !current_objective.done {
				id: f32 = 9999.0
				otyp, ook := objective_item_type(current_objective.kind)
				if ook {
					for i in 0 ..< MAX_ITEMS {
						it := &items[i]
						if !it.active || it.fake || it.typ != otyp do continue
						dx := it.pos[0] - pos.x
						dz := it.pos[2] - pos.z
						d := math.sqrt(dx * dx + dz * dz)
						if d < id do id = d
					}
				}
				if id < 9999.0 {
					panel_text(&p, fmt.ctprintf("nearest task item %.1f m", id), {255, 220, 130, 255})
				} else {
					panel_text(&p, "nearest task item: none spawned", {200, 140, 120, 255})
				}
			}
		} else {
			panel_text(&p, "none on this floor", {150, 150, 160, 255})
		}

		panel_head(&p, "INVENTORY", {120, 140, 165, 255})
		if has_key {
			panel_text(&p, "key: CARRIED", {255, 220, 90, 255})
		} else if key_item.active && same_floor {
			panel_text(&p, fmt.ctprintf("key: %.1f m at %d, %d", cell_dist(pos, i32(key_item.pos[0] / CELL), i32(key_item.pos[2] / CELL)), i32(key_item.pos[0] / CELL), i32(key_item.pos[2] / CELL)), {255, 220, 90, 255})
		} else if key_item.active {
			panel_text(&p, "key: spawned on your floor (not viewed)", {200, 180, 110, 255})
		} else {
			panel_text(&p, "key: none (spawns from floor 5)", {150, 150, 160, 255})
		}
		if walkie_active {
			panel_text(&p, fmt.ctprintf("walkie: STATIC %.1fs at %.1f m", walkie_timer, cell_dist(pos, i32(walkie_pos[0] / CELL), i32(walkie_pos[2] / CELL))), {255, 160, 120, 255})
		} else if walkie_dropped {
			panel_text(&p, fmt.ctprintf("walkie: dropped %.1f m (walk back)", cell_dist(pos, i32(walkie_pos[0] / CELL), i32(walkie_pos[2] / CELL))), {200, 170, 100, 255})
		} else if has_walkie {
			panel_text(&p, "walkie: carried", {150, 190, 210, 255})
		} else {
			panel_text(&p, "walkie: none", {150, 150, 160, 255})
		}

		panel_head(&p, "THREATS", {120, 140, 165, 255})
		real_n, phant_n, chase_n, invest_n: i32
		for i in 0 ..< MAX_ENTITIES {
			e := &entities[i]
			if !e.active do continue
			if e.phantom {
				phant_n += 1
			} else {
				real_n += 1
				if e.state == .Chase {
					chase_n += 1
				} else if e.state == .Investigate {
					invest_n += 1
				}
			}
		}
		panel_text(&p, fmt.ctprintf("entities %d real + %d phantom", real_n, phant_n), chase_n > 0 ? rl.Color{255, 80, 80, 255} : rl.WHITE)
		panel_text(&p, fmt.ctprintf("chasing %d   investigating %d", chase_n, invest_n), rl.WHITE)
		ed, es, ep := nearest_entity_info(pos)
		if ed < 9999.0 {
			panel_text(&p, fmt.ctprintf("nearest %.1f m (%s%s)", ed, entity_state_name(es), ", phantom" if ep else ""), es == .Chase ? rl.Color{255, 120, 120, 255} : rl.WHITE)
		} else {
			panel_text(&p, "nearest: none", {150, 150, 160, 255})
		}

		panel_head(&p, "SYSTEMS", {120, 140, 165, 255})
		if loop_active {
			panel_text(&p, fmt.ctprintf("loop ACTIVE at %d,%d  %.1fs", loop_cell[0], loop_cell[1], loop_timer), {140, 230, 255, 255})
			panel_text(&p, fmt.ctprintf("  gaze %d%%", i32(loop_gaze / LOOP_GAZE_TIME * 100)), {190, 240, 255, 255})
		} else {
			panel_text(&p, fmt.ctprintf("loop idle   solved %d", loop_solved_count), {150, 150, 160, 255})
		}
		panel_text(&p, fmt.ctprintf("grace sanity %.1fs  entity %.1fs", max(sanity_grace, 0), max(entity_grace, 0)), {170, 175, 185, 255})
		panel_text(&p, fmt.ctprintf("final-level exits %d", exit_cell_count), {170, 175, 185, 255})
		if !same_floor {
			panel_text(&p, fmt.ctprintf("markers hidden: viewing L%02d", m.view_level), {255, 200, 120, 255})
		}
		if p.clipped {
			rl.DrawText("…", p.x, p.bottom - 10, 10, {150, 150, 160, 255})
		}
	}

	// ── top bar ──
	rl.DrawRectangle(0, 0, sw, TOP_BAR_H, {9, 10, 15, 250})
	rl.DrawRectangle(0, TOP_BAR_H - 1, sw, 1, {48, 54, 68, 255})
	rl.DrawText("DEV MAP", 10, 7, 12, {255, 215, 90, 255})
	rl.DrawText(fmt.ctprintf("L%02d  %s", m.view_level, LEVELS[m.view_level].name), 78, 9, 10, rl.WHITE)
	if same_floor {
		rl.DrawText("YOU ARE HERE", 78 + rl.MeasureText(fmt.ctprintf("L%02d  %s", m.view_level, LEVELS[m.view_level].name), 10) + 12, 9, 10, {120, 255, 170, 255})
	} else {
		rl.DrawText(fmt.ctprintf("you: L%02d  %s", player_level, LEVELS[player_level].name), 78 + rl.MeasureText(fmt.ctprintf("L%02d  %s", m.view_level, LEVELS[m.view_level].name), 10) + 12, 9, 10, {255, 200, 120, 255})
	}

	right_txt := fmt.ctprintf("%dx zoom   %d fps   Tab panels", i32(m.zoom), rl.GetFPS())
	rl.DrawText(right_txt, sw - rl.MeasureText(right_txt, 10) - 10, 9, 10, {170, 180, 195, 255})

	rl.EndDrawing()
}
