package main

SANITY_MAX :: 100.0
SANITY_MIN :: 0.0

sanity: f32 = SANITY_MAX
flashlight_on: bool = true
flashlight_battery: f32 = 100.0
flashlight_max_battery: f32 = 100.0
torch_drain_mult: f32 = 1.0

// in_dark: the current cell has no ceiling light.
// has_flashlight: the player's flashlight is on and has charge.
// The flashlight halves the dark penalty but does not remove it.
sanity_drain :: proc(dt: f32, in_dark: bool, has_flashlight: bool) {
	if in_dark {
		s := game_settings.sanity_drain_base * dt * game_settings.sanity_drain_dark
		if has_flashlight {
			s *= 0.5
		}
		sanity = clamp(sanity - s, SANITY_MIN, SANITY_MAX)
	} else {
		// Standing in a lit pocket slowly restores sanity.
		sanity = clamp(sanity + 0.8 * dt, SANITY_MIN, SANITY_MAX)
	}

	// Battery drain only while the light is on.
	if flashlight_on {
		flashlight_battery = clamp(
			flashlight_battery - game_settings.battery_drain * torch_drain_mult * dt,
			0,
			flashlight_max_battery,
		)
		if flashlight_battery <= 0 {
			flashlight_on = false
		}
	}
}

sanity_heal :: proc(amount: f32) {
	sanity = clamp(sanity + amount, SANITY_MIN, SANITY_MAX)
}

sanity_damage :: proc(amount: f32) {
	sanity = clamp(sanity - amount, SANITY_MIN, SANITY_MAX)
}

// Phase 1.1: proximity pressure. Being near an active Wanderer eats sanity
// even before it touches you. Phantoms are ignored.
sanity_drain_near_entity :: proc(dist: f32, dt: f32) {
	if dist >= 8.0 do return
	f := (8.0 - dist) / 8.0
	sanity_damage((1.5 + 5.0 * f) * dt)
}

flashlight_recharge :: proc(amount: f32) {
	flashlight_battery = clamp(flashlight_battery + amount, 0, flashlight_max_battery)
	if flashlight_battery > 0 {
		flashlight_on = true
	}
}

sanity_is_low :: proc() -> bool {
	return sanity < 30.0
}

sanity_is_critical :: proc() -> bool {
	return sanity < 15.0
}

toggle_flashlight :: proc() {
	if flashlight_battery > 0 {
		flashlight_on = !flashlight_on
	}
}
