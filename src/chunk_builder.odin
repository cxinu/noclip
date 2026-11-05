package main

import rl "vendor:raylib"

// Resumable, time-sliced chunk builder (light cache -> geometry -> GPU upload).

chunk_builder_begin :: proc(b: ^Chunk_Builder, c: Chunk_Coord, floor: i32) {
	chunk_builder_cancel(b)
	b.active = true
	b.coord = c
	b.floor = floor
	b.theme = floor
	b.stage = .Light_Cache
	b.cache_index = 0
	b.cell_index = 0
	light_grid_begin(c)
}

chunk_builder_step :: proc(b: ^Chunk_Builder) {
	// All existing world queries are floor-contextual globals. Only one builder
	// runs at a time, so scope them around this atomic slice and restore the
	// player's storey immediately afterwards.
	saved_floor, saved_level := current_floor, current_level
	current_floor, current_level = b.floor, b.theme

	switch b.stage {
	case .Light_Cache:
		i := b.cache_index % LIGHT_GRID_N
		j := b.cache_index / LIGHT_GRID_N
		light_grid_fill_cell(i, j)
		b.cache_index += 1
		if b.cache_index >= LIGHT_GRID_N * LIGHT_GRID_N {
			b.stage = .Geometry
		}

	case .Geometry:
		x := i32(b.cell_index % int(CHUNK_SIZE))
		z := i32(b.cell_index / int(CHUNK_SIZE))
		build_chunk_cell(&b.verts, b.coord, x, z)
		b.cell_index += 1
		if b.cell_index >= int(CHUNK_SIZE * CHUNK_SIZE) {
			b.stage = .Upload
		}

	case .Idle, .Upload:
	// Nothing to do in these stages.
	}

	current_floor, current_level = saved_floor, saved_level
}

chunk_builder_upload :: proc(b: ^Chunk_Builder) -> rl.Mesh {
	v := &b.verts
	n := len(v.col) / 4
	m := rl.Mesh {
		vertexCount   = i32(n),
		triangleCount = i32(n / 3),
	}

	if n > 0 {
		world_y := floor_world_offset(b.floor)
		for i := 1; i < len(v.pos); i += 3 {v.pos[i] += world_y}
		m.vertices = cast([^]f32)rl.MemAlloc(u32(len(v.pos) * size_of(f32)))
		m.colors = cast([^]u8)rl.MemAlloc(u32(len(v.col)))
		copy(m.vertices[:len(v.pos)], v.pos[:])
		copy(m.colors[:len(v.col)], v.col[:])
		rl.UploadMesh(&m, false)
	}

	return m
}

// Compatibility helper for tools that still request a fully built mesh directly.
// Normal gameplay should use world_update's time-sliced Chunk_Builder instead.
build_chunk :: proc(c: Chunk_Coord) -> rl.Mesh {
	b: Chunk_Builder
	chunk_builder_begin(&b, c, current_floor)

	for b.stage != .Upload {
		chunk_builder_step(&b)
	}

	m := chunk_builder_upload(&b)
	chunk_builder_cancel(&b)
	return m
}
