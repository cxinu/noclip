package main

import rl "vendor:raylib"
import "core:fmt"
import "core:math"

draw_hud :: proc(p: ^Player) {
	sw := f32(rl.GetScreenWidth())
	sh := f32(rl.GetScreenHeight())

	// ── Crosshair ──
	cx := i32(sw / 2)
	cy := i32(sh / 2)
	rl.DrawLine(cx - 8, cy, cx + 8, cy, rl.Color{255, 255, 255, 200})
	rl.DrawLine(cx, cy - 8, cx, cy + 8, rl.Color{255, 255, 255, 200})
	rl.DrawPixel(cx, cy, rl.Color{255, 255, 255, 255})

	// ── Sanity bar (top-left) ──
	bar_w: i32 = 200
	bar_h: i32 = 18
	bar_x: i32 = 20
	bar_y: i32 = 20
	rl.DrawRectangle(bar_x, bar_y, bar_w, bar_h, rl.Color{30, 30, 40, 200})
	fill_w := i32(f32(bar_w) * sanity / SANITY_MAX)
	bar_col := rl.Color{220, 220, 100, 255}
	if sanity_is_critical() {
		bar_col = rl.Color{220, 60, 60, 255}
	} else if sanity_is_low() {
		bar_col = rl.Color{220, 160, 60, 255}
	}
	rl.DrawRectangle(bar_x, bar_y, fill_w, bar_h, bar_col)
	rl.DrawRectangleLines(bar_x, bar_y, bar_w, bar_h, rl.Color{255, 255, 255, 100})
	rl.DrawText(fmt.ctprintf("SANITY %d", i32(sanity)), bar_x, bar_y + bar_h + 2, 10, rl.Color{220, 220, 220, 255})
	if nearest_entity_dist(p) < 8.0 {
		rl.DrawText(
			"SOMETHING IS NEAR",
			bar_x + bar_w + 10,
			bar_y + 4,
			10,
			rl.Color{255, 90, 90, 240},
		)
	}

	// ── Flashlight (below sanity) ──
	flash_y: i32 = bar_y + bar_h + 24
	rl.DrawRectangle(bar_x, flash_y, bar_w, bar_h, rl.Color{30, 30, 40, 200})
	fb_fill := i32(f32(bar_w) * flashlight_battery / flashlight_max_battery)
	flash_col := rl.Color{100, 200, 255, 255}
	if !flashlight_on {
		flash_col = rl.Color{100, 100, 100, 255}
	} else if flashlight_battery <= 10.0 {
		flash_col = rl.Color{255, 80, 80, 255}
	}
	rl.DrawRectangle(bar_x, flash_y, fb_fill, bar_h, flash_col)
	rl.DrawRectangleLines(bar_x, flash_y, bar_w, bar_h, rl.Color{255, 255, 255, 100})
	flash_label: cstring = "FLASHLIGHT [F]"
	if !flashlight_on {
		flash_label = "FLASHLIGHT [F] (OFF)"
	}
	rl.DrawText(flash_label, bar_x, flash_y + bar_h + 2, 10, rl.Color{220, 220, 220, 255})

	// ── Key indicator (top-right) ──
	if has_key {
		rl.DrawText("KEY ACQUIRED", i32(sw) - 200, 20, 14, rl.Color{255, 215, 0, 255})
		rl.DrawRectangle(i32(sw) - 200, 42, 16, 16, rl.Color{255, 215, 0, 255})
		rl.DrawRectangleLines(i32(sw) - 200, 42, 16, 16, rl.Color{255, 255, 255, 200})
	}

	// ── Floor / level ──
	lvl_text := fmt.ctprintf("FLOOR %d: %s", current_level, LEVELS[current_level].name)
	rl.DrawText(lvl_text, 20, i32(sh) - 30, 10, rl.Color{180, 180, 200, 220})

	// ── Game mode ──
	mode_text: cstring = "MODE: NORMAL"
	if current_game_mode == .Easy {
		mode_text = "MODE: EASY"
	} else if current_game_mode == .Hard {
		mode_text = "MODE: HARD"
	}
	rl.DrawText(mode_text, 20, i32(sh) - 16, 10, rl.Color{150, 150, 180, 200})

	// ── Sprint hint ──
	if rl.IsKeyDown(.LEFT_SHIFT) && rl.IsKeyDown(.W) {
		rl.DrawText("SPRINTING - louder", i32(sw) - 180, i32(sh) - 24, 10, rl.Color{255, 160, 160, 220})
	}

	// ── Focus warning ──
	if !rl.IsWindowFocused() {
		rl.DrawRectangle(0, i32(sh / 2) - 30, i32(sw), 60, rl.Color{0, 0, 0, 180})
		rl.DrawText(
			"CLICK THE WINDOW TO CAPTURE THE MOUSE",
			i32(sw / 2) - 150,
			i32(sh / 2) - 8,
			12,
			rl.Color{255, 220, 120, 255},
		)
	}

	// ── Contextual prompts ──
	// Key nearby
	if !has_key && key_item.active {
		dx := key_item.pos[0] - p.cam.position.x
		dz := key_item.pos[2] - p.cam.position.z
		dy := key_item.pos[1] - p.cam.position.y
		if dx * dx + dz * dz < 9.0 && abs(dy) < 2.2 {
			rl.DrawText("PRESS E TO TAKE THE KEY", i32(sw / 2) - 100, i32(sh / 2) + 40, 12, rl.Color{255, 215, 0, 255})
		}
	}
	// Exit door
	if current_level == NUM_LEVELS - 1 && exit_at(p.cell_x, p.cell_z) {
		if has_key {
			rl.DrawText("PRESS E TO ESCAPE", i32(sw / 2) - 80, i32(sh / 2) + 40, 14, rl.Color{120, 255, 160, 255})
		} else {
			rl.DrawText("THE DOOR IS LOCKED - FIND THE KEY", i32(sw / 2) - 140, i32(sh / 2) + 40, 12, rl.Color{255, 120, 120, 255})
		}
	}

	// Phase 2.2 + Phase 3.3: sanity-gated no-clip tear.
	if glitch_enabled() && is_glitch_cell(p.cell_x, p.cell_z) {
		rl.DrawText(
			"PRESS E TO NO-CLIP THROUGH THE WALL",
			i32(sw / 2) - 140,
			i32(sh / 2) + 58,
			12,
			rl.Color{255, 120, 255, 240},
		)
	}

	// Completed floor task: the green exit door is the way onward.
	if task_exit_active &&
	   p.cell_x == task_exit_cell[0] &&
	   p.cell_z == task_exit_cell[1] {
		rl.DrawText(
			"PRESS E TO DESCEND THROUGH THE FLOOR EXIT",
			i32(sw / 2) - 160,
			i32(sh / 2) + 58,
			12,
			rl.Color{120, 255, 170, 245},
		)
	}

	// Phase 2.1: looping-room gaze puzzle.
	if loop_active {
		rl.DrawRectangle(
			i32(sw / 2) - 150,
			i32(sh / 2) - 92,
			300,
			48,
			rl.Color{5, 15, 25, 190},
		)
		rl.DrawText(
			"THE HALLWAY LOOPS",
			i32(sw / 2) - 70,
			i32(sh / 2) - 86,
			12,
			rl.Color{140, 230, 255, 255},
		)
		rl.DrawText(
			fmt.ctprintf("STARE AT THE FLICKERING LIGHT  %d%%", i32(loop_gaze / LOOP_GAZE_TIME * 100)),
			i32(sw / 2) - 120,
			i32(sh / 2) - 68,
			10,
			rl.Color{190, 240, 255, 230},
		)
	}

	// Shared event banner.
	if event_t > 0 {
		tw := rl.MeasureText(event_msg, 12)
		x := i32(sw / 2) - tw / 2
		y := i32(sh) - 96
		rl.DrawRectangle(x - 8, y - 5, tw + 16, 22, rl.Color{0, 0, 0, 190})
		rl.DrawText(event_msg, x, y, 12, rl.Color{255, 235, 170, 245})
	}

	// ── Objective line (top-right, under key status) ──
	objective: cstring = ""
	if has_key {
		if current_level == NUM_LEVELS - 1 {
			objective = "OBJECTIVE: REACH THE EXIT"
		} else {
			objective = "OBJECTIVE: DESCEND TO LEVEL 24"
		}
	} else if current_level >= 5 {
		objective = "OBJECTIVE: FIND THE KEY"
	} else {
		objective = "OBJECTIVE: DESCEND DEEPER"
	}
	rl.DrawText(objective, i32(sw) - 230, 70, 10, rl.Color{180, 200, 220, 220})

	if current_objective.kind != .None {
		rl.DrawText(objective_hud_text(), i32(sw) - 300, 98, 10, rl.Color{255, 220, 130, 230})
		if task_exit_active {
			dx := f32(task_exit_cell[0]) * CELL + CELL / 2 - p.cam.position.x
			dz := f32(task_exit_cell[1]) * CELL + CELL / 2 - p.cam.position.z
			dist := i32(math.sqrt(dx * dx + dz * dz) + 0.5)
			rl.DrawText(
				fmt.ctprintf("FLOOR EXIT: %d m (GREEN DOOR, E)", dist),
				i32(sw) - 300,
				112,
				10,
				rl.Color{120, 255, 170, 235},
			)
		} else if !current_objective.done {
			item_dist := nearest_objective_item_dist(p)
			if item_dist >= 0 {
				rl.DrawText(
					fmt.ctprintf("TASK ITEM: %d m", i32(item_dist + 0.5)),
					i32(sw) - 300,
					112,
					10,
					rl.Color{255, 220, 130, 220},
				)
			}
		}
	}

	// ── Walkie-talike status (Phase 1.3) ──
	walkie_text: cstring = ""
	walkie_col := rl.Color{150, 190, 210, 220}
	if walkie_active {
		walkie_text = "WALKIE: BROADCASTING STATIC"
		walkie_col = rl.Color{255, 160, 120, 240}
	} else if walkie_dropped {
		walkie_text = "WALKIE: DROPPED (WALK BACK TO IT)"
		walkie_col = rl.Color{200, 170, 100, 220}
	} else if has_walkie {
		walkie_text = "Q: DROP WALKIE"
	}
	if walkie_active || walkie_dropped || has_walkie {
		rl.DrawText(walkie_text, i32(sw) - 260, 126, 10, walkie_col)
	}

	// ── Hiding status (Phase 1.4) ──
	if p.hiding {
		hidden := !in_light(p.cell_x, p.cell_z)
		hide_text: cstring = "CROUCHED - LIGHT EXPOSES YOU"
		hide_col := rl.Color{255, 190, 100, 230}
		if hidden {
			hide_text = "HIDDEN - ENTITIES LOSE YOUR TRAIL"
			hide_col = rl.Color{120, 240, 160, 240}
		}
		rl.DrawText(hide_text, 20, i32(sh) - 48, 10, hide_col)
	}

	// ── Key signal (distance only, so the key is findable without pixel
	// hunting). The risk is the trip, not the search. ──
	if !has_key && key_item.active {
		dx := key_item.pos[0] - p.cam.position.x
		dz := key_item.pos[2] - p.cam.position.z
		dist := i32(math.sqrt(dx * dx + dz * dz) + 0.5)
		rl.DrawText(
			fmt.ctprintf("KEY SIGNAL: %d m", dist),
			i32(sw) - 230,
			84,
			10,
			rl.Color{255, 215, 0, 220},
		)
	}

	// ── Debug overlay (F3) ──
	if rl.IsKeyDown(.F3) {
		md := rl.GetMouseDelta()
		rl.DrawRectangle(0, i32(sh / 2) + 70, 260, 74, rl.Color{0, 0, 0, 190})
		rl.DrawText(
			fmt.ctprintf("mouse delta: %.2f, %.2f", md.x, md.y),
			8,
			i32(sh / 2) + 76,
			10,
			rl.Color{120, 255, 120, 255},
		)
		rl.DrawText(
			fmt.ctprintf("cursor hidden: %v  focused: %v", rl.IsCursorHidden(), rl.IsWindowFocused()),
			8,
			i32(sh / 2) + 90,
			10,
			rl.Color{120, 255, 120, 255},
		)
		rl.DrawText(
			fmt.ctprintf("pos: %.1f, %.1f  cell: %d, %d", p.cam.position.x, p.cam.position.z, p.cell_x, p.cell_z),
			8,
			i32(sh / 2) + 104,
			10,
			rl.Color{120, 255, 120, 255},
		)
	}
}

