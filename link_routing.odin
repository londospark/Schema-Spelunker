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
	p0, p3: ig.Vec2,
	node_rects: map[GlobalTableIndex]Rect2,
	exclude_a, exclude_b: GlobalTableIndex,
) -> [dynamic]ig.Vec2 {
	obstacles := find_obstacles(p0, p3, node_rects, exclude_a, exclude_b)
	waypoints := make([dynamic]ig.Vec2, 0, 2 * len(obstacles), context.temp_allocator)
	if len(obstacles) == 0 {
		return waypoints
	}
	stagger := link_stagger(p0, p3)

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
		bump_y += stagger

		append(&waypoints, ig.Vec2{obstacle.rect.min.x - LINK_ROUTE_MARGIN, bump_y})
		append(&waypoints, ig.Vec2{obstacle.rect.max.x + LINK_ROUTE_MARGIN, bump_y})
	}
	return waypoints
}

CHAIN_SEGMENT_SAMPLES :: 16

// Builds one path through every control point in `points` (at least 2
// entries) using the *same* per-segment construction as sample_direct_curve
// for each consecutive pair — not a different spline style. That match
// matters: it's what keeps every link in the diagram looking like one
// consistent curve family rather than a mix of "straight-ish bezier" for a
// simple link and "wavy spline" for anything routed around an obstacle.
// It also joins cleanly with no visible kink at a waypoint for free: each
// segment's own tangent at its endpoints is purely horizontal (the
// bezier's control-point offset is x-only), so the outgoing tangent of one
// segment and the incoming tangent of the next always match.
sample_chained_curve :: proc(points: []ig.Vec2, out: ^[dynamic]ig.Vec2) {
	segment: [CHAIN_SEGMENT_SAMPLES + 1]ig.Vec2
	for i in 0 ..< len(points) - 1 {
		sample_direct_curve(points[i], points[i + 1], segment[:])
		// Every segment after the first shares its start point with the
		// previous segment's end — skip it so the joint isn't duplicated.
		start := i == 0 ? 0 : 1
		for j in start ..< len(segment) {
			append(out, segment[j])
		}
	}
}

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

// Unit vector, defaulting to pointing along +x for a (near-)zero input
// rather than dividing by ~0 — only reachable if two consecutive path
// samples coincide exactly, which doesn't happen in practice here.
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

// Walks along `path` from one end, accumulating segment length, and returns
// the point exactly `distance` along it — interpolating within whichever
// segment crosses that distance, or clamping to the far end if the path is
// shorter than `distance` (only possible for a very short link, and still a
// reasonable fallback: the anchor just ends up at the opposite pin).
// `from_start` true walks from path[0]; false walks backward from the last
// point. Used to find a real point on the *actual* rendered curve near a
// pin, rather than assuming a fixed direction, so a cardinality glyph's
// orientation always matches the curve it's attached to — including when a
// routed link approaches its pin at a steep angle instead of head-on.
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

CARDINALITY_FOOT_LEN :: 26.0
CARDINALITY_FOOT_SPREAD :: 12.0
CARDINALITY_CIRCLE_R :: 6.0
CARDINALITY_TICK_DIST :: 20.0
CARDINALITY_TICK_LEN :: 11.0

// Crow's-foot-notation cardinality glyphs at each end of a link's already
// (fully sampled) path: a crow's foot at the referencing/"many" pin (plus a
// hollow circle if that column is nullable, marking the relationship
// zero-or-many rather than one-or-many), and a single tick at the
// referenced/"one" pin (a FK always points at exactly one parent row).
// Orientation is derived from the actual curve near each pin (see
// point_at_arc_distance) rather than assumed horizontal, so the glyph
// lines up with the curve even where it enters at a steep angle — e.g. a
// routed link bumping up and over an obstacle right before it reaches its
// destination pin.
draw_cardinality_glyphs :: proc(
	draw_list: ^ig.DrawList,
	path: []ig.Vec2,
	many_optional: bool,
	color: u32,
	thickness: f32,
) {
	many_pos := path[len(path) - 1]
	one_pos := path[0]

	far := point_at_arc_distance(path, false, CARDINALITY_FOOT_LEN)
	outward := vec2_normalize(vec2_sub(far, many_pos))
	perp := vec2_scale(vec2_perp(outward), CARDINALITY_FOOT_SPREAD)

	ig.DrawList_AddLine(draw_list, far, many_pos, color, thickness)
	ig.DrawList_AddLine(draw_list, far, vec2_add(many_pos, perp), color, thickness)
	ig.DrawList_AddLine(draw_list, far, vec2_sub(many_pos, perp), color, thickness)
	if many_optional {
		centre := vec2_add(far, vec2_scale(outward, CARDINALITY_CIRCLE_R + 2.0))
		ig.DrawList_AddCircle(draw_list, centre, CARDINALITY_CIRCLE_R, color, 0, thickness)
	}

	near := point_at_arc_distance(path, true, CARDINALITY_TICK_DIST)
	tick_perp := vec2_scale(vec2_perp(vec2_normalize(vec2_sub(near, one_pos))), CARDINALITY_TICK_LEN)
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
	many_optional: bool,
	color: u32,
	hover_color: u32,
	thickness: f32,
) {
	waypoints := route_link_waypoints(one_pos, many_pos, node_rects, one_table, many_table)

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
	sample_chained_curve(control_points[:], &path)

	draw_color := color
	draw_thickness := thickness
	if path_hovered(path[:], ig.GetMousePos()) {
		draw_color = hover_color
		draw_thickness = thickness + LINK_HOVER_THICKNESS_BONUS
	}

	ig.DrawList_AddPolyline(draw_list, &path[0], i32(len(path)), draw_color, draw_thickness)
	draw_cardinality_glyphs(draw_list, path[:], many_optional, draw_color, draw_thickness)
}
