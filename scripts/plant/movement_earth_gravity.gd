extends XRToolsMovementProvider

## Default player gravity for the AR arena (order 4).
##
## Must be in group "movement_providers" on the node (see ar_network_arena.tscn).
## XRToolsPlayerBody only runs providers from that group, sorted by `order`.
##
## Runs before MovementToyModeGravity (order 5), which can zero gravity in toy model mode.

@export var order: int = 4
@export var gravity_mps2: float = 9.81


func physics_pre_movement(_delta: float, player_body: XRToolsPlayerBody) -> void:
	if not enabled:
		return
	player_body.gravity = Vector3(0.0, -gravity_mps2, 0.0)
