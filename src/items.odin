package main

import "core:math"
import rl "vendor:raylib"

Item_Type :: enum {
	Key,
	Flashlight,
	Battery,
	Almond_Water,
	Fuse,
	Valve,
	Tape,
	Phantom_Door,
}

Item :: struct {
	pos:    [3]f32,
	typ:    Item_Type,
	active: bool,
	bob_t:  f32,
	fake:   bool, // Phase 3.1: hallucinated pickup
}

key_item: Item
has_key: bool = false
key_spawned: bool = false

MAX_ITEMS :: 16
items: [MAX_ITEMS]Item
item_count: i32 = 0

// Pickups are reset on every level transition (the old floor is gone).
clear_pickups :: proc() {
	item_count = 0
	for i in 0 ..< MAX_ITEMS {
		items[i] = Item{}
	}
}

init_items :: proc() {
	key_item = Item{}
	has_key = false
	key_spawned = false
	clear_pickups()
}

item_rng_state: u32 = 0xA5A5F00D

item_rng :: proc() -> f32 {
	x := item_rng_state
	x ~= x << 13
	x ~= x >> 17
	x ~= x << 5
	item_rng_state = x
	return f32(x >> 8) / 16777216.0
}

// Place a pickup on solid floor 4-12 cells from the player.
spawn_random_item :: proc(p: ^Player, typ: Item_Type, fake: bool) -> bool {
	if item_count >= MAX_ITEMS do return false
	for _ in 0 ..< 24 {
		angle := item_rng() * 2 * math.PI
		radius := 4.0 + item_rng() * 8.0
		wx := p.cell_x + i32(math.round(math.cos(angle) * radius))
		wz := p.cell_z + i32(math.round(math.sin(angle) * radius))
		if hole_at(wx, wz) || stair_at(wx, wz) || pillar_at(wx, wz) || exit_at(wx, wz) do continue

		for i in 0 ..< MAX_ITEMS {
			if items[i].active do continue
			items[i] = Item {
				pos    = {f32(wx) * CELL + CELL / 2, floor_h(wx, wz) + 0.6, f32(wz) * CELL + CELL / 2},
				typ    = typ,
				active = true,
				bob_t  = item_rng() * 6.28,
				fake   = fake,
			}
			item_count += 1
			return true
		}
	}
	return false
}

// One battery per level keeps the flashlight manageable without making it
// free. The player still has to spot and detour to it.
spawn_level_pickups :: proc(p: ^Player) {
	spawn_random_item(p, .Battery, false)
}

spawn_key :: proc(wx, wz: i32, y: f32) {
	key_item.pos = {f32(wx) * CELL + CELL / 2, y + 0.6, f32(wz) * CELL + CELL / 2}
	key_item.typ = .Key
	key_item.active = true
	key_item.bob_t = 0
	key_spawned = true
}

update_items :: proc(p: ^Player, dt: f32) {
	key_item.bob_t += dt * 4.0

	if key_item.active {
		dx := key_item.pos[0] - p.cam.position.x
		dz := key_item.pos[2] - p.cam.position.z
		dy := key_item.pos[1] - p.cam.position.y
		dist := math.sqrt(dx * dx + dz * dz)
		if dist < 1.6 && abs(dy) < 2.2 {
			key_item.active = false
			has_key = true
			sanity_heal(15.0)
		}
	}

	for i in 0 ..< MAX_ITEMS {
		it := &items[i]
		if !it.active do continue
		it.bob_t += dt * 3.0

		dx := it.pos[0] - p.cam.position.x
		dz := it.pos[2] - p.cam.position.z
		dy := it.pos[1] - p.cam.position.y
		if math.sqrt(dx * dx + dz * dz) < 1.5 && abs(dy) < 2.2 {
			if it.fake {
				// Phase 3.1: hallucinated pickups sting when touched.
				if it.typ == .Phantom_Door {
					sanity_damage(24.0)
					set_event("THE DOOR WAS NEVER THERE", 3.0)
				} else {
					sanity_damage(16.0)
					set_event("IT WASN'T REAL. YOUR MIND IS SLIPPING.", 3.0)
				}
				it.active = false
				item_count -= 1
				continue
			}
			switch it.typ {
			case .Battery:
				flashlight_recharge(35.0)
				objective_collect(.Battery)
			case .Almond_Water:
				sanity_heal(20.0)
			case .Fuse, .Valve, .Tape:
				objective_collect(it.typ)
			case .Phantom_Door:
				// Unreachable for real items, kept exhaustive.
			case .Flashlight, .Key:
			// Nothing extra.
			}
			it.active = false
			item_count -= 1
		}
	}
}