draw_menu :: proc() {
	sw := f32(rl.GetScreenWidth())
	sh := f32(rl.GetScreenHeight())
	rl.ClearBackground(rl.Color{10, 10, 15, 255})

	rl.DrawText("NOCLIP", i32(sw / 2) - 100, i32(sh / 2) - 120, 40, rl.Color{220, 220, 220, 255})
	rl.DrawText("PS1 Backrooms", i32(sw / 2) - 80, i32(sh / 2) - 80, 20, rl.Color{160, 160, 180, 255})

	menu_items := [4]cstring{"CONTINUE", "NEW GAME", "OPTIONS", "QUIT"}
	save_exists := has_save()
	for i in 0 ..< 4 {
		ii := i32(i)
		col := rl.Color{255, 255, 255, 255}
		if ii == menu_selection {
			col = rl.Color{255, 215, 0, 255}
		}
		label := menu_items[i]
		if ii == 0 && !save_exists {
			label = "CONTINUE (NO SAVE)"
			if ii != menu_selection {
				col = rl.Color{100, 100, 110, 220}
			}
		}
		if ii == 2 {
			switch current_game_mode {
			case .Easy:
				label = "OPTIONS  < EASY >"
			case .Normal:
				label = "OPTIONS  < NORMAL >"
			case .Hard:
				label = "OPTIONS  < HARD >"
			}
		}
		rl.DrawText(label, i32(sw / 2) - 80, i32(sh / 2) - 20 + ii * 30, 20, col)
	}

	rl.DrawText("WASD move | Mouse look | Shift sprint | Ctrl hide | F flashlight | E interact", 20, i32(sh) - 34, 11, rl.Color{140, 140, 160, 220})
	rl.DrawText("Q drop walkie | ESC pause | Arrows look (fallback) | Key on levels 5-23 | Exit on 24", 20, i32(sh) - 18, 11, rl.Color{140, 140, 160, 220})
}

