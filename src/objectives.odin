package main

import "core:fmt"
import "core:math"

// Phase 4: each notable floor gets a small task. Tasks are optional: they pay
// out sanity / battery and give the player something to do besides rushing the
// stairs. They also make the floors feel different from one another.
Objective_Kind :: enum {
	None,
	Glitch_Wall,
	Fuse_Boxes,
	Valves,
	Tapes,
	Torch_Fuel,
}

Objective_State :: struct {
	kind:     Objective_Kind,
	target:   i32,
	progress: i32,
	done:     bool,
}

current_objective: Objective_State
objective_pending_restore: bool
objective_saved: Objective_State

// Floor task exits. Completing a task opens a clear green door somewhere
// nearby; the stairs/holes still work, but the door is the obvious way on.
task_exit_active: bool
task_exit_announced: bool
task_exit_cell: [2]i32

init_objectives :: proc() {
	current_objective = {}
	objective_pending_restore = false
	objective_saved = {}
	task_exit_active = false
	task_exit_announced = false
}

objective_init_for_level :: proc(lvl: i32) {
	current_objective = {}
	task_exit_active = false
	task_exit_announced = false
	switch lvl {
	case 0:
		current_objective = {kind = .Glitch_Wall, target = 1}
	case 1:
		current_objective = {kind = .Fuse_Boxes, target = 3}
	case 2:
		current_objective = {kind = .Valves, target = 3}
	case 4:
		current_objective = {kind = .Tapes, target = 3}
	case 8:
		current_objective = {kind = .Torch_Fuel, target = 2}
	}
	torch_drain_mult = lvl == 8 ? 1.8 : 1.0
}

objective_item_type :: proc(kind: Objective_Kind) -> (Item_Type, bool) {
	switch kind {
	case .Fuse_Boxes:
		return .Fuse, true
	case .Valves:
		return .Valve, true
	case .Tapes:
		return .Tape, true
	case .Torch_Fuel:
		return .Battery, true
	case .None, .Glitch_Wall:
	}
	return .Key, false
}

spawn_objective_items :: proc(p: ^Player) {
	typ, ok := objective_item_type(current_objective.kind)
	if !ok || current_objective.done do return
	remaining := max(0, current_objective.target - current_objective.progress)
	for _ in 0 ..< remaining {
		spawn_random_item(p, typ, false)
	}
}

objective_restore_if_pending :: proc() {
	if !objective_pending_restore do return
	if objective_saved.kind == current_objective.kind && current_objective.kind != .None {
		current_objective.progress = clamp(
			objective_saved.progress,
			0,
			current_objective.target,
		)
		current_objective.done = objective_saved.done ||
			current_objective.progress >= current_objective.target
	}
	objective_pending_restore = false
}

objective_reward :: proc() {
	current_objective.done = true
	sanity_heal(15.0)
	flashlight_recharge(25.0)
	set_event("FLOOR TASK COMPLETE - YOU FEEL STEADIER", 3.5)
}

objective_collect :: proc(typ: Item_Type) {
	if current_objective.done do return
	matched := false
	switch current_objective.kind {
	case .Fuse_Boxes:
		matched = typ == .Fuse
	case .Valves:
		matched = typ == .Valve
	case .Tapes:
		matched = typ == .Tape
	case .Torch_Fuel:
		matched = typ == .Battery
	case .None, .Glitch_Wall:
	}
	if !matched do return

	current_objective.progress += 1
	if current_objective.progress >= current_objective.target {
		objective_reward()
	} else {
		set_event("TASK PROGRESS RECORDED", 1.5)
	}
}

objective_glitch_used :: proc() {
	if current_objective.kind != .Glitch_Wall || current_objective.done do return
	current_objective.progress = 1
	objective_reward()
}

// Pick a nearby safe cell for the task exit door.
find_task_exit_cell :: proc(p: ^Player) -> [2]i32 {
	for radius in 5 ..= 12 {
		for k in 0 ..< 12 {
			ang := f32(k) * (math.TAU / 12.0) + f32(current_level) * 0.7
			x := p.cell_x + i32(math.round(math.cos(ang) * f32(radius)))
			z := p.cell_z + i32(math.round(math.sin(ang) * f32(radius)))
			if x == p.cell_x && z == p.cell_z do continue
			if hole_at(x, z) || stair_at(x, z) || pillar_at(x, z) || exit_at(x, z) do continue
			if floor_level(x, z) != 0 do continue
			return {x, z}
		}
	}
	return {p.cell_x, p.cell_z}
}

// Called every frame (and after a load) so a completed task always has a
// visible way onward.
objective_update_exit :: proc(p: ^Player) {
	if current_objective.kind == .None || current_objective.kind == .Glitch_Wall do return
	if !current_objective.done || task_exit_active do return
	task_exit_cell = find_task_exit_cell(p)
	task_exit_active = true
	if !task_exit_announced {
		task_exit_announced = true
		set_event("TASK COMPLETE - A FLOOR EXIT OPENED NEARBY", 4.5)
	}
}

use_task_exit :: proc(p: ^Player) -> bool {
	if !task_exit_active do return false
	p.fade = 1.0
	set_level(current_level + 1)
	nx, nz := safe_landing(p.cell_x, p.cell_z)
	p.cell_x, p.cell_z = nx, nz
	p.cam.position.x = (f32(nx) + 0.5) * CELL
	p.cam.position.z = (f32(nz) + 0.5) * CELL
	p.feet_y = floor_h(nx, nz)
	p.eye_y = p.feet_y + EYE_H
	p.cam.position.y = p.eye_y
	p.pending = 0
	p.vel_y = 0
	p.grounded = true
	p.grace = 0.8
	task_exit_active = false
	set_event("YOU DESCEND THROUGH THE FLOOR EXIT", 3.0)
	return true
}

nearest_objective_item_dist :: proc(p: ^Player) -> f32 {
	typ, ok := objective_item_type(current_objective.kind)
	if !ok || current_objective.done do return -1
	best: f32 = 9999.0
	for i in 0 ..< MAX_ITEMS {
		it := &items[i]
		if !it.active || it.fake || it.typ != typ do continue
		dx := it.pos[0] - p.cam.position.x
		dz := it.pos[2] - p.cam.position.z
		d := math.sqrt(dx * dx + dz * dz)
		if d < best do best = d
	}
	if best >= 9999.0 do return -1
	return best
}

objective_label :: proc(kind: Objective_Kind) -> string {
	switch kind {
	case .Glitch_Wall:
		return "FIND THE GLITCHED WALL"
	case .Fuse_Boxes:
		return "RESTORE THE FUSES"
	case .Valves:
		return "SHUT THE STEAM VALVES"
	case .Tapes:
		return "RECOVER THE TAPES"
	case .Torch_Fuel:
		return "SCAVENGE TORCH FUEL"
	case .None:
	}
	return ""
}

objective_hud_text :: proc() -> cstring {
	if current_objective.kind == .None do return ""
	label := objective_label(current_objective.kind)
	if current_objective.done {
		return fmt.ctprintf("TASK DONE: %s", label)
	}
	return fmt.ctprintf(
		"TASK: %s  %d/%d",
		label,
		current_objective.progress,
		current_objective.target,
	)
}