// Phase 3.1: at low sanity the level starts lying to you. Fake pickups and
// phantom exit doors appear nearby; touching one costs sanity.
hallucination_timer: f32 = 0

update_hallucinations :: proc(p: ^Player, dt: f32) {
	if !sanity_is_low() {
		hallucination_timer = 0
		return
	}
	hallucination_timer += dt
	if hallucination_timer < 9.0 || item_count >= MAX_ITEMS do return
	hallucination_timer = 0
	typ := Item_Type.Almond_Water
	if item_rng() < 0.4 do typ = .Phantom_Door
	if spawn_random_item(p, typ, true) {
		set_event("DID YOU SEE SOMETHING?", 1.8)
	}
}

draw_item :: proc(it: ^Item) {
	if !it.active do return
	y := it.pos[1] + math.sin(it.bob_t) * 0.12

	// Phantom exit doors get a full frame rather than a pickup cube.
	if it.typ == .Phantom_Door {
		flicker := 0.45 + 0.55 * math.sin(it.bob_t * 7.0)
		col := rl.Color{70, 220, 120, u8(80 + 120 * flicker)}
		frame := rl.Color{120, 255, 160, u8(140 + 100 * flicker)}
		base := it.pos[1] - 0.6
		rl.DrawCube(rl.Vector3{it.pos[0], base + 1.1, it.pos[2]}, 1.25, 2.1, 0.07, col)
		rl.DrawCubeWires(rl.Vector3{it.pos[0], base + 1.1, it.pos[2]}, 1.3, 2.15, 0.1, frame)
		return
	}

	size_x, size_y, size_z: f32 = 0.35, 0.35, 0.35
	fill := rl.Color{255, 215, 0, 255} // key gold
	glow := rl.Color{255, 215, 0, 180}
	switch it.typ {
	case .Battery:
		size_x, size_y, size_z = 0.22, 0.5, 0.22
		fill = rl.Color{90, 220, 255, 255}
		glow = rl.Color{90, 220, 255, 180}
	case .Almond_Water:
		size_x, size_y, size_z = 0.25, 0.45, 0.25
		fill = rl.Color{235, 235, 245, 255}
		glow = rl.Color{235, 235, 245, 180}
	case .Flashlight:
		size_x, size_y, size_z = 0.2, 0.2, 0.55
		fill = rl.Color{180, 180, 190, 255}
		glow = rl.Color{255, 240, 180, 180}
	case .Fuse:
		size_x, size_y, size_z = 0.3, 0.45, 0.3
		fill = rl.Color{255, 130, 60, 255}
		glow = rl.Color{255, 180, 80, 200}
	case .Valve:
		size_x, size_y, size_z = 0.5, 0.16, 0.5
		fill = rl.Color{220, 200, 70, 255}
		glow = rl.Color{255, 240, 120, 200}
	case .Tape:
		size_x, size_y, size_z = 0.42, 0.26, 0.26
		fill = rl.Color{80, 120, 220, 255}
		glow = rl.Color{120, 170, 255, 200}
	case .Phantom_Door, .Key:
	// Handled above / default gold key.
	}

	if it.fake {
		fill.a = 150
		glow.a = 110
	}

	rl.DrawCube(rl.Vector3{it.pos[0], y, it.pos[2]}, size_x, size_y, size_z, fill)
	rl.DrawCubeWires(rl.Vector3{it.pos[0], y, it.pos[2]}, size_x, size_y, size_z, rl.Color{255, 255, 255, 255})
	// glow cross
	rl.DrawLine3D(
		rl.Vector3{it.pos[0] - 0.5, y, it.pos[2]},
		rl.Vector3{it.pos[0] + 0.5, y, it.pos[2]},
		glow,
	)
	rl.DrawLine3D(
		rl.Vector3{it.pos[0], y - 0.5, it.pos[2]},
		rl.Vector3{it.pos[0], y + 0.5, it.pos[2]},
		glow,
	)
}
