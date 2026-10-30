extends Control

## Lobby UI — ENet connection + LAN discovery.
##
## Flow:
## 1. Host: create_server(port) → set ServiceDiscovery server_data → broadcast UDP 4040
## 2. Client: scan_lan_servers() or manual IP → create_client(host, port)
## 3. On connect: network_lobby.gd loads ar_network_arena.tscn (peer persists across scene change)
##
## Uses ServiceDiscovery autoload from lan_servers_discovery addon.

signal server_started

const SERVER_NAME := "AR Distillery Game"
const SCANNING_MESSAGE := "Scanning for games..."
const EMPTY_MESSAGE := "No LAN games found. Tap Refresh or use Manual Join."

@onready var server_list_container: VBoxContainer = $Panel/VBoxContainer/HBoxContainer/Panel/ServerListSection/MarginContainer/VBoxContainer/MarginContainer2/VBoxContainer/ServerListScroll/ServerList

## Spectator overlay (set by network_lobby.gd before it enters the tree): hide hosting, join the
## first LAN game found (or SpectatorMode.join_host), and keep rescanning until one appears.
var auto_join: bool = false

const AUTO_JOIN_RESCAN_SECONDS := 4.0

var _scanning: bool = false
var _connecting: bool = false
var _known_server_keys: Dictionary = {}

func _ready() -> void:
	# Drop existing network
	multiplayer.multiplayer_peer = null

	_connect_service_discovery_signals()
	if not multiplayer.connection_failed.is_connected(_on_connection_failed):
		multiplayer.connection_failed.connect(_on_connection_failed)

	# Initial scan
	_refresh_server_list()

	if auto_join:
		_setup_spectator_lobby()


func _setup_spectator_lobby() -> void:
	var host_panel := get_node_or_null("Panel/VBoxContainer/HBoxContainer/Panel2")
	if host_panel:
		host_panel.visible = false
	var host_separator := get_node_or_null("Panel/VBoxContainer/HBoxContainer/VSeparator")
	if host_separator:
		host_separator.visible = false
	var subtitle := get_node_or_null("Panel/VBoxContainer/VBoxContainer2/VBoxContainer/Subtitle") as Label
	if subtitle:
		subtitle.text = "Spectator mode: joins the first LAN game found."

	if SpectatorMode.join_host != "":
		_join_server(SpectatorMode.join_host, SpectatorMode.join_port)

	var timer := Timer.new()
	timer.wait_time = AUTO_JOIN_RESCAN_SECONDS
	timer.autostart = true
	timer.timeout.connect(_on_auto_join_rescan)
	add_child(timer)


## No game found yet (or the last attempt failed): scan again until one shows up.
func _on_auto_join_rescan() -> void:
	if not _connecting and not _scanning and _known_server_keys.is_empty():
		_refresh_server_list()


func _exit_tree() -> void:
	# Don't stop server here - let it continue broadcasting in the game scene
	_disconnect_service_discovery_signals()
	if multiplayer.connection_failed.is_connected(_on_connection_failed):
		multiplayer.connection_failed.disconnect(_on_connection_failed)


func _on_quit_button_pressed() -> void:
	get_tree().quit()


func _on_host_button_pressed() -> void:
	print("[Lobby2D] Host button pressed")
	
	# Create the server
	var port := roundi(%HostPort.value)
	print("[Lobby2D] Creating server on port: ", port)
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(port)
	if err != OK:
		print("[Lobby2D] Error ", err, " creating server")
		return

	# Use the server
	print("[Lobby2D] Server created successfully")
	multiplayer.multiplayer_peer = peer
	
	# Advertise the game on the LAN. The broadcast itself starts once the host's arena has loaded
	# (ar_network_arena.gd), so a client that finds the game never joins a half-loaded host.
	if ServiceDiscovery:
		ServiceDiscovery.server_data = {
			'Name': SERVER_NAME,
			'port': port
		}

	server_started.emit()


func _on_join_button_pressed() -> void:
	# Manual join with IP
	var host := str(%JoinHost.text).strip_edges()
	var port := roundi(%JoinPort.value)
	_join_server(host, port)


