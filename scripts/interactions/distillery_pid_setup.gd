extends Node3D

## Distillery P&ID — VR-readable diagram with bright clickable hotspot regions.

signal hotspot_clicked(hotspot_name: String)

const DISTILLERY_TEXTURE := preload("res://data/technical_drawings/PIDwithHotspots_distilleryPID.png")
const INTERACTABLE_SCRIPT := preload("res://addons/godot-xr-tools/objects/interactable_area.gd")

const POINTER_LAYER := 1048577

const PID_PLANE_NAMES := ["Flash Drum PID Edited", "distilleryPID", "Scene"]
const HOTSPOT_TAGS := [
	"B101", "C100", "E102", "P101", "P103", "P102", "FT105", "FT106", "FT103",
]

const PID_LOCAL_POS := {
	"B101": Vector3(-0.393153, 0.002, 0.193232),
	"C100": Vector3(-0.353743, 0.002, 0.150022),
	"E102": Vector3(-0.193406, 0.002, -0.114301),
	"P101": Vector3(0.346803, 0.002, 0.417477),
	"P103": Vector3(-0.361554, 0.002, 0.370942),
	"P102": Vector3(-0.185835, 0.002, 0.212416),
	"FT105": Vector3(-0.553734, 0.002, 0.223780),
	"FT106": Vector3(-0.002799, 0.002, 0.012694),
	"FT103": Vector3(-0.256701, 0.002, 0.312823),
}

@export var hotspot_marker_size: float = 0.24
@export var pid_emission_energy: float = 0.35
@export var pid_albedo_tint: Color = Color(0.92, 0.94, 0.98)
@export var backdrop_padding: float = 0.08
@export var backdrop_color: Color = Color(0.12, 0.14, 0.18)

var _hotspot_meshes: Dictionary = {}


func _ready() -> void:
	add_to_group("pid_ui")
	call_deferred("_setup")


func _setup() -> void:
	_apply_distillery_texture()
	var wired := _wire_existing_hotspot_meshes(self)
	if wired < HOTSPOT_TAGS.size():
		_spawn_pid_hotspot_markers()
	print("[DistilleryPID] P&ID hotspots ready (%d/%d wired)" % [wired, HOTSPOT_TAGS.size()])


func _apply_distillery_texture() -> void:
	for node in _find_pid_planes(self):
		_apply_backdrop(node)
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.albedo_texture = DISTILLERY_TEXTURE
		mat.albedo_color = pid_albedo_tint
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
		mat.emission_enabled = true
		mat.emission_texture = DISTILLERY_TEXTURE
		mat.emission = Color(1.0, 1.0, 1.0)
		mat.emission_energy_multiplier = pid_emission_energy
		node.material_override = mat
		node.cast_shadow = 0
		node.visible = true


func _apply_backdrop(plane: MeshInstance3D) -> void:
	if plane.get_node_or_null("VRBackdrop"):
		return

	var aabb := plane.get_aabb()
	var backdrop := MeshInstance3D.new()
	backdrop.name = "VRBackdrop"
	var quad := QuadMesh.new()
	quad.size = Vector2(
		aabb.size.x + backdrop_padding * 2.0,
		aabb.size.y + backdrop_padding * 2.0,
	)
	backdrop.mesh = quad
	backdrop.position = aabb.get_center() + Vector3(0.0, 0.0, -0.015)

	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = backdrop_color
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	backdrop.material_override = mat
	backdrop.cast_shadow = 0
	plane.add_child(backdrop)


func _find_pid_planes(node: Node) -> Array[MeshInstance3D]:
	var found: Array[MeshInstance3D] = []
	if node is MeshInstance3D:
		if node.name in PID_PLANE_NAMES or "PID" in node.name or "distill" in node.name.to_lower():
			found.append(node)
	for child in node.get_children():
		found.append_array(_find_pid_planes(child))
	return found


func _tag_matches_node(tag: String, node_name: String) -> bool:
	return node_name == tag or node_name.begins_with(tag + "_") or node_name.begins_with(tag + ".")


func _wire_existing_hotspot_meshes(node: Node) -> int:
	var wired := 0
	for child in node.get_children():
		if child is MeshInstance3D:
			for tag in HOTSPOT_TAGS:
				if _tag_matches_node(tag, child.name):
					if _make_pid_hotspot(child, tag):
						wired += 1
					break
		wired += _wire_existing_hotspot_meshes(child)
	return wired


func _spawn_pid_hotspot_markers() -> void:
	var anchor := _find_hotspot_anchor()
	if anchor == null:
		push_warning("[DistilleryPID] Could not find P&ID plane to attach hotspot markers")
		return

	for tag in HOTSPOT_TAGS:
		if _find_node_named(anchor, tag):
			continue
		var marker := MeshInstance3D.new()
		marker.name = tag
		marker.position = PID_LOCAL_POS.get(tag, Vector3.ZERO)
		var mesh := QuadMesh.new()
		mesh.size = Vector2(hotspot_marker_size, hotspot_marker_size)
		marker.mesh = mesh
		anchor.add_child(marker)
		_make_pid_hotspot(marker, tag)


