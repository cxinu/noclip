package main

import "core:math"
import rl "vendor:raylib"

Player :: struct {
	cam:                              rl.Camera3D,
	yaw, pitch, feet_y, eye_y, vel_y: f32,
	step_t, walk, run, time:          f32,
	kick, kick_v:                     [3]f32,
	grounded:                         bool,
	warmup:                           int,
	cell_x, cell_z:                   i32,
	// NEW: level-transition state
	pending:                          i32, // 0=none, +1=up, -1=down
	pending_cx, pending_cz:           i32,
	fade:                             f32, // 0=transparent, 1=black
	grace:                            f32, // seconds until next transition allowed
}

player_init :: proc() -> Player {
	return Player {
		cam = {
			position = {CELL / 2, EYE_H, CELL / 2},
			target = {CELL / 2, EYE_H, CELL / 2 + 1},
			up = {0, 1, 0},
			fovy = 60,
			projection = .PERSPECTIVE,
		},
		eye_y = EYE_H,
		grounded = true,
		warmup = 10,
	}
}

wobble :: proc(t, seed: f32) -> f32 {
	return(
		math.sin(t * 1.0 + seed) * 0.5 +
		math.sin(t * 2.3 + seed * 2.1) * 0.3 +
		math.sin(t * 4.7 + seed * 3.7) * 0.2 \
	)
}

step_rand :: proc(n: i32, seed: u32) -> f32 {
	x := u32(n) * 747796405 + seed * 2891336453
	x = ((x >> ((x >> 28) + 4)) ~ x) * 277803737
	x = (x >> 22) ~ x
	return f32(x & 0xFFFF) / 32767.5 - 1
}

cell_of :: proc(w: f32) -> i32 {return i32(math.floor(w / CELL))}

// NEW: find a safe landing cell (no hole, stair, or pillar) near a target.
safe_landing :: proc(cx, cz: i32) -> (i32, i32) {
	if !hole_at(cx, cz) && !stair_at(cx, cz) && !pillar_at(cx, cz) do return cx, cz
	for o in ([8][2]i32{{1, 0}, {-1, 0}, {0, 1}, {0, -1}, {1, 1}, {1, -1}, {-1, 1}, {-1, -1}}) {
		nx, nz := cx + o[0], cz + o[1]
		if hole_at(nx, nz) || stair_at(nx, nz) || pillar_at(nx, nz) do continue
		return nx, nz
	}
	return cx, cz
}

