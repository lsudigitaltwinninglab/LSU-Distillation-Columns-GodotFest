@tool
extends Node3D

## Walk-through-aware colliders for the distillery GLB.
##
## Editor workflow:
## 1. Select LSUDistillationLab in scenes/plant/lsu_distillation_lab.tscn
## 2. Toggle show_debug_colliders to see red collision boxes
## 3. Edit/delete/move bodies under GeneratedStaticColliders, then save the scene
## 4. Set regenerate_colliders = true only when you want to rebuild from mesh geometry

const STATIC_LAYER := 1

const SKIP_NAME_PARTS := [
	"GN Instance", "Bolt", "Flange", "Mirror", "Valve.", "Valve Test",
	"Hook", "Circle.010", "Ladder", "Instrumentation", "Electric",
	"Pipe.", "pipe.",
]

const FULL_HEIGHT_NAMES := ["Cylinder.023", "MetalFrame"]

const SOLID_VOLUME_NAMES := [
	"Cylinder.023", "MetalFrame", "Body", "Reactor",
	"TK101", "TK102", "TK103", "Tank.002", "Tank.003", "Tank-col", "Tank.001-col",
	"Pump-col", "pump-col", "Pumps", "Cylinder-col", "Cylinder.004-col",
	"TankFront", "Tanks", "TankParts", "TankFP.001",
]

var _regenerate_colliders: bool = false
var _show_debug_colliders: bool = true

@export_group("Collision Generation")
@export var walk_clearance_height: float = 1.75
@export var max_body_height: float = 1.35
@export var min_mesh_extent: float = 0.08
@export var max_colliders: int = 96
@export var regenerate_colliders: bool = false:
	get:
		return _regenerate_colliders
	set(value):
		_regenerate_colliders = value
		if value and is_inside_tree():
			call_deferred("_build_colliders")

@export_group("Debug")
@export var show_debug_colliders: bool = true:
	get:
		return _show_debug_colliders
	set(value):
		_show_debug_colliders = value
		_update_debug_visibility()

var _floor_y: float = 0.0
var _debug_material: StandardMaterial3D


func _ready() -> void:
	call_deferred("_build_colliders")


func _build_colliders() -> void:
	var existing := get_node_or_null("GeneratedStaticColliders") as Node3D
	if existing and not regenerate_colliders:
		_update_debug_visibility()
		return
	if existing:
		existing.queue_free()

	_floor_y = _estimate_floor_y()

	var container := Node3D.new()
	container.name = "GeneratedStaticColliders"
	add_child(container)
	if Engine.is_editor_hint() and get_tree():
		container.owner = get_tree().edited_scene_root

	var built := 0
	for mesh_inst in find_children("*", "MeshInstance3D", true, false):
		if built >= max_colliders:
			break
		if _should_skip(mesh_inst.name):
			continue
		if _add_mesh_collider(container, mesh_inst as MeshInstance3D):
			built += 1

	_regenerate_colliders = false
	_update_debug_visibility()
	print("[DistilleryLabCollision] Built %d colliders (floor_y=%.2f, debug=%s)" % [built, _floor_y, _show_debug_colliders])


func _estimate_floor_y() -> float:
	var column := find_child("Cylinder.023", true, false) as Node3D
	if column:
		return column.global_transform.origin.y
	return global_transform.origin.y


func _should_skip(node_name: String) -> bool:
	for part in SKIP_NAME_PARTS:
		if part in node_name:
			return true
	return false


func _is_solid_volume(node_name: String) -> bool:
	for part in SOLID_VOLUME_NAMES:
		if part in node_name:
			return true
	return false


func _is_full_height(node_name: String) -> bool:
	for part in FULL_HEIGHT_NAMES:
		if part in node_name:
			return true
	return false


func _global_mesh_aabb(mesh_inst: MeshInstance3D) -> AABB:
	var local := mesh_inst.get_aabb()
	return mesh_inst.global_transform * local


