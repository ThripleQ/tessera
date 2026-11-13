extends Node3D

## 把世界计划变成节点。除了建块和剔除，这里不做任何决策。
##
## 所有"世界里有什么、排在哪"都在 Plan 里定好了；这里只回答
## "现在这一帧哪些块需要画"。

const CHUNK_SCRIPT = preload("res://scripts/world/chunk.gd")

## 超过这个距离的块整体不画。第一级剔除，粒度就是块。
const VISIBLE_RANGE := 120.0

var chunks: Dictionary = {}
var _camera: Camera3D = null


func realize(plan) -> void:
	_add_ground(plan)

	for room_id in plan.rooms:
		var room: Dictionary = plan.rooms[room_id]
		var chunk = CHUNK_SCRIPT.new()
		chunk.name = String(room_id).replace("/", "_")
		chunk.room_id = room_id
		chunk.bounds = room["bounds"]
		chunk.floor_size = room["floor_size"]
		for item in room["items"]:
			chunk.add_instance(item["mesh"], item["xform"], item["color"])
		add_child(chunk)
		chunk.realize()
		chunks[room_id] = chunk


## 世界底板。房间之间留了走道，没有它就是一块块悬空的平台露出天空。
## 这是引擎的视觉托底，不是内容：它不参与任何玩法，也不该有碰撞。
func _add_ground(plan) -> void:
	if plan.rooms.is_empty():
		return
	var total := AABB()
	var first := true
	for room_id in plan.rooms:
		var b: AABB = plan.rooms[room_id]["bounds"]
		total = b if first else total.merge(b)
		first = false

	var plane := PlaneMesh.new()
	plane.size = Vector2(total.size.x + 120.0, total.size.z + 120.0)
	var node := MeshInstance3D.new()
	node.name = "ground"
	node.mesh = plane
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.material_override = _ground_material()
	node.position = Vector3(total.get_center().x, -0.02, total.get_center().z)
	add_child(node)


static var _ground_mat: StandardMaterial3D = null


static func _ground_material() -> StandardMaterial3D:
	if _ground_mat == null:
		_ground_mat = StandardMaterial3D.new()
		_ground_mat.albedo_color = Color(0.17, 0.18, 0.20)
		_ground_mat.roughness = 1.0
		_ground_mat.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	return _ground_mat


func attach_camera(cam: Camera3D) -> void:
	_camera = cam


## 第一级剔除：整块在视距外就不画。故意做成最粗的粒度——
## 逐实例的视锥剔除是后面的事，先把"内容多但同屏少"这条路走通。
func _process(_delta: float) -> void:
	if _camera == null:
		return
	for room_id in chunks:
		var chunk = chunks[room_id]
		var c: Vector3 = chunk.bounds.get_center()
		var d := Vector2(c.x - _camera.position.x, c.z - _camera.position.z).length()
		chunk.visible = d <= VISIBLE_RANGE