draw_pause :: proc() {
	sw := f32(rl.GetScreenWidth())
	sh := f32(rl.GetScreenHeight())
	rl.DrawRectangle(0, 0, i32(sw), i32(sh), rl.Color{0, 0, 0, 160})

	rl.DrawText("PAUSED", i32(sw / 2) - 60, i32(sh / 2) - 100, 30, rl.Color{255, 255, 255, 255})

	pause_items := [4]cstring{"RESUME", "GAME MODE", "SAVE GAME", "QUIT TO MENU"}
	for i in 0 ..< 4 {
		ii := i32(i)
		col := rl.Color{255, 255, 255, 255}
		if ii == pause_selection {
			col = rl.Color{255, 215, 0, 255}
		}
		rl.DrawText(pause_items[i], i32(sw / 2) - 80, i32(sh / 2) - 20 + ii * 35, 20, col)
	}

	mode_text := "MODE: NORMAL"
	if current_game_mode == .Easy {
		mode_text = "MODE: EASY"
	} else if current_game_mode == .Hard {
		mode_text = "MODE: HARD"
	}
	mode_full := fmt.ctprintf("Current mode: %s", mode_text)
	rl.DrawText(mode_full, i32(sw / 2) - 100, i32(sh / 2) + 140, 14, rl.Color{180, 180, 200, 220})

	// Save feedback.
	if save_feedback_t > 0 {
		msg: cstring = "SAVE FAILED"
		col := rl.Color{255, 120, 120, 255}
		if !game_settings.saving_allowed {
			msg = "SAVING IS DISABLED IN HARD MODE"
		} else if save_feedback_ok {
			msg = "GAME SAVED"
			col = rl.Color{120, 255, 160, 255}
		}
		rl.DrawText(msg, i32(sw / 2) - 130, i32(sh / 2) + 175, 14, col)
	}
}

