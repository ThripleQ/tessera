extends RefCounted

## 交给 mod 的唯一对象。
##
## 设计原则（ADR 0005）：**暴露意图，不暴露结构**。
##   ✓ spawn / impulse / tint / nearest   —— 动词，mod 想要的结果
##   ✗ get_node / Transform3D / 组件对象   —— 名词，引擎的内部形状
##
## 为什么这条比"扩展点够不够多"重要：一旦 mod 拿到节点树，第一天就会有人写
## get_node("../../chunk_0/MultiMesh")，引擎的内部结构当天被生态钉死，
## 之后任何重构都会破坏所有 mod —— 于是你再也不敢改引擎。
##
## 所以 mod 手里只有整数 handle。它不能遍历、不能反查、不能拼路径，
## 只能通过这里列出的方法请求一件事发生。

## 世界里"被造出来"的东西的上限，动态静态一起算。
## 开放不等于无限：一个没人拦的 spawn 循环能把帧率瞬间打到零，
## 而"预算由系统强制"是这个项目从第一天起的规矩（ADR 0005 末尾）。
const MAX_SPAWNED := 96
const MAX_QUERY := 64

var _pack = null
## 世界节点。造东西要经过它 —— "造一个物体会发生什么"（登记 handle、监视碰撞、
## 发 entity.spawn）只有一份实现，在这里自己 add_child 会悄悄绕过那一份。
var _world: Node3D = null
var _bodies: Dictionary = {}     # handle -> RigidBody3D
var _ids: Dictionary = {}        # handle -> 内容 id（引擎只转手，不解读）
var _base_color: Dictionary = {} # handle -> 原始颜色，给 reset_tint 用
## 现在世界上有几件"我造出来的"东西 —— 预算按这张表算。
##
## 为什么不是单纯的计数器：拆除必须能**归还**预算，读档必须能**重新认领**
## 上次造的东西。两件事都要求"哪几件是我造的"这个信息本身存在，
## 而计数器不记得任何人的名字，于是删掉的东西照样占着额度，
## 读一次档额度还会清零（可以无限刷）。
var _made: Dictionary = {}       # instance_id -> handle（静态物没有 handle，记 0）
var _next := 1
var refused := 0


func _init(pack) -> void:
	_pack = pack


## 世界节点是 mod 造物的父节点。传进来而不是让 mod 自己找 ——
## mod 永远不该知道节点树长什么样。
func attach_world(world: Node3D) -> void:
	_world = world


## 引擎侧登记一个刚体，返回它的 handle。
func register(body: RigidBody3D, content_id: String) -> int:
	var h := _next
	_next += 1
	_bodies[h] = body
	_ids[h] = content_id
	_base_color[h] = _read_color(body)
	return h


func handle_of(body) -> int:
	for h in _bodies:
		if _bodies[h] == body:
			return h
	return 0


func count() -> int:
	return _bodies.size()


## 预算已用多少。动态和静态一起算 —— 静态物不参与模拟，但它的碰撞体
## 永久占用物理查询，"不动的物体不要钱"是错觉，只是便宜。
func budget_used() -> int:
	return _made.size()


func budget_left() -> int:
	return max(0, MAX_SPAWNED - _made.size())


func _remember(node: Node, handle: int) -> void:
	if node == null:
		return
	_made[node.get_instance_id()] = handle


## 一件东西被拿掉了：归还预算，作废它的 handle。
##
## 由 world 在移除时调用 —— 世界知道"谁走了"，api 只知道"我记过谁"。
## 两边的信息合起来才是事实：只是从世界里删掉节点，handle 会留在这里
## 继续指向一个被释放的对象；只从这张表里删掉，预算会永久漏掉一格。
func release(node: Node) -> void:
	if node == null or not is_instance_valid(node):
		return
	var iid: int = node.get_instance_id()
	if not _made.has(iid):
		return
	var h := int(_made[iid])
	_made.erase(iid)
	if h > 0:
		_bodies.erase(h)
		_ids.erase(h)
		_base_color.erase(h)


## 把一件**已经造好的**东西认领进预算。读档还原走这里。
## 不认领的话读一次档预算就清零，玩家能把上次删掉的东西再造一遍 ——
## 那不是预算，那是个计数器。
func adopt(node: Node) -> void:
	if node == null:
		return
	_remember(node, int(node.get_meta("handle", 0)))


## mod 删掉一件东西。返回 false = 这个 handle 不存在，或者那东西不归玩家删
## （比如房间墙上的碰撞壳 —— 它不在 world.props 里，是内容的形状）。
func remove(handle: int) -> bool:
	var b = _bodies.get(handle, null)
	if b == null or not is_instance_valid(b):
		return false
	if _world == null:
		return false
	return _world.remove_thing(b)


## 世界里的刚体被整体换掉之后调用（读档）。旧 handle 必须全部作废 ——
## 留着它们意味着 mod 调 api.pos(h) 会去读一个已经释放的对象。
## _next 不回退：handle 单调递增，mod 不可能拿旧 handle 撞上新物体。
##
## 预算表一起清空：这张表按节点身份记账，而节点已经全没了。
## **现存的东西要占额度，得由调用方重新认领**（`adopt`）——读档正是这么做的。
## 不这么分，"读一次档额度清零"就成了无限刷东西的后门。
func forget_all() -> void:
	_bodies.clear()
	_ids.clear()
	_base_color.clear()
	_made.clear()


func exists(handle: int) -> bool:
	var b = _bodies.get(handle, null)
	return b != null and is_instance_valid(b)


# ---------------------------------------------------------------- 读

