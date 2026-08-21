package imnodes

// Odin bindings for ImNodes (nelarius/imnodes).
// C++ sources are compiled into vendor/imgui/imgui.lib alongside ImGui.

Col :: enum i32 {
	NodeBackground                = 0,
	NodeBackgroundHovered         = 1,
	NodeBackgroundSelected        = 2,
	NodeOutline                   = 3,
	TitleBar                      = 4,
	TitleBarHovered               = 5,
	TitleBarSelected              = 6,
	Link                          = 7,
	LinkHovered                   = 8,
	LinkSelected                  = 9,
	Pin                           = 10,
	PinHovered                    = 11,
	BoxSelector                   = 12,
	BoxSelectorOutline            = 13,
	GridBackground                = 14,
	GridLine                      = 15,
	GridLinePrimary               = 16,
	MiniMapBackground             = 17,
	MiniMapBackgroundHovered      = 18,
	MiniMapOutline                = 19,
	MiniMapOutlineHovered         = 20,
	MiniMapNodeBackground         = 21,
	MiniMapNodeBackgroundHovered  = 22,
	MiniMapNodeBackgroundSelected = 23,
	MiniMapNodeOutline            = 24,
	MiniMapLink                   = 25,
	MiniMapLinkSelected           = 26,
	MiniMapCanvas                 = 27,
	MiniMapCanvasOutline          = 28,
}

StyleVar :: enum i32 {
	GridSpacing               = 0,
	NodeCornerRounding        = 1,
	NodePadding               = 2,
	NodeBorderThickness       = 3,
	LinkThickness             = 4,
	LinkLineSegmentsPerLength = 5,
	LinkHoverDistance         = 6,
	PinCircleRadius           = 7,
	PinQuadSideLength         = 8,
	PinTriangleSideLength     = 9,
	PinLineThickness          = 10,
	PinHoverRadius            = 11,
	PinOffset                 = 12,
	MiniMapPadding            = 13,
	MiniMapOffset             = 14,
}

PinShape :: enum i32 {
	Circle         = 0,
	CircleFilled   = 1,
	Triangle       = 2,
	TriangleFilled = 3,
	Quad           = 4,
	QuadFilled     = 5,
}

MiniMapLocation :: enum i32 {
	BottomLeft  = 0,
	BottomRight = 1,
	TopLeft     = 2,
	TopRight    = 3,
}

COL_COUNT :: 29

Style :: struct {
	grid_spacing:             f32,
	node_corner_rounding:     f32,
	node_padding:             [2]f32,
	node_border_thickness:    f32,
	link_thickness:           f32,
	link_line_segments:       f32,
	link_hover_distance:      f32,
	pin_circle_radius:        f32,
	pin_quad_side_length:     f32,
	pin_triangle_side_length: f32,
	pin_line_thickness:       f32,
	pin_hover_radius:         f32,
	pin_offset:               f32,
	mini_map_padding:         [2]f32,
	mini_map_offset:          [2]f32,
	flags:                    i32,
	colors:                   [COL_COUNT]u32,
}

when ODIN_OS == .Windows {
	@(export)
	foreign import imnodeslib "../imgui/imgui.lib"
} else {
	@(export)
	foreign import imnodeslib "../imgui/imgui.a"
}

@(default_calling_convention = "c", link_prefix = "imn")
foreign imnodeslib {
	// Context
	CreateContext :: proc() -> rawptr ---
	DestroyContext :: proc(ctx: rawptr) ---
	GetCurrentContext :: proc() -> rawptr ---
	SetCurrentContext :: proc(ctx: rawptr) ---

	// Editor
	BeginNodeEditor :: proc() ---
	EndNodeEditor :: proc() ---
	MiniMap :: proc(minimap_location: MiniMapLocation, node_hovering: i32) ---

	// Nodes
	BeginNode :: proc(id: i32) ---
	EndNode :: proc() ---
	BeginNodeTitleBar :: proc() ---
	EndNodeTitleBar :: proc() ---

	// Attributes
	BeginInputAttribute :: proc(id: i32, shape: PinShape) ---
	EndInputAttribute :: proc() ---
	BeginOutputAttribute :: proc(id: i32, shape: PinShape) ---
	EndOutputAttribute :: proc() ---

	// Links
	Link :: proc(link_id: i32, start_attr_id: i32, end_attr_id: i32) ---

	// Styling
	PushColorStyle :: proc(item: Col, color: u32) ---
	PopColorStyle :: proc() ---
	PushStyleVarFloat :: proc(style_var: StyleVar, value: f32) ---
	PushStyleVarVec2 :: proc(style_var: StyleVar, x: f32, y: f32) ---
	PopStyleVar :: proc(count: i32) ---

	// Interaction queries
	IsEditorHovered :: proc() -> i32 ---
	IsNodeHovered :: proc(node_id: ^i32) -> i32 ---
	IsLinkHovered :: proc(link_id: ^i32) -> i32 ---
	IsPinHovered :: proc(attribute_id: ^i32) -> i32 ---

	// Selection
	ClearNodeSelection :: proc() ---
	ClearLinkSelection :: proc() ---
	SelectNode :: proc(node_id: i32) ---
	ClearNodeSelectionSingle :: proc(node_id: i32) ---
	IsNodeSelected :: proc(node_id: i32) -> i32 ---
	SelectLink :: proc(link_id: i32) ---
	ClearLinkSelectionSingle :: proc(link_id: i32) ---
	IsLinkSelected :: proc(link_id: i32) -> i32 ---
	GetSelectedNodes :: proc(node_ids: ^i32) ---
	GetSelectedLinks :: proc(link_ids: ^i32) ---

	// Positioning
	SetNodeGridSpacePos :: proc(node_id: i32, x: f32, y: f32) ---
	GetNodeGridSpacePos :: proc(node_id: i32, out_x: ^f32, out_y: ^f32) ---

	// Editor view (panning)
	EditorContextResetPanning :: proc(x: f32, y: f32) ---

	// Styles
	StyleColorsDark :: proc() ---
	StyleColorsLight :: proc() ---
	StyleColorsClassic :: proc() ---
	GetStyle :: proc() -> ^Style ---
}
