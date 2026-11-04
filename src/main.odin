package main

import rl "vendor:raylib"

clear_world_chunks :: proc(w: ^World) {
	for _, m in w.chunks do rl.UnloadMesh(m)
	clear(&w.chunks)
}

main :: proc() {
	rl.SetConfigFlags({.WINDOW_RESIZABLE, .VSYNC_HINT})
	rl.InitWindow(INTERNAL_W * WINDOW_SCALE, INTERNAL_H * WINDOW_SCALE, WINDOW_TITLE)
	defer rl.CloseWindow()
	rl.SetTargetFPS(60)

	r := renderer_init()
	defer renderer_destroy(&r)
	p := player_init()
	rl.DisableCursor()
	w := world_init(r.shader)
	defer world_destroy(&w)
	d := devmap_init()
	defer devmap_destroy(&d)

	for !rl.WindowShouldClose() {
		dt := rl.GetFrameTime()
		devmap_update(&d, &p)
		renderer_handle_keys(&r)
		if !d.open do player_update(&p, dt)
		if level_dirty {
			clear_world_chunks(&w)
			level_dirty = false
		}
		world_update(&w, p.cam.position)
		if d.open do devmap_draw(&d, p.cam.position, p.yaw)
		else {
			scene_draw(&r, &w, p.cam)
			renderer_present(&r, p.fade)
		}
		free_all(context.temp_allocator)
	}
}
