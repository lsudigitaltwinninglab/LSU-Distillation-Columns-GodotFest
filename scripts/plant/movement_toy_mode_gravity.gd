extends XRToolsMovementProvider

## Toy model mode — zero player gravity (order 5).
##
## Enabled/disabled by ModelSyncManager._apply_toy_mode_gravity() on all peers when
## the host toggles toy model mode (MenuControl → ModelSyncManager).
##
## Must be in group "movement_providers" AND "toy_mode_gravity_override" (arena scene).
## Do not use WorldGrabArea gravity_space_override — that zeroed the whole physics
## space and caused slow upward drift on the character.
##
## Starts disabled; only active while toy model mode is on.

@export var order: int = 5


func _ready() -> void:
	add_to_group("toy_mode_gravity_override")
	enabled = false


func physics_pre_movement(_delta: float, player_body: XRToolsPlayerBody) -> void:
	if not enabled:
		return
	player_body.gravity = Vector3.ZERO
