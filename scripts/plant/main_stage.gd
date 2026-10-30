extends Node3D

## Plant scene root (scenes/plant/main_stage.tscn) — instanced inside ar_network_arena.
##
## Lighting: balanced 3-point setup (key + fill + strong COLOR ambient), shadows off.
## AR mode only toggles passthrough / ground visibility — not harsh single-direction lighting.

const AMBIENT_ENERGY := 2.2
const KEY_LIGHT_ENERGY := 0.4
const FILL_LIGHT_ENERGY := 0.45

## Ring of point lights around the plant (children of this scene, so they move, turn and scale with the model).
const MODEL_LIGHT_COLOR := Color(1.0, 0.96, 0.9)
const MODEL_LIGHT_ENERGY := 1.6
const MODEL_LIGHT_FILL_ENERGY := 0.7
## How far outside the plant's footprint the corner lights sit (fraction of its size).
const MODEL_LIGHT_MARGIN := 0.35
## Plant meshes bigger than this are sky / ground planes, not part of the plant.
const MODEL_BOUNDS_MAX_SIZE := 500.0

var xr_interface: XRInterface
var _qr_manager: Node = null

var _toy_model_mode_active: bool = false
## Set by the arena, which has its own (invisible) floor: keeps this scene's green ground quad hidden.
var ground_always_hidden: bool = false
var _ar_mode_active: bool = false
@export var conference_demo_mode: bool = true

## Below this model size the plant stops colliding with the player: a tabletop model isn't something to walk
## into, and the player's body overlapping thousands of its triangles at once is what made walking up to it lag.
const SMALL_MODEL_SCALE := 0.5
## Imported tri-mesh colliders with more faces than this are replaced by a simplified convex shape.
const HEAVY_TRIMESH_FACES := 100

var _plant_collision_on: bool = true
var _plant_collision_layers: Dictionary = {}  # StaticBody3D -> its normal collision_layer

var _model_lights: Array[OmniLight3D] = []
var _model_light_ranges: Array[float] = []
var _model_light_scale: float = -1.0

@onready var environment: Environment = $WorldEnvironment.environment
@onready var ground_mesh_instance_3d: MeshInstance3D = get_node_or_null("SceneCollection/Ground/Ground_MeshInstance3D")
@onready var directional_light: DirectionalLight3D = get_node_or_null("DirectionalLight3D")
@onready var fill_light: DirectionalLight3D = get_node_or_null("FillLight")


func _ready() -> void:
	xr_interface = XRServer.find_interface("OpenXR")
	_connect_xr_session_retry()
	_connect_qr_manager()
	call_deferred("_bootstrap_lighting")
	call_deferred("_connect_menu_signal")
	call_deferred("_build_model_lights")
	call_deferred("_sync_mirror_materials")
	call_deferred("_simplify_plant_colliders")
	if conference_demo_mode:
		_apply_demo_render_profile()


## The mirrored half of the plant must look like the half it reflects.
func _sync_mirror_materials() -> void:
	var lab := get_node_or_null("LSUDistillationLab") as Node3D
	if lab:
		var changed := MirrorMaterialSync.apply(lab)
		print("[MainStage] Mirrored pieces re-materialed to match their originals: ", changed)


### Lighting around the model ###

## Light ranges don't follow node scale, so keep them in step with the model's size.
func _process(_delta: float) -> void:
	var model_scale := global_transform.basis.get_scale().x
	_update_plant_collision(model_scale)
	if _model_lights.is_empty() or is_equal_approx(model_scale, _model_light_scale):
		return
	_model_light_scale = model_scale
	for i in _model_lights.size():
		_model_lights[i].omni_range = _model_light_ranges[i] * model_scale


### Collision cost ###

## The glTF import gave the biggest equipment (column, tanks, pumps, a pipe) tri-mesh colliders of 2,000 to 5,000
## faces each. Walking into one means testing the player's capsule against all those triangles every physics
## step. Convex pieces become a simplified convex hull (cheap and still solid); the thin pipe, which a hull would
## turn into a solid block, stops colliding (the plant's walk-through box colliders cover the rest).
func _simplify_plant_colliders() -> void:
	var lab := get_node_or_null("LSUDistillationLab")
	if not lab:
		return
	var simplified := 0
	var disabled := 0
	for node in lab.find_children("*", "CollisionShape3D", true, false):
		var shape_node := node as CollisionShape3D
		var trimesh := shape_node.shape as ConcavePolygonShape3D
		if not trimesh or trimesh.get_faces().size() / 3 <= HEAVY_TRIMESH_FACES:
			continue
		# Imported layout: MeshInstance3D / StaticBody3D / CollisionShape3D
		var mesh_instance := shape_node.get_parent().get_parent() as MeshInstance3D
		if mesh_instance == null or mesh_instance.mesh == null or mesh_instance.name.begins_with("PipeLine"):
			shape_node.set_deferred("disabled", true)
			disabled += 1
			continue
		shape_node.shape = mesh_instance.mesh.create_convex_shape(true, true)
		simplified += 1
	print("[MainStage] Heavy tri-mesh colliders: %d simplified to convex hulls, %d disabled" % [simplified, disabled])


