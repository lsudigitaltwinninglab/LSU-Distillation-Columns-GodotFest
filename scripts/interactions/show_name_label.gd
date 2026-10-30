extends Node

# Equipment metadata label — hidden on hover so the view stays clean (P&ID / network pins still show it).
# While pointing at a hotspot:
# - LEFT trigger: open the description for this player only
# - RIGHT trigger: open it and share it with every peer via SharedInspection
# The locally opened label closes when the pointer leaves the hotspot.

var label_instance: Label3D  # Description; the title and "Shared by" parts are its children.
var _title_label: Label3D
var _shared_label: Label3D
var _look_target: Node3D
var _pinned_by_pid: bool = false
var _pointer_over: bool = false
var _opened_by_trigger: bool = false
var _shared_by: String = ""
var _label_color: Color = Color(1.0, 1.0, 0.85)
var _hover_glow: MeshInstance3D
var _applied_scale: float = -1.0

## Label3D's default pixel_size — full-size text at model scale 1.
const LABEL_PIXEL_SIZE := 0.005
const LABEL_FONT_SIZE := 64
const TITLE_COLOR := Color(0.35, 0.7, 1.0)
const DESCRIPTION_COLOR := Color(1.0, 1.0, 1.0)

@export var label_standoff: float = 0.35
@export var label_lift: float = 0.2
## The label (text, offset) shrinks with the model in toy mode, but never below this fraction of full size.
@export_range(0.01, 1.0) var min_label_scale: float = 0.12
## Faint rim glow while a pointer is on the hotspot (cue that a trigger will open details).
@export var hover_glow_color: Color = Color(0.35, 0.9, 1.0)
@export_range(0.0, 1.0) var hover_glow_strength: float = 0.3

const HOVER_GLOW_SHADER := """
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_back, shadows_disabled;
uniform vec4 glow_color : source_color = vec4(0.35, 0.9, 1.0, 1.0);
uniform float strength = 0.3;
void fragment() {
	float rim = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 2.5);
	ALBEDO = glow_color.rgb;
	ALPHA = rim * strength;
}
"""
static var _hover_glow_shader: Shader


func _ready() -> void:
	_look_target = get_tree().get_first_node_in_group("player_body")
	if _look_target == null:
		_look_target = get_tree().get_first_node_in_group("xr_camera")

	MetadataManager.get_metadata(get_parent().metadata_id)
	set_process(false)


## While the label is open, keep its size in step with the model (it is top-level, so it doesn't inherit the scale).
func _process(_delta: float) -> void:
	if not label_instance or not is_instance_valid(label_instance):
		set_process(false)
		return
	if not is_equal_approx(_model_scale(), _applied_scale):
		_apply_label_scale()
		_update_label_position()


## Current model scale, floored so the text stays readable when the model is tiny.
func _model_scale() -> float:
	var area := get_parent() as Node3D
	return maxf(area.global_transform.basis.get_scale().x, min_label_scale) if area else 1.0


func _apply_label_scale() -> void:
	_applied_scale = _model_scale()
	var pixel_size := LABEL_PIXEL_SIZE * _applied_scale
	label_instance.pixel_size = pixel_size
	if _title_label:
		_title_label.pixel_size = pixel_size
	if _shared_label:
		_shared_label.pixel_size = pixel_size
		# Sit one title line above the title.
		var line_px := ThemeDB.fallback_font.get_height(LABEL_FONT_SIZE)
		_shared_label.position = Vector3.UP * line_px * pixel_size


func pointer_event(event: XRToolsPointerEvent) -> void:
	if _pinned_by_pid:
		match event.event_type:
			XRToolsPointerEvent.Type.ENTERED:
				_pointer_over = true
				_set_hover_glow(true)
			XRToolsPointerEvent.Type.EXITED:
				_pointer_over = false
				_opened_by_trigger = false
				_set_hover_glow(false)
			XRToolsPointerEvent.Type.PRESSED:
				_opened_by_trigger = true
				if _is_right_hand(event):
					_share_with_peers()
			XRToolsPointerEvent.Type.MOVED:
				if label_instance:
					_update_label_position()
		return

	match event.event_type:
		XRToolsPointerEvent.Type.ENTERED:
			_pointer_over = true
			_set_hover_glow(true)
		XRToolsPointerEvent.Type.MOVED:
			if label_instance:
				_update_label_position()
		XRToolsPointerEvent.Type.PRESSED:
			# Either trigger opens the label locally; right trigger also shares it.
			_opened_by_trigger = true
			_refresh_label_visibility()
			if _is_right_hand(event):
				_share_with_peers()
		XRToolsPointerEvent.Type.EXITED:
			_pointer_over = false
			_opened_by_trigger = false
			_set_hover_glow(false)
			_hide_label()


## Pin the label (P&ID selection or a network share). shared_by is shown as the first line.
func show_from_pid(shared_by: String = "", color: Color = Color(1.0, 1.0, 0.85)) -> void:
	_pinned_by_pid = true
	_shared_by = shared_by
	_label_color = color
	_free_label()
	_show_label()


func hide_from_pid() -> void:
	_pinned_by_pid = false
	_shared_by = ""
	_label_color = Color(1.0, 1.0, 0.85)
	_free_label()
	# Still pointing at a label this player opened: keep it open.
	_refresh_label_visibility()


