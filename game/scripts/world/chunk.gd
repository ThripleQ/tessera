extends Node3D

## 一个世界块。按 room 划分 —— 契约里 room 组件的原话是"分块流式加载以它为单位"。
##
## 职责只有一件：把这块里的实例压成最少的提交次数。
## 同一种网格 = 一个 MultiMesh = 一次提交；换色靠 instance color，不增加提交。
##
## 建块分两步：先 plan（纯数据，无头模式只走这一步好统计），再 realize（生成节点）。
## 分开是为了让 check.sh 能在没有 GPU 的机器上拿到真实的批次与三角形数。

const ASSETS = preload("res://scripts/world/assets.gd")
const MESH_LIB = preload("res://scripts/world/mesh_lib.gd")

static var _floor_mat: ShaderMaterial = null

var room_id: String = ""
var bounds := AABB()
var floor_size := Vector2.ZERO

var _plan: Dictionary = {}
var _instance_total := 0
var _skipped: Array[String] = []


## 收一个待画的实例。
## 刚体不进合批：MultiMesh 的所有实例共用一个节点，而物理需要每个物体一个身份。
## 这条不是优化取舍，是两者结构上无法共存 —— 硬塞会导致物理只能整体推动。
func add_instance(item: Dictionary) -> bool:
	if bool(item.get("dynamic", false)):
		return false
	var mesh_id := String(item["mesh"])
	if ASSETS.mesh(mesh_id) == null:
		if not _skipped.has(mesh_id):
			_skipped.append(mesh_id)
		return false
	if not _plan.has(mesh_id):
		_plan[mesh_id] = []
	_plan[mesh_id].append({"xform": item["xform"], "color": item["color"]})
	_instance_total += 1
	return true


func instance_count() -> int:
	return _instance_total


## 这个块会提交几次。空 = 没有东西要画。
func batch_count() -> int:
	return _plan.size()


func triangle_count() -> int:
	var t := 0
	for mesh_id in _plan:
		t += ASSETS.triangles_of(mesh_id) * (_plan[mesh_id] as Array).size()
	return t


func skipped_meshes() -> PackedStringArray:
	return PackedStringArray(_skipped)


func realize() -> void:
	for mesh_id in _plan:
		var items: Array = _plan[mesh_id]
		if items.is_empty():
			continue
		var mesh := ASSETS.mesh(mesh_id)
		if mesh == null:
			continue

		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.mesh = mesh
		mm.instance_count = items.size()
		for i in items.size():
			mm.set_instance_transform(i, items[i]["xform"])
			mm.set_instance_color(i, items[i]["color"])

		var node := MultiMeshInstance3D.new()
		node.name = mesh_id
		node.multimesh = mm
		node.material_override = MESH_LIB.material()
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(node)

	if floor_size.x > 0.0 and floor_size.y > 0.0:
		var plane := PlaneMesh.new()
		plane.size = floor_size
		var floor_node := MeshInstance3D.new()
		floor_node.name = "floor"
		floor_node.mesh = plane
		floor_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		floor_node.material_override = _floor_tint()
		floor_node.position = Vector3(
			bounds.position.x + floor_size.x * 0.5,
			0.0,
			bounds.position.z + floor_size.y * 0.5)
		add_child(floor_node)


static func _floor_tint() -> ShaderMaterial:
	if _floor_mat == null:
		_floor_mat = MESH_LIB.toon_material_for(Color(0.42, 0.44, 0.50), 0.0)
	return _floor_mat
