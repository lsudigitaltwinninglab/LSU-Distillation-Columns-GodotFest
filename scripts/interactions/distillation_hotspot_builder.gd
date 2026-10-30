extends Node3D
class_name DistillationHotspotBuilder

## XR-pointer hotspots for column C100 — positions from distillery P&ID + 3D model anchors.
## Enable show_debug_meshes to tune placement in the editor.

const AREA_SCRIPT := preload("res://scripts/interactions/area_3d.gd")
const LABEL_SCRIPT := preload("res://scripts/interactions/show_name_label.gd")
const HIGHLIGHT_SCENE := preload("res://assets/instances/sphere_highlight.tscn")

## Layer 21 "Pointable Objects" only: that is what the XR pointer rays look for. (The hotspots used to sit on layer 1,
## "Static World", as well, which paired each of the 100 areas with every static body and with each other.)
const POINTER_LAYER := 1048576

## Tag layout: GLB node name + fallback position (plant root space, meters).
const SCENE_PART_MAP: Dictionary = {
	"C100": {"node": "Tank_001", "abs": Vector3(0.772, 1.300, -0.422)},
	"B101": {"node": "Body", "pos": Vector3(-0.180, 0.798, 0.444), "y": 0.80},
	"R101": {"node": "Reactor?", "pos": Vector3(0.130, 1.803, 0.604), "y": 1.80},
	"E102": {"node": "PipeLine - Feed from P101", "abs": Vector3(0.242, 1.829, 0.031)},
	"E103": {"node": "PipeLine - Condensate from Reboiler", "abs": Vector3(0.899, 0.679, -0.121)},
	"E104": {"node": "PipeLine - Cooling Water to E104", "abs": Vector3(0.060, 1.271, 0.125)},
	"FT101": {"node": "FT101 - Feed Flow", "pos": Vector3(-0.837, 1.057, -0.597), "y": 1.06},
	"FT102": {"node": "FT102 - Reflux Flow", "pos": Vector3(-0.482, 1.381, -0.270), "y": 1.38},
	"FT103": {"node": "FT102 - Bottom Product Flow", "pos": Vector3(0.445, 1.630, -0.334), "y": 1.63},
	"FT104": {"node": "FT104 - Distillate Flow", "pos": Vector3(-0.480, 1.660, -0.548), "y": 1.66},
	"FT105": {"node": "FT105 - Supply Steam", "pos": Vector3(1.256, 1.387, 0.528), "y": 1.39},
	"FT106": {"node": "FT106 - CW Flow to E101", "pos": Vector3(1.041, 2.342, 0.318), "y": 2.34},
	"TT101": {"node": "PipeLine - Reboiler Outlet Liquid", "abs": Vector3(0.330, 1.233, -0.319)},
	"TT102": {"node": "Tank_001", "abs": Vector3(0.772, 1.900, -0.422)},
	"TT103": {"node": "Tank_001", "abs": Vector3(0.772, 2.450, -0.422)},
	"TT104": {"node": "Tank_001", "abs": Vector3(0.772, 3.000, -0.422)},
	"TT105": {"node": "Tank_001", "abs": Vector3(0.772, 3.550, -0.422)},
	"TT106": {"node": "Tank_001", "abs": Vector3(0.772, 4.100, -0.422)},
	"TT107": {"node": "Tank_001", "abs": Vector3(0.772, 4.650, -0.422)},
	"TT108": {"node": "Tank_001", "abs": Vector3(0.772, 5.200, -0.422)},
	"TT109": {"node": "Tank_001", "abs": Vector3(0.772, 5.750, -0.422)},
	"TT110": {"node": "Tank_001", "abs": Vector3(0.772, 6.300, -0.422)},
	"TT111": {"node": "Tank_001", "abs": Vector3(0.772, 6.950, -0.422)},
	"TT112": {"node": "PipeLine - Feed from P101", "abs": Vector3(0.242, 1.829, 0.031), "offset": Vector3(0, 0.3, 0)},
	"TT113": {"node": "Reactor?", "pos": Vector3(0.130, 1.803, 0.604), "y": 1.80, "offset": Vector3(0, 0.35, 0)},
	"TT114": {"node": "FT102 - Reflux Flow", "pos": Vector3(-0.482, 1.381, -0.270), "y": 1.38, "offset": Vector3(0, 0.3, 0)},
	"TT115": {"node": "FT104 - Distillate Flow", "pos": Vector3(-0.480, 1.660, -0.548), "y": 1.66, "offset": Vector3(0, 0.3, 0)},
	"TT116": {"node": "FT102 - Bottom Product Flow", "pos": Vector3(0.445, 1.630, -0.334), "y": 1.63, "offset": Vector3(0, 0.3, 0)},
	"TT117": {"node": "PipeLine - Cooling Water Supply", "abs": Vector3(1.235, 1.634, -0.386)},
	"TT118": {"node": "PipeLine - Cooling Water Return", "abs": Vector3(0.372, 1.922, 0.090), "offset": Vector3(0.15, 0.15, 0.1)},
	"TT119": {"node": "PipeLine - Steam Supply", "abs": Vector3(0.602, 1.323, 0.466)},
	"TT120": {"node": "PipeLine - Condensate from Reboiler", "abs": Vector3(0.899, 0.679, -0.121), "offset": Vector3(0, 0.3, 0)},
	"TT121": {"node": "FT101 - Feed Flow", "pos": Vector3(-0.837, 1.057, -0.597), "y": 1.06, "offset": Vector3(0, 0.3, 0)},
	"TT122": {"node": "PipeLine - Vacuum Inlet", "abs": Vector3(-0.031, 0.713, -0.148)},
	"DPT101": {"node": "Pressure gauge_001", "abs": Vector3(0.328, 0.936, -0.252)},
	"LT101": {"node": "Body", "pos": Vector3(-0.180, 0.798, 0.444), "y": 0.80, "offset": Vector3(0, 0.4, 0)},
	"LT102": {"node": "Reactor?", "pos": Vector3(0.130, 1.803, 0.604), "y": 1.80, "offset": Vector3(0, -0.35, 0)},
	"LT103": {"node": "Tank_002", "abs": Vector3(-0.233, 1.527, -0.080)},
	"PT101": {"node": "PT101", "pos": Vector3(1.263, 2.162, 0.341), "y": 2.16},
	"PT102": {"node": "Pressure gauge", "pos": Vector3(-0.645, 0.660, -0.551), "y": 0.66},
	"TK101": {"node": "TK101 - Feed Tank", "abs": Vector3(-1.288, 1.100, 0.047)},
	"TK102": {"node": "TK102 - Distillate Tank", "abs": Vector3(-1.288, 1.100, 0.577)},
	"TK103": {"node": "TK103 - Bottoms Tank", "abs": Vector3(-1.288, 1.100, -0.466)},
	"P101": {"node": "Pumps", "pos": Vector3(-0.933, 0.264, -0.448), "y": 0.26},
	"P102": {"node": "PipeLine - Distillate Reflux", "abs": Vector3(0.808, 3.672, -0.124)},
	"P103": {"node": "PipeLine - Reboiler Outlet Liquid_001", "abs": Vector3(0.787, 1.226, -0.173)},
	"P104": {"node": "Vacuum", "pos": Vector3(0.449, 0.713, -0.311), "y": 0.71},
	"P105": {"node": "PipeLine - P105 Suction", "abs": Vector3(-1.173, 0.285, 0.056)},
	"P106": {"node": "PipeLine - P105 Discharge_002", "abs": Vector3(-0.945, 2.339, 0.535)},
	"V146": {"node": "V149", "pos": Vector3(-1.321, 0.283, -0.034), "y": 0.28},
}

