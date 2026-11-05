package main

import "core:math"
import rl "vendor:raylib"

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

	trim_cx, trim_cz, trim_floor := i32(0x7fffffff), i32(0), i32(-1)
	for !rl.WindowShouldClose() {
		dt := rl.GetFrameTime()
		devmap_update(&d, &p)
		renderer_handle_keys(&r)
		if !d.open do player_update(&p, dt)
		if d.open {
			devmap_draw(&d, p.cam.position, p.yaw)
		} else {
			world_update(&w, p.cam.position, p.cam.target)
			cell_x := i32(math.floor(p.cam.position.x / CELL))
			cell_z := i32(math.floor(p.cam.position.z / CELL))
			if cell_x / 8 != trim_cx || cell_z / 8 != trim_cz || current_floor != trim_floor {
				regions_trim(cell_x, cell_z)
				trim_cx, trim_cz, trim_floor = cell_x / 8, cell_z / 8, current_floor
			}
			scene_draw(&r, &w, p.cam)
			renderer_present(&r)
		}
		free_all(context.temp_allocator)
	}
}
