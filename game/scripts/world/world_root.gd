extends Node3D

## 把世界计划变成节点。除了建块和剔除，这里不做任何决策。
##
## 所有"世界里有什么、排在哪"都在 Plan 里定好了；这里只回答
## "现在这一帧哪些块需要画"。

const MESH_LIB = preload("res://scripts/world/mesh_lib.gd")
const CHUNK_SCRIPT = preload("res://scripts/world/chunk.gd")
const SOLIDS = preload("res://scripts/physics/solids.gd")
const CULLING = preload("res://scripts/world/culling.gd")

## 撞击事件的门槛。太轻的接触不发 —— 事件也要按预算来，
## 否则一堆箱子互相靠着就能把每帧事件额度吃光。
const IMPACT_MIN_SPEED := 2.0

## 单件剔除用的包围球半径。1.5 米比最大的道具（2.2 米的柱子）的半宽大，
## 宁可包大一点也不要"探头进屏幕却没画"—— 剔除只有多画是对的。
const PROP_CULL_RADIUS := 1.5

var chunks: Dictionary = {}
## 有独立物理身份的东西。mod 通过 handle 认出它们，但它们本身不知道 mod 存在。
var bodies: Array[RigidBody3D] = []
## 玩家和 mod 摆出来的静态物体（钉住、不参与模拟）。
##
## 它们**不在** `bodies` 里，因为静态物体没有物理身份、不该被抓取或推动。
## 但它们必须被单独记住：房间里的静态障碍是"内容的形状"，由房间决定；
## 这些是"玩家的动作"，要进存档、要能删掉。
var props: Array[Node3D] = []

## 由 main 注入。为空时世界照常跑 —— 没有 mod 的平台也必须能玩。
var bus = null
var api = null

var _camera: Camera3D = null
var _rooms_with_rigid: Array[String] = []
var _speeds: Dictionary = {}

## 上一帧的剔除结果。给探针读 —— "该剔的剔了吗"必须能被断言，
## 否则剔除退化成"什么都不剔"时，验收照样全绿，只是帧时慢慢涨。
var cull_stats := {"shown": 0, "hidden": 0}

## 这一帧发生的撞击，给系统用（vitals 据此算伤害），用完就清。
##
## 为什么不直接给 vitals 发消息：world 不该认识"谁在处理撞击"。
## 它只负责记下发生了什么，谁消费是装配层的事。
## 注意它**不是**发给 mod 的那份：这一份带节点（引擎内部用），
## 发给 mod 的那份只有 handle —— mod 拿到节点树的那天，引擎的内部结构就被钉死了。
var impacts: Array = []


func realize(plan) -> void:
	_add_ground(plan)
	_rooms_with_rigid.clear()
	bodies.clear()
	props.clear()

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
	# 出生点。AI 的游荡和栓绳都围着它转 —— 不记下来的话，
	# 一只"绕着家门口转圈"的怪会以它被扔到的地方为家。
	rb.set_meta("home", rb.global_position)
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
	# 引擎自己那份（带节点，给 vitals 算伤害）先记。
	# 放在 bus 之前，而且**不看 bus 是不是 null** —— 没有 mod 的平台也必须会疼。
	impacts.append({"node": rb, "speed": spd})
	if bus == null:
		return
	bus.emit("impact", {
		"id": String(rb.get_meta("content_id", "")),
		"handle": int(rb.get_meta("handle", 0)),
		"speed": spd,
		"pos": rb.global_position,
	})


## 在世界里造一个刚体。mod 的 spawn 和存档还原都走这一处 ——
## "造一个物体会发生什么"（登记 handle、监视碰撞、发 entity.spawn）
## 只能有一份实现，否则存档还原出来的东西会悄悄少掉某些登记，
## 表现成"读档之后有些箱子不响应抓取"这种极难查的差异。
##
## 要求 world 已入树：登记时会发 entity.spawn，mod 拿到的位置必须是世界坐标。
func add_dynamic(item: Dictionary) -> RigidBody3D:
	var rb: RigidBody3D = SOLIDS.make_dynamic(item)
	if rb == null:
		return null
	add_child(rb)
	_register_body(rb, item)
	return rb


## 造一个钉住的东西：碰撞壳 + 自己的一份视觉。
##
## 房间里那些静态障碍的视觉在 MultiMesh 合批里，所以它们不需要这个；
## 玩家和 mod 摆出来的东西不属于任何块，必须自带网格 ——
## 否则会得到一个看不见但会挡路的幽灵。
func add_static(item: Dictionary) -> Node3D:
	var mesh := MESH_LIB.build(String(item["mesh"]))
	if mesh == null:
		return null
	var body: StaticBody3D = SOLIDS.make_static(item)
	body.set_meta("content_id", String(item.get("id", "")))
	var visual := MeshInstance3D.new()
	visual.name = "visual"
	visual.mesh = mesh
	visual.material_override = MESH_LIB.toon_material_for(item["color"])
	body.add_child(visual)
	add_child(body)
	props.append(body)
	return body


