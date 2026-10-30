extends Node3D

# Highlights equipment selected on the P&ID — brief 3D marker + label, then hides.

## Hotspots on the mirrored half of the plant are named like the original plus this suffix.
const MIRROR_SUFFIX := "_M"

@export var highlight_duration: float = 4.0
@export var listen_to_pid_ui: bool = true

@onready var _beam: GPUParticles3D = $GPUParticles3D
@onready var mat := _beam.process_material as ParticleProcessMaterial
@onready var base_speed := mat.get_param_min(ParticleProcessMaterial.PARAM_INITIAL_LINEAR_VELOCITY)

## Areas currently highlighted: the hotspot and, for a P&ID selection, its mirrored twin on the other side.
var _active_areas: Array[Area3D] = []
var _highlight_areas: Dictionary = {}
var _highlight_timer: Timer
var _camera: XRCamera3D


func _ready() -> void:
	add_to_group("distillation_hotspot_highlighter")
	_camera = get_tree().get_first_node_in_group("xr_camera")

	_beam.local_coords = true
	_highlight_timer = Timer.new()
	_highlight_timer.one_shot = true
	add_child(_highlight_timer)
	_highlight_timer.timeout.connect(_on_highlight_timeout)

	call_deferred("_connect_pid_signals")
	call_deferred("_cache_highlight_areas")


func _connect_pid_signals() -> void:
	if not listen_to_pid_ui:
		return
	for emitter in get_tree().get_nodes_in_group("pid_ui"):
		if emitter.has_signal("hotspot_clicked") and not emitter.hotspot_clicked.is_connected(_highlight_clicked):
			emitter.hotspot_clicked.connect(_highlight_clicked)


func _highlight_clicked(name_input: String) -> void:
	print("[HotspotHighlighter] P&ID click: ", name_input)
	# A P&ID click means the equipment itself, which exists on both halves of the plant: highlight both.
	_highlight(name_input, "", Color(1.0, 1.0, 0.85), true)


## Network share from SharedInspection — same highlight, label tagged with who shared it.
## Only the hotspot that was pointed at lights up, never its mirrored twin on the other half.
func highlight_shared(name_input: String, shared_by: String, color: Color) -> void:
	_highlight(name_input, shared_by, color, false)


func _highlight(name_input: String, shared_by: String, color: Color, include_twin: bool) -> void:
	if _highlight_areas.is_empty():
		_cache_highlight_areas()

	_clear_all_highlights()

	var area: Area3D = _highlight_areas.get(name_input, null)
	if area == null:
		return

	var areas: Array[Area3D] = [area]
	if include_twin and not name_input.ends_with(MIRROR_SUFFIX):
		var twin: Area3D = _highlight_areas.get(name_input + MIRROR_SUFFIX, null)
		if twin != null:
			areas.append(twin)
	for target in areas:
		_reveal_area(target, shared_by, color)
		_active_areas.append(target)

	_highlight_timer.stop()
	_highlight_timer.wait_time = highlight_duration
	_highlight_timer.start()

	_camera = get_tree().get_first_node_in_group("xr_camera")
	if _camera:
		var target_pos := area.global_transform.origin
		_beam.global_transform.origin = _camera.global_transform.origin
		_beam.look_at(target_pos, Vector3.UP)
		var dist_to_target := _beam.global_transform.origin.distance_to(target_pos)
		# The beam lives in this node's (model-scaled) space: its particles and their speed shrink with the
		# model in toy mode, so the travel time has to account for that or the beam falls short.
		var model_scale := maxf(global_transform.basis.get_scale().x, 0.001)
		_beam.lifetime = maxf(dist_to_target / (base_speed * model_scale), 0.1)
		_beam.emitting = false
		_beam.emitting = true


func _reveal_area(area: Area3D, shared_by: String = "", color: Color = Color(1.0, 1.0, 0.85)) -> void:
	var hl := area.get_node_or_null("Highlight") as Node3D
	if hl:
		# Eye candy: the aura pops in, overshooting slightly before it settles.
		if not hl.has_meta(&"full_scale"):
			hl.set_meta(&"full_scale", hl.scale)
		var full_scale: Vector3 = hl.get_meta(&"full_scale")
		hl.scale = full_scale * 0.4
		hl.visible = true
		hl.create_tween().tween_property(hl, "scale", full_scale, 0.35).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
#	if shared_by != "":
		# Someone shared this hotspot: a bell from where it is.
		#Sfx.play(&"chime", area.global_position, -3.0)

	var debug := area.get_node_or_null("DebugSphere")
	if debug:
		debug.visible = true

	var debug_tag := area.get_node_or_null("DebugTag")
	if debug_tag:
		debug_tag.visible = true

	var label_node := area.get_node_or_null("ShowNameLabel")
	if label_node and label_node.has_method("show_from_pid"):
		label_node.show_from_pid(shared_by, color)


func _on_highlight_timeout() -> void:
	_clear_all_highlights()


func _clear_all_highlights() -> void:
	for area in _active_areas.duplicate():
		if is_instance_valid(area):
			_clear_highlight(area)
	_active_areas.clear()


func _clear_highlight(area: Area3D) -> void:
	var hl := area.get_node_or_null("Highlight")
	if hl:
		hl.visible = false

	var debug := area.get_node_or_null("DebugSphere")
	if debug:
		debug.visible = false

	var debug_tag := area.get_node_or_null("DebugTag")
	if debug_tag:
		debug_tag.visible = false

	var label_node := area.get_node_or_null("ShowNameLabel")
	if label_node and label_node.has_method("hide_from_pid"):
		label_node.hide_from_pid()

	_active_areas.erase(area)


func _cache_highlight_areas() -> void:
	_highlight_areas.clear()
	_collect_areas(self)


func _collect_areas(node: Node) -> void:
	for child in node.get_children():
		if child is Area3D and child.name != "XRToolsInteractableArea":
			_highlight_areas[child.name] = child
		_collect_areas(child)
