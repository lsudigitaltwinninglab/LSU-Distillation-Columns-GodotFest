extends Node

## Autoload: loads res://data/equipment_metadata.json for XR hotspot labels.
## Keys are equipment tags (e.g. FT101, TT111, B101). Values: name, type, range, other_info, size.

var metadata_map: Dictionary = {}

@export var metadata_path: String = "res://data/equipment_metadata.json"


func _ready() -> void:
	load_metadata()


func load_metadata() -> void:
	var file = FileAccess.open(metadata_path, FileAccess.READ)
	if file == null:
		push_error("Failed to open metadata file: " + metadata_path)
		return

	var text := file.get_as_text()
	var json = JSON.new()
	var result := json.parse(text)
	if result != OK:
		push_error("Failed to parse equipment metadata JSON: %s" % json.get_error_message())
		return

	metadata_map = json.data if typeof(json.data) == TYPE_DICTIONARY else {}
	for key in metadata_map.keys():
		if metadata_map[key] is Dictionary:
			metadata_map[key] = _sanitize_metadata(metadata_map[key])
	print("[MetadataManager] Loaded %d equipment tags" % metadata_map.size())


func get_metadata(id: String) -> Dictionary:
	if id.is_empty():
		return {}
	var raw: Dictionary
	if metadata_map.has(id):
		raw = metadata_map[id]
	else:
		var compact := id.replace("-", "").replace("_", "")
		if metadata_map.has(compact):
			raw = metadata_map[compact]
		else:
			return {}
	return _sanitize_metadata(raw)


func _sanitize_metadata(data: Dictionary) -> Dictionary:
	var clean := {}
	for key in data.keys():
		var val = data[key]
		if val is String:
			clean[key] = str(val).replace("?", "").strip_edges()
		else:
			clean[key] = val
	return clean