## A model shrunk to tabletop size doesn't collide with the player; at normal size it does.
func _update_plant_collision(model_scale: float) -> void:
	# A little hysteresis so a model hovering around the threshold while being scaled doesn't flip every frame.
	var should_collide := model_scale >= (SMALL_MODEL_SCALE if _plant_collision_on else SMALL_MODEL_SCALE + 0.05)
	if should_collide == _plant_collision_on:
		return
	_plant_collision_on = should_collide
	var bodies: Array[Node] = []
	var lab := get_node_or_null("LSUDistillationLab")
	if lab:
		bodies.append_array(lab.find_children("*", "StaticBody3D", true, false))
	var generated := get_node_or_null("GeneratedCollisionBodies")
	if generated:
		bodies.append_array(generated.find_children("*", "StaticBody3D", true, false))
	for body in bodies:
		var static_body := body as StaticBody3D
		if should_collide:
			static_body.collision_layer = _plant_collision_layers.get(static_body, static_body.collision_layer)
		else:
			_plant_collision_layers[static_body] = static_body.collision_layer
			static_body.collision_layer = 0


## Four lights above the corners of the plant's footprint, one overhead and one low fill, so the plant is lit
## evenly from every side against the dark background (and in toy mode, at any size and wherever it is put).
func _build_model_lights() -> void:
	var lab := get_node_or_null("LSUDistillationLab") as Node3D
	if not lab:
		return
	var bounds := _mesh_bounds(lab)
	if bounds.size.length() < 0.1:
		return

	var center := bounds.get_center()
	var half := bounds.size * 0.5
	var reach := Vector3(half.x * (1.0 + MODEL_LIGHT_MARGIN), 0.0, half.z * (1.0 + MODEL_LIGHT_MARGIN))
	var corner_height := bounds.position.y + bounds.size.y * 0.75
	var spread := maxf(bounds.size.x, bounds.size.z)
	var corner_range := maxf(spread, bounds.size.y) * 1.6

	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			_add_model_light(Vector3(center.x + reach.x * sx, corner_height, center.z + reach.z * sz), corner_range, MODEL_LIGHT_ENERGY)
	_add_model_light(Vector3(center.x, bounds.end.y + bounds.size.y * 0.3, center.z), corner_range * 1.2, MODEL_LIGHT_ENERGY)
	_add_model_light(Vector3(center.x, bounds.position.y + bounds.size.y * 0.1, center.z), corner_range, MODEL_LIGHT_FILL_ENERGY)
	_model_light_scale = -1.0


func _add_model_light(light_position: Vector3, light_range: float, energy: float) -> void:
	var light := OmniLight3D.new()
	light.name = "ModelLight%d" % _model_lights.size()
	light.position = light_position
	light.light_color = MODEL_LIGHT_COLOR
	light.light_energy = energy
	light.omni_range = light_range
	light.omni_attenuation = 1.0
	light.shadow_enabled = false
	add_child(light)
	_model_lights.append(light)
	_model_light_ranges.append(light_range)


## Bounds of the meshes under [param root], in this scene's own space.
func _mesh_bounds(root: Node) -> AABB:
	var to_local := global_transform.affine_inverse()
	var bounds := AABB()
	var found := false
	for node in root.find_children("*", "MeshInstance3D", true, false):
		var mesh_instance := node as MeshInstance3D
		if not mesh_instance.mesh:
			continue
		var mesh_bounds: AABB = to_local * mesh_instance.global_transform * mesh_instance.get_aabb()
		if mesh_bounds.size.length() > MODEL_BOUNDS_MAX_SIZE:
			continue
		bounds = mesh_bounds if not found else bounds.merge(mesh_bounds)
		found = true
	return bounds if found else AABB()


func _connect_xr_session_retry() -> void:
	if not xr_interface:
		return
	if xr_interface.has_signal("session_begun"):
		if not xr_interface.session_begun.is_connected(_on_xr_session_begun):
			xr_interface.session_begun.connect(_on_xr_session_begun)


func _on_xr_session_begun() -> void:
	if _ar_mode_active:
		switch_to_ar()