## Human-readable label when metadata name is unavailable (never show raw Blender names with "?").
const TAG_DISPLAY_NAMES: Dictionary = {
	"R101": "Reflux drum",
	"LT102": "Reflux drum level",
	"TT113": "Reflux drum temperature",
	"E102": "Feed preheater",
	"E103": "Bottoms cooler",
	"E104": "Distillate cooler",
}

@export var plant_root_path: NodePath = ^"../../LSUDistillationLab"
@export var snap_to_model_nodes: bool = true
@export var collision_radius: float = 0.28
@export var large_equipment_radius: float = 0.65
## Also place every hotspot on the mirrored half of the plant (the plant is two mirror-image halves).
@export var mirror_hotspots: bool = true
@export var show_debug_meshes: bool = false
@export var editor_always_show_debug: bool = false

## The mirrored half is the original reflected across the plane z = MIRROR_PLANE_SUM / 2 of the plant model
## (measured from all 142 mirrored pieces, which match their originals to under a micrometre).
const MIRROR_PLANE_SUM := MirrorMaterialSync.PLANE_SUM
## Mirrored hotspots are named like the original plus this suffix, and show the original's equipment info.
const MIRROR_SUFFIX := "_M"

const LARGE_TAGS := ["B101", "R101", "TK101", "TK102", "TK103", "E102", "E103", "E104"]

