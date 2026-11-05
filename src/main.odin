package main

import "core:math"
import rl "vendor:raylib"

clear_world_chunks :: proc(w: ^World) {
	for _, m in w.chunks do rl.UnloadMesh(m)
	clear(&w.chunks)
}

start_new_game :: proc(p: ^Player, w: ^World) {
	// Reset the player fully (position, camera, warmup, transitions).
	p^ = player_init()
	p.warmup = 5

	// Reset survival systems.
	sanity = SANITY_MAX
	flashlight_on = true
	flashlight_battery = flashlight_max_battery

	// Reset inventory / entities and give the first floor one battery.
	init_items()
	init_objectives()
	objective_init_for_level(0)
	reset_walkie(true)
	reset_loop_state()
	spawn_level_pickups(p)
	spawn_objective_items(p)
	init_entities()

	// Reset world to the first level.
	current_level = 0
	last_region = nil
	exit_cell_count = 0
	level_dirty = false
	clear_world_chunks(w)
	w.level = current_level

	// Grace period: no sanity drain and no entity spawns for a few seconds.
	sanity_grace = 5.0
	entity_grace = 8.0

	current_state = .Playing
}

activate_menu_item :: proc(i: i32, p: ^Player, w: ^World) {
	switch i {
	case 0:
		// Continue
		if load_game(p) {
			current_state = .Playing
		}
	case 1:
		// New Game
		start_new_game(p, w)
	case 2:
		// Options / game mode
		m := i32(current_game_mode) + 1
		if m > 2 {m = 0}
		set_game_mode(Game_Mode(m))
	case 3:
		// Quit
		rl.CloseWindow()
	}
}

update_menu :: proc(p: ^Player, w: ^World) {
	// Never leave a run parked on the disabled Continue entry.
	if menu_selection == 0 && !has_save() do menu_selection = 1

	dir: i32 = 0
	if rl.IsKeyPressed(.UP) || rl.IsKeyPressed(.W) do dir = -1
	if rl.IsKeyPressed(.DOWN) || rl.IsKeyPressed(.S) do dir = 1
	if dir != 0 {
		menu_selection = (menu_selection + dir + 4) % 4
		// Skip the disabled Continue entry when there is no save.
		if !has_save() && menu_selection == 0 {
			menu_selection = (menu_selection + dir + 4) % 4
		}
	}

	// Mouse support: hover to select, click to confirm. The disabled Continue
	// entry must not steal the selection, otherwise a mouse parked over the
	// middle of the screen makes Enter/New Game look broken.
	mp := rl.GetMousePosition()
	sw := f32(rl.GetScreenWidth())
	sh := f32(rl.GetScreenHeight())
	save_exists := has_save()
	for i in 0 ..< 4 {
		ii := i32(i)
		x := sw / 2 - 80
		y := sh / 2 - 20 + f32(ii) * 30
		if mp.x >= x - 10 && mp.x <= x + 220 && mp.y >= y - 4 && mp.y <= y + 26 {
			if ii == 0 && !save_exists do continue
			menu_selection = ii
			if rl.IsMouseButtonPressed(.LEFT) {
				activate_menu_item(ii, p, w)
			}
		}
	}

	if rl.IsKeyPressed(.ENTER) || rl.IsKeyPressed(.SPACE) {
		activate_menu_item(menu_selection, p, w)
	}
}

update_pause :: proc(p: ^Player) {
	if rl.IsKeyPressed(.ESCAPE) {
		current_state = .Playing
	}
	if rl.IsKeyPressed(.UP) || rl.IsKeyPressed(.W) {
		pause_selection = (pause_selection - 1 + 4) % 4
	}
	if rl.IsKeyPressed(.DOWN) || rl.IsKeyPressed(.S) {
		pause_selection = (pause_selection + 1) % 4
	}
	if rl.IsKeyPressed(.ENTER) || rl.IsKeyPressed(.SPACE) {
		switch pause_selection {
		case 0:
			// Resume
			current_state = .Playing
		case 1:
			// Game Mode
			m := i32(current_game_mode) + 1
			if m > 2 {m = 0}
			set_game_mode(Game_Mode(m))
		case 2:
			// Save
			if game_settings.saving_allowed {
				save_game(p)
			} else {
				save_feedback_t = 2.0
				save_feedback_ok = false
			}
		case 3:
			// Quit to Menu
			current_state = .Menu
		}
	}
}

// The cursor must be grabbed only when it needs to change state. Both
// EnableCursor() and DisableCursor() call SetMousePosition() internally,
// which resets the mouse delta to zero. Calling either every frame (as the
// menu previously did with EnableCursor) pins the cursor and kills look.
cursor_hidden: bool

ensure_cursor_visible :: proc() {
	if cursor_hidden {
		rl.EnableCursor()
		cursor_hidden = false
	}
}

grab_cursor :: proc(p: ^Player) {
	if !cursor_hidden {
		rl.DisableCursor() // also enables GLFW raw mouse motion
		p.warmup = 3 // ignore the recenter delta spike
		cursor_hidden = true
	}
}