func _refresh_label_visibility() -> void:
	if _pointer_over and _opened_by_trigger:
		_show_label()
	else:
		_hide_label()


func _set_hover_glow(on: bool) -> void:
	if on and not _hover_glow:
		_hover_glow = _build_hover_glow()
	if _hover_glow:
		_hover_glow.visible = on


func _build_hover_glow() -> MeshInstance3D:
	var area := get_parent() as Node3D
	if not area:
		return null
	# Match the hotspot's collision sphere (same 1.1x margin as the shared Highlight).
	var radius := 0.3
	for child in area.get_children():
		if child is CollisionShape3D and (child as CollisionShape3D).shape is SphereShape3D:
			radius = ((child as CollisionShape3D).shape as SphereShape3D).radius
			break

	if not _hover_glow_shader:
		_hover_glow_shader = Shader.new()
		_hover_glow_shader.code = HOVER_GLOW_SHADER
	var mat := ShaderMaterial.new()
	mat.shader = _hover_glow_shader
	mat.set_shader_parameter("glow_color", hover_glow_color)
	mat.set_shader_parameter("strength", hover_glow_strength)

	var sphere := SphereMesh.new()
	sphere.radius = radius * 1.1
	sphere.height = radius * 2.2
	sphere.radial_segments = 32
	sphere.rings = 16

	var glow := MeshInstance3D.new()
	glow.name = "HoverGlow"
	glow.mesh = sphere
	glow.material_override = mat
	glow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	glow.visible = false
	area.add_child(glow)
	return glow


func _is_right_hand(event: XRToolsPointerEvent) -> bool:
	var controller := XRHelpers.get_xr_controller(event.pointer)
	return controller != null and controller.tracker == &"right_hand"


func _share_with_peers() -> void:
	var sharing := get_tree().get_first_node_in_group("shared_inspection")
	if sharing and sharing.has_method("share_hotspot"):
		sharing.share_hotspot(String(get_parent().name))


## Description lines under the title (the title itself is the metadata id).
func _build_description_text() -> String:
	var parent_node = get_parent()
	var id: String = parent_node.metadata_id
	var meta := MetadataManager.get_metadata(id)
	var part_val: String = str(parent_node.part_name).replace("?", "").strip_edges() if parent_node.get("part_name") else ""

	var lines: Array[String] = []
	if part_val != "" and part_val != id:
		lines.append(part_val)

	if not meta.is_empty():
		var name_val = str(meta.get("name", "")).replace("?", "").strip_edges()
		if name_val != "" and name_val != id and name_val != part_val:
			lines.append(name_val)
		var type_val = str(meta.get("type", "")).replace("?", "").strip_edges()
		if type_val != "":
			lines.append(type_val)
		var range_val = str(meta.get("range", "")).replace("?", "").strip_edges()
		if range_val != "":
			lines.append(range_val)
		var size_val = str(meta.get("size", "")).replace("?", "").strip_edges()
		if size_val != "":
			lines.append(size_val)
		var other_val = str(meta.get("other_info", "")).replace("?", "").strip_edges()
		if other_val != "":
			lines.append(other_val)

	return "\n".join(lines)


func _show_label() -> void:
	if label_instance:
		return

	# Label3D is one color, so the label is three stacked parts: the description (root, hangs
	# below the anchor), the title just above it, and "Shared by" above the title.
	label_instance = _new_label_part(_build_description_text(), DESCRIPTION_COLOR, VERTICAL_ALIGNMENT_TOP)
	label_instance.top_level = true
	_title_label = _new_label_part(String(get_parent().metadata_id), TITLE_COLOR, VERTICAL_ALIGNMENT_BOTTOM)
	label_instance.add_child(_title_label)
	if _pinned_by_pid and _shared_by != "":
		_shared_label = _new_label_part("Shared by %s" % _shared_by, _label_color, VERTICAL_ALIGNMENT_BOTTOM)
		label_instance.add_child(_shared_label)

	var host := _label_host()
	host.add_child(label_instance)
	_apply_label_scale()
	_update_label_position()
	set_process(true)


func _new_label_part(text: String, color: Color, v_align: VerticalAlignment) -> Label3D:
	var part := Label3D.new()
	part.text = text
	part.font_size = LABEL_FONT_SIZE
	part.outline_size = 8
	part.modulate = color
	part.vertical_alignment = v_align
	part.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	part.no_depth_test = true
	part.render_priority = 20
	return part


func _update_label_position() -> void:
	if label_instance:
		label_instance.global_position = _label_anchor_position()


func _label_anchor_position() -> Vector3:
	var area := get_parent() as Node3D
	var label_scale := _model_scale()
	var anchor := area.global_position + Vector3.UP * label_lift * label_scale
	if _look_target:
		var to_viewer := _look_target.global_position - anchor
		to_viewer.y = 0.0
		if to_viewer.length() > 0.01:
			anchor += to_viewer.normalized() * label_standoff * label_scale
	return anchor


func _label_host() -> Node:
	var host := get_parent().get_parent()
	while host != null and not host is Node3D:
		host = host.get_parent()
	if host == null:
		host = get_tree().current_scene
	return host


func _hide_label() -> void:
	if _pinned_by_pid:
		return
	_free_label()


func _free_label() -> void:
	if label_instance and label_instance.is_inside_tree():
		label_instance.queue_free()
	label_instance = null
	_title_label = null
	_shared_label = null
	_applied_scale = -1.0
	set_process(false)