var _plant_root: Node3D


func _ready() -> void:
	call_deferred("_build_hotspots")


func _build_hotspots() -> void:
	await get_tree().process_frame
	_plant_root = get_node_or_null(plant_root_path) as Node3D
	if _plant_root == null:
		_plant_root = _find_plant_root()
	var built := 0
	for tag in SCENE_PART_MAP.keys():
		if has_node(NodePath(tag)):
			continue
		var entry: Dictionary = SCENE_PART_MAP[tag]
		var local_pos: Vector3 = _resolve_position(tag, entry)
		_create_hotspot(tag, local_pos, str(entry.get("node", "")))
		built += 1
	_realign_from_model()
	var mirrored := _build_mirrored_hotspots()
	print("[DistillationHotspotBuilder] Built %d hotspots + %d mirrored (debug=%s)" % [built, mirrored, show_debug_meshes])
	var highlighter := get_parent()
	if highlighter and highlighter.has_method("_cache_highlight_areas"):
		highlighter.call_deferred("_cache_highlight_areas")


## Reflects a position of this node across the plant's mirror plane (in plant space, so it holds wherever
## the hotspots node sits).
func _mirror_position(local_pos: Vector3) -> Vector3:
	var in_plant := _plant_root.to_local(to_global(local_pos))
	in_plant.z = MIRROR_PLANE_SUM - in_plant.z
	return to_local(_plant_root.to_global(in_plant))


func _build_mirrored_hotspots() -> int:
	if not mirror_hotspots or _plant_root == null:
		return 0
	var built := 0
	for tag in SCENE_PART_MAP.keys():
		var original := get_node_or_null(NodePath(tag)) as Area3D
		if original == null or has_node(NodePath(tag + MIRROR_SUFFIX)):
			continue
		var radius := large_equipment_radius if tag in LARGE_TAGS else collision_radius
		var mirrored := _mirror_position(original.position)
		# Equipment on the mirror plane is its own twin: no second hotspot on top of the first.
		if original.position.distance_to(mirrored) < radius:
			continue
		_create_hotspot(tag + MIRROR_SUFFIX, mirrored, str(SCENE_PART_MAP[tag].get("node", "")), tag)
		built += 1
	return built


## Keeps each mirrored hotspot reflected from its (possibly re-snapped) original.
func _place_mirrored_hotspots() -> void:
	if not mirror_hotspots or _plant_root == null:
		return
	for tag in SCENE_PART_MAP.keys():
		var original := get_node_or_null(NodePath(tag)) as Area3D
		var twin := get_node_or_null(NodePath(tag + MIRROR_SUFFIX)) as Area3D
		if original and twin:
			twin.position = _mirror_position(original.position)


func _find_plant_root() -> Node3D:
	var n: Node = self
	while n != null:
		var candidate := n.get_node_or_null("LSUDistillationLab") as Node3D
		if candidate != null:
			return candidate
		n = n.get_parent()
	return null


func _realign_from_model() -> void:
	if not snap_to_model_nodes or _plant_root == null:
		return
	for tag in SCENE_PART_MAP.keys():
		var area := get_node_or_null(NodePath(tag)) as Area3D
		if area == null:
			continue
		var entry: Dictionary = SCENE_PART_MAP[tag]
		area.position = _resolve_position(tag, entry)
	_place_mirrored_hotspots()


## Where a hotspot goes (in this node's space). Entries may carry:
## - "abs":    a position measured on the model, in plant (LSUDistillationLab) space — used as is
## - "offset": added afterwards, to keep hotspots that share one piece of equipment pointable separately
## Otherwise the hotspot snaps to the middle of its "node" in the model, falling back to "pos".
func _resolve_position(tag: String, entry: Dictionary) -> Vector3:
	var offset: Vector3 = entry.get("offset", Vector3.ZERO)
	if entry.has("abs"):
		var plant_pos: Vector3 = entry["abs"]
		if _plant_root == null:
			return plant_pos + offset
		return to_local(_plant_root.to_global(plant_pos)) + offset
	return _resolve_snapped_position(tag, entry) + offset


