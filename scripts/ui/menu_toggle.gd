extends Node

@onready var viewport_2_din_3d: XRToolsViewport2DIn3D = $".."
@export var camera_node : XRCamera3D
@export var follow_distance : float = 2.0
@export var lag_speed : float = 4.0


func _ready() -> void:
	# Only process menu position calculation when menu is visible
	set_process(viewport_2_din_3d.visible)
	if multiplayer.multiplayer_peer:
		print("[MenuToggle][DemoMode] Ready: %s (peer_id=%s) - menu %s" % ["host" if multiplayer.is_server() else "client", multiplayer.get_unique_id(), "full" if multiplayer.is_server() else "pencil only"])

func _on_left_controller_button_pressed(button_name: String) -> void:
	if button_name != "menu_button":
		return
	# Demo mode: clients get a reduced menu (pencil only); host controls stay host-only
	# (item_visibility_toggle.gd hides the host rows on clients).

	# Toggle visibility
	viewport_2_din_3d.visible =  not viewport_2_din_3d.visible
	# Only run the Menu positioning algorithm when the Menu is visible
	set_process(viewport_2_din_3d.visible)
	print("[MenuToggle] Menu ", "opened" if viewport_2_din_3d.visible else "closed")
	if viewport_2_din_3d.visible:
		# Snap Menu to the exact target position + orientation
		_snap_menu_to_camera()


func _process(delta: float) -> void:
	
	# 1) Compute target in front of camera
	var cam_xform = camera_node.global_transform
	var target_point = cam_xform.origin + cam_xform.basis.z * -follow_distance
	
	# 2) Lerp current -> target
	var cur_pos = viewport_2_din_3d.global_transform.origin
	var t = clamp(lag_speed * delta, 0.0, 1.0)
	var new_pos = cur_pos.lerp(target_point, t)
	
	# 3) Apply position and face camera
	var vt = viewport_2_din_3d.global_transform
	vt.origin = new_pos
	viewport_2_din_3d.global_transform = vt
	viewport_2_din_3d.look_at(camera_node.global_transform.origin, Vector3.UP)
	viewport_2_din_3d.rotate_object_local(Vector3.UP,PI)

func _snap_menu_to_camera() -> void:
	# Compute the exact spot in front of the camera
	var cam_xform = camera_node.global_transform
	var adjusted_direction = cam_xform.basis.z * -follow_distance
	var target_point = cam_xform.origin + adjusted_direction
	# Build a transform at that spot, looking back at camera
	var xf = Transform3D()
	xf.origin = target_point
	xf = xf.looking_at(camera_node.global_transform.origin, Vector3.UP)
	
	viewport_2_din_3d.global_transform = xf
	viewport_2_din_3d.rotate_object_local(Vector3.UP,PI)
