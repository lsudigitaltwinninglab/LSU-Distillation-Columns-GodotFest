extends StaticBody3D

# This script adjusts the Ground plane vertical position to align objects in AR mode

@export var y_scale : float = 1.0 # Slider world scale units

var _slider_connect_attempts : int = 0
const MAX_SLIDER_CONNECT_ATTEMPTS : int = 10

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	call_deferred("_connect_slider")

func _connect_slider() -> void:
	_slider_connect_attempts += 1
	var slider = get_tree().get_first_node_in_group("ground_adjust_slider")
	if slider:
		slider.value_changed.connect(_on_slider_value_changed)
	elif _slider_connect_attempts < MAX_SLIDER_CONNECT_ATTEMPTS:
		# keep waiting next frame for slider to be created
		call_deferred("_connect_slider")
	# else: give up, slider doesn't exist in this scene

func _on_slider_value_changed(value: float) -> void:
	var new_y = -value * y_scale
	
	var t = global_transform
	t.origin.y = new_y
	global_transform = t
	
