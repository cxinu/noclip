package main

import "core:math"
import rl "vendor:raylib"

Renderer :: struct {
	target:       rl.RenderTexture2D,
	bloom_target: rl.RenderTexture2D,
	shader:       rl.Shader,
	post:         rl.Shader,
	bloom_shader: rl.Shader,
	color_depth:  i32,
	dithering:    i32,
	gamma:        f32,
}

renderer_init :: proc() -> Renderer {
	r: Renderer

	r.target = rl.LoadRenderTexture(INTERNAL_W, INTERNAL_H)
	rl.SetTextureFilter(r.target.texture, .BILINEAR)

	r.shader = rl.LoadShader(SHADER_OBJ_VS, SHADER_OBJ_FS)

	res := rl.Vector2{f32(INTERNAL_W), f32(INTERNAL_H)}
	rl.SetShaderValue(r.shader, rl.GetShaderLocation(r.shader, "resolution"), &res, .VEC2)

	snap := f32(SNAP)
	rl.SetShaderValue(r.shader, rl.GetShaderLocation(r.shader, "snapFactor"), &snap, .FLOAT)

	fog := rl.ColorNormalize(FOG_COLOR)
	fog_color := [3]f32{fog.x, fog.y, fog.z}
	fog_range := WORLD_FOG
	rl.SetShaderValue(r.shader, rl.GetShaderLocation(r.shader, "fogColor"), &fog_color, .VEC3)
	rl.SetShaderValue(r.shader, rl.GetShaderLocation(r.shader, "fogRange"), &fog_range, .VEC2)

	r.post = rl.LoadShader(nil, SHADER_POST_FS)

	r.color_depth = DEFAULT_COLOR_DEPTH
	r.dithering = 1
	r.gamma = 1.0

	rl.SetShaderValue(r.post, rl.GetShaderLocation(r.post, "color_depth"), &r.color_depth, .INT)
	rl.SetShaderValue(r.post, rl.GetShaderLocation(r.post, "dithering"), &r.dithering, .INT)
	rl.SetShaderValue(r.post, rl.GetShaderLocation(r.post, "gamma"), &r.gamma, .FLOAT)

	bloom_strength := f32(BLOOM_STRENGTH)
	rl.SetShaderValue(
		r.post,
		rl.GetShaderLocation(r.post, "bloomStrength"),
		&bloom_strength,
		.FLOAT,
	)

	bloom_w := i32(INTERNAL_W / BLOOM_SCALE)
	bloom_h := i32(INTERNAL_H / BLOOM_SCALE)
	r.bloom_target = rl.LoadRenderTexture(bloom_w, bloom_h)
	rl.SetTextureFilter(r.bloom_target.texture, .BILINEAR)

	r.bloom_shader = rl.LoadShader(nil, SHADER_BLOOM_FS)

	texel := rl.Vector2{1.0 / f32(bloom_w), 1.0 / f32(bloom_h)}
	rl.SetShaderValue(
		r.bloom_shader,
		rl.GetShaderLocation(r.bloom_shader, "texelSize"),
		&texel,
		.VEC2,
	)

	threshold := f32(BLOOM_THRESHOLD)
	rl.SetShaderValue(
		r.bloom_shader,
		rl.GetShaderLocation(r.bloom_shader, "threshold"),
		&threshold,
		.FLOAT,
	)

	return r
}

renderer_handle_keys :: proc(r: ^Renderer) {
	if rl.IsKeyPressed(.F1) {
		r.dithering = r.dithering == 0 ? 1 : 0
		rl.SetShaderValue(r.post, rl.GetShaderLocation(r.post, "dithering"), &r.dithering, .INT)
	}
}

renderer_destroy :: proc(r: ^Renderer) {
	rl.UnloadShader(r.shader)
	rl.UnloadShader(r.post)
	rl.UnloadShader(r.bloom_shader)
	rl.UnloadRenderTexture(r.target)
	rl.UnloadRenderTexture(r.bloom_target)
}

// fade: 0.0 = fully visible, 1.0 = fully black. Drawn on top of everything so
// level transitions are hidden without the shader chain quantizing the fade.
renderer_present :: proc(r: ^Renderer, fade: f32 = 0) {
	rl.BeginDrawing()
	rl.ClearBackground(rl.BLACK)

	src := rl.Rectangle{0, 0, f32(INTERNAL_W), f32(-INTERNAL_H)}

	// 1. Bloom pass
	rl.BeginTextureMode(r.bloom_target)
	rl.ClearBackground(rl.BLACK)
	rl.BeginShaderMode(r.bloom_shader)
	rl.DrawTexturePro(
		r.target.texture,
		src,
		{0, 0, f32(r.bloom_target.texture.width), f32(r.bloom_target.texture.height)},
		{0, 0},
		0,
		rl.WHITE,
	)
	rl.EndShaderMode()
	rl.EndTextureMode()

	// 2. Post pass
	rl.SetShaderValueTexture(
		r.post,
		rl.GetShaderLocation(r.post, "bloomTex"),
		r.bloom_target.texture,
	)
	rl.BeginShaderMode(r.post)
	rl.DrawTexturePro(r.target.texture, src, renderer_viewport(), {0, 0}, 0, rl.WHITE)
	rl.EndShaderMode()

	// 3. Fade overlay — outside the shader, so it's pure black over the
	//    full window (letterbox + viewport), not quantized/dithered.
	if fade > 0 {
		a := u8(clamp(fade, 0, 1) * 255 + 0.5)
		rl.DrawRectangle(0, 0, rl.GetScreenWidth(), rl.GetScreenHeight(), {0, 0, 0, a})
	}

	rl.EndDrawing()
}

renderer_viewport :: proc() -> rl.Rectangle {
	sw := f32(rl.GetScreenWidth())
	sh := f32(rl.GetScreenHeight())
	scale := min(sw / f32(INTERNAL_W), sh / f32(INTERNAL_H))

	w := f32(INTERNAL_W) * scale
	h := f32(INTERNAL_H) * scale

	x0 := math.round((sw - w) * 0.5)
	y0 := math.round((sh - h) * 0.5)
	x1 := math.round((sw + w) * 0.5)
	y1 := math.round((sh + h) * 0.5)

	return {x0, y0, x1 - x0, y1 - y0}
}
