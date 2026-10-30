class_name PencilVisual
extends Node3D

## The pencil model on its own (no physics): used by the grabbable PencilTool and for other players'
## pencils, which NetworkAnnotations shows wherever their owner is holding them.
##
## Long axis is Z, the writing tip at the front (-Z). The band near the eraser shows the ink color.

const LENGTH := 0.22
const RADIUS := 0.009
const TIP_LENGTH := 0.04
const ERASER_LENGTH := 0.02
const FERRULE_LENGTH := 0.014

## Point the ink comes from.
var tip: Marker3D

var _band_material: StandardMaterial3D


func _init() -> void:
	_build()


func set_ink_color(color: Color) -> void:
	_band_material.albedo_color = color
	_band_material.emission_enabled = true
	_band_material.emission = color
	_band_material.emission_energy_multiplier = 0.6


func _build() -> void:
	var half := LENGTH * 0.5
	var body_start := -half + TIP_LENGTH
	var body_end := half - ERASER_LENGTH - FERRULE_LENGTH

	# Wooden cone, then graphite point on its end.
	_add_part(_cone(TIP_LENGTH, RADIUS), _material(Color(0.9, 0.72, 0.5)), -half + TIP_LENGTH * 0.5)
	_add_part(_cone(TIP_LENGTH * 0.3, RADIUS * 0.3), _material(Color(0.12, 0.12, 0.14)), -half + TIP_LENGTH * 0.15)
	# Yellow barrel.
	_add_part(_cylinder(body_end - body_start, RADIUS), _material(Color(1.0, 0.78, 0.1)), (body_start + body_end) * 0.5)
	# Metal ferrule, ink band, eraser.
	var ferrule_material := _material(Color(0.78, 0.78, 0.82))
	ferrule_material.metallic = 0.8
	_add_part(_cylinder(FERRULE_LENGTH, RADIUS * 1.05), ferrule_material, body_end + FERRULE_LENGTH * 0.5)
	_band_material = _material(Color(1.0, 0.85, 0.1))
	_add_part(_cylinder(0.008, RADIUS * 1.08), _band_material, body_end - 0.012)
	_add_part(_cylinder(ERASER_LENGTH, RADIUS), _material(Color(0.95, 0.5, 0.55)), half - ERASER_LENGTH * 0.5)

	tip = Marker3D.new()
	tip.name = "Tip"
	tip.position = Vector3(0.0, 0.0, -half)
	add_child(tip)


## Meshes are built along +Y; rotating -90 degrees about X lays them along -Z (apex toward the front).
func _add_part(mesh: Mesh, material: Material, z: float) -> void:
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.material_override = material
	instance.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	instance.position = Vector3(0.0, 0.0, z)
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(instance)


func _cylinder(length: float, radius: float) -> CylinderMesh:
	var mesh := CylinderMesh.new()
	mesh.top_radius = radius
	mesh.bottom_radius = radius
	mesh.height = length
	mesh.radial_segments = 12
	mesh.rings = 1
	return mesh


func _cone(length: float, radius: float) -> CylinderMesh:
	var mesh := CylinderMesh.new()
	mesh.top_radius = 0.0
	mesh.bottom_radius = radius
	mesh.height = length
	mesh.radial_segments = 12
	mesh.rings = 1
	return mesh


func _material(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.6
	return material
