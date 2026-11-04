package main

import "core:math"
import rl "vendor:raylib"

Player :: struct {
	cam:       rl.Camera3D,
	yaw:       f32,
	pitch:     f32,
	feet_y:    f32,
	eye_y:     f32,
	vel_y:     f32,
	grounded:  bool,
	bob_phase: f32,
	warmup:    int,
}

player_init :: proc() -> Player {
	return Player {
		cam = rl.Camera3D {
			position = {CELL / 2, 2, CELL / 2},
			target = {CELL / 2, 2, CELL / 2 + 1},
			up = {0, 1, 0},
			fovy = 60,
			projection = .PERSPECTIVE,
		},
		feet_y = 0,
		eye_y = 2,
		grounded = true,
		warmup = 10,
	}
}

player_update :: proc(p: ^Player, dt: f32) {
	// --- mouse look ---
	md := rl.GetMouseDelta()
	if p.warmup > 0 {
		p.warmup -= 1
		md = {0, 0}
	}
	md.x = clamp(md.x, -150, 150)
	md.y = clamp(md.y, -150, 150)
	p.yaw -= md.x * 0.003
	p.pitch -= md.y * 0.003
	p.pitch = clamp(p.pitch, -1.4, 1.4)

	forward := rl.Vector3 {
		math.sin(p.yaw) * math.cos(p.pitch),
		math.sin(p.pitch),
		math.cos(p.yaw) * math.cos(p.pitch),
	}
	forward_flat := rl.Vector3{math.sin(p.yaw), 0, math.cos(p.yaw)}
	right_flat := rl.Vector3{-math.cos(p.yaw), 0, math.sin(p.yaw)}

	// --- WASD ---
	dir := rl.Vector3{0, 0, 0}
	if rl.IsKeyDown(.W) do dir += forward_flat
	if rl.IsKeyDown(.S) do dir -= forward_flat
	if rl.IsKeyDown(.D) do dir += right_flat
	if rl.IsKeyDown(.A) do dir -= right_flat

	length := math.sqrt(dir.x * dir.x + dir.z * dir.z)
	if length > 0 {
		dir.x /= length
		dir.z /= length
	}

	move_speed := f32(4.0)
	p.cam.position.x += dir.x * move_speed * dt
	p.cam.position.z += dir.z * move_speed * dt

	// --- wall collision ---
	fixed := collide_walls({p.cam.position.x, p.cam.position.z}, PLAYER_R)
	p.cam.position.x = fixed.x
	p.cam.position.z = fixed.y

	// --- simple flat ground check (y = 0) ---
	ground := f32(0.0)
	if p.grounded && rl.IsKeyPressed(.SPACE) {
		p.vel_y = 5.0
		p.grounded = false
	}
	p.vel_y -= 9.81 * 2 * dt
	p.feet_y += p.vel_y * dt

	if p.feet_y <= ground {
		p.feet_y = ground
		p.vel_y = 0
		p.grounded = true
	} else {
		p.grounded = false
	}

	// --- head-bob + smoothed eye height ---
	bob: f32 = 0
	if length > 0 && p.grounded {
		p.bob_phase += dt * 8
		bob = math.sin(p.bob_phase) * 0.04
	}
	p.eye_y += (p.feet_y + 1.7 - p.eye_y) * min(1.0, 18 * dt)
	p.cam.position.y = p.eye_y + bob
	p.cam.target = p.cam.position + forward
}
