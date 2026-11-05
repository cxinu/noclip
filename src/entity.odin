package main

import "core:math"
import rl "vendor:raylib"

Entity_State :: enum {
	Idle,
	Patrol,
	Chase,
	Investigate, // walking toward the dropped walkie-talkie's static
}

Entity :: struct {
	pos:     [3]f32,
	target:  [3]f32,
	state:   Entity_State,
	timer:   f32,
	active:  bool,
	spawn_t: f32,
	phantom: bool, // hallucination: wanders, never harms, vanishes when sane
}

MAX_ENTITIES :: 10
entities: [MAX_ENTITIES]Entity
entity_count: i32 = 0
entity_spawn_timer: f32 = 0
phantom_spawn_timer: f32 = 0

init_entities :: proc() {
	entity_count = 0
	entity_spawn_timer = 0
	phantom_spawn_timer = 0
	for i in 0 ..< MAX_ENTITIES {
		entities[i] = Entity{}
	}
}

// Small xorshift state. A stateful RNG matters: repeated calls in the same
// frame must not return the same value (spawn offsets, patrol targets, ...).
entity_rng_state: u32 = 0x9E3779B9

entity_rng :: proc() -> f32 {
	x := entity_rng_state
	x ~= x << 13
	x ~= x >> 17
	x ~= x << 5
	entity_rng_state = x
	return f32(x >> 8) / 16777216.0
}

spawn_entity :: proc(wx, wz: i32, y: f32, phantom: bool) {
	if entity_count >= MAX_ENTITIES do return
	for i in 0 ..< MAX_ENTITIES {
		if !entities[i].active {
			entities[i] = Entity{
				pos = {f32(wx) * CELL + CELL / 2, y, f32(wz) * CELL + CELL / 2},
				target = {f32(wx) * CELL + CELL / 2, y, f32(wz) * CELL + CELL / 2},
				state = .Idle,
				timer = 0,
				active = true,
				spawn_t = run_time,
				phantom = phantom,
			}
			entity_count += 1
			return
		}
	}
}

despawn_entity :: proc(i: i32) {
	entities[i].active = false
	entity_count -= 1
}

