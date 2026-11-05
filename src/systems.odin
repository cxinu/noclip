package main

import "core:math"
import rl "vendor:raylib"

// ─────────────────────────────────────────────────────────────────────────────
// Shared event banner
// ─────────────────────────────────────────────────────────────────────────────
event_msg: cstring = ""
event_t: f32 = 0

set_event :: proc(msg: cstring, duration: f32 = 2.5) {
	event_msg = msg
	event_t = duration
}

update_events :: proc(dt: f32) {
	if event_t > 0 do event_t -= dt
}

// ─────────────────────────────────────────────────────────────────────────────
// Walkie-talkie (Phase 1.3)
// Drop it with Q; the static pulls nearby entities to its position.
// ─────────────────────────────────────────────────────────────────────────────
WALKIE_BROADCAST :: 9.0
WALKIE_RANGE :: 26.0

has_walkie: bool = true
walkie_dropped: bool = false
walkie_active: bool = false
walkie_pos: [3]f32
walkie_timer: f32 = 0

drop_walkie :: proc(p: ^Player) {
	if !has_walkie || walkie_active do return
	has_walkie = false
	walkie_dropped = true
	walkie_active = true
	walkie_timer = WALKIE_BROADCAST
	walkie_pos = {p.cam.position.x, p.feet_y + 0.25, p.cam.position.z}
	set_event("WALKIE DROPPED - THE STATIC IS DRAWING THEM IN", 3.0)
}

update_walkie :: proc(p: ^Player, dt: f32) {
	if walkie_active {
		walkie_timer -= dt
		if walkie_timer <= 0 {
			walkie_active = false
			set_event("THE STATIC FADES")
		}
	}
	if walkie_dropped && !walkie_active {
		dx := walkie_pos[0] - p.cam.position.x
		dz := walkie_pos[2] - p.cam.position.z
		if dx * dx + dz * dz < 2.25 {
			walkie_dropped = false
			has_walkie = true
			set_event("WALKIE-TALKIE RECOVERED")
		}
	}
}

reset_walkie :: proc(give_back: bool) {
	has_walkie = give_back
	walkie_dropped = false
	walkie_active = false
	walkie_timer = 0
}

draw_walkie :: proc() {
	if !walkie_dropped do return
	flicker := 0.55 + 0.45 * math.sin(run_time * 17.0)
	col := rl.Color{70, 70, 78, 255}
	lamp := rl.Color{120, 90, 90, 200}
	if walkie_active {
		col = rl.Color{90, 90, 100, 255}
		lamp = rl.Color{255, u8(60 + 150 * flicker), 60, 255}
	}
	x, y, z := walkie_pos[0], walkie_pos[1], walkie_pos[2]
	rl.DrawCube(rl.Vector3{x, y, z}, 0.26, 0.42, 0.16, col)
	rl.DrawCubeWires(rl.Vector3{x, y, z}, 0.26, 0.42, 0.16, rl.Color{170, 170, 180, 255})
	rl.DrawCube(rl.Vector3{x, y + 0.28, z}, 0.06, 0.12, 0.06, lamp)
	rl.DrawLine3D(
		rl.Vector3{x, y + 0.2, z},
		rl.Vector3{x + 0.16, y + 0.55, z},
		rl.Color{150, 150, 160, 255},
	)
}

// ─────────────────────────────────────────────────────────────────────────────
// Looping rooms (Phase 2.1)
// Enter a marked hallway and reality resets you to where you came from unless
// you hold your gaze on the flickering beacon for two seconds.
// ─────────────────────────────────────────────────────────────────────────────
LOOP_LIMIT :: 6.0
LOOP_GAZE_TIME :: 2.0
LOOP_SOLVED_MAX :: 64

loop_solved: [LOOP_SOLVED_MAX][2]i32
loop_solved_count: i32
loop_active: bool
loop_cell: [2]i32
loop_timer, loop_gaze, loop_cooldown: f32
loop_last_safe: rl.Vector3

reset_loop_state :: proc() {
	loop_solved_count = 0
	loop_active = false
	loop_timer = 0
	loop_gaze = 0
	loop_cooldown = 1.5
}

