package main

// Custom FK-link drawing: routes each link's curve around any visible table
// it would otherwise cross, and draws crow's-foot-notation cardinality
// glyphs at each end. Deliberately doesn't use ImNodes' own Link() — that
// draws a fixed two-point bezier with no obstacle awareness at all — but
// stays entirely on top of ImNodes' public Odin bindings (DrawList_* and
// the node/pin geometry the render loop already captures each frame), per
// this project's rule of never touching the vendored ImGui/ImNodes source
// (see AGENTS.md). Everything here is recomputed fresh every frame from
// what ImNodes just drew, the same way the rest of the diagram already
// mirrors live positions back — so panning, dragging a node, and re-laying
// out the view all just work without any extra plumbing.

import "core:math"
import "core:sort"
import ig "vendor/imgui"

Rect2 :: struct {
	min, max: ig.Vec2,
}

rect2_contains :: proc(r: Rect2, p: ig.Vec2) -> bool {
	return p.x >= r.min.x && p.x <= r.max.x && p.y >= r.min.y && p.y <= r.max.y
}

// Ports ImNodes' own link-hover hit test (RectangleOverlapsLineSegment in
// vendor/imgui/imnodes.cpp) rather than re-deriving it from scratch, so
// "does this segment cross this table" agrees with how ImNodes itself
// reasons about link/rect overlap.
rect2_overlaps_segment :: proc(r: Rect2, p1, p2: ig.Vec2) -> bool {
	if rect2_contains(r, p1) || rect2_contains(r, p2) {
		return true
	}
	if (p1.x < r.min.x && p2.x < r.min.x) ||
	   (p1.x > r.max.x && p2.x > r.max.x) ||
	   (p1.y < r.min.y && p2.y < r.min.y) ||
	   (p1.y > r.max.y && p2.y > r.max.y) {
		return false
	}
	corners := [4]ig.Vec2{r.min, {r.max.x, r.min.y}, {r.min.x, r.max.y}, r.max}
	sign_sum, sign_abs_sum: int
	for c in corners {
		v := (p2.y - p1.y) * (c.x - p1.x) - (p2.x - p1.x) * (c.y - p1.y)
		s := 0
		if v > 1e-6 {
			s = 1
		} else if v < -1e-6 {
			s = -1
		}
		sign_sum += s
		sign_abs_sum += abs(s)
	}
	return sign_sum != sign_abs_sum
}

// Same construction as ImNodes' own link curve (GetCubicBezier in
// imnodes.cpp): control points offset purely along x by a quarter of the
// pin-to-pin distance. Kept identical so a link with a clear path looks
// exactly as it always has.
sample_direct_curve :: proc(p0, p3: ig.Vec2, out: []ig.Vec2) {
	dx := p3.x - p0.x
	dy := p3.y - p0.y
	length := math.sqrt(dx * dx + dy * dy)
	offset := 0.25 * length
	p1 := ig.Vec2{p0.x + offset, p0.y}
	p2 := ig.Vec2{p3.x - offset, p3.y}
	n := len(out)
	for i in 0 ..< n {
		t := f32(i) / f32(n - 1)
		mt := 1 - t
		a := mt * mt * mt
		b := 3 * mt * mt * t
		c := 3 * mt * t * t
		d := t * t * t
		out[i] = ig.Vec2 {
			a * p0.x + b * p1.x + c * p2.x + d * p3.x,
			a * p0.y + b * p1.y + c * p2.y + d * p3.y,
		}
	}
}

ROUTING_SAMPLE_COUNT :: 20
RoutingSamples :: [ROUTING_SAMPLE_COUNT]ig.Vec2

LINK_ROUTE_MARGIN :: 14.0
LINK_ROUTE_MAX_OBSTACLES :: 4

Obstacle :: struct {
	rect:     Rect2,
	center_x: f32,
}

compare_obstacles :: proc(a, b: Obstacle) -> int {
	if a.center_x < b.center_x {
		return -1
	}
	if a.center_x > b.center_x {
		return 1
	}
	return 0
}

