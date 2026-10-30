extends Node

## SpectatorMode autoload — decides whether this instance is a headset player or a desktop spectator.
##
## A spectator joins the host's game like any client but has no headset and no avatar: it gets a
## free/follow camera instead (see SpectatorController).
##
## Spectator when (checked once, the first time is_active() is called after the XR staging has
## started, since XRToolsStartXR initializes OpenXR in its own _ready):
## - `--spectator` is on the command line, or
## - OpenXR could not be initialized (no headset / runtime) on a non-Android build.
## `--no-spectator` forces normal behaviour. Launch a spectator on the headset PC with
## `--spectator --xr-mode off` so it doesn't compete with the headset for OpenXR.
##
## `--join=host[:port]` makes the spectator lobby connect straight to that game instead of scanning the LAN.

const DEFAULT_PORT := 7777

var join_host: String = ""
var join_port: int = DEFAULT_PORT

var _resolved: bool = false
var _active: bool = false


func _ready() -> void:
	for arg in _command_line():
		if arg.begins_with("--join="):
			var target := arg.trim_prefix("--join=")
			var parts := target.rsplit(":", true, 1)
			if parts.size() == 2 and parts[1].is_valid_int():
				join_host = parts[0]
				join_port = int(parts[1])
			else:
				join_host = target


## True when this instance should run as a spectator.
func is_active() -> bool:
	if not _resolved:
		_resolved = true
		_active = _detect()
		print("[SpectatorMode] spectator=%s" % _active)
		if _active:
			_release_xr()
	return _active


func _detect() -> bool:
	var args := _command_line()
	if "--no-spectator" in args:
		return false
	if "--spectator" in args:
		return true
	# Standalone headsets always run as players.
	if OS.has_feature("android"):
		return false
	var xr_interface := XRServer.find_interface("OpenXR")
	return xr_interface == null or not xr_interface.is_initialized()


## A spectator must never hold the headset: drop OpenXR if it came up anyway.
func _release_xr() -> void:
	var xr_interface := XRServer.find_interface("OpenXR")
	if xr_interface and xr_interface.is_initialized():
		xr_interface.uninitialize()
	get_viewport().use_xr = false


func _command_line() -> PackedStringArray:
	var args := OS.get_cmdline_args()
	args.append_array(OS.get_cmdline_user_args())
	return args