update_entities :: proc(p: ^Player, dt: f32) {
	// Spawn check. No spawns during the initial grace window.
	entity_spawn_timer += dt
	phantom_spawn_timer += dt
	if entity_grace > 0 {
		entity_spawn_timer = 0
	} else if entity_spawn_timer > 1.0 &&
	   entity_rng() < game_settings.entity_spawn_chance * dt &&
	   entity_count < MAX_ENTITIES {
		// Spawn on a ring 8-14 cells away so nothing appears on top of the
		// player. Sample a few points until one lands on solid floor.
		px := i32(math.floor(p.cam.position.x / CELL))
		pz := i32(math.floor(p.cam.position.z / CELL))
		for _ in 0 ..< 8 {
			angle := entity_rng() * 2 * math.PI
			radius := 8.0 + entity_rng() * 6.0
			wx := px + i32(math.round(math.cos(angle) * radius))
			wz := pz + i32(math.round(math.sin(angle) * radius))
			if hole_at(wx, wz) || stair_at(wx, wz) || pillar_at(wx, wz) do continue
			base := floor_h(wx, wz)
			spawn_entity(wx, wz, base + 0.05, false)
			break
		}
		entity_spawn_timer = 0
	}

	// Phase 3.2: phantoms only exist while sanity is low.
	if sanity_is_low() {
		if phantom_spawn_timer > 7.0 && entity_count < MAX_ENTITIES {
			phantom_spawn_timer = 0
			px := i32(math.floor(p.cam.position.x / CELL))
			pz := i32(math.floor(p.cam.position.z / CELL))
			for _ in 0 ..< 8 {
				angle := entity_rng() * 2 * math.PI
				radius := 5.0 + entity_rng() * 8.0
				wx := px + i32(math.round(math.cos(angle) * radius))
				wz := pz + i32(math.round(math.sin(angle) * radius))
				if hole_at(wx, wz) || stair_at(wx, wz) || pillar_at(wx, wz) do continue
				spawn_entity(wx, wz, floor_h(wx, wz) + 0.05, true)
				break
			}
		}
	} else {
		phantom_spawn_timer = 0
	}

	hidden := p.hiding && !in_light(p.cell_x, p.cell_z)

	for i in 0 ..< MAX_ENTITIES {
		e := &entities[i]
		if !e.active do continue

		// Hallucinations evaporate when the player stabilises.
		if e.phantom && !sanity_is_low() {
			despawn_entity(i32(i))
			continue
		}

		dx := p.cam.position.x - e.pos[0]
		dz := p.cam.position.z - e.pos[2]
		dist := math.sqrt(dx * dx + dz * dz)

		// Phase 1.3: the walkie-talkie pulls real entities away from the player.
		if !e.phantom && walkie_active && dist > 3.0 {
			wdx := walkie_pos[0] - e.pos[0]
			wdz := walkie_pos[2] - e.pos[2]
			wd := math.sqrt(wdx * wdx + wdz * wdz)
			if wd < WALKIE_RANGE && e.state != .Investigate {
				e.state = .Investigate
				e.timer = 0
			}
		}

		// --- Detection ---
		// Base detection range; sprinting increases it (sound footprint).
		sprinting := rl.IsKeyDown(.LEFT_SHIFT) && rl.IsKeyDown(.W) && !p.hiding
		detect_range: f32 = 10.0
		if sprinting {
			detect_range = 16.0
		}
		// Phase 1.4: crouching in darkness breaks line of sight.
		if hidden {
			detect_range = 2.5
		}
		// Low sanity makes entities more aggressive / easier to detect player.
		if sanity < 30.0 {
			detect_range *= 1.5
		}

		can_see := false
		if !e.phantom && dist < detect_range {
			if sprinting {
				// Sound footprint: loud footsteps carry through walls.
				can_see = true
			} else {
				// Ray from entity to player, blocked by walls?
				// light_blocked returns true if blocked.
				can_see = !light_blocked(
					e.pos[0],
					e.pos[1] + 1.2,
					e.pos[2],
					p.cam.position.x,
					p.cam.position.y,
					p.cam.position.z,
				)
			}
		}

		// A chase breaks after the player stays hidden in a dark corner.
		if e.state == .Chase && hidden && dist > 2.0 {
			e.timer += dt
			if e.timer > 1.6 {
				e.state = .Idle
				e.timer = 0
				e.target = e.pos
				set_event("IT LOST YOU IN THE DARK")
			}
		}

		// --- State machine ---
		switch e.state {
		case .Idle:
			e.timer += dt
			if e.phantom && dist < 3.0 {
				despawn_entity(i32(i))
				continue
			}
			if e.timer > 2.5 + entity_rng() * 2.0 {
				e.state = .Patrol
				e.timer = 0
				// Pick a random patrol target nearby
				rx := e.pos[0] + (entity_rng() * 8 - 4)
				rz := e.pos[2] + (entity_rng() * 8 - 4)
				e.target = {rx, e.pos[1], rz}
			}

		case .Patrol:
			e.timer += dt
			if e.phantom && dist < 3.0 {
				despawn_entity(i32(i))
				continue
			}
			if !e.phantom && (can_see || dist < 5.0) {
				e.state = .Chase
				e.timer = 0
			} else if e.timer > 6.0 {
				e.state = .Idle
				e.timer = 0
			}
			// Move slowly toward patrol target
			move_toward(e, e.target, (e.phantom ? 0.7 : 1.2) * dt)

		case .Investigate:
			e.timer += dt
			if !walkie_active || e.timer > 12.0 {
				e.state = .Idle
				e.timer = 0
			} else {
				e.target = {walkie_pos[0], e.pos[1], walkie_pos[2]}
				move_toward(e, e.target, game_settings.entity_speed * 0.9 * dt)
				wdx := walkie_pos[0] - e.pos[0]
				wdz := walkie_pos[2] - e.pos[2]
				if wdx * wdx + wdz * wdz < 2.25 {
					e.state = .Idle
					e.timer = 0
				}
			}

		case .Chase:
			if can_see {
				e.target = {p.cam.position.x, e.pos[1], p.cam.position.z}
			}
			// Chase speed from game mode
			move_toward(e, e.target, game_settings.entity_speed * dt)
			if dist < 1.1 {
				sanity_damage(15.0 * dt)
				// Knockback away from entity (guard against zero distance).
				if dist > 0.001 {
					p.cam.position.x -= dx / dist * 0.3
					p.cam.position.z -= dz / dist * 0.3
				}
			}
			// Give up chase if player gets far away
			if dist > 30.0 {
				e.state = .Idle
				e.timer = 0
			}
		}

		// Phantoms dissipate on their own.
		if e.phantom && run_time - e.spawn_t > 14.0 {
			despawn_entity(i32(i))
			continue
		}

		// Keep entity on ground
		gy := ground_at(e.pos[0], e.pos[2])
		if e.pos[1] > gy + 0.5 {
			e.pos[1] -= 12.0 * dt
		} else if e.pos[1] < gy - 0.1 {
			e.pos[1] = gy + 0.05
		}

		// Despawn if too far
		if dist > 70.0 {
			despawn_entity(i32(i))
		}
	}
}

