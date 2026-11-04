package main

import rl "vendor:raylib"

scene_draw :: proc(r: ^Renderer, w: ^World, cam: rl.Camera3D) {
	rl.BeginTextureMode(r.target)
	rl.ClearBackground(FOG_COLOR)
	rl.BeginMode3D(cam)
	world_draw(w)
	rl.EndMode3D()
	rl.EndTextureMode()
}