func pos(handle: int) -> Vector3:
	var b = _bodies.get(handle, null)
	if b == null:
		return Vector3.ZERO
	# 给的是几何中心，不是节点原点。内容的原点在底面（站着的地面），
	# 对 mod 来说"这个东西在哪"永远是它的中心 —— 让每个 mod 自己 +0.4 是灾难。
	return b.to_global(b.center_of_mass)


func speed(handle: int) -> float:
	var b = _bodies.get(handle, null)
	if b == null:
		return 0.0
	return b.linear_velocity.length()


func mass(handle: int) -> float:
	var b = _bodies.get(handle, null)
	if b == null:
		return 0.0
	return b.mass


## 内容 id。引擎不解读它，只是转手给 mod —— 而 mod 本来就是内容的一部分，
## 认识内容 id 是它的正当权利。这条分界很容易搞反：引擎必须对内容无知，mod 不必。
func content_id(handle: int) -> String:
	return String(_ids.get(handle, ""))


## 半径内最近的刚体。0 表示没有。
func nearest(center: Vector3, radius: float) -> int:
	var best := 0
	var best_d := radius
	var n := 0
	for h in _bodies:
		var b = _bodies[h]
		if b == null or not is_instance_valid(b):
			continue
		n += 1
		if n > MAX_QUERY:
			break
		var d: float = b.global_position.distance_to(center)
		if d <= best_d:
			best_d = d
			best = h
	return best


# ---------------------------------------------------------------- 写

func impulse(handle: int, v: Vector3) -> bool:
	var b = _bodies.get(handle, null)
	if b == null or not is_instance_valid(b):
		return false
	b.apply_central_impulse(v)
	return true


## 染色。走的是每个刚体自己那份卡通材质，所以不会影响同网格的其它实例
## （合批的静态实例共用一份材质，它们根本没有独立 handle）。
func tint(handle: int, color: Color) -> bool:
	var b = _bodies.get(handle, null)
	if b == null:
		return false
	var mi := b.get_node_or_null("visual") as MeshInstance3D
	if mi == null:
		return false
	var mat = mi.material_override
	if mat is ShaderMaterial:
		(mat as ShaderMaterial).set_shader_parameter("base_color", color)
		return true
	return false


func reset_tint(handle: int) -> bool:
	var c = _base_color.get(handle, null)
	if c == null:
		return false
	return tint(handle, c)


## 按内容 id 造一个东西。造出来是刚体还是钉住的静态物，**由内容数据决定**，
## 调用方不需要知道，也不该知道（铁律 2）。
##
## 返回 `{ok, handle, dynamic, reason}`：
##   ok=false  时 `reason` 是给人看的一句话，会被 UI 原样显示
##   handle    只有刚体才有。静态物没有物理身份，所以是 0 —— 但 ok 是 true
##
## 为什么不再用"返回 0 就是失败"：静态物本来就没有 handle，于是在一个 int 里
## "放下了"和"没放下"没法区分。而生成菜单必须能说出是哪一种 ——
## 一个只会说"失败"的菜单，会让人以为整个功能坏着。
func spawn(content_id: String, at: Vector3, yaw: float = 0.0) -> Dictionary:
	if _pack == null or _world == null:
		return _refuse("引擎还没装配好世界")
	# 预算由系统强制（ADR 0005）。开放不等于无限：没人拦的 spawn 循环
	# 能把帧率瞬间打到零，而"玩家的东西能无限放、mod 的不能"更糟 ——
	# 那预算就成了只约束好人的规矩。
	if _made.size() >= MAX_SPAWNED:
		refused += 1
		return _refuse("预算用尽（上限 %d），先拆掉一些" % MAX_SPAWNED)
	if not _pack.entities.has(content_id):
		return _refuse("没有这条内容：%s" % content_id)
	# 抽象基类不能单独存在。它的数据往往是不完整的，摆出来是个半成品，
	# 而且不会报错 —— 所以在这里挡住，理由说清楚。
	if _pack.is_abstract(content_id):
		return _refuse("`%s` 是抽象基类，只能被 extends" % content_id)

	var item: Dictionary = _pack.item_for(content_id, Transform3D(Basis(Vector3.UP, yaw), at))
	if item.is_empty():
		return _refuse("`%s` 没有外观，摆不出来" % content_id)

	# 静态物：有碰撞、挡路、推不动，不进 bodies、没有 handle。
	# 它照样是"玩家的动作"，会被单独记住（world.props / 存档）。
	if not bool(item["dynamic"]):
		var prop = _world.add_static(item)
		if prop == null:
			return _refuse("网格 `%s` 引擎没实现几何" % String(item["mesh"]))
		_remember(prop, 0)
		return {"ok": true, "handle": 0, "dynamic": false, "reason": ""}

	var body = _world.add_dynamic(item)
	if body == null:
		return _refuse("刚体造不出来：`%s`" % content_id)
	# handle 由 world 在登记时算好挂在刚体上。这里不自己发号 ——
	# 一个物体两个号，mod 手里的 handle 就有一半是假的。
	var handle := int(body.get_meta("handle", 0))
	_remember(body, handle)
	return {"ok": true, "handle": handle, "dynamic": true, "reason": ""}


func _refuse(reason: String) -> Dictionary:
	return {"ok": false, "handle": 0, "dynamic": false, "reason": reason}


func _read_color(body: RigidBody3D) -> Color:
	var mi := body.get_node_or_null("visual") as MeshInstance3D
	if mi == null:
		return Color.WHITE
	var mat = mi.material_override
	if mat is ShaderMaterial:
		var c = (mat as ShaderMaterial).get_shader_parameter("base_color")
		if c is Color:
			return c
	return Color.WHITE
