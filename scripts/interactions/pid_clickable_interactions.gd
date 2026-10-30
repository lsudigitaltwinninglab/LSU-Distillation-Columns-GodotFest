extends Node3D

# Emitted whenever any hotspot is clicked, passing its node‐name
signal hotspot_clicked(hotspot_name:String)

func _ready() -> void:
	_connect_all_hotspots(self)

# Automatically identifies all XRToolsInteractable Areas and wires up signals
func _connect_all_hotspots(parent:Node) -> void:
	for child in parent.get_children():
		if child is MeshInstance3D and child.get_script() != null:
			child.connect("clicked", Callable(self,"_on_hotspot_clicked"))
		_connect_all_hotspots(child)
		

func _on_hotspot_clicked(mesh_name: String) -> void:
	print("Root received click on: ", mesh_name)
	emit_signal("hotspot_clicked", mesh_name)
	
	
