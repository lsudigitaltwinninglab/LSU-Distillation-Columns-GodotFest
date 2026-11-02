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


## Toy mode also turns off the player's collision (ModelSyncManager), so the body is never on the
## ground: XRToolsPlayerBody then applies no drag, and keeps re-adding the ground_velocity it last
## measured. Whatever the body was doing when toy mode started — e.g. riding a client's model as
## the host sync or QR re-anchor moved it — would carry the player away forever. Hold it still;
## head tracking (_update_body_under_camera) still moves the body as the player walks.
func physics_pre_movement(_delta: float, player_body: XRToolsPlayerBody) -> void:
	if not enabled:
		return
	player_body.gravity = Vector3.ZERO
	player_body.velocity = Vector3.ZERO
	player_body.ground_velocity = Vector3.ZERO