func _bootstrap_lighting() -> void:
	# Default VR mode — do not auto-start AR passthrough.
	_ar_mode_active = false
	var sync_manager := get_tree().get_first_node_in_group("model_sync_manager")
	if sync_manager and sync_manager.has_method("is_ar_mode"):
		_ar_mode_active = sync_manager.is_ar_mode()
	_apply_lighting_profile()
	call_deferred("_apply_lighting_profile")


func _connect_qr_manager() -> void:
	if not xr_interface:
		xr_interface = XRServer.find_interface("OpenXR")
	if not xr_interface:
		return
	await get_tree().process_frame
	_qr_manager = get_tree().get_first_node_in_group("qr_marker_manager")
	if not _qr_manager:
		return
	if xr_interface.has_signal("session_begun"):
		if not xr_interface.session_begun.is_connected(_qr_manager._on_session_begun):
			xr_interface.session_begun.connect(_qr_manager._on_session_begun)
	if xr_interface.has_signal("session_stopping"):
		if not xr_interface.session_stopping.is_connected(_qr_manager._on_session_ended):
			xr_interface.session_stopping.connect(_qr_manager._on_session_ended)
	if xr_interface.is_initialized():
		_qr_manager._on_session_begun()


func switch_to_ar() -> bool:
	if xr_interface:
		var modes = xr_interface.get_supported_environment_blend_modes()
		if XRInterface.XR_ENV_BLEND_MODE_ALPHA_BLEND in modes:
			xr_interface.environment_blend_mode = XRInterface.XR_ENV_BLEND_MODE_ALPHA_BLEND
		elif XRInterface.XR_ENV_BLEND_MODE_ADDITIVE in modes:
			xr_interface.environment_blend_mode = XRInterface.XR_ENV_BLEND_MODE_ADDITIVE
		else:
			return false
	else:
		return false
	get_viewport().transparent_bg = true
	return true


func switch_to_vr() -> bool:
	if xr_interface:
		var modes = xr_interface.get_supported_environment_blend_modes()
		if XRInterface.XR_ENV_BLEND_MODE_OPAQUE in modes:
			xr_interface.environment_blend_mode = XRInterface.XR_ENV_BLEND_MODE_OPAQUE
		else:
			return false
	else:
		return false
	get_viewport().transparent_bg = false
	return true


func _connect_menu_signal() -> void:
	if MenuControl.has_signal("ar_state_changed"):
		if not MenuControl.is_connected("ar_state_changed", _on_ar_state_changed):
			MenuControl.connect("ar_state_changed", Callable(self, "_on_ar_state_changed"))
	if MenuControl.has_signal("toy_model_mode"):
		if not MenuControl.is_connected("toy_model_mode", _on_toy_model_mode_changed):
			MenuControl.connect("toy_model_mode", _on_toy_model_mode_changed)


func _on_ar_state_changed(new_state: bool) -> void:
	_ar_mode_active = new_state
	if new_state:
		switch_to_ar()
	else:
		switch_to_vr()
	_apply_lighting_profile()


func _on_toy_model_mode_changed(toggled_on: bool) -> void:
	_toy_model_mode_active = toggled_on
	_apply_lighting_profile()


func _apply_lighting_profile() -> void:
	_apply_balanced_environment()
	_disable_all_shadows()
	_update_ground_mesh_visibility()


func _apply_balanced_environment() -> void:
	if not environment:
		return
	environment.background_mode = Environment.BG_SKY
	# COLOR ambient lights faces the key light misses (e.g. right-side tanks).
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.88, 0.90, 0.94)
	environment.ambient_light_energy = AMBIENT_ENERGY
	if directional_light:
		directional_light.light_energy = KEY_LIGHT_ENERGY
	if fill_light:
		fill_light.light_energy = FILL_LIGHT_ENERGY


func _apply_demo_render_profile() -> void:
	if environment:
		environment.background_energy_multiplier = max(environment.background_energy_multiplier, 0.9)
		environment.adjustment_contrast = min(environment.adjustment_contrast, 1.0)
		environment.tonemap_mode = Environment.TONE_MAPPER_ACES


func _update_ground_mesh_visibility() -> void:
	if not ground_mesh_instance_3d:
		return
	ground_mesh_instance_3d.visible = not (ground_always_hidden or _ar_mode_active or _toy_model_mode_active)


func _disable_all_shadows() -> void:
	if directional_light:
		directional_light.shadow_enabled = false
	if fill_light:
		fill_light.shadow_enabled = false
	for node in find_children("*", "GeometryInstance3D", true, false):
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