nearest_entity_dist :: proc(p: ^Player) -> f32 {
	best: f32 = 999.0
	for i in 0 ..< MAX_ENTITIES {
		e := &entities[i]
		if !e.active || e.phantom do continue
		dx := p.cam.position.x - e.pos[0]
		dz := p.cam.position.z - e.pos[2]
		d := math.sqrt(dx * dx + dz * dz)
		if d < best do best = d
	}
	return best
}

move_toward :: proc(e: ^Entity, target: [3]f32, step: f32) {
	dx := target[0] - e.pos[0]
	dz := target[2] - e.pos[2]
	d := math.sqrt(dx * dx + dz * dz)
	if d > 0.05 {
		e.pos[0] += dx / d * step
		e.pos[2] += dz / d * step
	}
	// Simple wall push-out using existing collision (2D)
	fixed := collide_walls([2]f32{e.pos[0], e.pos[2]}, 0.35)
	e.pos[0] = fixed[0]
	e.pos[2] = fixed[1]
}

draw_entity :: proc(e: ^Entity, cam: rl.Vector3) {
	if !e.active do return
	fill := rl.Color{200, 30, 30, 230}
	wire := rl.Color{255, 80, 80, 255}
	if e.phantom {
		fill = rl.Color{130, 70, 190, 130}
		wire = rl.Color{200, 140, 255, 210}
	}
	rl.DrawCube(rl.Vector3{e.pos[0], e.pos[1] + 0.9, e.pos[2]}, 0.5, 1.8, 0.5, fill)
	rl.DrawCubeWires(rl.Vector3{e.pos[0], e.pos[1] + 0.9, e.pos[2]}, 0.5, 1.8, 0.5, wire)
	// Vision cone line when chasing.
	if e.state == .Chase && !e.phantom {
		rl.DrawLine3D(
			rl.Vector3{e.pos[0], e.pos[1] + 1.2, e.pos[2]},
			cam,
			rl.Color{255, 0, 0, 120},
		)
	}
	// At low sanity the outline is visible even through walls in spirit:
	// a second, larger wire box makes the shape read as an "afterimage".
	if e.phantom {
		rl.DrawCubeWires(
			rl.Vector3{e.pos[0], e.pos[1] + 0.9, e.pos[2]},
			0.65,
			2.0,
			0.65,
			rl.Color{160, 100, 230, 90},
		)
	}
}