func _resolve_snapped_position(_tag: String, entry: Dictionary) -> Vector3:
	var fallback: Vector3 = entry.get("pos", Vector3.ZERO)
	if not snap_to_model_nodes or _plant_root == null:
		return fallback

	var part_name: String = str(entry.get("node", ""))
	if part_name == "":
		return fallback

	var model_node := _find_model_node(part_name)
	if model_node == null:
		return fallback

	var local_pos := to_local(_mesh_anchor_world(model_node))
	if entry.get("fixed_y", false):
		local_pos.y = fallback.y
	return local_pos


## glTF import turns "." in Blender names into "_" ("Tank.002" -> "Tank_002") and the "-col" collision
## suffix isn't exported, so try those spellings too.
func _find_model_node(part_name: String) -> Node3D:
	for candidate in [part_name, part_name.replace(".", "_"), part_name.trim_suffix("-col"), part_name.trim_suffix("-col").replace(".", "_")]:
		var found := _find_node_by_name(_plant_root, candidate)
		if found != null:
			return found
	return null


func _mesh_anchor_world(node: Node3D) -> Vector3:
	var mesh_node := _find_mesh_instance(node)
	if mesh_node != null:
		var aabb := mesh_node.get_aabb()
		return mesh_node.global_transform * aabb.get_center()
	return node.global_transform.origin


func _find_mesh_instance(node: Node) -> MeshInstance3D:
	if node is MeshInstance3D and (node as MeshInstance3D).mesh:
		return node as MeshInstance3D
	for child in node.get_children():
		var found := _find_mesh_instance(child)
		if found != null:
			return found
	return null


func _find_node_by_name(node: Node, target_name: String) -> Node3D:
	if node.name == target_name:
		return node as Node3D
	for child in node.get_children():
		var found := _find_node_by_name(child, target_name)
		if found != null:
			return found
	return null


## [param source_tag] is the equipment tag for a mirrored hotspot (its node name is the tag plus MIRROR_SUFFIX).
func _create_hotspot(tag: String, local_pos: Vector3, part_name: String, source_tag: String = "") -> void:
	var equipment_tag := source_tag if source_tag != "" else tag
	var area := Area3D.new()
	area.name = tag
	# Hotspots only need to be *found* by the pointer ray (monitorable). Monitoring would make each of the 100
	# areas test every overlapping tri-mesh collider and every neighbouring hotspot, every physics step.
	area.collision_layer = POINTER_LAYER
	area.collision_mask = 0
	area.monitoring = false
	area.monitorable = true
	area.set_script(AREA_SCRIPT)
	area.position = local_pos
	add_child(area)
	area.set("metadata_id", equipment_tag)
	area.set("part_name", _display_name_for_tag(equipment_tag, part_name))

	var radius := large_equipment_radius if equipment_tag in LARGE_TAGS else collision_radius
	var shape := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = radius
	shape.shape = sphere
	area.add_child(shape)

	var label_node := Node.new()
	label_node.name = "ShowNameLabel"
	label_node.set_script(LABEL_SCRIPT)
	area.add_child(label_node)

	var highlight := HIGHLIGHT_SCENE.instantiate()
	highlight.name = "Highlight"
	highlight.visible = false
	var s := radius * 2.2
	highlight.scale = Vector3(s, s, s)
	area.add_child(highlight)

	var debug := MeshInstance3D.new()
	debug.name = "DebugSphere"
	var mesh := SphereMesh.new()
	mesh.radius = radius
	mesh.height = radius * 2.0
	debug.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(0.1, 0.95, 1.0, 0.45)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.no_depth_test = true
	mat.render_priority = 10
	debug.material_override = mat
	debug.visible = show_debug_meshes or editor_always_show_debug
	area.add_child(debug)

	var tag_label := Label3D.new()
	tag_label.name = "DebugTag"
	tag_label.text = tag
	tag_label.font_size = 48
	tag_label.modulate = Color(1.0, 1.0, 0.2)
	tag_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	tag_label.position = Vector3(0.0, radius + 0.08, 0.0)
	tag_label.scale = Vector3(0.004, 0.004, 0.004)
	tag_label.visible = show_debug_meshes or editor_always_show_debug
	area.add_child(tag_label)


func _display_name_for_tag(tag: String, node_name: String) -> String:
	var meta := MetadataManager.get_metadata(tag)
	if not meta.is_empty():
		var name_val := str(meta.get("name", "")).replace("?", "").strip_edges()
		if name_val != "":
			return name_val
	if TAG_DISPLAY_NAMES.has(tag):
		return TAG_DISPLAY_NAMES[tag]
	return node_name.replace("?", "").strip_edges()