// Finds every table rect (other than the link's own two endpoint tables)
// that the direct p0->p3 curve actually crosses, ordered left to right.
find_obstacles :: proc(
	p0, p3: ig.Vec2,
	node_rects: map[GlobalTableIndex]Rect2,
	exclude_a, exclude_b: GlobalTableIndex,
) -> [dynamic]Obstacle {
	samples: RoutingSamples
	sample_direct_curve(p0, p3, samples[:])

	obstacles := make([dynamic]Obstacle, 0, 4, context.temp_allocator)
	for table_idx, rect in node_rects {
		if table_idx == exclude_a || table_idx == exclude_b {
			continue
		}
		hit := false
		for i in 0 ..< len(samples) - 1 {
			if rect2_overlaps_segment(rect, samples[i], samples[i + 1]) {
				hit = true
				break
			}
		}
		if hit {
			append(&obstacles, Obstacle{rect = rect, center_x = (rect.min.x + rect.max.x) * 0.5})
		}
	}
	sort.merge_sort_proc(obstacles[:], compare_obstacles)
	return obstacles
}

// Greedy single-pass detour: for each obstacle the direct path crosses,
// left to right, adds a waypoint pair that bumps the path above or below
// it — whichever side is closer to the path's height at that point — with
// a small clearance margin. Doesn't re-check the detoured path against
// further obstacles, so a dense cluster of overlapping tables can still
// leave a residual close call; that's a deliberate simplicity tradeoff, and
// still a large improvement over drawing straight through every one of
// them. Obstacle count is capped since a table with dozens of crossed
// neighbours (a heavily-shared hub's neighbourhood) would otherwise produce
// a waypoint list long enough to zigzag rather than clarify.
route_link_waypoints :: proc(
	p0, p3: ig.Vec2,
	node_rects: map[GlobalTableIndex]Rect2,
	exclude_a, exclude_b: GlobalTableIndex,
) -> [dynamic]ig.Vec2 {
	obstacles := find_obstacles(p0, p3, node_rects, exclude_a, exclude_b)
	waypoints := make([dynamic]ig.Vec2, 0, 2 * len(obstacles), context.temp_allocator)
	if len(obstacles) == 0 {
		return waypoints
	}

	count := min(len(obstacles), LINK_ROUTE_MAX_OBSTACLES)
	for i in 0 ..< count {
		obstacle := obstacles[i]
		t: f32 = 0
		if p3.x != p0.x {
			t = clamp((obstacle.center_x - p0.x) / (p3.x - p0.x), 0, 1)
		}
		path_y := p0.y + (p3.y - p0.y) * t

		above_y := obstacle.rect.min.y - LINK_ROUTE_MARGIN
		below_y := obstacle.rect.max.y + LINK_ROUTE_MARGIN
		bump_y := above_y
		if abs(below_y - path_y) < abs(above_y - path_y) {
			bump_y = below_y
		}

		append(&waypoints, ig.Vec2{obstacle.rect.min.x - LINK_ROUTE_MARGIN, bump_y})
		append(&waypoints, ig.Vec2{obstacle.rect.max.x + LINK_ROUTE_MARGIN, bump_y})
	}
	return waypoints
}

CATMULL_SEGMENTS_PER_SPAN :: 16

sample_catmull_rom_segment :: proc(p0, p1, p2, p3: ig.Vec2, out: ^[dynamic]ig.Vec2) {
	for s in 0 ..< CATMULL_SEGMENTS_PER_SPAN {
		t := f32(s) / f32(CATMULL_SEGMENTS_PER_SPAN)
		t2 := t * t
		t3 := t2 * t
		x :=
			0.5 *
			((2 * p1.x) +
					(-p0.x + p2.x) * t +
					(2 * p0.x - 5 * p1.x + 4 * p2.x - p3.x) * t2 +
					(-p0.x + 3 * p1.x - 3 * p2.x + p3.x) * t3)
		y :=
			0.5 *
			((2 * p1.y) +
					(-p0.y + p2.y) * t +
					(2 * p0.y - 5 * p1.y + 4 * p2.y - p3.y) * t2 +
					(-p0.y + 3 * p1.y - 3 * p2.y + p3.y) * t3)
		append(out, ig.Vec2{x, y})
	}
}

// Smooth path through every point in `points` (at least 2 entries),
// duplicating the end points as their own neighbour so the first/last span
// still has a well-defined tangent instead of a sharp corner.
sample_smooth_path :: proc(points: []ig.Vec2, out: ^[dynamic]ig.Vec2) {
	n := len(points)
	for i in 0 ..< n - 1 {
		p0 := points[max(i - 1, 0)]
		p1 := points[i]
		p2 := points[i + 1]
		p3 := points[min(i + 2, n - 1)]
		sample_catmull_rom_segment(p0, p1, p2, p3, out)
	}
	append(out, points[n - 1])
}

