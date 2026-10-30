extends Node
class_name SharedInspection

## Real-time shared equipment inspection (Map/SharedInspection in ar_network_arena).
##
## - LEFT trigger on a hotspot opens its metadata label for that player only (show_name_label.gd).
## - RIGHT trigger on a hotspot shares it: every peer sees the highlight, beam and label,
##   tagged with who shared it and tinted with that player's ink color.
## - Any peer may share; the RPC relays through the server to all peers.
##
## RPC inventory:
## | RPC | Direction | Reliability | Purpose |
## |-----|-----------|-------------|---------|
## | _rpc_share_hotspot | any → all (call_local) | reliable | Highlight hotspot on every peer |

signal hotspot_shared(peer_id: int, hotspot_name: String)

## Minimum seconds between shares from this peer (avoids trigger-spam floods).
@export var share_cooldown: float = 0.5

var _last_share_msec: int = -100000


func _ready() -> void:
	add_to_group("shared_inspection")


## Called locally when this peer selects a hotspot (trigger press while pointing).
func share_hotspot(hotspot_name: String) -> void:
	if hotspot_name == "":
		return
	var now := Time.get_ticks_msec()
	if now - _last_share_msec < int(share_cooldown * 1000.0):
		return
	_last_share_msec = now
	_rpc_share_hotspot.rpc(hotspot_name)


@rpc("any_peer", "call_local", "reliable")
func _rpc_share_hotspot(hotspot_name: String) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if sender == 0:
		sender = multiplayer.get_unique_id()
	var who := NetworkAnnotations.player_name_for_peer(sender)
	if sender == multiplayer.get_unique_id():
		who = "You"
	var color := NetworkAnnotations.color_for_peer(sender)

	var highlighter := get_tree().get_first_node_in_group("distillation_hotspot_highlighter")
	if highlighter and highlighter.has_method("highlight_shared"):
		highlighter.highlight_shared(hotspot_name, who, color)
	hotspot_shared.emit(sender, hotspot_name)
	print("[SharedInspection] %s shared %s" % [who, hotspot_name])