func _get_debug_material() -> StandardMaterial3D:
	if _debug_material == null:
		_debug_material = StandardMaterial3D.new()
		_debug_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_debug_material.albedo_color = Color(0.95, 0.25, 0.15, 0.38)
		_debug_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_debug_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	return _debug_material


func _update_debug_visibility() -> void:
	var container := get_node_or_null("GeneratedStaticColliders")
	if container == null:
		return
	var show_debug := _show_debug_colliders and Engine.is_editor_hint()
	for body in container.get_children():
		if body is StaticBody3D:
			var debug := body.get_node_or_null("DebugMesh") as MeshInstance3D
			if debug:
				debug.visible = show_debug
		elif body is Node3D:
			for child in body.get_children():
				if child is StaticBody3D:
					var debug := child.get_node_or_null("DebugMesh") as MeshInstance3D
					if debug:
						debug.visible = show_debug


func _add_mesh_collider(container: Node3D, mesh_inst: MeshInstance3D) -> bool:
	var mesh := mesh_inst.mesh
	if mesh == null:
		return false

	var global_aabb := _global_mesh_aabb(mesh_inst)
	var size := global_aabb.size
	if size.length() < min_mesh_extent:
		return false

	var walk_ceil := _floor_y + walk_clearance_height
	var aabb_bottom := global_aabb.position.y

	if aabb_bottom > walk_ceil + 0.05:
		return false

	var is_pipe := size.y < 0.22 and maxf(size.x, size.z) > 0.35
	if is_pipe and aabb_bottom > _floor_y + 0.9:
		return _add_tight_box(container, mesh_inst, global_aabb, Vector3(size.x, minf(size.y, 0.14), size.z))

	if not _is_solid_volume(mesh_inst.name):
		if maxf(size.x, maxf(size.y, size.z)) < 0.2:
			return false
		if aabb_bottom > _floor_y + 0.5 and not is_pipe:
			return false

	var collider_size := size
	var collider_center := global_aabb.get_center()

	if _is_full_height(mesh_inst.name):
		collider_size = Vector3(size.x * 0.88, size.y, size.z * 0.88)
	elif is_pipe:
		collider_size = Vector3(size.x, minf(size.y, 0.14), size.z)
	else:
		var body_height := minf(size.y, max_body_height)
		collider_center.y = aabb_bottom + body_height * 0.5
		collider_size = Vector3(size.x * 0.85, body_height, size.z * 0.85)

	return _add_tight_box(container, mesh_inst, global_aabb, collider_size, collider_center)


func _add_tight_box(
		container: Node3D,
		mesh_inst: MeshInstance3D,
		global_aabb: AABB,
		box_size: Vector3,
		center_override: Vector3 = Vector3.INF
) -> bool:
	if box_size.x < 0.04 or box_size.z < 0.04 or box_size.y < 0.04:
		return false

	var body := StaticBody3D.new()
	body.name = "%s_Collision" % mesh_inst.name
	body.collision_layer = STATIC_LAYER
	body.collision_mask = 0
	body.add_to_group("distillery_collider")
	container.add_child(body)
	if Engine.is_editor_hint() and get_tree():
		body.owner = get_tree().edited_scene_root

	var center := center_override if center_override != Vector3.INF else global_aabb.get_center()
	body.global_position = center

	var shape_node := CollisionShape3D.new()
	shape_node.name = "CollisionShape3D"
	var box := BoxShape3D.new()
	box.size = Vector3(maxf(box_size.x, 0.04), maxf(box_size.y, 0.04), maxf(box_size.z, 0.04))
	shape_node.shape = box
	body.add_child(shape_node)
	if Engine.is_editor_hint() and get_tree():
		shape_node.owner = get_tree().edited_scene_root

	var debug := MeshInstance3D.new()
	debug.name = "DebugMesh"
	var debug_mesh := BoxMesh.new()
	debug_mesh.size = box.size
	debug.mesh = debug_mesh
	debug.material_override = _get_debug_material()
	debug.visible = _show_debug_colliders and Engine.is_editor_hint()
	body.add_child(debug)
	if Engine.is_editor_hint() and get_tree():
		debug.owner = get_tree().edited_scene_root

	return true
