class_name MirrorMaterialSync
extends RefCounted

## The plant (LSUDistillationLab) is two mirror-image halves: the named pieces under "Model" and their
## reflections under "Mirror" (instances named "GN Instance…"). Every reflected piece must look exactly like
## its original, so this pairs each Mirror piece with the Model piece it reflects and gives it the same
## materials. Pairs are found by geometry (same size, reflected position), so it works whatever the pieces
## are called.

## Reflecting across the plane z = PLANE_SUM / 2 (plant space) maps each Mirror piece onto its Model piece:
## the average of (mirror z + model z) over all 142 pairs, to under a micrometre.
const PLANE_SUM := 2.4193
## A pair must match its reflected centre and size within this many metres in total.
const PAIR_TOLERANCE := 0.03


## Returns how many mirrored pieces had their materials changed to match their originals.
static func apply(lab: Node3D) -> int:
	var mirror_root := lab.get_node_or_null("Scene Collection/Mirror")
	var model_root := lab.get_node_or_null("Scene Collection/Model")
	if not mirror_root or not model_root:
		return 0
	var to_lab := lab.global_transform.affine_inverse()

	var mirrored: Array[MeshInstance3D] = []
	_collect_meshes(mirror_root, mirrored)
	var originals: Array[MeshInstance3D] = []
	_collect_meshes(model_root, originals)
	# Only pieces with a real, named material count: the plain parents (a pipe whose child GN instance carries
	# the look) hold glTF's default white and would hide the real counterpart.
	originals = originals.filter(_has_named_material)

	var original_bounds: Array[AABB] = []
	for piece in originals:
		original_bounds.append(to_lab * piece.global_transform * piece.get_aabb())

	var taken := {}
	var changed := 0
	for piece in mirrored:
		var bounds: AABB = to_lab * piece.global_transform * piece.get_aabb()
		var centre := bounds.get_center()
		var reflected := Vector3(centre.x, centre.y, PLANE_SUM - centre.z)

		var best := -1
		var best_score := PAIR_TOLERANCE
		for i in originals.size():
			if taken.has(i):
				continue
			var score := original_bounds[i].get_center().distance_to(reflected) + (original_bounds[i].size - bounds.size).length()
			if score < best_score:
				best_score = score
				best = i
		if best < 0:
			continue
		taken[best] = true
		changed += _copy_materials(originals[best], piece)
	return changed


static func _collect_meshes(node: Node, out: Array[MeshInstance3D]) -> void:
	if node is MeshInstance3D and (node as MeshInstance3D).mesh:
		out.append(node as MeshInstance3D)
	for child in node.get_children():
		_collect_meshes(child, out)


## Judged by the mesh's own material, not an override: the lab scene overrides every surface with a named look,
## which would make the plain default-white parent pieces look "real".
static func _has_named_material(piece: MeshInstance3D) -> bool:
	for i in piece.mesh.get_surface_count():
		var material := piece.mesh.surface_get_material(i)
		if material and material.resource_name != "":
			return true
	return false


## Gives [param target] the materials of [param source], surface by surface. Returns 1 if anything changed.
static func _copy_materials(source: MeshInstance3D, target: MeshInstance3D) -> int:
	if source.mesh.get_surface_count() != target.mesh.get_surface_count():
		return 0
	var changed := false
	for i in source.mesh.get_surface_count():
		var wanted := source.get_active_material(i)
		if target.get_active_material(i) != wanted:
			target.set_surface_override_material(i, wanted)
			changed = true
	return 1 if changed else 0
