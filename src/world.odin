package main

import "core:math"
import "core:time"
import rl "vendor:raylib"
import "vendor:raylib/rlgl"

// World container and chunk streaming: which chunks exist, what gets built next, drawing.

Chunk_Build_Stage :: enum {
	Idle,
	Light_Cache,
	Geometry,
	Upload,
}

Chunk_Key :: struct {
	x, z, floor: i32,
}

Chunk_Builder :: struct {
	active:      bool,
	coord:       Chunk_Coord,
	theme:       i32,
	floor:       i32,
	stage:       Chunk_Build_Stage,
	cache_index: int,
	cell_index:  int,
	verts:       Verts,
}

World :: struct {
	// Chunks are indexed in X/Z and physical floor. Mesh vertices themselves
	// are uploaded at their absolute world-space Y offset.
	chunks:   map[Chunk_Key]rl.Mesh,
	bounds:   map[Chunk_Key]rl.BoundingBox,
	material: rl.Material,
	builder:  Chunk_Builder,
}

chunk_key :: proc(c: Chunk_Coord, floor: i32) -> Chunk_Key {
	return Chunk_Key{x = c.x, z = c.y, floor = floor}
}

// CPU generation is time-sliced. A single cell is the smallest indivisible unit.
CHUNK_BUILD_BUDGET_US :: f64(9000.0) // per-frame slice when only other storeys are loading

URGENT_CHUNK_BUDGET_US :: f64(30000.0) // per-frame slice while the player's own ring has holes

world_init :: proc(shader: rl.Shader) -> World {
	w: World
	w.chunks = make(map[Chunk_Key]rl.Mesh)
	w.bounds = make(map[Chunk_Key]rl.BoundingBox)
	w.material = rl.LoadMaterialDefault()
	w.material.shader = shader
	return w
}

chunk_builder_cancel :: proc(b: ^Chunk_Builder) {
	delete(b.verts.pos)
	delete(b.verts.col)
	b^ = Chunk_Builder{}
}

world_destroy :: proc(w: ^World) {
	chunk_builder_cancel(&w.builder)
	for _, m in w.chunks {
		rl.UnloadMesh(m)
	}
	delete(w.chunks)
	delete(w.bounds)
}

// Pick the next chunk to build. Ring on the player's storey first; other
// storeys are ordered by distance, biased toward where the camera is looking
// (including up/down, so a stairwell or shaft you look into loads first).
pick_chunk_target :: proc(
	w: ^World,
	pc: Chunk_Coord,
	center_floor, floor_lo, floor_hi: i32,
	look: rl.Vector3,
) -> (
	target: Chunk_Coord,
	target_floor: i32,
	ok: bool,
) {
	fl := math.sqrt(look.x * look.x + look.z * look.z)
	fx, fz: f32
	if fl > 0.001 {fx, fz = look.x / fl, look.z / fl}

	best: f32 = 1e30
	for floor in floor_lo ..= floor_hi {
		vd := floor - center_floor
		vpen: f32 = 40
		// Looking toward that storey (up or down): treat it as nearly as urgent as ours.
		if vd != 0 && f32(vd) * look.y > 0.3 do vpen = 4
		for dz in -VIEW_RADIUS ..= VIEW_RADIUS {
			for dx in -VIEW_RADIUS ..= VIEW_RADIUS {
				c := Chunk_Coord{pc.x + i32(dx), pc.y + i32(dz)}
				if chunk_key(c, floor) in w.chunks do continue
				ahead := f32(dx) * fx + f32(dz) * fz
				score := f32(dx * dx + dz * dz) * 4 + f32(vd * vd) * vpen - ahead * 3
				if score < best {
					best = score
					target, target_floor, ok = c, floor, true
				}
			}
		}
	}
	return
}

