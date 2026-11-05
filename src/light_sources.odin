package main

import rl "vendor:raylib"

// Where lights are placed and what colour they are.

LIGHT_SPACING := [Biome_Type][2]i32 {
	.Mono_Yellow       = {2, 2},
	.Fluorescent_White = {2, 2},
	.Poolrooms         = {3, 3},
	.Concrete_Maze     = {3, 2},
	.Parking_Garage    = {2, 3},
	.Red_Rooms         = {3, 3},
	.Warehouse         = {4, 4},
	.Hotel_Corridor    = {3, 2},
	.Arcade_Night      = {2, 3},
	.Sub_Basement      = {3, 3},
}

light_power :: proc(x, z: i32) -> f32 {
	if _, has_link, _ := vertical_link_at(x, z); has_link do return 0
	sp := LIGHT_SPACING[biome_at(x, z)]
	if x %% sp.x != 0 || z %% sp.y != 0 do return 0
	if pillar_at(x, z) do return 0
	r := (raw_hash(x, z + 3001) >> 8) & 0xFF
	if r < 20 do return 0
	if r < 70 do return 0.5
	return 1
}

light_color :: proc(x, z: i32) -> rl.Color {
	b := biome_at(x, z)
	#partial switch b {
	case .Red_Rooms:
		return rl.Color{173, 30, 30, 255}
	case .Poolrooms:
		return rl.Color{180, 240, 255, 255}
	case .Arcade_Night:
		return rl.Color{255, 100, 255, 255}
	}
	return rl.Color{255, 245, 220, 255}
}