CARDINALITY_FOOT_LEN :: 20.0
CARDINALITY_FOOT_SPREAD :: 9.0
CARDINALITY_CIRCLE_R :: 5.0
CARDINALITY_TICK_DIST :: 16.0
CARDINALITY_TICK_LEN :: 9.0

// Crow's-foot-notation cardinality glyphs at each end of a link: a crow's
// foot at the referencing/"many" pin (plus a hollow circle if that column
// is nullable, marking the relationship zero-or-many rather than
// one-or-many), and a single tick at the referenced/"one" pin (a FK always
// points at exactly one parent row). Input pins always sit on a node's left
// edge and open further left; Output pins always sit on the right edge and
// open further right (see BeginInputAttribute/BeginOutputAttribute call
// sites in main.odin) — the "many" end is always the Input pin and the
// "one" end always Output in this app's FK convention, so the outward
// directions are fixed constants rather than a parameter.
draw_cardinality_glyphs :: proc(
	draw_list: ^ig.DrawList,
	many_pos: ig.Vec2,
	one_pos: ig.Vec2,
	many_optional: bool,
	color: u32,
	thickness: f32,
) {
	many_outward: f32 = -1
	one_outward: f32 = 1

	far := ig.Vec2{many_pos.x + many_outward * CARDINALITY_FOOT_LEN, many_pos.y}
	ig.DrawList_AddLine(draw_list, far, many_pos, color, thickness)
	ig.DrawList_AddLine(
		draw_list,
		far,
		ig.Vec2{many_pos.x, many_pos.y + CARDINALITY_FOOT_SPREAD},
		color,
		thickness,
	)
	ig.DrawList_AddLine(
		draw_list,
		far,
		ig.Vec2{many_pos.x, many_pos.y - CARDINALITY_FOOT_SPREAD},
		color,
		thickness,
	)
	if many_optional {
		centre := ig.Vec2{far.x + many_outward * (CARDINALITY_CIRCLE_R + 2.0), far.y}
		ig.DrawList_AddCircle(draw_list, centre, CARDINALITY_CIRCLE_R, color, 0, thickness)
	}

	tick_centre := ig.Vec2{one_pos.x + one_outward * CARDINALITY_TICK_DIST, one_pos.y}
	ig.DrawList_AddLine(
		draw_list,
		ig.Vec2{tick_centre.x, tick_centre.y + CARDINALITY_TICK_LEN},
		ig.Vec2{tick_centre.x, tick_centre.y - CARDINALITY_TICK_LEN},
		color,
		thickness,
	)
}

// Draws one FK link: a curve from the referenced ("one") pin to the
// referencing ("many") pin, routed around any other visible table it would
// otherwise cross, plus cardinality glyphs at each end. Call between
// imn.BeginNodeEditor() and imn.EndNodeEditor(), with the drawlist's
// current channel already set to ImNodes' link background channel (channel
// 0 — see DrawList_ChannelsSetCurrent at the call site in main.odin) so
// links layer under every node exactly like ImNodes' own Link() would.
draw_fk_link :: proc(
	draw_list: ^ig.DrawList,
	node_rects: map[GlobalTableIndex]Rect2,
	one_table, many_table: GlobalTableIndex,
	one_pos, many_pos: ig.Vec2,
	many_optional: bool,
	color: u32,
	thickness: f32,
) {
	waypoints := route_link_waypoints(one_pos, many_pos, node_rects, one_table, many_table)

	if len(waypoints) == 0 {
		samples: RoutingSamples
		sample_direct_curve(one_pos, many_pos, samples[:])
		ig.DrawList_AddPolyline(draw_list, &samples[0], i32(len(samples)), color, thickness)
	} else {
		control_points := make(
			[dynamic]ig.Vec2,
			0,
			len(waypoints) + 2,
			context.temp_allocator,
		)
		append(&control_points, one_pos)
		for wp in waypoints {
			append(&control_points, wp)
		}
		append(&control_points, many_pos)

		path := make(
			[dynamic]ig.Vec2,
			0,
			(len(control_points) - 1) * CATMULL_SEGMENTS_PER_SPAN + 1,
			context.temp_allocator,
		)
		sample_smooth_path(control_points[:], &path)
		ig.DrawList_AddPolyline(draw_list, &path[0], i32(len(path)), color, thickness)
	}

	draw_cardinality_glyphs(draw_list, many_pos, one_pos, many_optional, color, thickness)
}
