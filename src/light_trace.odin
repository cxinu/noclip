package main

import "core:math"

// Visibility rays: DDA through the cached walls, floor slabs, stairs and slide shells.

CEIL_SLACK :: 0.35

// Sloped side rails are finite volumes, not ordinary wall-cache spans.
light_slide_cheek_hit :: proc(
	l: Vertical_Link,
	side: u8,
	wx, wz: i32,
	y, along, y_offset, along_margin, height_margin: f32,
) -> bool {
	if l.kind != .Slide || link_boundary_open(l, .Upper, side, wx, wz) do return false
	start := f32(wx) * CELL if side < 2 else f32(wz) * CELL
	finish := start + CELL
	half: f32 = WALL_T * 0.5
	if along < start - half - along_margin || along > finish + half + along_margin do return false
	sample := clamp(along, start, finish)
	sx, sz: f32
	switch side {
	case 0: sx, sz = sample, f32(wz) * CELL
	case 1: sx, sz = sample, f32(wz + 1) * CELL
	case 2: sx, sz = f32(wx + 1) * CELL, sample
	case 3: sx, sz = f32(wx) * CELL, sample
	}
	surface := link_surface_local(l, .Upper, sx, sz)
	local_y := y - y_offset
	room_top: f32 = 0
	switch side {
	case 0: room_top = north_wall_height(wx, wz)
	case 1: room_top = north_wall_height(wx, wz + 1)
	case 2: room_top = west_wall_height(wx + 1, wz)
	case 3: room_top = west_wall_height(wx, wz)
	}
	// emit_upper_link_side also fills the cheek from the rail to the adjacent
	// room-wall top. Include that extension in the light blocker as well.
	cheek_top := max(surface + LINK_RAIL_HEIGHT, room_top)
	return local_y + height_margin >= surface - LINK_SHELL_THICKNESS && local_y - height_margin <= cheek_top
}

// The slide mouth is an exposed cross-section of the 18 cm chute shell.
// It remains traversable for the player, but it is still an opaque surface to
// baked-light rays. This is distinct from the raised side cheeks.
light_slide_mouth_hit :: proc(
	l: Vertical_Link,
	side: u8,
	wx, wz: i32,
	y, along, y_offset, along_margin, height_margin: f32,
) -> bool {
	if l.kind != .Slide || !link_boundary_open(l, .Upper, side, wx, wz) do return false
	start := f32(wx) * CELL if side < 2 else f32(wz) * CELL
	finish := start + CELL
	if along < start - along_margin || along > finish + along_margin do return false
	sample := clamp(along, start, finish)
	sx, sz: f32
	switch side {
	case 0: sx, sz = sample, f32(wz) * CELL
	case 1: sx, sz = sample, f32(wz + 1) * CELL
	case 2: sx, sz = f32(wx + 1) * CELL, sample
	case 3: sx, sz = f32(wx) * CELL, sample
	}
	surface := link_surface_local(l, .Upper, sx, sz)
	local_y := y - y_offset
	return local_y + height_margin >= surface - LINK_SHELL_THICKNESS && local_y - height_margin <= surface
}

// Test the sloped slide cheek at one world-space grid edge. The upper-storey
// context is searched as well as the current and lower storeys, because the
// mesh for a slide belongs to its upper floor.
light_slide_edge_blocks_w :: proc(x, z: i32, y, along, along_margin, height_margin: f32) -> bool {
	base_floor := current_floor
	base_theme := current_level
	for layer in 0 ..< LIGHT_FLOOR_COUNT {
		source_floor := base_floor + i32(layer) - LIGHT_FLOOR_PAD
		if source_floor < 0 || source_floor >= WORLD_FLOOR_COUNT do continue
		current_floor, current_level = source_floor, source_floor
		y_offset := f32(source_floor - base_floor) * FLOOR_SPACING
		if l, ok, role := vertical_link_at(x, z); ok && role == .Upper && l.x == x {
			if light_slide_cheek_hit(l, 3, x, z, y, along, y_offset, along_margin, height_margin) ||
			   light_slide_mouth_hit(l, 3, x, z, y, along, y_offset, along_margin, height_margin) {
				current_floor, current_level = base_floor, base_theme
				return true
			}
		}
		if l, ok, role := vertical_link_at(x - 1, z); ok && role == .Upper && l.x + l.w == x {
			if light_slide_cheek_hit(l, 2, x - 1, z, y, along, y_offset, along_margin, height_margin) ||
			   light_slide_mouth_hit(l, 2, x - 1, z, y, along, y_offset, along_margin, height_margin) {
				current_floor, current_level = base_floor, base_theme
				return true
			}
		}
	}
	current_floor, current_level = base_floor, base_theme
	return false
}