func _join_server(host: String, port: int) -> void:
	if _connecting:
		return
	if host.is_empty():
		_show_join_status("Enter the host's IP address first.", Color(1.0, 0.6, 0.4))
		return
	print("[Lobby2D] Joining server at ", host, ":", port)

	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(host, port)
	if err != OK:
		print("[Lobby2D] Error ", err, " creating client")
		_show_join_status("Could not start connection (error %d). Check the IP and port." % err, Color(1.0, 0.6, 0.4))
		return

	# Use the client - lobby loads arena on server-connect
	multiplayer.multiplayer_peer = peer
	_connecting = true
	_show_join_status("Connecting to %s:%d..." % [host, port], Color(0.6, 0.6, 0.6))


## ENet gave up reaching the host (wrong IP/port, host not running, different network, firewall).
func _on_connection_failed() -> void:
	_connecting = false
	multiplayer.multiplayer_peer = null
	_show_join_status("Could not reach the host. Check the IP, port and that both devices are on the same network.", Color(1.0, 0.6, 0.4))


func _show_join_status(text: String, color: Color) -> void:
	if not server_list_container:
		return
	_clear_server_list()
	_known_server_keys.clear()
	_show_status_message(text, color, true)


func _on_refresh_button_pressed() -> void:
	print("[Lobby2D] Refreshing server list...")
	_refresh_server_list()


## Called when ServiceDiscovery finds a server during scan
func _on_scanned_server(data) -> void:
	# Add server to list immediately
	_add_server_to_list(data)


## Called when ServiceDiscovery scan completes
func _on_scan_complete() -> void:
	_scanning = false
	if _connecting:
		return
	if server_list_container and _known_server_keys.is_empty():
		_show_status_message(EMPTY_MESSAGE, Color(0.65, 0.65, 0.7), true)


func _refresh_server_list() -> void:
	if not server_list_container:
		return

	_clear_server_list()
	_known_server_keys.clear()

	_show_status_message(SCANNING_MESSAGE, Color(0.6, 0.6, 0.6))

	# Start scan via ServiceDiscovery autoload
	if ServiceDiscovery:
		_scanning = true
		ServiceDiscovery.scan_lan_servers()
	else:
		_scanning = false
		_show_status_message(EMPTY_MESSAGE, Color(0.65, 0.65, 0.7), true)


func _add_server_to_list(data: Dictionary) -> void:
	if not server_list_container:
		return

	# Get server info from data
	var server_name: String = data.get("server_data", {}).get("Name", data.get("Name", "Unknown Game"))
	var server_ip: String = data.get("server_ip", "")
	var server_port: int = data.get("server_data", {}).get("port", data.get("port", 7777))
	var server_key := "%s:%d" % [server_ip, server_port]
	if _known_server_keys.has(server_key):
		return

	if _known_server_keys.is_empty():
		_clear_server_list()

	_known_server_keys[server_key] = true

	# Create button for this server
	var button := Button.new()
	button.text = "%s @ %s:%d" % [server_name, server_ip, server_port]
	button.custom_minimum_size = Vector2(0, 40)
	button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	
	# Capture server info for the callback
	var ip = server_ip
	var port = server_port
	button.pressed.connect(func(): _join_server(ip, port))

	server_list_container.add_child(button)

	if auto_join and not _connecting:
		_join_server(ip, port)


func _connect_service_discovery_signals() -> void:
	if not ServiceDiscovery:
		return

	var scanned_server_callback := Callable(self, "_on_scanned_server")
	if not ServiceDiscovery.scanned_server.is_connected(scanned_server_callback):
		ServiceDiscovery.scanned_server.connect(scanned_server_callback)

	var scan_complete_callback := Callable(self, "_on_scan_complete")
	if not ServiceDiscovery.scanned.is_connected(scan_complete_callback):
		ServiceDiscovery.scanned.connect(scan_complete_callback)


func _disconnect_service_discovery_signals() -> void:
	if not ServiceDiscovery:
		return

	var scanned_server_callback := Callable(self, "_on_scanned_server")
	if ServiceDiscovery.scanned_server.is_connected(scanned_server_callback):
		ServiceDiscovery.scanned_server.disconnect(scanned_server_callback)

	var scan_complete_callback := Callable(self, "_on_scan_complete")
	if ServiceDiscovery.scanned.is_connected(scan_complete_callback):
		ServiceDiscovery.scanned.disconnect(scan_complete_callback)


func _clear_server_list() -> void:
	for child in server_list_container.get_children():
		child.queue_free()


func _show_status_message(text: String, color: Color, autowrap: bool = false) -> void:
	var label := Label.new()
	label.text = text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART if autowrap else TextServer.AUTOWRAP_OFF
	label.add_theme_color_override("font_color", color)
	server_list_container.add_child(label)
