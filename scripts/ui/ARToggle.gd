extends HBoxContainer


@export var toggled_on: bool = false

@onready var ar_button: Button = $ARButton
@onready var vr_button: Button = $VRButton


func _ready() -> void:
	# ensure buttons can be toggled
	ar_button.toggle_mode = true
	vr_button.toggle_mode = true

	# connect their toggled signals
	if not ar_button.is_connected("toggled", Callable(self, "_on_ar_button_toggled")):
		ar_button.toggled.connect(_on_ar_button_toggled)
	if not vr_button.is_connected("toggled", Callable(self, "_on_vr_button_toggled")):
		vr_button.toggled.connect(_on_vr_button_toggled)


func _on_vr_button_toggled(pressed: bool) -> void:
	if pressed:
		# when VR goes on, turn AR off
		ar_button.set_pressed_no_signal(false)
		MenuControl._on_vrar_h_box_container_ar_toggle(false)

#Confirm
func _on_ar_button_toggled(pressed: bool) -> void:
	if pressed:
		# when AR goes on, turn VR off
		vr_button.set_pressed_no_signal(false)
		MenuControl._on_vrar_h_box_container_ar_toggle(true)