loop_is_solved :: proc(cx, cz: i32) -> bool {
	for i in 0 ..< loop_solved_count {
		if loop_solved[i][0] == cx && loop_solved[i][1] == cz do return true
	}
	return false
}

loop_mark_solved :: proc(cx, cz: i32) {
	if loop_solved_count >= LOOP_SOLVED_MAX || loop_is_solved(cx, cz) do return
	loop_solved[loop_solved_count] = {cx, cz}
	loop_solved_count += 1
}

is_loop_cell :: proc(cx, cz: i32) -> bool {
	if abs(cx) <= SPAWN_CLEAR + 4 || abs(cz) <= SPAWN_CLEAR + 4 do return false
	h := raw_hash(cx * 31 + current_level * 1009, cz * 17 + 7)
	if h % 97 != 0 do return false
	if hole_at(cx, cz) || stair_at(cx, cz) || pillar_at(cx, cz) || exit_at(cx, cz) do return false
	return floor_level(cx, cz) == 0
}

loop_beacon_pos :: proc(cx, cz: i32) -> rl.Vector3 {
	return {
		f32(cx) * CELL + CELL / 2,
		floor_h(cx, cz) + 2.35,
		f32(cz) * CELL + CELL / 2,
	}
}

update_loop_room :: proc(p: ^Player, dt: f32) {
	if loop_cooldown > 0 do loop_cooldown -= dt

	in_cell := is_loop_cell(p.cell_x, p.cell_z)
	if !loop_active && !in_cell {
		loop_last_safe = p.cam.position
	}

	if !loop_active {
		if in_cell && loop_cooldown <= 0 && !loop_is_solved(p.cell_x, p.cell_z) {
			loop_active = true
			loop_cell = {p.cell_x, p.cell_z}
			loop_timer = 0
			loop_gaze = 0
			set_event("THE HALLWAY REPEATS. STARE AT THE LIGHT.", 3.0)
		}
		return
	}

	// Leaving the trigger cell releases the loop.
	if p.cell_x != loop_cell[0] || p.cell_z != loop_cell[1] {
		loop_active = false
		loop_gaze = 0
		return
	}

	loop_timer += dt
	beacon := loop_beacon_pos(loop_cell[0], loop_cell[1])
	to := beacon - p.cam.position
	to_len := math.sqrt(to.x * to.x + to.y * to.y + to.z * to.z)
	fwd := p.cam.target - p.cam.position
	fwd_len := math.sqrt(fwd.x * fwd.x + fwd.y * fwd.y + fwd.z * fwd.z)
	if to_len > 0.001 && fwd_len > 0.001 {
		dot := (to.x * fwd.x + to.y * fwd.y + to.z * fwd.z) / (to_len * fwd_len)
		if dot > 0.93 {
			loop_gaze += dt
		} else {
			loop_gaze = max(0, loop_gaze - dt * 1.8)
		}
	}

	if loop_gaze >= LOOP_GAZE_TIME {
		loop_mark_solved(loop_cell[0], loop_cell[1])
		loop_active = false
		loop_gaze = 0
		sanity_heal(8.0)
		set_event("THE LOOP BREAKS. THE HALLWAY LETS YOU THROUGH.", 3.0)
		return
	}

	if loop_timer >= LOOP_LIMIT {
		p.cam.position.x = loop_last_safe.x
		p.cam.position.z = loop_last_safe.z
		p.cell_x = cell_of(p.cam.position.x)
		p.cell_z = cell_of(p.cam.position.z)
		p.feet_y = ground_at(p.cam.position.x, p.cam.position.z)
		p.eye_y = p.feet_y + EYE_H
		p.cam.position.y = p.eye_y
		p.vel_y = 0
		p.grounded = true
		p.fade = 1.0
		sanity_damage(6.0)
		loop_active = false
		loop_gaze = 0
		loop_cooldown = 3.0
		set_event("YOU WALKED IN A CIRCLE. SOMETHING NOTICED.", 3.0)
	}
}

