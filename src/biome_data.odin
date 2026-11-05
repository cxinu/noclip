package main

import rl "vendor:raylib"

// Biome / level tables: palettes, wall heights, biome-space prototypes.

Biome_Type :: enum {
	Mono_Yellow,
	Fluorescent_White,
	Poolrooms,
	Concrete_Maze,
	Parking_Garage,
	Red_Rooms,
	Warehouse,
	Hotel_Corridor,
	Arcade_Night,
	Sub_Basement,
}

Level_Def :: struct {
	name:     string,
	dominant: Biome_Type,
	bias:     f32,
}

LEVELS := [NUM_LEVELS]Level_Def {
	{"Lobby", .Mono_Yellow, 0.20},
	{"Habitable Zone", .Warehouse, 0.25},
	{"Pipe Dreams", .Sub_Basement, 0.25},
	{"Electrical Station", .Concrete_Maze, 0.25},
	{"Abandoned Office", .Fluorescent_White, 0.25},
	{"Terror Hotel", .Hotel_Corridor, 0.30},
	{"Lights Out", .Sub_Basement, 0.30},
	{"Thalassophobia", .Poolrooms, 0.30},
	{"Cave System", .Concrete_Maze, 0.30},
	{"The Suburbs", .Mono_Yellow, 0.15},
	{"Level 10", .Warehouse, 0.25},
	{"Level 11", .Concrete_Maze, 0.25},
	{"Level 12", .Parking_Garage, 0.25},
	{"Level 13", .Red_Rooms, 0.25},
	{"Level 14", .Arcade_Night, 0.25},
	{"Level 15", .Fluorescent_White, 0.25},
	{"Level 16", .Poolrooms, 0.25},
	{"Level 17", .Hotel_Corridor, 0.25},
	{"Level 18", .Sub_Basement, 0.25},
	{"Level 19", .Parking_Garage, 0.25},
	{"Level 20", .Warehouse, 0.25},
	{"Level 21", .Red_Rooms, 0.25},
	{"Level 22", .Arcade_Night, 0.25},
	{"Level 23", .Concrete_Maze, 0.25},
}

Palette :: struct {
	floor, wall, ceil: rl.Color,
}

PALETTES := [Biome_Type]Palette {
	.Mono_Yellow       = {{62, 57, 34, 255}, {85, 78, 48, 255}, {45, 42, 26, 255}},
	.Fluorescent_White = {{50, 53, 50, 255}, {72, 77, 72, 255}, {35, 38, 35, 255}},
	.Poolrooms         = {{35, 55, 58, 255}, {68, 92, 95, 255}, {24, 38, 40, 255}},
	.Concrete_Maze     = {{32, 33, 35, 255}, {55, 57, 61, 255}, {20, 21, 23, 255}},
	.Parking_Garage    = {{28, 29, 31, 255}, {48, 51, 56, 255}, {18, 19, 21, 255}},
	.Red_Rooms         = {{55, 22, 20, 255}, {84, 36, 33, 255}, {32, 12, 11, 255}},
	.Warehouse         = {{42, 38, 30, 255}, {66, 59, 47, 255}, {26, 23, 18, 255}},
	.Hotel_Corridor    = {{48, 40, 31, 255}, {74, 63, 50, 255}, {30, 25, 19, 255}},
	.Arcade_Night      = {{22, 20, 28, 255}, {45, 38, 55, 255}, {14, 12, 18, 255}},
	.Sub_Basement      = {{26, 24, 21, 255}, {46, 42, 37, 255}, {16, 14, 12, 255}},
}

WALL_HEIGHT := [Biome_Type]f32 {
	.Mono_Yellow       = 3.2,
	.Fluorescent_White = 3.4,
	.Poolrooms         = 4.8,
	.Concrete_Maze     = 3.2,
	.Parking_Garage    = 4.4,
	.Red_Rooms         = 3.0,
	.Warehouse         = 5.2,
	.Hotel_Corridor    = 2.9,
	.Arcade_Night      = 3.2,
	.Sub_Basement      = 2.6,
}

BIOME_SCALE :: 60.0

BIOME_CONTRAST :: 2.0

BLEND_MARGIN :: 0.35

Biome_Info :: struct {
	b, b2: Biome_Type,
	w:     f32,
}

BIOME_PROTO := [Biome_Type][2]f32 {
	.Mono_Yellow       = {0.50, 0.50},
	.Hotel_Corridor    = {0.92, 0.50},
	.Red_Rooms         = {0.82, 0.77},
	.Arcade_Night      = {0.57, 0.91},
	.Sub_Basement      = {0.29, 0.86},
	.Concrete_Maze     = {0.11, 0.64},
	.Poolrooms         = {0.11, 0.36},
	.Parking_Garage    = {0.29, 0.14},
	.Warehouse         = {0.57, 0.09},
	.Fluorescent_White = {0.82, 0.23},
}

BIOME_BIAS := [Biome_Type]f32 {
	.Mono_Yellow       = 0,
	.Fluorescent_White = 0,
	.Poolrooms         = 0,
	.Concrete_Maze     = 0,
	.Parking_Garage    = 0,
	.Red_Rooms         = 0,
	.Warehouse         = 0,
	.Hotel_Corridor    = 0,
	.Arcade_Night      = 0,
	.Sub_Basement      = 0,
}