main :: proc() {
	rl.SetConfigFlags({.WINDOW_RESIZABLE, .VSYNC_HINT})
	rl.InitWindow(INTERNAL_W * WINDOW_SCALE, INTERNAL_H * WINDOW_SCALE, WINDOW_TITLE)
	defer rl.CloseWindow()
	rl.SetTargetFPS(60)

	init_game()

	r := renderer_init()
	defer renderer_destroy(&r)

	p := player_init()

	w := world_init(r.shader)
	world_preload(&w, p.cam.position)
	defer world_destroy(&w)

	d := devmap_init()
	defer devmap_destroy(&d)

	for !rl.WindowShouldClose() {
		// Cap dt so a stalled frame (shader compile, alt-tab) cannot drain
		// sanity or move the player in one huge step.
		dt := min(rl.GetFrameTime(), 0.05)
		run_time += dt

		if rl.IsWindowFocused() {
			if sanity_grace > 0 do sanity_grace -= dt
			if entity_grace > 0 do entity_grace -= dt
			if save_feedback_t > 0 do save_feedback_t -= dt
			update_events(dt)
		}

		switch current_state {
		case .Menu:
			ensure_cursor_visible()
			update_menu(&p, &w)
			rl.BeginDrawing()
			draw_menu()
			rl.EndDrawing()

		case .Playing:
			// Freeze the simulation while alt-tabbed. Without this, sanity
			// kept draining in real time and players could come back to a
			// game-over screen they never saw coming.
			if !rl.IsWindowFocused() {
				ensure_cursor_visible()
				if !d.open {
					scene_draw(&r, &w, p.cam)
					renderer_present(&r, p.fade, &p)
				}
				free_all(context.temp_allocator)
				continue
			}

			devmap_update(&d, &p)

			// Grab the cursor once per entry into gameplay, or release it
			// while the dev map is open. Both raylib calls recenter the
			// mouse, so they must never run every frame.
			if d.open {
				ensure_cursor_visible()
			} else {
				grab_cursor(&p)
			}
			renderer_handle_keys(&r)

			if rl.IsKeyPressed(.ESCAPE) {
				current_state = .Paused
				ensure_cursor_visible()
				continue
			}

			if !d.open do player_update(&p, dt)

			// Rebuild the floor before any per-level systems run (load, stairs,
			// holes, or the dev map may have changed the level this frame).
			if level_dirty {
				clear_world_chunks(&w)
				level_dirty = false
				init_entities()
				clear_pickups()
				reset_loop_state()
				objective_init_for_level(current_level)
				objective_restore_if_pending()
				spawn_level_pickups(&p)
				spawn_objective_items(&p)
				objective_update_exit(&p)
				entity_grace = 3.0
				// Spawn one key per level from level 5 onward (including the
				// final level, so missing an earlier key can never soft-lock
				// the run). Old maps are gone, so always discard the previous
				// key first, even when the player climbs back up.
				if !has_key {
					key_item.active = false
					if current_level >= 5 {
						kx, kz := find_key_cell(p.cell_x, p.cell_z)
						ky := floor_h(kx, kz)
						spawn_key(kx, kz, ky)
					}
				}
			}

			if !d.open {
				update_walkie(&p, dt)
				update_loop_room(&p, dt)
				update_hallucinations(&p, dt)
				if rl.IsKeyPressed(.Q) do drop_walkie(&p)
				if rl.IsKeyPressed(.E) && is_glitch_cell(p.cell_x, p.cell_z) {
					_ = use_glitch(&p)
				}
			}

			if d.open {
				devmap_draw(&d, p.cam.position, p.yaw)
			} else {
				// ── sanity ──
				in_dark := !in_light(p.cell_x, p.cell_z)
				has_flashlight := flashlight_on && flashlight_battery > 0
				if sanity_grace <= 0 {
					sanity_drain(dt, in_dark, has_flashlight)
				}

				// ── death ──
				if sanity <= SANITY_MIN {
					current_state = .Game_Over
					continue
				}

				// ── world ──
				world_update(&w, p.cam.position)
				cell_x := i32(math.floor(p.cam.position.x / CELL))
				cell_z := i32(math.floor(p.cam.position.z / CELL))
				regions_trim(cell_x, cell_z)

				// ── entities ──
				update_entities(&p, dt)
				if sanity_grace <= 0 {
					sanity_drain_near_entity(nearest_entity_dist(&p), dt)
				}

				// ── items ──
				update_items(&p, dt)
				objective_update_exit(&p)

				// Task exit: completing the floor task opens a green door.
				if task_exit_active &&
				   p.cell_x == task_exit_cell[0] &&
				   p.cell_z == task_exit_cell[1] &&
				   rl.IsKeyPressed(.E) {
					_ = use_task_exit(&p)
				}

				// ── win condition: on exit level, have key, standing on exit ──
				if current_level == NUM_LEVELS - 1 &&
				   has_key &&
				   exit_at(p.cell_x, p.cell_z) &&
				   rl.IsKeyPressed(.E) {
					current_state = .Win
				}

				scene_draw(&r, &w, p.cam)
				renderer_present(&r, p.fade, &p)
			}

		case .Paused:
			ensure_cursor_visible()
			update_pause(&p)
			// draw the game behind the pause overlay
			if !d.open {
				scene_draw(&r, &w, p.cam)
				renderer_present(&r, p.fade)
			}
			rl.BeginDrawing()
			draw_pause()
			rl.EndDrawing()

		case .Game_Over:
			ensure_cursor_visible()
			if cast(i32)rl.GetKeyPressed() > 0 || rl.IsMouseButtonPressed(.LEFT) {
				current_state = .Menu
			}
			rl.BeginDrawing()
			draw_game_over()
			rl.EndDrawing()

		case .Win:
			ensure_cursor_visible()
			if cast(i32)rl.GetKeyPressed() > 0 || rl.IsMouseButtonPressed(.LEFT) {
				current_state = .Menu
			}
			rl.BeginDrawing()
			draw_win()
			rl.EndDrawing()
		}

		free_all(context.temp_allocator)
	}
}