// ─────────────────────────────────────────────────────────────────────────────
// Glitched walls / no-clip transitions (Phase 2.2 + sanity-gated shortcut)
// ─────────────────────────────────────────────────────────────────────────────
GLITCH_SANITY :: 55.0

is_glitch_cell :: proc(cx, cz: i32) -> bool {
	if abs(cx) <= SPAWN_CLEAR + 6 || abs(cz) <= SPAWN_CLEAR + 6 do return false
	h := raw_hash(cx * 53 + current_level * 7919, cz * 97 + 13)
	if h % 127 != 0 do return false
	if hole_at(cx, cz) || stair_at(cx, cz) || pillar_at(cx, cz) || exit_at(cx, cz) do return false
	return floor_level(cx, cz) == 0
}

glitch_enabled :: proc() -> bool {
	return current_level == 0 || sanity < GLITCH_SANITY
}

use_glitch :: proc(p: ^Player) -> bool {
	if !is_glitch_cell(p.cell_x, p.cell_z) || !glitch_enabled() do return false
	objective_glitch_used()
	p.fade = 1.0
	set_level(current_level + 1)
	nx, nz := safe_landing(p.cell_x, p.cell_z)
	p.cell_x, p.cell_z = nx, nz
	p.cam.position.x = (f32(nx) + 0.5) * CELL
	p.cam.position.z = (f32(nz) + 0.5) * CELL
	p.feet_y = floor_h(nx, nz)
	p.eye_y = p.feet_y + EYE_H
	p.cam.position.y = p.eye_y
	p.vel_y = 0
	p.grounded = true
	p.grace = 0.8
	set_event("YOU NO-CLIPPED THROUGH THE WALL", 3.0)
	return true
}

// ─────────────────────────────────────────────────────────────────────────────
// Drawing for Phase 2 markers
// ─────────────────────────────────────────────────────────────────────────────
draw_loop_beacons :: proc(cam: rl.Vector3) {
	pcx := i32(math.floor(cam.x / CELL))
	pcz := i32(math.floor(cam.z / CELL))
	radius :: 12
	for dz in -radius ..= radius do for dx in -radius ..= radius {
		cx, cz := pcx + i32(dx), pcz + i32(dz)
		if !is_loop_cell(cx, cz) || loop_is_solved(cx, cz) do continue
		pos := loop_beacon_pos(cx, cz)
		pulse := 0.45 + 0.55 * (0.5 + 0.5 * math.sin(run_time * 9.0 + f32(cx + cz)))
		a := u8(120 + 120 * pulse)
		rl.DrawCube(pos, 0.22, 0.22, 0.22, rl.Color{120, 230, 255, a})
		rl.DrawCubeWires(pos, 0.34, 0.34, 0.34, rl.Color{150, 255, 255, 255})
		// A thin shaft of light makes the beacon visible down the hall.
		rl.DrawLine3D(pos, {pos.x, floor_h(cx, cz), pos.z}, rl.Color{90, 200, 255, u8(45 * pulse)})
	}
}

draw_glitch_markers :: proc(cam: rl.Vector3) {
	if !glitch_enabled() do return
	pcx := i32(math.floor(cam.x / CELL))
	pcz := i32(math.floor(cam.z / CELL))
	radius :: 8
	for dz in -radius ..= radius do for dx in -radius ..= radius {
		cx, cz := pcx + i32(dx), pcz + i32(dz)
		if !is_glitch_cell(cx, cz) do continue
		x := f32(cx) * CELL + CELL / 2
		z := f32(cz) * CELL + CELL / 2
		y := floor_h(cx, cz)
		flicker := 0.5 + 0.5 * math.sin(run_time * 23.0 + f32(cx * 3 + cz))
		a := u8(90 + 120 * flicker)
		rl.DrawCube(rl.Vector3{x, y + 1.3, z}, 0.12, 2.4, 2.4, rl.Color{210, 40, 220, a})
		rl.DrawCubeWires(rl.Vector3{x, y + 1.3, z}, 0.16, 2.5, 2.5, rl.Color{255, 120, 255, 255})
	}
}
