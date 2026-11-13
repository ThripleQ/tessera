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

const SOLIDS = preload("res://scripts/physics/solids.gd")

## mod 造物的上限。开放不等于无限：一个没人拦的 spawn 循环能把帧率瞬间打到零，
## 而"预算由系统强制"是这个项目从第一天起的规矩（ADR 0005 末尾）。
const MAX_SPAWNED := 96
const MAX_QUERY := 64

var _pack = null
var _parent: Node3D = null
var _bodies: Dictionary = {}     # handle -> RigidBody3D
var _ids: Dictionary = {}        # handle -> 内容 id（引擎只转手，不解读）
var _base_color: Dictionary = {} # handle -> 原始颜色，给 reset_tint 用
var _next := 1
var spawned := 0
var refused := 0


func _init(pack) -> void:
	_pack = pack


## 世界节点是 mod 造物的父节点。传进来而不是让 mod 自己找 ——
## mod 永远不该知道节点树长什么样。
func attach_world(world: Node3D) -> void:
	_parent = world


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


## 世界里的刚体被整体换掉之后调用（读档）。旧 handle 必须全部作废 ——
## 留着它们意味着 mod 调 api.pos(h) 会去读一个已经释放的对象。
## _next 不回退：handle 单调递增，mod 不可能拿旧 handle 撞上新物体。
func forget_all() -> void:
	_bodies.clear()
	_ids.clear()
	_base_color.clear()


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


## 按内容 id 造一个刚体。id 必须是内容里声明过 dynamic 的原型，
## 否则拒绝 —— 引擎不替内容决定"什么能造"。
func spawn(content_id: String, at: Vector3, yaw: float = 0.0) -> int:
	if _pack == null or _parent == null:
		return 0
	if spawned >= MAX_SPAWNED:
		refused += 1
		return 0
	if not _pack.entities.has(content_id):
		return 0
	var item: Dictionary = _pack.item_for(content_id, Transform3D(Basis(Vector3.UP, yaw), at))
	# 只有内容是刚体的东西才造得出来。mod 不能凭空造一个静态障碍 ——
	# 那会在世界里留下一个没人能删掉、也不知道从哪来的碰撞体。
	if item.is_empty() or not bool(item["dynamic"]):
		return 0
	var body = SOLIDS.make_dynamic(item)
	if body == null:
		return 0
	_parent.add_child(body)
	spawned += 1
	return register(body, content_id)


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
