extends Node3D

## 把世界计划变成节点。除了建块和剔除，这里不做任何决策。
##
## 所有"世界里有什么、排在哪"都在 Plan 里定好了；这里只回答
## "现在这一帧哪些块需要画"。

const MESH_LIB = preload("res://scripts/world/mesh_lib.gd")
const CHUNK_SCRIPT = preload("res://scripts/world/chunk.gd")
const SOLIDS = preload("res://scripts/physics/solids.gd")

## 超过这个距离的块整体不画。第一级剔除，粒度就是块。
const VISIBLE_RANGE := 120.0

var chunks: Dictionary = {}
var _camera: Camera3D = null
var _rooms_with_rigid: Array[String] = []


func realize(plan) -> void:
	_add_ground(plan)
	_rooms_with_rigid.clear()

	for room_id in plan.rooms:
		var room: Dictionary = plan.rooms[room_id]
		var chunk = CHUNK_SCRIPT.new()
		chunk.name = String(room_id).replace("/", "_")
		chunk.room_id = room_id
		chunk.bounds = room["bounds"]
		chunk.floor_size = room["floor_size"]
		var has_rigid := false
		for item in room["items"]:
			if item["dynamic"]:
				# 刚体挂在块下，跟着块一起进退；但它自己一格渲染，不参与合批。
				chunk.add_child(SOLIDS.make_dynamic(item))
				has_rigid = true
				continue
			chunk.add_instance(item)
			if not (item["collider"] as Dictionary).is_empty():
				# 钉住的障碍：视觉在合批里，碰撞是个看不见的壳。
				chunk.add_child(SOLIDS.make_static(item))
		if has_rigid:
			_rooms_with_rigid.append(room_id)
		add_child(chunk)
		chunk.realize()

		var floor_origin := Vector3(room["bounds"].position.x, 0.0, room["bounds"].position.z)
		chunk.add_child(SOLIDS.make_floor(floor_origin, room["floor_size"]))
		chunks[room_id] = chunk


## 开场该站在哪。优先选有刚体的房间 —— 玩家第一眼就该看到"东西会动"，
## 否则他会以为这还是一片静态布景。
func start_bounds() -> AABB:
	if not _rooms_with_rigid.is_empty():
		return chunks[_rooms_with_rigid[0]].bounds
	for room_id in chunks:
		return chunks[room_id].bounds
	return AABB(Vector3.ZERO, Vector3(24, 6, 24))


## 世界底板。房间之间留了走道，没有它就是一块块悬空的平台露出天空。
## 它是引擎的视觉托底，不是内容 —— 但它必须有碰撞：否则玩家走出房间就掉进虚空，
## 世界边界会变成死亡陷阱。这块板不给玩法任何东西，只兜住玩家。
func _add_ground(plan) -> void:
	if plan.rooms.is_empty():
		return
	var total := AABB()
	var first := true
	for room_id in plan.rooms:
		var b: AABB = plan.rooms[room_id]["bounds"]
		total = b if first else total.merge(b)
		first = false

	var size := Vector2(total.size.x + 120.0, total.size.z + 120.0)
	var center := Vector3(total.get_center().x, 0.0, total.get_center().z)

	var plane := PlaneMesh.new()
	plane.size = size
	var node := MeshInstance3D.new()
	node.name = "ground"
	node.mesh = plane
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.material_override = _ground_material()
	node.position = Vector3(center.x, -0.02, center.z)
	add_child(node)

	add_child(SOLIDS.make_ground(center, size))


static var _ground_mat: ShaderMaterial = null


static func _ground_material() -> ShaderMaterial:
	if _ground_mat == null:
		_ground_mat = MESH_LIB.toon_material_for(Color(0.30, 0.33, 0.40), 0.0)
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
