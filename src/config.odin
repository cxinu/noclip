package main

import rl "vendor:raylib"

// ---- display ----
INTERNAL_W :: 320
INTERNAL_H :: 240
WINDOW_SCALE :: 3
WINDOW_TITLE :: "PS1 Base Engine"

// ---- look ----
FOG_COLOR :: rl.Color{12, 16, 28, 255}
WORLD_FOG :: [2]f32{6, 72}
SNAP :: 1.0
DEFAULT_COLOR_DEPTH :: 6

// ---- bloom ----
BLOOM_SCALE :: 4
BLOOM_THRESHOLD :: 0.5
BLOOM_STRENGTH :: 0.9

// ---- assets ----
SHADER_OBJ_VS :: "assets/shaders/ps1_obj.vs"
SHADER_OBJ_FS :: "assets/shaders/ps1_obj.fs"
SHADER_POST_FS :: "assets/shaders/ps1_post.fs"
SHADER_BLOOM_FS :: "assets/shaders/bloom.fs"

// ---- player ----
EYE_H :: 1.3
PLAYER_R :: 0.5
GRAVITY :: 26.0
JUMP_V :: 8.5
MOVE_SPEED :: 4.0
MOUSE_SENS :: 0.0028

STEP_UP_HEIGHT :: 0.55 // max vertical step the player can walk up
STEP_DOWN_SNAP :: 0.80 // while grounded, snap down to floor within this range
STEP_PROBE :: 0.30 // how far ahead we look for a wall-from-height
