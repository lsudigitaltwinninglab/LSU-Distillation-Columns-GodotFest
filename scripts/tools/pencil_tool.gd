class_name PencilTool
extends XRToolsPickable

## Grabbable VR pencil (spawned by NetworkAnnotations when the menu's Pencil toggle is on).
##
## - Grip to pick it up with either hand (or ranged-grab it with the pointer); it stays where
##   it is released instead of falling.
## - While it is held, NetworkAnnotations lets you draw from [member tip]:
##   A = draw, X = erase, hold X = erase all, B = swap red / yellow ink (host).
## - The band near the eraser shows your ink color.
## - Other players see the pencil too (NetworkAnnotations streams it as a PencilVisual).

## Physics layer 26: outside every body's mask (the player body only collides with layers 1-25), so the
## pencil never blocks or shoves anything. Only the hands' pickup areas look for it (see _ready).
const PENCIL_LAYER := 1 << 25

## Point the ink comes from (front end of the pencil, forward is -Z).
var tip: Marker3D

var _held: bool = false
var _visual: PencilVisual
var _hint: Label3D


func _init() -> void:
	collision_layer = PENCIL_LAYER
	collision_mask = 0
	gravity_scale = 0.0
	freeze = true
	freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	release_mode = ReleaseMode.FROZEN
	ranged_grab_method = RangedMethod.LERP
	second_hand_grab = SecondHandGrab.SWAP
	_build()


func _ready() -> void:
	super._ready()
	picked_up.connect(_on_picked_up)
	dropped.connect(_on_dropped)
	_let_hands_grab_pencil_layer()


## The pencil's layer is outside the hands' default pickup masks: add it so grip and ranged grab still find it.
func _let_hands_grab_pencil_layer() -> void:
	var origin := get_tree().get_first_node_in_group("xr_origin")
	if not origin:
		return
	for node in origin.find_children("*", "", true, false):
		var pickup := node as XRToolsFunctionPickup
		if pickup:
			pickup.grab_collision_mask |= PENCIL_LAYER
			pickup.ranged_collision_mask |= PENCIL_LAYER


func is_held() -> bool:
	return _held


## Tint the ink band and hint text with the local player's ink color.
func set_ink_color(color: Color) -> void:
	_visual.set_ink_color(color)
	if _hint:
		_hint.modulate = color


func set_hint_text(text: String) -> void:
	if _hint:
		_hint.text = text


## Show the controls hint while holding the pencil and not drawing.
func set_drawing(drawing: bool) -> void:
	if _hint:
		_hint.visible = _held and not drawing


## Short haptic tick on the holding hand (called while ink is laid down).
func pulse() -> void:
	var controller := get_picked_up_by_controller()
	if controller:
		controller.trigger_haptic_pulse("haptic", 0.0, 0.2, 0.04, 0.0)


func _on_picked_up(_pickable: Variant) -> void:
	_held = true
	if _hint:
		_hint.visible = true


func _on_dropped(_pickable: Variant) -> void:
	_held = false
	if _hint:
		_hint.visible = false


func _build() -> void:
	_visual = PencilVisual.new()
	_visual.name = "Visual"
	add_child(_visual)
	tip = _visual.tip

	# Generous grab volume so the pencil is easy to catch.
	var shape := CollisionShape3D.new()
	shape.name = "CollisionShape3D"
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.03
	capsule.height = PencilVisual.LENGTH + 0.04
	shape.shape = capsule
	shape.rotation_degrees = Vector3(90.0, 0.0, 0.0)
	add_child(shape)

	_hint = Label3D.new()
	_hint.name = "Hint"
	_hint.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_hint.font_size = 24
	_hint.pixel_size = 0.0006
	_hint.outline_size = 6
	_hint.no_depth_test = true
	_hint.position = Vector3(0.0, 0.07, 0.0)
	_hint.visible = false
	add_child(_hint)