player_update :: proc(p: ^Player, dt: f32) {
	// ── look ──
	md := rl.GetMouseDelta()
	if p.warmup > 0 {p.warmup -= 1; md = {}}
	p.yaw -= clamp(md.x, -150, 150) * MOUSE_SENS
	p.pitch = clamp(p.pitch - clamp(md.y, -150, 150) * MOUSE_SENS, -1.4, 1.4)

	sy, cy := math.sin(p.yaw), math.cos(p.yaw)
	fwd := rl.Vector3{sy, 0, cy}
	right := rl.Vector3{-cy, 0, sy}

	// ── movement ──
	dir: rl.Vector3
	if rl.IsKeyDown(.W) do dir += fwd
	if rl.IsKeyDown(.S) do dir -= fwd
	if rl.IsKeyDown(.D) do dir += right
	if rl.IsKeyDown(.A) do dir -= right
	if l := math.sqrt(dir.x * dir.x + dir.z * dir.z); l > 0 do dir /= l

	sprint := rl.IsKeyDown(.LEFT_SHIFT) && rl.IsKeyDown(.W)
	speed := f32(MOVE_SPEED) * (sprint ? 1.7 : 1.0)
	old_pos := p.cam.position

	proposed := rl.Vector2 {
		p.cam.position.x + dir.x * speed * dt,
		p.cam.position.z + dir.z * speed * dt,
	}
	if dest_h := ground_at(proposed.x, proposed.y);
	   p.grounded && dest_h - p.feet_y > STEP_UP_HEIGHT {
		axis_x := rl.Vector2{proposed.x, p.cam.position.z}
		axis_z := rl.Vector2{p.cam.position.x, proposed.y}
		can_x := ground_at(axis_x.x, axis_x.y) - p.feet_y <= STEP_UP_HEIGHT
		can_z := ground_at(axis_z.x, axis_z.y) - p.feet_y <= STEP_UP_HEIGHT
		switch {
		case can_x && !can_z:
			proposed = axis_x
		case can_z && !can_x:
			proposed = axis_z
		case:
			proposed = {p.cam.position.x, p.cam.position.z}
		}
	}
	fixed := collide_walls(proposed, PLAYER_R)
	p.cam.position.x, p.cam.position.z = fixed.x, fixed.y
	p.cell_x = cell_of(p.cam.position.x)
	p.cell_z = cell_of(p.cam.position.z)

	// ── vertical ──
	ground := ground_at(p.cam.position.x, p.cam.position.z)
	was_grounded := p.grounded

	if p.grounded && rl.IsKeyPressed(.SPACE) {
		p.vel_y = JUMP_V
		p.grounded = false
	}
	p.vel_y -= GRAVITY * dt
	p.feet_y += p.vel_y * dt

	if p.feet_y <= ground {
		if !was_grounded && p.vel_y < -2 {
			impact := clamp(-p.vel_y, 0, 18) / 18
			drop := max(old_pos.y - ground, 0)
			scale := 0.05 + 0.10 * clamp(drop / (FLOOR_STEP * 2), 0, 1)
			p.kick_v[0] += p.vel_y * scale
			p.kick_v[1] += p.vel_y * scale * 0.6
			_ = impact
		}
		p.feet_y, p.vel_y, p.grounded = ground, 0, true
	} else if p.grounded && p.feet_y - ground <= STEP_DOWN_SNAP {
		p.feet_y = ground
	} else {
		p.grounded = false
	}

	// ── NEW: transition triggers ──
	if p.grace <= 0 && p.pending == 0 {
		// UP: standing on the top tread of a stairwell
		if stair_at(p.cell_x, p.cell_z) {
			base := floor_h(p.cell_x, p.cell_z)
			if p.feet_y - base > STAIR_RISE * 0.85 {
				p.pending = 1
				p.pending_cx = p.cell_x
				p.pending_cz = p.cell_z
			}
		}
		// DOWN: fallen into a shaft
		if hole_at(p.cell_x, p.cell_z) {
			base := floor_h(p.cell_x, p.cell_z)
			if p.feet_y < base - 1.0 {
				p.pending = -1
				p.pending_cx = p.cell_x
				p.pending_cz = p.cell_z
			}
		}
	}

	// Cancel if the player moved away from the trigger
	if p.pending == 1 {
		if p.cell_x != p.pending_cx ||
		   p.cell_z != p.pending_cz ||
		   p.feet_y - floor_h(p.cell_x, p.cell_z) < STAIR_RISE * 0.8 {
			p.pending = 0
		}
	}
	if p.pending == -1 {
		if p.cell_x != p.pending_cx ||
		   p.cell_z != p.pending_cz ||
		   p.feet_y > floor_h(p.cell_x, p.cell_z) - 0.8 {
			p.pending = 0
		}
	}

	// Fade: ramp up while pending, then commit at the darkest point
	if p.pending != 0 {
		p.fade = min(1.0, p.fade + dt * 6.0)
		if p.fade >= 0.95 {
			// Commit the transition
			dir_lvl := p.pending
			ox, oz := p.pending_cx, p.pending_cz
			p.pending = 0
			p.fade = 1.0
			set_level(current_level + dir_lvl)
			nx, nz := safe_landing(ox, oz)
			p.cam.position.x = (f32(nx) + 0.5) * CELL
			p.cam.position.z = (f32(nz) + 0.5) * CELL
			p.feet_y = floor_h(nx, nz)
			p.vel_y = 0
			p.grounded = true
			p.eye_y = p.feet_y + EYE_H
			p.cell_x = nx
			p.cell_z = nz
			p.grace = 0.5
		}
	} else {
		p.fade = max(0.0, p.fade - dt * 4.0)
	}
	if p.grace > 0 do p.grace -= dt

	// ── POV mechanics (unchanged) ──
	moved := math.sqrt(
		(p.cam.position.x - old_pos.x) * (p.cam.position.x - old_pos.x) +
		(p.cam.position.z - old_pos.z) * (p.cam.position.z - old_pos.z),
	)
	spd := p.grounded ? moved / (max(dt, 0.0001) * f32(MOVE_SPEED)) : 0
	p.walk += (clamp(spd, 0, 1) - p.walk) * min(1.0, 6 * dt)
	p.run += (clamp((spd - 1) / 0.7, 0, 1) - p.run) * min(1.0, 4 * dt)
	walk, run := p.walk, p.run
	p.time += dt

	n0 := i32(math.floor(p.step_t))
	p.step_t += dt * 1.8 * spd
	n1 := i32(math.floor(p.step_t))
	if n1 != n0 {
		a, b := step_rand(n1, 1), step_rand(n1, 2)
		side := f32(n1 & 1 == 0 ? 1 : -1) * 0.6 + b * 0.6
		p.kick_v[0] -= (0.05 * walk + 0.20 * run) * (1 + 0.3 * a)
		p.kick_v[1] -= (0.03 * walk + 0.16 * run) * (1 + 0.4 * b)
		p.kick_v[2] += (0.01 * walk + 0.17 * run) * side
	}

	sdt := min(dt, 1.0 / 30.0)
	for i in 0 ..< 3 {
		p.kick_v[i] += (-220 * p.kick[i] - 16 * p.kick_v[i]) * sdt
		p.kick[i] += p.kick_v[i] * sdt
	}

	ph := p.step_t * math.TAU
	stride := -math.cos(ph) * (0.006 * walk + 0.010 * run)
	sway := math.sin(ph * 0.5)
	roll := sway * (0.003 * walk + 0.006 * run) + p.kick[2]

	t, d := p.time, 1 + 2.5 * run
	yaw := p.yaw + math.cos(ph * 0.5) * 0.002 * run + wobble(t * 0.9, 1) * 0.0025 * d
	pitch := clamp(p.pitch + p.kick[1] + wobble(t * 0.8, 7) * 0.002 * d, -1.45, 1.45)
	roll += wobble(t * 0.7, 13) * 0.003 * d

	p.eye_y += (p.feet_y + EYE_H - p.eye_y) * min(1.0, 18 * dt)
	p.cam.position.y = p.eye_y + stride + p.kick[0]
	p.cam.target =
		p.cam.position +
		rl.Vector3 {
				math.sin(yaw) * math.cos(pitch),
				math.sin(pitch),
				math.cos(yaw) * math.cos(pitch),
			}
	p.cam.up = rl.Vector3{0, 1, 0} * math.cos(roll) + right * math.sin(roll)
}
