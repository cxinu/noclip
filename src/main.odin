package main

import rl "vendor:raylib"

main :: proc() {
	rl.SetConfigFlags({.WINDOW_RESIZABLE, .VSYNC_HINT})
	rl.InitWindow(INTERNAL_W * WINDOW_SCALE, INTERNAL_H * WINDOW_SCALE, WINDOW_TITLE)
	defer rl.CloseWindow()
	rl.SetTargetFPS(60)

	renderer := renderer_init()
	defer renderer_destroy(&renderer)

	player := player_init()
	rl.DisableCursor()

	world := world_init(renderer.shader)
	defer world_destroy(&world)

	dev := devmap_init()

	for !rl.WindowShouldClose() {
		dt := rl.GetFrameTime()

		devmap_update(&dev, &player)
		renderer_handle_keys(&renderer)
		if !dev.open do player_update(&player, dt)

		world_update(&world, player.cam.position)

		if dev.open {
			devmap_draw(&dev, player.cam.position, player.yaw)
		} else {
			scene_draw(&renderer, &world, player.cam)
			renderer_present(&renderer)
		}

		free_all(context.temp_allocator)
	}
}
