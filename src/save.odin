package main

import "core:mem"
import "core:os"

// Saves are a fixed-layout binary blob. They are only written on modes where
// saving is allowed (Easy / Normal); Hard disables saving entirely.
SAVE_PATH :: "noclip_save.bin"
SAVE_MAGIC :: u32(0x4E4F434C) // "NOCL"
SAVE_VERSION :: u32(2)

Save_Data :: struct {
	magic:          u32,
	version:        u32,
	level:          i32,
	mode:           i32,
	pos_x, pos_z:   f32,
	feet_y:         f32,
	yaw, pitch:     f32,
	sanity:         f32,
	battery:        f32,
	flashlight_on:  u8,
	has_key:        u8,
	has_walkie:     u8,
	obj_kind:       i32,
	obj_progress:   i32,
	obj_done:       u8,
	_pad:           [3]u8,
}

save_feedback_t: f32 = 0
save_feedback_ok: bool = false

has_save :: proc() -> bool {
	return os.exists(SAVE_PATH)
}

save_game :: proc(p: ^Player) -> bool {
	sd := Save_Data {
		magic         = SAVE_MAGIC,
		version       = SAVE_VERSION,
		level         = current_level,
		mode          = i32(current_game_mode),
		pos_x         = p.cam.position.x,
		pos_z         = p.cam.position.z,
		feet_y        = p.feet_y,
		yaw           = p.yaw,
		pitch         = p.pitch,
		sanity        = sanity,
		battery       = flashlight_battery,
		flashlight_on = u8(flashlight_on ? 1 : 0),
		has_key       = u8(has_key ? 1 : 0),
		has_walkie    = u8(has_walkie ? 1 : 0),
		obj_kind      = i32(current_objective.kind),
		obj_progress  = current_objective.progress,
		obj_done      = u8(current_objective.done ? 1 : 0),
	}

	err := os.write_entire_file_from_bytes(SAVE_PATH, mem.ptr_to_bytes(&sd))
	ok := err == nil
	save_feedback_t = 2.0
	save_feedback_ok = ok
	return ok
}

load_game :: proc(p: ^Player) -> bool {
	data, err := os.read_entire_file_from_path(SAVE_PATH, context.temp_allocator)
	if err != nil do return false
	if len(data) < size_of(Save_Data) do return false

	sd := (^Save_Data)(raw_data(data))^
	if sd.magic != SAVE_MAGIC || sd.version != SAVE_VERSION do return false
	if sd.level < 0 || sd.level >= NUM_LEVELS do return false

	mode := clamp(i32(sd.mode), i32(Game_Mode.Easy), i32(Game_Mode.Hard))
	set_game_mode(Game_Mode(mode))

	// Rebuild the saved floor on the next world update.
	current_level = sd.level
	last_region = nil
	exit_cell_count = 0
	level_dirty = true

	sanity = clamp(sd.sanity, SANITY_MIN, SANITY_MAX)
	flashlight_battery = clamp(sd.battery, 0, flashlight_max_battery)
	flashlight_on = sd.flashlight_on != 0 && flashlight_battery > 0
	has_key = sd.has_key != 0
	key_item.active = false
	key_spawned = false

	has_walkie = sd.has_walkie != 0
	walkie_dropped = false
	walkie_active = false
	walkie_timer = 0

	objective_saved = {
		kind     = Objective_Kind(clamp(i32(sd.obj_kind), 0, 5)),
		progress = sd.obj_progress,
		done     = sd.obj_done != 0,
	}
	objective_pending_restore = objective_saved.kind != .None

	// Loop rooms and hallucinations are transient: a load starts clean.
	loop_active = false
	loop_gaze = 0
	loop_cooldown = 1.5
	loop_solved_count = 0

	p^ = player_init()
	p.cam.position.x = sd.pos_x
	p.cam.position.z = sd.pos_z
	p.feet_y = sd.feet_y
	p.eye_y = sd.feet_y + EYE_H
	p.cam.position.y = p.eye_y
	p.cell_x = cell_of(p.cam.position.x)
	p.cell_z = cell_of(p.cam.position.z)
	p.yaw = sd.yaw
	p.pitch = clamp(sd.pitch, -1.4, 1.4)
	p.warmup = 5

	init_entities()
	sanity_grace = 3.0
	entity_grace = 5.0
	return true
}
