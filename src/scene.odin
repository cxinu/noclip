package main

import "core:math"
import rl "vendor:raylib"
import rlgl "vendor:raylib/rlgl"

draw_exit_marker :: proc(cx, cz: i32) {
	y := floor_h(cx, cz)
	x := f32(cx) * CELL + CELL / 2
	z := f32(cz) * CELL + CELL / 2
	frame := rl.Color{80, 255, 130, 255}

	// Free-standing green door frame so the exit reads from a distance.
	rl.DrawCube(rl.Vector3{x - 0.8, y + 1.1, z}, 0.14, 2.2, 0.14, frame)
	rl.DrawCube(rl.Vector3{x + 0.8, y + 1.1, z}, 0.14, 2.2, 0.14, frame)
	rl.DrawCube(rl.Vector3{x, y + 2.2, z}, 1.74, 0.14, 0.14, frame)
	// Glowing plane inside the frame.
	rl.DrawCube(rl.Vector3{x, y + 1.05, z}, 1.4, 2.0, 0.04, rl.Color{45, 190, 105, 190})
}

scene_draw :: proc(r: ^Renderer, w: ^World, cam: rl.Camera3D) {
	rl.BeginTextureMode(r.target)
	rl.ClearBackground(FOG_COLOR)
	rl.BeginMode3D(cam)
	world_draw(w)

	// Entities. High sanity keeps them invisible until close; low sanity
	// reveals phantom copies and lingering outlines (Phase 3.2).
	for i in 0 ..< MAX_ENTITIES {
		e := &entities[i]
		if !e.active do continue
		if e.phantom && !sanity_is_low() do continue
		dx := cam.position.x - e.pos[0]
		dz := cam.position.z - e.pos[2]
		dist := math.sqrt(dx * dx + dz * dz)
		if !e.phantom && !sanity_is_low() && dist > 12.0 && e.state != .Chase do continue
		draw_entity(e, cam.position)
	}

	// Low sanity: outlines bleed through walls (Phase 3.2).
	if sanity_is_low() {
		rlgl.DisableDepthTest()
		for i in 0 ..< MAX_ENTITIES {
			e := &entities[i]
			if !e.active do continue
			col := rl.Color{255, 70, 70, 90}
			if e.phantom do col = rl.Color{190, 130, 255, 80}
			rl.DrawCubeWires(
				rl.Vector3{e.pos[0], e.pos[1] + 0.9, e.pos[2]},
				0.7,
				2.0,
				0.7,
				col,
			)
		}
		rlgl.EnableDepthTest()
	}

	// Phase 2 markers and the dropped walkie-talkie.
	draw_loop_beacons(cam.position)
	draw_glitch_markers(cam.position)
	draw_walkie()

	// Pickups: key and consumables.
	draw_item(&key_item)
	for i in 0 ..< MAX_ITEMS {
		if items[i].active {
			draw_item(&items[i])
		}
	}

	// Floor-task exit door (opens when the floor task is complete).
	if task_exit_active {
		draw_exit_marker(task_exit_cell[0], task_exit_cell[1])
	}

	// Exit markers on the final level.
	if current_level == NUM_LEVELS - 1 {
		for i in 0 ..< exit_cell_count {
			draw_exit_marker(exit_cells[i][0], exit_cells[i][1])
		}
	}

	rl.EndMode3D()
	rl.EndTextureMode()
}