draw_game_over :: proc() {
	sw := f32(rl.GetScreenWidth())
	sh := f32(rl.GetScreenHeight())
	rl.ClearBackground(rl.Color{20, 0, 0, 255})

	rl.DrawText("YOUR SANITY FRACTURED", i32(sw / 2) - 160, i32(sh / 2) - 60, 30, rl.Color{255, 255, 255, 255})
	rl.DrawText(fmt.ctprintf("Reached floor %d", current_level), i32(sw / 2) - 80, i32(sh / 2), 16, rl.Color{200, 200, 200, 255})
	rl.DrawText("Press any key to return to menu", i32(sw / 2) - 120, i32(sh / 2) + 60, 14, rl.Color{150, 150, 150, 200})
}

draw_win :: proc() {
	sw := f32(rl.GetScreenWidth())
	sh := f32(rl.GetScreenHeight())
	rl.ClearBackground(rl.Color{20, 20, 40, 255})

	rl.DrawText("YOU ESCAPED", i32(sw / 2) - 110, i32(sh / 2) - 60, 30, rl.Color{200, 220, 255, 255})
	rl.DrawText(fmt.ctprintf("Floors descended: %d", current_level), i32(sw / 2) - 80, i32(sh / 2), 16, rl.Color{200, 200, 200, 255})
	rl.DrawText("Press any key to return to menu", i32(sw / 2) - 120, i32(sh / 2) + 60, 14, rl.Color{150, 150, 150, 200})
}