## 这件东西是不是"造出来的"（玩家放的、或者 mod 造的）。
## 房间自带的障碍不在里面 —— 它们是内容的形状，不在任何一份记账里。
##
## 和 `remove_thing` 一样**先按类型分岔**：在两个类型化数组上做 `has`，
## 拿错类型照样是引擎报错，不是返回 false。
func is_made(node) -> bool:
	if node == null or not is_instance_valid(node):
		return false
	if node is RigidBody3D:
		return bodies.has(node)
	if node is Node3D:
		return props.has(node)
	return false


## 清空所有"被造出来的东西"：动态刚体 + 玩家摆的静态物体。
## 载入存档时必须先清再建 —— 否则旧的会和新的一起留在世界里，
## 而且每读一次档数量就涨一轮。
func clear_spawned() -> int:
	var n := 0
	for rb in bodies:
		if is_instance_valid(rb):
			if api != null:
				api.release(rb)
			rb.queue_free()
			n += 1
	bodies.clear()
	for p in props:
		if is_instance_valid(p):
			if api != null:
				api.release(p)
			p.queue_free()
			n += 1
	props.clear()
	_speeds.clear()
	return n


## 拿掉**一件**被造出来的东西。动态的归还 handle 和预算，静态的直接释放。
##
## **返回被拿走那件的内容 id**，空串 = 它不归我（不在 bodies 或 props 里）。
##
## 为什么返回 id 而不是 bool：调用方两边都需要它 —— 玩家右键要把它装进背包，
## 而 mod 的 `api.remove` 只要"成不成"。返回 bool 会让前者再查一遍
## "刚才拿掉的是哪个"，而那时节点已经 queue_free 了。
##
## 这个判断很重要：射线打到房间墙上的碰撞壳时，`remove_thing` 必须返回空串。
## 房间的障碍不在 `props` 里，正是因为那条分界 —— 它们是内容的形状，
## 玩家不该能一块一块拆掉房间。
##
## **先按类型分岔，再 find**：`bodies` 是 `Array[RigidBody3D]`，拿一个
## StaticBody3D 去 `find` 是类型错误 —— 引擎会打一条 ERROR 再返回 -1。
## 功能上刚好"对"（落到 props 分支），所以探针照样绿、grep 也看不见，
## 只有真跑起来看 stderr 才知道玩家每右键一次墙，日志就脏一行。
func remove_thing(node: Node) -> String:
	if node == null or not is_instance_valid(node):
		return ""

	if node is RigidBody3D:
		var i := bodies.find(node)
		if i < 0:
			return ""
		var id := String(node.get_meta("content_id", ""))
		var h := int(node.get_meta("handle", 0))
		var pos: Vector3 = node.global_position
		bodies.remove_at(i)
		_speeds.erase(node)
		if api != null:
			api.release(node)
		# 与 entity.spawn 对称：只有拿过 handle 的东西才有"离开"这件事要通知。
		# 位置在 queue_free 之前取，之后它就不再是世界坐标了。
		if bus != null and h > 0:
			bus.emit("entity.remove", {"id": id, "handle": h, "pos": pos})
		node.queue_free()
		return id

	var j := props.find(node)
	if j < 0:
		return ""
	var pid := String(node.get_meta("content_id", ""))
	props.remove_at(j)
	if api != null:
		api.release(node)
	node.queue_free()
	return pid


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


## 剔除：决定这一帧画谁。**只管画，不动物理** ——
## 隐藏起来的箱子照样挡路、照样能被抓、照样进存档。
##
## 三类东西过同一份判定（`culling.gd`），但包围盒的来源不同：
##   块    —— 房间的 bounds。合批的单位，只能整块进退，粒度最粗
##   刚体  —— 逐件。它们各自一格渲染，正该逐件判
##   静态物 —— 逐件。玩家摆的东西**以前完全不在剔除范围里**，放多少画多少
##
## 最后那条就是这一轮要还的账：`props` 挂在 world 下、不进任何块，
## 而老的剔除只遍历 `chunks` —— 于是玩家摆满 96 件之后，96 件全在画。
func _process(_delta: float) -> void:
	if _camera == null:
		return
	var shown := 0
	var hidden := 0
	for room_id in chunks:
		var chunk = chunks[room_id]
		var draw: bool = CULLING.should_draw(_camera, chunk.bounds)
		chunk.visible = draw
		if draw:
			shown += 1
		else:
			hidden += 1
	for p in props:
		if not is_instance_valid(p):
			continue
		var draw: bool = CULLING.should_draw(
			_camera, CULLING.ball(p.global_position, PROP_CULL_RADIUS))
		p.visible = draw
		if draw:
			shown += 1
		else:
			hidden += 1
	for rb in bodies:
		if not is_instance_valid(rb):
			continue
		var draw: bool = CULLING.should_draw(
			_camera, CULLING.ball(rb.global_position, PROP_CULL_RADIUS))
		rb.visible = draw
		if draw:
			shown += 1
		else:
			hidden += 1
	cull_stats = {"shown": shown, "hidden": hidden}


## 记录每个刚体的速度。这不是"为了撞击事件多跑一趟"——
## 接触信号到达时速度已经被解算掉了，没有这一帧的缓存，撞击永远读到 0。
func _physics_process(_delta: float) -> void:
	for rb in bodies:
		if is_instance_valid(rb):
			_speeds[rb] = rb.linear_velocity.length()
