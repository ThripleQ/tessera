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

## 撞击事件的门槛。太轻的接触不发 —— 事件也要按预算来，
## 否则一堆箱子互相靠着就能把每帧事件额度吃光。
const IMPACT_MIN_SPEED := 2.0

var chunks: Dictionary = {}
## 有独立物理身份的东西。mod 通过 handle 认出它们，但它们本身不知道 mod 存在。
var bodies: Array[RigidBody3D] = []

## 由 main 注入。为空时世界照常跑 —— 没有 mod 的平台也必须能玩。
var bus = null
var api = null

var _camera: Camera3D = null
var _rooms_with_rigid: Array[String] = []
var _speeds: Dictionary = {}


func realize(plan) -> void:
	_add_ground(plan)
	_rooms_with_rigid.clear()
	bodies.clear()

	for room_id in plan.rooms:
		var room: Dictionary = plan.rooms[room_id]
		var chunk = CHUNK_SCRIPT.new()
		chunk.name = String(room_id).replace("/", "_")
		chunk.room_id = room_id
		chunk.bounds = room["bounds"]
		chunk.floor_size = room["floor_size"]
		var has_rigid := false
		var pending: Array = []
		for item in room["items"]:
			if item["dynamic"]:
				# 刚体挂在块下，跟着块一起进退；但它自己一格渲染，不参与合批。
				var rb: RigidBody3D = SOLIDS.make_dynamic(item)
				chunk.add_child(rb)
				pending.append({"body": rb, "item": item})
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

		# 登记必须在入树之后：handle 是给 mod 用的，而 mod 拿到的第一个位置
		# 就已经是世界坐标了，不能是块内坐标。
		for p in pending:
			_register_body(p["body"], p["item"])

		var floor_origin := Vector3(room["bounds"].position.x, 0.0, room["bounds"].position.z)
		chunk.add_child(SOLIDS.make_floor(floor_origin, room["floor_size"]))
		chunks[room_id] = chunk


func _register_body(rb: RigidBody3D, item: Dictionary) -> void:
	bodies.append(rb)
	var h: int = api.register(rb, String(item.get("id", ""))) if api != null else 0
	rb.set_meta("handle", h)
	rb.contact_monitor = true
	rb.max_contacts_reported = 2
	rb.body_entered.connect(_on_body_entered.bind(rb))
	if bus != null:
		bus.emit("entity.spawn", {
			"id": String(item.get("id", "")),
			"handle": h,
			"pos": rb.global_position,
		})


## 撞击事件。速度取的是**上一物理帧**的值 —— 信号到达时接触已经被解算，
## 此刻 linear_velocity 往往已经归零，用它算出来的撞击永远是 0。
func _on_body_entered(other: Node, rb: RigidBody3D) -> void:
	var spd: float = float(_speeds.get(rb, 0.0))
	if spd < IMPACT_MIN_SPEED:
		return
	if bus == null:
		return
	bus.emit("impact", {
		"id": String(rb.get_meta("content_id", "")),
		"handle": int(rb.get_meta("handle", 0)),
		"speed": spd,
		"pos": rb.global_position,
	})


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


## 记录每个刚体的速度。这不是"为了撞击事件多跑一趟"——
## 接触信号到达时速度已经被解算掉了，没有这一帧的缓存，撞击永远读到 0。
func _physics_process(_delta: float) -> void:
	for rb in bodies:
		if is_instance_valid(rb):
			_speeds[rb] = rb.linear_velocity.length()