func _find_node_named(node: Node, target_name: String) -> Node:
	if node.name == target_name:
		return node
	for child in node.get_children():
		var found := _find_node_named(child, target_name)
		if found:
			return found
	return null


func _find_hotspot_anchor() -> Node3D:
	for plane in _find_pid_planes(self):
		return plane
	for child in get_children():
		if child is Node3D:
			return child
	return self


func _make_pid_hotspot(mesh_node: MeshInstance3D, tag: String) -> bool:
	mesh_node.visible = true
	mesh_node.name = tag
	_hotspot_meshes[tag] = mesh_node

	if mesh_node.mesh is QuadMesh:
		(mesh_node.mesh as QuadMesh).size = Vector2(hotspot_marker_size, hotspot_marker_size)

	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(1.0, 0.55, 0.05, 0.82)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.65, 0.1)
	mat.emission_energy_multiplier = 2.5
	mat.render_priority = 5
	mesh_node.material_override = mat
	mesh_node.cast_shadow = 0

	var area: Area3D = mesh_node.get_node_or_null("XRToolsInteractableArea") as Area3D
	if area == null:
		area = Area3D.new()
		area.name = "XRToolsInteractableArea"
		var shape := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(hotspot_marker_size, 0.06, hotspot_marker_size)
		shape.shape = box
		area.add_child(shape)
		mesh_node.add_child(area)

	area.collision_layer = POINTER_LAYER
	area.collision_mask = 0
	area.monitorable = true
	area.monitoring = false
	if area.get_script() != INTERACTABLE_SCRIPT:
		area.set_script(INTERACTABLE_SCRIPT)

	var bound_handler := _on_pid_area_pointer_event.bind(tag)
	if not area.pointer_event.is_connected(bound_handler):
		area.pointer_event.connect(bound_handler)

	if mesh_node.get_node_or_null("TagLabel") == null:
		var label := Label3D.new()
		label.name = "TagLabel"
		label.text = tag
		label.font_size = 72
		label.outline_size = 12
		label.modulate = Color(1.0, 1.0, 0.15)
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		label.no_depth_test = true
		label.render_priority = 10
		label.position = Vector3(0.0, 0.06, 0.0)
		label.scale = Vector3(0.0035, 0.0035, 0.0035)
		mesh_node.add_child(label)

	if mesh_node.get_node_or_null("RingOutline") == null:
		var ring := MeshInstance3D.new()
		ring.name = "RingOutline"
		var ring_mesh := TorusMesh.new()
		ring_mesh.inner_radius = hotspot_marker_size * 0.42
		ring_mesh.outer_radius = hotspot_marker_size * 0.5
		ring.mesh = ring_mesh
		ring.rotation_degrees = Vector3(90.0, 0.0, 0.0)
		var ring_mat := StandardMaterial3D.new()
		ring_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		ring_mat.albedo_color = Color(1.0, 0.95, 0.2, 0.95)
		ring_mat.emission_enabled = true
		ring_mat.emission = Color(1.0, 0.9, 0.2)
		ring_mat.emission_energy_multiplier = 3.0
		ring_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		ring_mat.no_depth_test = true
		ring_mat.render_priority = 6
		ring.material_override = ring_mat
		mesh_node.add_child(ring)

	return true


func _set_hotspot_hover(tag: String, hovered: bool) -> void:
	var mesh_node: MeshInstance3D = _hotspot_meshes.get(tag)
	if mesh_node == null:
		return
	var mat := mesh_node.material_override as StandardMaterial3D
	if mat == null:
		return
	if hovered:
		mat.albedo_color = Color(1.0, 0.75, 0.15, 0.95)
		mat.emission_energy_multiplier = 4.0
	else:
		mat.albedo_color = Color(1.0, 0.55, 0.05, 0.82)
		mat.emission_energy_multiplier = 2.5


func _on_pid_area_pointer_event(event: XRToolsPointerEvent, tag: String) -> void:
	match event.event_type:
		XRToolsPointerEvent.Type.ENTERED:
			_set_hotspot_hover(tag, true)
		XRToolsPointerEvent.Type.EXITED:
			_set_hotspot_hover(tag, false)
		XRToolsPointerEvent.Type.PRESSED:
			_on_hotspot_clicked(tag)


func _on_hotspot_clicked(mesh_name: String) -> void:
	print("[DistilleryPID] Clicked: ", mesh_name)
	hotspot_clicked.emit(mesh_name)
