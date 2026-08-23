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
// imnodes.cpp): control points offset from each endpoint along that
// endpoint's own outward direction (dir0/dir3 — away from the node it sits
// on, not always +x/-x: see the pin_is_input comment at the draw_fk_link
// call site in main.odin, which reassigns which edge a pin renders on
// based on the tables' current relative position, not the FK's one/many
// role), by a quarter of the pin-to-pin distance capped at
// MAX_TANGENT_OFFSET. The cap is the one deviation from ImNodes' own
// formula: several links can share a single pin (e.g. every table with a
// company_id all referencing the same companies.id), and an uncapped
// quarter-of-total-length offset makes a long-distance link launch on a
// long near-straight run in lockstep with every other link sharing that
// pin before they visibly diverge — which reads as one big
// crow's-foot-like fan swallowing the real cardinality glyph. Capping the
// offset makes long links diverge from a shared pin much sooner, while
// leaving anything shorter than the cap (the common case) completely
// unaffected.
sample_direct_curve :: proc(p0, p3, dir0, dir3: ig.Vec2, out: []ig.Vec2) {
	dx := p3.x - p0.x
	dy := p3.y - p0.y
	length := math.sqrt(dx * dx + dy * dy)
	offset := min(0.25 * length, MAX_TANGENT_OFFSET)
	p1 := vec2_add(p0, vec2_scale(dir0, offset))
	p2 := vec2_add(p3, vec2_scale(dir3, offset))
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

MAX_TANGENT_OFFSET :: 80.0

ROUTING_SAMPLE_COUNT :: 20
RoutingSamples :: [ROUTING_SAMPLE_COUNT]ig.Vec2

LINK_ROUTE_MARGIN :: 14.0
LINK_ROUTE_MAX_OBSTACLES :: 4
LINK_STAGGER_RANGE :: 6.0

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
	p0, p3, dir0, dir3: ig.Vec2,
	node_rects: map[GlobalTableIndex]Rect2,
	exclude_a, exclude_b: GlobalTableIndex,
) -> [dynamic]Obstacle {
	samples: RoutingSamples
	sample_direct_curve(p0, p3, dir0, dir3, samples[:])

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

// A small, cheap, deterministic pseudo-random value from two points (the
// classic "fract(sin(dot(...)) * big_number)" hash) — same link endpoints
// always give the same stagger, so it doesn't jitter between frames, but
// two different links get two different values. Used to keep two links
// that both detour around the same obstacle from landing on the exact same
// waypoint coordinates: without this, they'd overlap completely through the
// whole detour and only visibly separate again once they reach their own
// distinct endpoints — reading as if they "branch off each other" partway
// along instead of at the pin, which is the wrong impression for two
// unrelated relationships that just happen to cross the same table.
link_stagger :: proc(p0, p3: ig.Vec2) -> f32 {
	v := p0.x * 12.9898 + p0.y * 78.233 + p3.x * 37.719 + p3.y * 94.673
	s := math.sin(v) * 43758.5453
	frac := s - math.floor(s)
	return (frac - 0.5) * 2 * LINK_STAGGER_RANGE
}

// Greedy single-pass detour: for each obstacle the direct path crosses,
// left to right, adds a waypoint pair that bumps the path above or below
// it — whichever side is closer to the path's height at that point — with
// a small clearance margin, then nudges that bump by this link's stagger
// (comfortably smaller than the margin, so clearance is never actually
// lost). Doesn't re-check the detoured path against further obstacles, so a
// dense cluster of overlapping tables can still leave a residual close
// call; that's a deliberate simplicity tradeoff, and still a large
// improvement over drawing straight through every one of them. Obstacle
// count is capped since a table with dozens of crossed neighbours (a
// heavily-shared hub's neighbourhood) would otherwise produce a waypoint
// list long enough to zigzag rather than clarify.
route_link_waypoints :: proc(
	p0, p3, dir0, dir3: ig.Vec2,
	node_rects: map[GlobalTableIndex]Rect2,
	exclude_a, exclude_b: GlobalTableIndex,
) -> [dynamic]ig.Vec2 {
	obstacles := find_obstacles(p0, p3, dir0, dir3, node_rects, exclude_a, exclude_b)
	waypoints := make([dynamic]ig.Vec2, 0, 2 * len(obstacles), context.temp_allocator)
	if len(obstacles) == 0 {
		return waypoints
	}
	stagger := link_stagger(p0, p3)

	// Waypoints have to come out ordered along the path's *direction of
	// travel*, since the caller splices them between p0 and p3 in the order
	// returned. find_obstacles hands them back sorted left-to-right, which
	// is only the travel order when p0 is left of p3. A link running
	// right-to-left (which happens as soon as a table is dragged past its FK
	// partner — see the pin_is_input comment in main.odin, the pins flip
	// edges but the FK's one/many roles don't) would otherwise get a
	// waypoint list that doubles back on itself: out to the far obstacle's
	// left edge, back right to its right edge, then reverse again to reach
	// the endpoint — drawn as a hook/zigzag rather than a detour.
	travels_right := p3.x >= p0.x

	count := min(len(obstacles), LINK_ROUTE_MAX_OBSTACLES)
	for i in 0 ..< count {
		obstacle := travels_right ? obstacles[i] : obstacles[len(obstacles) - 1 - i]
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
		bump_y += stagger

		// Near edge first, far edge second — "near" relative to the
		// direction the path is actually running.
		left_x := obstacle.rect.min.x - LINK_ROUTE_MARGIN
		right_x := obstacle.rect.max.x + LINK_ROUTE_MARGIN
		entry_x := travels_right ? left_x : right_x
		exit_x := travels_right ? right_x : left_x

		append(&waypoints, ig.Vec2{entry_x, bump_y})
		append(&waypoints, ig.Vec2{exit_x, bump_y})
	}
	return waypoints
}

SELF_LOOP_MARGIN :: 24.0

// Waypoints for a self-referencing FK (e.g. cards.parent_id -> cards.id) —
// both pins belong to the same node, one on its right edge and one on its
// left, so route_link_waypoints' obstacle-avoidance doesn't apply (a table
// excludes itself from being its own obstacle, and there's no useful
// "direct path" between two pins on one node to test in the first place).
// Instead this always drops straight down from each pin to just below the
// node's own bottom edge and back up into the other pin — a small loop
// that reads immediately as "this table references itself" without ever
// crossing the node's own body.
self_loop_waypoints :: proc(one_pos, many_pos: ig.Vec2, node_rect: Rect2) -> [dynamic]ig.Vec2 {
	below_y := node_rect.max.y + SELF_LOOP_MARGIN
	waypoints := make([dynamic]ig.Vec2, 0, 2, context.temp_allocator)
	append(&waypoints, ig.Vec2{one_pos.x, below_y})
	append(&waypoints, ig.Vec2{many_pos.x, below_y})
	return waypoints
}

CHAIN_SEGMENT_SAMPLES :: 16

vec2_sub :: proc(a, b: ig.Vec2) -> ig.Vec2 {
	return ig.Vec2{a.x - b.x, a.y - b.y}
}

vec2_add :: proc(a, b: ig.Vec2) -> ig.Vec2 {
	return ig.Vec2{a.x + b.x, a.y + b.y}
}

vec2_scale :: proc(a: ig.Vec2, s: f32) -> ig.Vec2 {
	return ig.Vec2{a.x * s, a.y * s}
}

vec2_length :: proc(a: ig.Vec2) -> f32 {
	return math.sqrt(a.x * a.x + a.y * a.y)
}

// Unit vector, defaulting to +x for a (near-)zero input rather than
// dividing by ~0 — only reachable if two waypoints coincide exactly.
vec2_normalize :: proc(a: ig.Vec2) -> ig.Vec2 {
	length := vec2_length(a)
	if length < 1e-4 {
		return ig.Vec2{1, 0}
	}
	return ig.Vec2{a.x / length, a.y / length}
}

// perpendicular (rotate 90 degrees)
vec2_perp :: proc(a: ig.Vec2) -> ig.Vec2 {
	return ig.Vec2{-a.y, a.x}
}

// One cubic bezier segment from explicit start/end points and explicit
// start/end tangent vectors (already scaled to the desired control-point
// offset — not unit vectors). Same evaluation as sample_direct_curve, just
// with the control points handed in rather than derived from a fixed
// horizontal assumption — see sample_chained_curve.
sample_hermite_segment :: proc(p0, p3, tangent0, tangent3: ig.Vec2, out: []ig.Vec2) {
	p1 := vec2_add(p0, tangent0)
	p2 := vec2_sub(p3, tangent3)
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

// Builds one path through every control point in `points` (at least 2
// entries). dir_start/dir_end are the two true endpoints' own outward
// directions (see sample_direct_curve). Two points (no waypoints — the
// common case) goes straight through sample_direct_curve, unchanged. With
// waypoints in between, each segment is still a cubic bezier — never a
// different curve family — but the tangent at each interior waypoint is a
// Catmull-Rom central difference (the direction from the waypoint before
// to the one after) instead of a fixed assumption. A fixed tangent is only
// meaningful at the two true endpoints, where it's exactly correct (see
// draw_cardinality_glyphs); forcing it at every interior waypoint too meant
// each individual segment between two nearby waypoints — often short,
// since routing waypoints can sit close together — had barely enough
// length for its own offset to visibly curve, so a multi-waypoint detour
// chained a series of near-straight facets at slightly different angles
// instead of one smooth curve. The two true endpoints keep their fixed
// outward tangent regardless (matches the pin's actual rendered side —
// see sample_direct_curve — and keeps this identical to the two-point case
// whenever there are no waypoints to smooth between).
sample_chained_curve :: proc(points: []ig.Vec2, dir_start, dir_end: ig.Vec2, out: ^[dynamic]ig.Vec2) {
	segment: [CHAIN_SEGMENT_SAMPLES + 1]ig.Vec2
	n := len(points)
	if n == 2 {
		sample_direct_curve(points[0], points[1], dir_start, dir_end, segment[:])
		for p in segment {
			append(out, p)
		}
		return
	}

	tangent_dirs := make([]ig.Vec2, n, context.temp_allocator)
	tangent_dirs[0] = dir_start
	tangent_dirs[n - 1] = dir_end
	for i in 1 ..< n - 1 {
		tangent_dirs[i] = vec2_normalize(vec2_sub(points[i + 1], points[i - 1]))
	}

	for i in 0 ..< n - 1 {
		seg_len := vec2_length(vec2_sub(points[i + 1], points[i]))
		scale := min(seg_len / 3.0, MAX_TANGENT_OFFSET)
		t0 := vec2_scale(tangent_dirs[i], scale)
		t1 := vec2_scale(tangent_dirs[i + 1], scale)
		sample_hermite_segment(points[i], points[i + 1], t0, t1, segment[:])
		// Every segment after the first shares its start point with the
		// previous segment's end — skip it so the joint isn't duplicated.
		start := i == 0 ? 0 : 1
		for j in start ..< len(segment) {
			append(out, segment[j])
		}
	}
}

CARDINALITY_FOOT_LEN :: 26.0
CARDINALITY_FOOT_SPREAD :: 12.0
CARDINALITY_CIRCLE_R :: 6.0
CARDINALITY_TICK_DIST :: 20.0
CARDINALITY_TICK_LEN :: 11.0

// Walks along `path` from one end, accumulating segment length, and
// returns the point exactly `distance` along it — interpolating within
// whichever segment crosses that distance, or clamping to the far end if
// the path is shorter than `distance`. `from_start` true walks from
// path[0]; false walks backward from the last point. Used only to *place*
// a glyph's outer vertex on the curve the link actually draws (so it never
// visually detaches from the line, even where the curve bends quickly) —
// never to derive a *direction* from. An earlier version used a secant
// over this same distance for direction too, which could flip a glyph to
// point back into the node instead of away from it whenever a waypoint
// bent the curve sharply within that distance; direction now always comes
// from the pin's actual known outward vector instead (see
// draw_cardinality_glyphs), so this only ever affects where the glyph
// sits, never which way it opens.
point_at_arc_distance :: proc(path: []ig.Vec2, from_start: bool, distance: f32) -> ig.Vec2 {
	n := len(path)
	remaining := distance
	if from_start {
		for i in 0 ..< n - 1 {
			a, b := path[i], path[i + 1]
			seg_len := vec2_length(vec2_sub(b, a))
			if seg_len >= remaining {
				return vec2_add(a, vec2_scale(vec2_sub(b, a), remaining / seg_len))
			}
			remaining -= seg_len
		}
		return path[n - 1]
	}
	for i := n - 1; i > 0; i -= 1 {
		a, b := path[i], path[i - 1]
		seg_len := vec2_length(vec2_sub(b, a))
		if seg_len >= remaining {
			return vec2_add(a, vec2_scale(vec2_sub(b, a), remaining / seg_len))
		}
		remaining -= seg_len
	}
	return path[0]
}

// Crow's-foot-notation cardinality glyphs at each end of a link's already
// (fully sampled) path: a crow's foot at the referencing/"many" pin (plus a
// hollow circle if that column is nullable, marking the relationship
// zero-or-many rather than one-or-many), and a single tick at the
// referenced/"one" pin (a FK always points at exactly one parent row).
// many_outward/one_outward are each pin's actual outward direction — see
// the pin_is_input comment at the draw_fk_link call site in main.odin:
// which edge of a node a pin renders on follows the tables' current
// relative position, not the FK's one/many role, so this can be either
// direction and must never be assumed fixed. The glyph's outer vertex
// (far/near) is positioned by walking the actual curve — see
// point_at_arc_distance — so it stays visually attached to the line even
// where routing bends it quickly, but the fan/tick's own orientation
// always comes from the known-correct outward vector, never from that
// walk, so a sharp bend can change where the glyph sits without ever being
// able to flip which way it opens.
draw_cardinality_glyphs :: proc(
	draw_list: ^ig.DrawList,
	path: []ig.Vec2,
	many_outward, one_outward: ig.Vec2,
	many_optional: bool,
	color: u32,
	thickness: f32,
) {
	many_pos := path[len(path) - 1]

	far := point_at_arc_distance(path, false, CARDINALITY_FOOT_LEN)
	perp := vec2_scale(vec2_perp(many_outward), CARDINALITY_FOOT_SPREAD)

	ig.DrawList_AddLine(draw_list, far, many_pos, color, thickness)
	ig.DrawList_AddLine(draw_list, far, vec2_add(many_pos, perp), color, thickness)
	ig.DrawList_AddLine(draw_list, far, vec2_sub(many_pos, perp), color, thickness)
	if many_optional {
		centre := vec2_add(far, vec2_scale(many_outward, CARDINALITY_CIRCLE_R + 2.0))
		ig.DrawList_AddCircle(draw_list, centre, CARDINALITY_CIRCLE_R, color, 0, thickness)
	}

	near := point_at_arc_distance(path, true, CARDINALITY_TICK_DIST)
	tick_perp := vec2_scale(vec2_perp(one_outward), CARDINALITY_TICK_LEN)
	ig.DrawList_AddLine(
		draw_list,
		vec2_add(near, tick_perp),
		vec2_sub(near, tick_perp),
		color,
		thickness,
	)
}

LINK_HOVER_DISTANCE :: 6.0
LINK_HOVER_THICKNESS_BONUS :: 1.5

// Shortest distance from `p` to the segment a-b.
point_segment_distance :: proc(p, a, b: ig.Vec2) -> f32 {
	ab := vec2_sub(b, a)
	len_sq := ab.x * ab.x + ab.y * ab.y
	if len_sq < 1e-8 {
		return vec2_length(vec2_sub(p, a))
	}
	t := clamp(((p.x - a.x) * ab.x + (p.y - a.y) * ab.y) / len_sq, 0, 1)
	closest := vec2_add(a, vec2_scale(ab, t))
	return vec2_length(vec2_sub(p, closest))
}

path_hovered :: proc(path: []ig.Vec2, mouse: ig.Vec2) -> bool {
	for i in 0 ..< len(path) - 1 {
		if point_segment_distance(mouse, path[i], path[i + 1]) <= LINK_HOVER_DISTANCE {
			return true
		}
	}
	return false
}

// Draws one FK link: a curve from the referenced ("one") pin to the
// referencing ("many") pin, routed around any other visible table it would
// otherwise cross, plus cardinality glyphs at each end, thickening and
// brightening the whole thing when the mouse is over it. Call between
// imn.BeginNodeEditor() and imn.EndNodeEditor(), with the drawlist's
// current channel already set to ImNodes' link background channel (channel
// 0 — see DrawList_ChannelsSetCurrent at the call site in main.odin) so
// links layer under every node exactly like ImNodes' own Link() would.
draw_fk_link :: proc(
	draw_list: ^ig.DrawList,
	node_rects: map[GlobalTableIndex]Rect2,
	one_table, many_table: GlobalTableIndex,
	one_pos, many_pos: ig.Vec2,
	one_outward, many_outward: ig.Vec2,
	many_optional: bool,
	color: u32,
	hover_color: u32,
	thickness: f32,
) {
	waypoints: [dynamic]ig.Vec2
	if one_table == many_table {
		if rect, ok := node_rects[one_table]; ok {
			waypoints = self_loop_waypoints(one_pos, many_pos, rect)
		} else {
			waypoints = make([dynamic]ig.Vec2, 0, 0, context.temp_allocator)
		}
	} else {
		waypoints = route_link_waypoints(
			one_pos,
			many_pos,
			one_outward,
			many_outward,
			node_rects,
			one_table,
			many_table,
		)
	}

	// Always the same construction — see sample_chained_curve — whether or
	// not there were any waypoints to route around, so a routed link and a
	// plain one never look like two different kinds of line.
	control_points := make([dynamic]ig.Vec2, 0, len(waypoints) + 2, context.temp_allocator)
	append(&control_points, one_pos)
	for wp in waypoints {
		append(&control_points, wp)
	}
	append(&control_points, many_pos)

	path := make(
		[dynamic]ig.Vec2,
		0,
		(len(control_points) - 1) * CHAIN_SEGMENT_SAMPLES + 1,
		context.temp_allocator,
	)
	sample_chained_curve(control_points[:], one_outward, many_outward, &path)

	draw_color := color
	draw_thickness := thickness
	if path_hovered(path[:], ig.GetMousePos()) {
		draw_color = hover_color
		draw_thickness = thickness + LINK_HOVER_THICKNESS_BONUS
	}

	ig.DrawList_AddPolyline(draw_list, &path[0], i32(len(path)), draw_color, draw_thickness)
	draw_cardinality_glyphs(
		draw_list,
		path[:],
		many_outward,
		one_outward,
		many_optional,
		draw_color,
		draw_thickness,
	)
}
