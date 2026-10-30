extends Control

@export_file("*.png") var mask_path: String
@export var verbose_logging: bool = false

# map each exact Color8 to the region name:
@export var color_map := {
	"0014FF": "valve_001",
	"FF0035": "valve_002",
}

signal region_clicked(region_name: String)
signal region_entered(region_name: String)
signal region_exited(region_name: String)


var mask_image: Image
var _last_region : String = ""
var _packed_color_map: Dictionary = {}

func _ready():
	if mask_path =="":
		push_error("PID_UI: no mask_path assigned in Inspector")
		return

	mask_image = Image.new()
	if mask_image.load(mask_path) != OK:
		push_error("Failed loading mask: %s" % mask_path)
		return
	mask_image.convert(Image.FORMAT_RGBA8)
	_build_packed_color_map()

func _gui_input(event):
	# Click event
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_process_at(event.position, true)
	
	# Handle hover (mouse motion or touch drag)
	elif event is InputEventMouseMotion or event is InputEventScreenDrag:
		_process_at(event.position, false)
	

func _enter_tree():
	add_to_group("pid_ui")

func _process_at(pos:Vector2, emit_click:bool):
	var uv = pos / size
	if uv.x < 0 or uv.x > 1 or uv.y < 0 or uv.y > 1:
		return
	# convert to pixel coords in the mask image
	var img_sz = mask_image.get_size()
	#var px = int(uv.x * img_sz.x)
	#var py = int(uv.y * img_sz.y)
	
	var px = int(floor(uv.x * img_sz.x))
	var py = int(floor(uv.y * img_sz.y))
	
	# sample the mask color
	var c:Color = mask_image.get_pixel(px, py)
	# normalize to exact 0–255 ints
	var r8 = int(round(c.r * 255))
	var g8 = int(round(c.g * 255))
	var b8 = int(round(c.b * 255))
	var color_key: int = (r8 << 16) | (g8 << 8) | b8
	var region = _packed_color_map.get(color_key, "")
	
	# enter / exit
	if region != _last_region:
		if _last_region != "":
			emit_signal("region_exited", _last_region)
			if verbose_logging:
				print("[UIPID] region exited: ", _last_region)
		if region != "":
			emit_signal("region_entered", region)
			if verbose_logging:
				print("[UIPID] region entered: ", region)
		_last_region = region
	
	# click
	if emit_click and region != "":
		emit_signal("region_clicked", region)
		if verbose_logging:
			print("[UIPID] clicked: ", region)


func _build_packed_color_map() -> void:
	_packed_color_map.clear()
	for key in color_map.keys():
		var region_name: String = str(color_map[key])
		var key_string := str(key).strip_edges().to_upper()
		if key_string.length() != 6:
			continue
		var r := key_string.substr(0, 2).hex_to_int()
		var g := key_string.substr(2, 2).hex_to_int()
		var b := key_string.substr(4, 2).hex_to_int()
		var packed := (r << 16) | (g << 8) | b
		_packed_color_map[packed] = region_name
