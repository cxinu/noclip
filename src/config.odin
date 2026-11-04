package main

import rl "vendor:raylib"

// ---- display ----
INTERNAL_W :: 320
INTERNAL_H :: 240
WINDOW_SCALE :: 3
WINDOW_TITLE :: "PS1 Base Engine"

// ---- look ----
FOG_COLOR :: rl.Color{10, 14, 25, 255}
WORLD_FOG :: [2]f32{5, 64}
SNAP :: 1.0 // vertex snap grid: 1.0 = one step per internal pixel
DEFAULT_COLOR_DEPTH :: 5 // bits per channel

// ---- bloom ----
BLOOM_SCALE :: 4 // bloom target is INTERNAL / BLOOM_SCALE
BLOOM_THRESHOLD :: 0.55
BLOOM_STRENGTH :: 0.85

// ---- assets ----
SHADER_OBJ_VS :: "assets/shaders/ps1_obj.vs"
SHADER_OBJ_FS :: "assets/shaders/ps1_obj.fs"
SHADER_POST_FS :: "assets/shaders/ps1_post.fs"
SHADER_BLOOM_FS :: "assets/shaders/bloom.fs"

// ---- world bounds ----
PLAY_HALF :: 150.0

// ---- player ----
EYE_H :: 1.7
PLAYER_R :: 0.5
GRAVITY :: 26.0
JUMP_V :: 8.0
MOVE_SPEED :: 4.5
MOUSE_SENS :: 0.003