light_slide_edge_blocks_n :: proc(x, z: i32, y, along, along_margin, height_margin: f32) -> bool {
	base_floor := current_floor
	base_theme := current_level
	for layer in 0 ..< LIGHT_FLOOR_COUNT {
		source_floor := base_floor + i32(layer) - LIGHT_FLOOR_PAD
		if source_floor < 0 || source_floor >= WORLD_FLOOR_COUNT do continue
		current_floor, current_level = source_floor, source_floor
		y_offset := f32(source_floor - base_floor) * FLOOR_SPACING
		if l, ok, role := vertical_link_at(x, z); ok && role == .Upper && l.z == z {
			if light_slide_cheek_hit(l, 0, x, z, y, along, y_offset, along_margin, height_margin) ||
			   light_slide_mouth_hit(l, 0, x, z, y, along, y_offset, along_margin, height_margin) {
				current_floor, current_level = base_floor, base_theme
				return true
			}
		}
		if l, ok, role := vertical_link_at(x, z - 1); ok && role == .Upper && l.z + l.d == z {
			if light_slide_cheek_hit(l, 1, x, z - 1, y, along, y_offset, along_margin, height_margin) ||
			   light_slide_mouth_hit(l, 1, x, z - 1, y, along, y_offset, along_margin, height_margin) {
				current_floor, current_level = base_floor, base_theme
				return true
			}
		}
	}
	current_floor, current_level = base_floor, base_theme
	return false
}

edge_blocks_w :: proc(x, z: i32, y, along, along_margin, height_margin: f32) -> bool {
	if light_slide_edge_blocks_w(x, z, y, along, along_margin, height_margin) do return true
	for layer in 0 ..< LIGHT_FLOOR_COUNT {
		if edge_blocks(y, along, edge_base_w(x, z, layer), edge_top_w(x, z, layer), edge_door_w(x, z, layer), along_margin, height_margin) do return true
	}
	return false
}

edge_blocks_n :: proc(x, z: i32, y, along, along_margin, height_margin: f32) -> bool {
	if light_slide_edge_blocks_n(x, z, y, along, along_margin, height_margin) do return true
	for layer in 0 ..< LIGHT_FLOOR_COUNT {
		if edge_blocks(y, along, edge_base_n(x, z, layer), edge_top_n(x, z, layer), edge_door_n(x, z, layer), along_margin, height_margin) do return true
	}
	return false
}

// Test a ray against a wall segment.
// If the crossing point is inside a doorway and below its lintel,
// the ray passes through.

edge_blocks :: proc(
	y, along, bottom, top: f32,
	door: Door_Opening,
	along_margin, height_margin: f32,
) -> bool {
	if top <= bottom || y < bottom || y >= top do return false

	in_door_width :=
		door.valid && along > door.min + along_margin && along < door.max - along_margin

	in_door_height := door.valid && y - height_margin >= bottom && y + height_margin < door.top

	if in_door_width && in_door_height do return false

	return true
}

// Segment/plane crossing, with a small tolerance to avoid self-shadowing at
// the sampled mesh vertex.
crosses_plane :: proc(a, b, plane, eps: f32) -> bool {
	return (a < plane - eps && b > plane + eps) || (a > plane + eps && b < plane - eps)
}

// Intersect a ray segment with a linearly varying vertical slab. All values
// are endpoint heights; clipping the segment parameter against both slab
// inequalities catches thin surfaces and grazing intersections that a
// midpoint-only test misses.
segment_overlaps_y_slab :: proc(
	y0, y1, bottom0, bottom1, top0, top1, eps: f32,
) -> bool {
	lo, hi: f32 = 0, 1

	above0, above1 := y0 - bottom0 + eps, y1 - bottom1 + eps
	if above0 < 0 && above1 < 0 do return false
	if above0 < 0 || above1 < 0 {
		t := clamp(above0 / (above0 - above1), 0, 1)
		if above0 < 0 {lo = max(lo, t)} else {hi = min(hi, t)}
	}

	below0, below1 := top0 - y0 + eps, top1 - y1 + eps
	if below0 < 0 && below1 < 0 do return false
	if below0 < 0 || below1 < 0 {
		t := clamp(below0 / (below0 - below1), 0, 1)
		if below0 < 0 {lo = max(lo, t)} else {hi = min(hi, t)}
	}
	return lo <= hi + 1e-5
}

