package main

// Standalone check of the FK-link routing math in link_routing.odin (the
// obstacle detection, waypoint bumping, and Catmull-Rom smoothing — not the
// actual ImGui drawing calls, which need a live ImGui context this harness
// doesn't have). Byte-equivalent port of the pure-math procs, same
// convention as repro_layout.odin. Build:
// odin build test/repro_link_routing.odin -file -out:bin/repro_link_routing.exe

import "core:fmt"
import "core:math"
import "core:os"
import "core:sort"

GlobalTableIndex :: distinct u32

Vec2 :: struct {
	x, y: f32,
}

Rect2 :: struct {
	min, max: Vec2,
}

rect2_contains :: proc(r: Rect2, p: Vec2) -> bool {
	return p.x >= r.min.x && p.x <= r.max.x && p.y >= r.min.y && p.y <= r.max.y
}

rect2_overlaps_segment :: proc(r: Rect2, p1, p2: Vec2) -> bool {
	if rect2_contains(r, p1) || rect2_contains(r, p2) {
		return true
	}
	if (p1.x < r.min.x && p2.x < r.min.x) ||
	   (p1.x > r.max.x && p2.x > r.max.x) ||
	   (p1.y < r.min.y && p2.y < r.min.y) ||
	   (p1.y > r.max.y && p2.y > r.max.y) {
		return false
	}
	corners := [4]Vec2{r.min, {r.max.x, r.min.y}, {r.min.x, r.max.y}, r.max}
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

sample_direct_curve :: proc(p0, p3: Vec2, out: []Vec2) {
	dx := p3.x - p0.x
	dy := p3.y - p0.y
	length := math.sqrt(dx * dx + dy * dy)
	offset := 0.25 * length
	p1 := Vec2{p0.x + offset, p0.y}
	p2 := Vec2{p3.x - offset, p3.y}
	n := len(out)
	for i in 0 ..< n {
		t := f32(i) / f32(n - 1)
		mt := 1 - t
		a := mt * mt * mt
		b := 3 * mt * mt * t
		c := 3 * mt * t * t
		d := t * t * t
		out[i] = Vec2 {
			a * p0.x + b * p1.x + c * p2.x + d * p3.x,
			a * p0.y + b * p1.y + c * p2.y + d * p3.y,
		}
	}
}

ROUTING_SAMPLE_COUNT :: 20
RoutingSamples :: [ROUTING_SAMPLE_COUNT]Vec2

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

find_obstacles :: proc(
	p0, p3: Vec2,
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

route_link_waypoints :: proc(
	p0, p3: Vec2,
	node_rects: map[GlobalTableIndex]Rect2,
	exclude_a, exclude_b: GlobalTableIndex,
) -> [dynamic]Vec2 {
	obstacles := find_obstacles(p0, p3, node_rects, exclude_a, exclude_b)
	waypoints := make([dynamic]Vec2, 0, 2 * len(obstacles), context.temp_allocator)
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

		append(&waypoints, Vec2{obstacle.rect.min.x - LINK_ROUTE_MARGIN, bump_y})
		append(&waypoints, Vec2{obstacle.rect.max.x + LINK_ROUTE_MARGIN, bump_y})
	}
	return waypoints
}

CHAIN_SEGMENT_SAMPLES :: 16

// Same per-segment construction as sample_direct_curve for every
// consecutive pair of control points, chained together — see
// link_routing.odin's sample_chained_curve for why this replaced a
// Catmull-Rom spline: a routed link and a plain one must render as the same
// curve family, not two different-looking styles.
sample_chained_curve :: proc(points: []Vec2, out: ^[dynamic]Vec2) {
	segment: [CHAIN_SEGMENT_SAMPLES + 1]Vec2
	for i in 0 ..< len(points) - 1 {
		sample_direct_curve(points[i], points[i + 1], segment[:])
		start := i == 0 ? 0 : 1
		for j in start ..< len(segment) {
			append(out, segment[j])
		}
	}
}

path_overlaps_rect :: proc(path: []Vec2, r: Rect2) -> bool {
	for i in 0 ..< len(path) - 1 {
		if rect2_overlaps_segment(r, path[i], path[i + 1]) {
			return true
		}
	}
	return false
}

check :: proc(name: string, ok: bool) {
	status := ok ? "PASS" : "FAIL"
	fmt.printfln("[%v] %v", status, name)
	if !ok {
		os.exit(1)
	}
}

main :: proc() {
	// Case 1: clear path, no obstacles at all -> zero waypoints, and the
	// direct curve is untouched (same look as an ordinary ImNodes link).
	{
		p0 := Vec2{0, 0}
		p3 := Vec2{400, 0}
		rects := make(map[GlobalTableIndex]Rect2)
		waypoints := route_link_waypoints(p0, p3, rects, 0, 1)
		check("no obstacles -> zero waypoints", len(waypoints) == 0)
	}

	// Case 2: one obstacle rect sitting squarely on the straight path
	// between the endpoints -> waypoints are produced, and the resulting
	// smoothed path clears the obstacle with the routing margin.
	{
		p0 := Vec2{0, 100}
		p3 := Vec2{400, 100}
		obstacle := Rect2{Vec2{150, 50}, Vec2{250, 150}} // straddles y=100 at x in [150,250]

		rects := make(map[GlobalTableIndex]Rect2)
		rects[5] = obstacle

		waypoints := route_link_waypoints(p0, p3, rects, 0, 1)
		check("obstacle on straight path -> waypoints produced", len(waypoints) > 0)

		control_points := make([dynamic]Vec2, 0, len(waypoints) + 2)
		append(&control_points, p0)
		for wp in waypoints {
			append(&control_points, wp)
		}
		append(&control_points, p3)

		path := make([dynamic]Vec2, 0, 256)
		sample_chained_curve(control_points[:], &path)

		check("routed path clears the obstacle", !path_overlaps_rect(path[:], obstacle))

		direct: RoutingSamples
		sample_direct_curve(p0, p3, direct[:])
		check(
			"direct (unrouted) curve DOES hit the obstacle (sanity check)",
			path_overlaps_rect(direct[:], obstacle),
		)
	}

	// Case 3: the obstacle is one of the link's own two endpoint tables ->
	// excluded, so it must not generate a detour around itself.
	{
		p0 := Vec2{0, 100}
		p3 := Vec2{400, 100}
		rects := make(map[GlobalTableIndex]Rect2)
		rects[0] = Rect2{Vec2{-20, 80}, Vec2{20, 120}} // "endpoint" table 0
		rects[1] = Rect2{Vec2{380, 80}, Vec2{420, 120}} // "endpoint" table 1
		waypoints := route_link_waypoints(p0, p3, rects, 0, 1)
		check("endpoint tables excluded from obstacle set", len(waypoints) == 0)
	}

	fmt.println("[repro] all link routing checks passed")
}
