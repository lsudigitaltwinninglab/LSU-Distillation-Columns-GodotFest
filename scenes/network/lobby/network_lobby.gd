extends XRToolsSceneBase

const ARENA_SCENE := "res://scenes/network/arena/ar_network_arena.tscn"
const LOBBY_2D_SCENE := preload("res://scenes/network/lobby/lobby_2d.tscn")

@onready var lobby_menu: Node = $Map/LobbyMenu


func _ready() -> void:
	super()

	# Ensure networking is disabled before the user hosts or joins.
	multiplayer.multiplayer_peer = null
	_connect_network_signals()
	if SpectatorMode.is_active():
		_setup_spectator_lobby()


## No headset: the floating 3D lobby can't be used, so show the same lobby as a normal 2D window
## that joins the first game it finds (spectators never host).
func _setup_spectator_lobby() -> void:
	lobby_menu.visible = false
	lobby_menu.process_mode = Node.PROCESS_MODE_DISABLED

	var layer := CanvasLayer.new()
	layer.name = "SpectatorLobbyLayer"
	layer.layer = 10
	add_child(layer)

	var backdrop := ColorRect.new()
	backdrop.color = Color(0.05, 0.06, 0.08)
	backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	layer.add_child(backdrop)

	var lobby := LOBBY_2D_SCENE.instantiate()
	lobby.auto_join = true
	layer.add_child(lobby)


func _exit_tree() -> void:
	_disconnect_network_signals()


func _connect_network_signals() -> void:
	var connected_callback := Callable(self, "_on_connected_to_server")
	if not multiplayer.connected_to_server.is_connected(connected_callback):
		multiplayer.connected_to_server.connect(connected_callback)

	var lobby_scene: Node = lobby_menu.get_scene_instance()
	var server_started_callback := Callable(self, "_on_server_started")
	if lobby_scene and lobby_scene.has_signal("server_started"):
		if not lobby_scene.is_connected("server_started", server_started_callback):
			lobby_scene.connect("server_started", server_started_callback)


func _disconnect_network_signals() -> void:
	var connected_callback := Callable(self, "_on_connected_to_server")
	if multiplayer.connected_to_server.is_connected(connected_callback):
		multiplayer.connected_to_server.disconnect(connected_callback)

	var lobby_scene: Node = lobby_menu.get_scene_instance()
	var server_started_callback := Callable(self, "_on_server_started")
	if lobby_scene and lobby_scene.has_signal("server_started"):
		if lobby_scene.is_connected("server_started", server_started_callback):
			lobby_scene.disconnect("server_started", server_started_callback)


func _on_connected_to_server() -> void:
	_load_arena()


func _on_server_started() -> void:
	_load_arena()


func _load_arena() -> void:
	load_scene(ARENA_SCENE)