// Stair treads are quantized rather than planar. Subdivide each DDA cell
// segment more finely than the six treads per cell so the light ray is tested
// against each actual tread/riser band instead of one averaged midpoint.
segment_hits_stair_solid :: proc(
	l: Vertical_Link,
	role: Link_Role,
	ax, ay, az, bx, by, bz, bottom: f32,
) -> bool {
	steps := STAIR_STEPS * 4
	for i in 0 ..< steps {
		t0, t1 := f32(i) / f32(steps), f32(i + 1) / f32(steps)
		tm := (t0 + t1) * 0.5
		mx, mz := ax + (bx-ax)*tm, az + (bz-az)*tm
		top := link_surface_local(l, role, mx, mz)
		y0 := ay + (by-ay)*t0
		y1 := ay + (by-ay)*t1
		if segment_overlaps_y_slab(y0, y1, bottom, bottom, top, top, 0.01) do return true
	}
	return false
}

// Test a complete DDA cell segment against floor slabs and link solids in the
// lower/current/upper floor contexts. Coordinates passed here are relative to
// the chunk floor; each query converts them into the selected storey's local Y.
link_blocks_light_segment :: proc(
	ax, ay, az, bx, by, bz: f32,
) -> bool {
	base_floor, base_theme := current_floor, current_level
	eps: f32 = 0.025
	mx, mz := (ax + bx) * 0.5, (az + bz) * 0.5

	for layer in 0 ..< LIGHT_FLOOR_COUNT {
		source_floor := base_floor + i32(layer) - LIGHT_FLOOR_PAD
		if source_floor < 0 || source_floor >= WORLD_FLOOR_COUNT do continue
		y_offset := floor_world_offset(source_floor) - floor_world_offset(base_floor)
		current_floor, current_level = source_floor, source_floor

		cx, cz := i32(math.floor(mx / CELL)), i32(math.floor(mz / CELL))
		l, has_link, role := vertical_link_at(cx, cz)
		y0, y1 := ay - y_offset, by - y_offset
		blocked := false
		if !has_link {
			g0 := ground_local_at(ax, az)
			g1 := ground_local_at(bx, bz)
			blocked = crosses_plane(y0 - g0, y1 - g1, 0, eps)
		} else {
			s0 := link_surface_local(l, role, ax, az)
			s1 := link_surface_local(l, role, bx, bz)
			switch l.kind {
			case .Stairs, .Switchback, .Ramp:
				if l.kind == .Ramp {
					if role == .Lower {
						blocked = segment_overlaps_y_slab(y0, y1, -0.02, -0.02, s0, s1, eps)
					} else if role == .Upper {
						bottom: f32 = -f32(FLOOR_SPACING)
						blocked = segment_overlaps_y_slab(y0, y1, bottom, bottom, s0, s1, eps)
					}
				} else {
					if role == .Lower {
						blocked = segment_hits_stair_solid(l, role, ax, y0, az, bx, y1, bz, -0.02)
					} else if role == .Upper {
						bottom: f32 = -f32(FLOOR_SPACING)
						blocked = segment_hits_stair_solid(l, role, ax, y0, az, bx, y1, bz, bottom)
					}
				}
			case .Slide:
				if role == .Upper {
					// The chute shell is the slab between its top plane and its
					// 18 cm underside. Intersect both linearly varying bounds.
					blocked = segment_overlaps_y_slab(
						y0, y1,
						s0 - LINK_SHELL_THICKNESS, s1 - LINK_SHELL_THICKNESS,
						s0, s1, eps,
					)
				}
				if role == .Lower {blocked = crosses_plane(y0, y1, 0, eps)}
			case .Drop:
				if role == .Upper {blocked = crosses_plane(y0, y1, -f32(FLOOR_SPACING), eps)}
				if role == .Lower {blocked = crosses_plane(y0, y1, 0, eps)}
			}
		}
		current_floor, current_level = base_floor, base_theme
		if blocked do return true
	}
	return false
}

