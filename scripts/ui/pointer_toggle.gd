extends Node3D

@onready var function_pointer: XRToolsFunctionPointer = $"../FunctionPointer"

var is_pressed: bool = false

func _ready() -> void:
	# Keep pointer available at all times for demo usability.
	function_pointer.enabled = true
	function_pointer.show_laser = function_pointer.LaserShow.SHOW


func _on_left_controller_button_pressed(button_name: String) -> void:
	if button_name == "by_button":
		is_pressed = !is_pressed
		function_pointer.enabled = !function_pointer.enabled
		if function_pointer.enabled:
			function_pointer.show_laser = function_pointer.LaserShow.SHOW
		else:
			function_pointer.show_laser = function_pointer.LaserShow.HIDE


func _on_right_controller_button_pressed(button_name: String) -> void:
	if button_name == "by_button":
		is_pressed = !is_pressed
		function_pointer.enabled = !function_pointer.enabled
		if function_pointer.enabled:
			function_pointer.show_laser = function_pointer.LaserShow.SHOW
		else:
			function_pointer.show_laser = function_pointer.LaserShow.HIDE
