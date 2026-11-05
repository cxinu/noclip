package main



Game_State :: enum {
	Menu,
	Playing,
	Paused,
	Game_Over,
	Win,
}

Game_Mode :: enum {
	Easy,
	Normal,
	Hard,
}

Game_Settings :: struct {
	sanity_drain_base:   f32, // per second in light
	sanity_drain_dark:   f32, // multiplier in dark
	entity_spawn_chance: f32, // per second
	entity_speed:        f32, // movement speed
	battery_drain:       f32, // flashlight drain per second
	fall_damage:         bool,
	saving_allowed:      bool,
}

current_state: Game_State = .Menu
current_game_mode: Game_Mode = .Normal
game_settings: Game_Settings = Game_Settings{}
run_time: f32 = 0

// Grace timers prevent the first seconds of a run (or a level transition)
// from being lethal while the player orients themselves.
sanity_grace: f32 = 0
entity_grace: f32 = 0

menu_selection: i32 = 0 // 0: New Game, 1: Options, 2: Quit
pause_selection: i32 = 0 // 0: Resume, 1: Game Mode, 2: Save, 3: Quit to Menu

set_game_mode :: proc(mode: Game_Mode) {
	current_game_mode = mode
	switch mode {
	case .Easy:
		game_settings = Game_Settings{
			sanity_drain_base = 1.5, // ~89 s in darkness with the flashlight on
			sanity_drain_dark = 1.5,
			entity_spawn_chance = 0.04,
			entity_speed = 1.5,
			battery_drain = 0.3,
			fall_damage = false,
			saving_allowed = true,
		}
	case .Normal:
		game_settings = Game_Settings{
			sanity_drain_base = 3.0, // ~33 s in darkness with the flashlight on
			sanity_drain_dark = 2.0,
			entity_spawn_chance = 0.08,
			entity_speed = 2.0,
			battery_drain = 0.8,
			fall_damage = true,
			saving_allowed = true,
		}
	case .Hard:
		game_settings = Game_Settings{
			sanity_drain_base = 6.0, // ~11 s in darkness with the flashlight on
			sanity_drain_dark = 3.0,
			entity_spawn_chance = 0.14,
			entity_speed = 3.0,
			battery_drain = 1.5,
			fall_damage = true,
			saving_allowed = false,
		}
	}
}

init_game :: proc() {
	set_game_mode(.Normal)
	current_state = .Menu
	// Don't leave the cursor on a disabled "Continue" entry on first launch.
	menu_selection = has_save() ? 0 : 1
}