// DDA visibility ray traversal. Wall spans from all three resident floor
// contexts are tested at each crossing, so a chute cheek cannot leak light
// simply because its owning mesh belongs to the adjacent storey.
light_blocked :: proc(ax, ay, az, bx, by, bz: f32) -> bool {
	pax, paz := ax / CELL, az / CELL
	pbx, pbz := bx / CELL, bz / CELL
	cx := i32(math.floor(pax))
	cz := i32(math.floor(paz))
	dx := pbx - pax
	dz := pbz - paz
	step_x := dx > 0 ? i32(1) : (dx < 0 ? i32(-1) : i32(0))
	step_z := dz > 0 ? i32(1) : (dz < 0 ? i32(-1) : i32(0))
	inf: f32 = 1e30
	t_max_x, t_max_z := inf, inf
	t_delta_x, t_delta_z := inf, inf
	if step_x != 0 {
		next_x := f32(cx + (step_x > 0 ? 1 : 0))
		t_max_x = (next_x - pax) / dx
		t_delta_x = 1.0 / math.abs(dx)
	}
	if step_z != 0 {
		next_z := f32(cz + (step_z > 0 ? 1 : 0))
		t_max_z = (next_z - paz) / dz
		t_delta_z = 1.0 / math.abs(dz)
	}

	t_enter: f32 = 0
	for _ in 0 ..< 2 * LIGHT_PAD + 2 {
		cross_x := t_max_x <= t_max_z
		cross_z := t_max_z <= t_max_x
		t := min(t_max_x, t_max_z)
		t_exit := min(t, 1.0)
		if t_exit > t_enter {
			sx := ax + (bx - ax) * t_enter
			sy := ay + (by - ay) * t_enter
			sz := az + (bz - az) * t_enter
			ex := ax + (bx - ax) * t_exit
			ey := ay + (by - ay) * t_exit
			ez := az + (bz - az) * t_exit
			if link_blocks_light_segment(sx, sy, sz, ex, ey, ez) do return true
		}
		if t > 1.0 do break
		y := ay + (by - ay) * t
		// Test the air gap above each floor's ceiling, but not the interior of
		// the storey above it. Link cells cache a very high ceiling to mark holes.
		for layer in 0 ..< LIGHT_FLOOR_COUNT {
			floor_offset := f32(i32(layer) - LIGHT_FLOOR_PAD) * FLOOR_SPACING
			next_floor_y := floor_offset + FLOOR_SPACING
			if y > ceil_top(cx, cz, layer) + CEIL_SLACK && y < next_floor_y - 0.02 do return true
		}

		hit_x := ax + (bx - ax) * t
		hit_z := az + (bz - az) * t
		ray_dx := bx - ax
		ray_dy := by - ay
		ray_dz := bz - az
		half_wall: f32 = WALL_T * 0.5
		west_den := max(abs(ray_dx), 0.0001)
		north_den := max(abs(ray_dz), 0.0001)
		west_along_margin := half_wall * abs(ray_dz) / west_den + 0.02
		west_height_margin := half_wall * abs(ray_dy) / west_den + 0.02
		north_along_margin := half_wall * abs(ray_dx) / north_den + 0.02
		north_height_margin := half_wall * abs(ray_dy) / north_den + 0.02
		nx := cx + (cross_x ? step_x : 0)
		nz := cz + (cross_z ? step_z : 0)

		if cross_x {
			edge_x := step_x > 0 ? nx : nx + 1
			if edge_blocks_w(edge_x, cz, y, hit_z, west_along_margin, west_height_margin) do return true
			if cross_z && edge_blocks_w(edge_x, nz, y, hit_z, west_along_margin, west_height_margin) do return true
		}
		if cross_z {
			edge_z := step_z > 0 ? nz : nz + 1
			if edge_blocks_n(cx, edge_z, y, hit_x, north_along_margin, north_height_margin) do return true
			if cross_x && edge_blocks_n(nx, edge_z, y, hit_x, north_along_margin, north_height_margin) do return true
		}
		cx, cz = nx, nz
		t_enter = t
		if cross_x do t_max_x += t_delta_x
		if cross_z do t_max_z += t_delta_z
	}
	return false
}
