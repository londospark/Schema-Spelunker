package imnodes

// Odin bindings for ImNodes (nelarius/imnodes).
// C++ sources are compiled into vendor/imgui/imgui.lib alongside ImGui.

when ODIN_OS == .Windows {
	@export
	foreign import imnodeslib "../imgui/imgui.lib"
} else {
	@export
	foreign import imnodeslib "../imgui/imgui.a"
}

@(default_calling_convention="c", link_prefix="imn")
foreign imnodeslib {
	// Context
	CreateContext              :: proc() -> rawptr ---
	DestroyContext             :: proc(ctx: rawptr) ---
	GetCurrentContext          :: proc() -> rawptr ---
	SetCurrentContext          :: proc(ctx: rawptr) ---

	// Editor
	BeginNodeEditor            :: proc() ---
	EndNodeEditor              :: proc() ---
	MiniMap                    :: proc(minimap_location: i32, node_hovering: i32) ---

	// Nodes
	BeginNode                  :: proc(id: i32) ---
	EndNode                    :: proc() ---
	BeginNodeTitleBar          :: proc() ---
	EndNodeTitleBar            :: proc() ---

	// Attributes
	BeginInputAttribute        :: proc(id: i32, shape: i32) ---
	EndInputAttribute          :: proc() ---
	BeginOutputAttribute       :: proc(id: i32, shape: i32) ---
	EndOutputAttribute         :: proc() ---

	// Links
	Link                       :: proc(link_id: i32, start_attr_id: i32, end_attr_id: i32) ---

	// Styling
	PushColorStyle             :: proc(item: i32, color: u32) ---
	PopColorStyle              :: proc() ---
	PushStyleVarFloat          :: proc(style_var: i32, value: f32) ---
	PushStyleVarVec2           :: proc(style_var: i32, x: f32, y: f32) ---
	PopStyleVar                :: proc(count: i32) ---

	// Interaction queries
	IsEditorHovered            :: proc() -> i32 ---
	IsNodeHovered              :: proc(node_id: ^i32) -> i32 ---
	IsLinkHovered              :: proc(link_id: ^i32) -> i32 ---
	IsPinHovered               :: proc(attribute_id: ^i32) -> i32 ---

	// Selection
	ClearNodeSelection         :: proc() ---
	ClearLinkSelection         :: proc() ---
	SelectNode                 :: proc(node_id: i32) ---
	ClearNodeSelectionSingle   :: proc(node_id: i32) ---
	IsNodeSelected             :: proc(node_id: i32) -> i32 ---
	SelectLink                 :: proc(link_id: i32) ---
	ClearLinkSelectionSingle   :: proc(link_id: i32) ---
	IsLinkSelected             :: proc(link_id: i32) -> i32 ---
	GetSelectedNodes           :: proc(node_ids: ^i32) ---
	GetSelectedLinks           :: proc(link_ids: ^i32) ---

	// Positioning
	SetNodeGridSpacePos        :: proc(node_id: i32, x: f32, y: f32) ---
	GetNodeGridSpacePos        :: proc(node_id: i32, out_x: ^f32, out_y: ^f32) ---

	// Styles
	StyleColorsDark            :: proc() ---
	StyleColorsLight           :: proc() ---
	StyleColorsClassic         :: proc() ---
}
