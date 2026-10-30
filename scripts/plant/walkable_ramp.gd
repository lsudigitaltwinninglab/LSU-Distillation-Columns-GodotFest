@tool
extends StaticBody3D

## Editor-placeable walkable ramp (scene: scenes/network/arena/ramp.tscn).
##
## Instance under Map, align over stairs or slopes. Collision layer 1 matches player body mask.
## debug_visible shows a box mesh + label in-editor; turn off for shipping builds.
##
## ramp_width / ramp_length resize the box collider; thickness is fixed (RAMP_THICKNESS).

@export var debug_visible: bool = true:
	set(value):
		debug_visible = value
		_update_visual()

@export var ramp_width: float = 1.2:
	set(value):
		ramp_width = value
		_update_shape()

@export var ramp_length: float = 3.0:
	set(value):
		ramp_length = value
		_update_shape()

const RAMP_THICKNESS := 0.08

var _resources_unique: bool = false


func _ready() -> void:
	collision_layer = 1
	collision_mask = 0
	_ensure_unique_resources()
	_update_shape()
	_update_visual()


func _ensure_unique_resources() -> void:
	# Duplicated shapes/meshes so editing one ramp instance does not affect others.
	if _resources_unique:
		return
	_resources_unique = true

	var col := get_node_or_null("CollisionShape3D") as CollisionShape3D
	if col and col.shape:
		col.shape = col.shape.duplicate()

	var mesh_node := get_node_or_null("DebugMesh") as MeshInstance3D
	if mesh_node and mesh_node.mesh:
		mesh_node.mesh = mesh_node.mesh.duplicate()


func _update_shape() -> void:
	_ensure_unique_resources()

	var col := get_node_or_null("CollisionShape3D") as CollisionShape3D
	if col and col.shape is BoxShape3D:
		col.shape.size = Vector3(ramp_width, RAMP_THICKNESS, ramp_length)

	var mesh_node := get_node_or_null("DebugMesh") as MeshInstance3D
	if mesh_node and mesh_node.mesh is BoxMesh:
		mesh_node.mesh.size = Vector3(ramp_width, RAMP_THICKNESS, ramp_length)

	var label := get_node_or_null("Label3D") as Label3D
	if label:
		label.position.y = RAMP_THICKNESS * 0.5 + 0.15


func _update_visual() -> void:
	var mesh_node := get_node_or_null("DebugMesh") as MeshInstance3D
	if mesh_node:
		mesh_node.visible = debug_visible

	var label := get_node_or_null("Label3D") as Label3D
	if label:
		label.visible = debug_visible