world_update :: proc(w: ^World, pos: rl.Vector3, look_target: rl.Vector3) {
	pc := Chunk_Coord{i32(math.floor(pos.x / CHUNK_W)), i32(math.floor(pos.z / CHUNK_W))}
	center_floor := clamp(current_floor, 0, WORLD_FLOOR_COUNT - 1)
	floor_lo := max(0, center_floor - VERTICAL_VIEW_RADIUS)
	floor_hi := min(WORLD_FLOOR_COUNT - 1, center_floor + VERTICAL_VIEW_RADIUS)
	look := rl.Vector3Normalize(look_target - pos)

	// Drop a build that has fallen outside the streaming window.
	if w.builder.active {
		outside_horizontal :=
			abs(w.builder.coord.x - pc.x) > VIEW_RADIUS + 1 ||
			abs(w.builder.coord.y - pc.y) > VIEW_RADIUS + 1
		outside_vertical := w.builder.floor < floor_lo || w.builder.floor > floor_hi
		is_player_chunk :=
			w.builder.coord.x == pc.x && w.builder.coord.y == pc.y && w.builder.floor == center_floor
		player_chunk_missing := chunk_key(pc, center_floor) not_in w.chunks
		if outside_horizontal || outside_vertical || (player_chunk_missing && !is_player_chunk) {
			chunk_builder_cancel(&w.builder)
		}
	}

	// If any chunk of the player's own storey ring is missing, the player is
	// looking at holes: spend a large slice of the frame (accepting a brief
	// hitch) so it fills in at once. Other storeys fill with a smaller slice.
	ring_missing := false
	for dz in -VIEW_RADIUS ..= VIEW_RADIUS {
		for dx in -VIEW_RADIUS ..= VIEW_RADIUS {
			if chunk_key({pc.x + i32(dx), pc.y + i32(dz)}, center_floor) not_in w.chunks {
				ring_missing = true
			}
		}
	}
	budget_us := URGENT_CHUNK_BUDGET_US if ring_missing else CHUNK_BUILD_BUDGET_US

	// Build as many chunks as fit in the budget this frame: finish -> upload ->
	// pick the next one -> keep going, instead of one chunk per frame.
	start_tick := time.tick_now()
	did_work := false
	for {
		elapsed_us := time.duration_microseconds(time.tick_since(start_tick))
		if did_work && elapsed_us >= budget_us do break

		if w.builder.active && w.builder.stage == .Upload {
			key := chunk_key(w.builder.coord, w.builder.floor)
			mesh := chunk_builder_upload(&w.builder)
			w.chunks[key] = mesh
			w.bounds[key] = chunk_bounds(key)
			chunk_builder_cancel(&w.builder)
			did_work = true
			continue
		}

		if !w.builder.active {
			target, target_floor, ok := pick_chunk_target(w, pc, center_floor, floor_lo, floor_hi, look)
			if !ok do break // everything in the window is resident
			chunk_builder_begin(&w.builder, target, target_floor)
		}

		chunk_builder_step(&w.builder)
		did_work = true
	}

	// Unload at most one chunk outside the streaming window per frame.
	for key in w.chunks {
		outside_horizontal := abs(key.x - pc.x) > VIEW_RADIUS + 1 || abs(key.z - pc.y) > VIEW_RADIUS + 1
		outside_vertical := key.floor < floor_lo || key.floor > floor_hi
		if outside_horizontal || outside_vertical {
			rl.UnloadMesh(w.chunks[key])
			delete_key(&w.chunks, key)
			delete_key(&w.bounds, key)
			break
		}
	}
}

chunk_bounds :: proc(k: Chunk_Key) -> rl.BoundingBox {
	x0 := f32(k.x) * CHUNK_W
	z0 := f32(k.z) * CHUNK_W
	y0 := floor_world_offset(k.floor) - FLOOR_SPACING - 1
	y1 := floor_world_offset(k.floor) + FLOOR_SPACING + 8
	return {{x0 - 1, y0, z0 - 1}, {x0 + CHUNK_W + 1, y1, z0 + CHUNK_W + 1}}
}

// Cheap frustum-ish cull: the fog far plane is WORLD_FOG[1], and anything
// behind the camera plane can be skipped. Chunk AABB corners are tested
// against the view direction.
chunk_visible :: proc(bb: rl.BoundingBox, cam: rl.Camera3D) -> bool {
	fwd := rl.Vector3Normalize(cam.target - cam.position)
	far := f32(WORLD_FOG[1]) + 8
	// Nearest point of the box to the camera: distance cull.
	cp := cam.position
	nx := clamp(cp.x, bb.min.x, bb.max.x)
	ny := clamp(cp.y, bb.min.y, bb.max.y)
	nz := clamp(cp.z, bb.min.z, bb.max.z)
	dx, dy, dz := nx - cp.x, ny - cp.y, nz - cp.z
	if dx * dx + dy * dy + dz * dz > far * far do return false
	// Camera inside the box: always visible.
	if dx == 0 && dy == 0 && dz == 0 do return true
	// Behind-camera test using the box corner furthest along the view dir.
	best: f32 = -1e30
	for i in 0 ..< 8 {
		c := rl.Vector3 {
			bb.max.x if i & 1 != 0 else bb.min.x,
			bb.max.y if i & 2 != 0 else bb.min.y,
			bb.max.z if i & 4 != 0 else bb.min.z,
		}
		best = max(best, rl.Vector3DotProduct(c - cp, fwd))
	}
	return best > -2.0
}

world_draw :: proc(w: ^World, cam: rl.Camera3D) {
	rlgl.DisableBackfaceCulling()
	for k, m in w.chunks {
		if m.vertexCount == 0 do continue
		if bb, ok := w.bounds[k]; ok && !chunk_visible(bb, cam) do continue
		rl.DrawMesh(m, w.material, rl.Matrix(1))
	}
	rlgl.EnableBackfaceCulling()
}
