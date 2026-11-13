extends RefCounted

## 手能做的三件事：**抓、扔、拆**。
##
## 为什么这三件事在一个文件里：它们共用同一个"你正对着什么"的判断。
## 拆开成两个文件就要把射线打两遍，而两份射线迟早会在起点、距离、屏蔽列表上分叉 ——
## 表现成"有个位置明明能抓却拆不掉"，是最难查的一类不一致。
##
## 这个系统是沙盒乐趣的全部来源，所以它有三个不显眼但决定手感的选择：
##
## 1) **不重新挂载父节点**。抓住的东西仍留在世界里，用弹簧力把它拉向持握点。
##    挂到手上的话它就变成运动学物体：穿墙、推不动别的东西、也从世界里消失。
##    Garry's Mod 的物理枪就是这么做的。
##
## 2) **力有加速度上限，而且随质量衰减**。直接设置速度会让一吨的箱子和一个苹果
##    手感完全一样 —— 那不是"物理世界"，那是"磁铁"。所以重物的加速度更小，
##    提起来就慢，扔出去也慢。这条就是"重量"能被感知到的全部来源。
##
## 3) **扔出去的冲量有硬上限**。人是肌肉，不是火箭：轻的东西能扔很远，
##    重的只能推动。上限按固定值卡，而不是按质量线性放大。
##
## 事件：grab.request 可以否决抓取，也可以改持握距离；grab.release 在松手时发。
## 钩子必须在抓取逻辑之前就存在，否则抓取会变成引擎硬编码，mod 只能看不能改。

## 手能够到的距离，**从角色胸口量起**。
##
## 第一版把射线从相机发出，结果永远抓不到东西：第三人称相机在身后 3.8 米，
## 3.6 米的射线走到头刚好停在角色后脑勺。手长应该按身体算，不能按镜头算。
const REACH := 3.0
## 胸口高度。按角色身高取，不跟相机走 —— 相机抬高时空手抓空气会变得很怪。
const EYE_HEIGHT := 1.35
## 默认持握距离。太近会顶进身体，太远手会像被拉长。
const HOLD_DISTANCE := 1.7

## 弹簧刚度与阻尼。调这两个等于调"跟手程度"：刚度越高越紧跟，越低越有惯性。
const SPRING := 7.0
const DAMPING := 12.0
## 拉近时的速度上限，防止远距离瞬间拽到脸上。
const MAX_PULL_SPEED := 9.0
## 加速度上限（空手基准）。实际还会除以质量系数。
const HOLD_ACCEL := 26.0
## 每公斤额外削弱多少加速度。0.05 的意思是 20 公斤的箱子只剩约一半加速度。
const MASS_SAG := 0.05

const THROW_SPEED := 9.5
## 轻点一下就松手（几乎没有蓄力）时，只给这么多比例的速度，避免误触变成乱扔。
const TAP_THROW := 0.35
## 冲量硬上限。轻物能飞，重物只能挪。
const MAX_IMPULSE := 190.0

## 拉开超过这个距离就脱手。被墙卡住时不能像橡皮筋一样把人拽过去。
const BREAK_DISTANCE := 5.0

## 持握点相对胸口的横向偏移。
##
## 不为好看：第三人称镜头在背后，正前方拿东西会被自己的身体完全挡住 ——
## 玩家看不见自己拿着什么。偏到右手边，箱子就从肩侧露出来，
## 而且"举在身体一侧"本来就是人搬东西的姿势。
const SIDE_OFFSET := 0.46
const DROP_OFFSET := 0.28

var body: RigidBody3D = null
var handle := 0
var hold_distance := HOLD_DISTANCE

var _player = null
var _camera: Camera3D = null
var _bus = null
var _api = null
var _world = null
var _held_time := 0.0


## 手的位置：角色胸口，不是相机。
func _origin() -> Vector3:
	return _player.global_position + Vector3(0.0, EYE_HEIGHT, 0.0)


## 朝向仍然由相机决定 —— 玩家是在"看哪儿抓哪儿"，不是在"用胸口撞"。
func _aim_dir() -> Vector3:
	return -_camera.global_transform.basis.z


## 相机的右方向，用来把东西偏到身体一侧。
func _right() -> Vector3:
	return _camera.global_transform.basis.x


## 物体的几何中心（世界坐标）。
##
## 不能直接用 global_position：内容的原点在**底面**（所有东西都站在自己的原点上），
## 把原点拉到胸口等于让箱子悬在胸口上方浮着。拉质心才像"托着"。
## 用 center_of_mass 而不是猜一半高度，是因为它对任何形状、任何缩放都成立。
func _center(b: RigidBody3D) -> Vector3:
	return b.to_global(b.center_of_mass)


func setup(player, camera: Camera3D, bus, api, world) -> void:
	_player = player
	_camera = camera
	_bus = bus
	_api = api
	_world = world


func is_holding() -> bool:
	return body != null and is_instance_valid(body)


## 手上那个东西的内容 id。UI 与调试用；引擎不会拿它做任何判断。
func held_id() -> String:
	if not is_holding() or _api == null:
		return ""
	return _api.content_id(handle)


## 视线正中能碰到什么。返回任何物理体：刚体、钉住的静态物、房间墙上的碰撞壳。
func aim_node() -> Node:
	if _camera == null:
		return null
	var from := _origin()
	var to := from + _aim_dir() * REACH
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.exclude = [_player.get_rid()]
	q.collide_with_bodies = true
	var hit: Dictionary = _camera.get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty():
		return null
	return hit.get("collider")


## 视线正中能抓到什么。只有刚体能被抓 —— 钉住的东西没有物理身份，
## 拉它等于推一面墙。
func aim() -> RigidBody3D:
	var n := aim_node()
	if n is RigidBody3D:
		return n
	return null


## 拆掉视线里的东西。返回 true = 真的拆掉了。
##
## **只拆玩家和 mod 造出来的**：房间自带的障碍不在 `world.props` 里，
## `world.remove_thing` 会拒绝。房间是内容的形状，不该被一块一块拆掉 ——
## 那会在世界里留下一个既不属于内容、也不属于存档的洞。
##
## 为什么需要有这个动作：生成预算是 96 件，而在此之前**没有任何办法把它还回去**。
## 玩家放满 96 件之后沙盒就死了，只能重启。能放不能收，不叫沙盒。
func scrape() -> bool:
	if _world == null or _player == null:
		return false
	var node := aim_node()
	if node == null:
		return false
	# 手上正拿着的东西不拆：那个是"要用的"，不是"要扔的"。
	# 而且射线很容易先打到手里的箱子 —— 误触一次就把刚拿起来的东西弄没了。
	if is_holding() and node == body:
		return false
	return _world.remove_thing(node)


func press() -> bool:
	if is_holding() or _bus == null:
		return false
	var target := aim()
	if target == null:
		return false

	var h: int = _api.handle_of(target) if _api != null else 0
	var ctx := {
		"id": String(_api.content_id(h)) if _api != null else "",
		"handle": h,
		"mass": target.mass,
		"pos": _center(target),
	}
	var verdict: Dictionary = _bus.emit("grab.request", ctx)
	if not bool(verdict.get("allow", true)):
		return false

	body = target
	handle = h
	_held_time = 0.0
	hold_distance = clamp(float(verdict.get("hold", HOLD_DISTANCE)), 0.9, REACH * 1.4)
	# 持握期间关掉重力，否则弹簧要一直和 9.8 拔河，重物会明显下垂到底。
	body.gravity_scale = 0.0
	# 不和自己碰撞：拖箱子时箱子会顶着自己走，像在推一台推土机。
	body.add_collision_exception_with(_player)
	return true


func release(thrown: bool = true) -> void:
	if not is_holding():
		body = null
		return
	var b := body
	body = null

	b.gravity_scale = 1.0
	b.remove_collision_exception_with(_player)

	var spd := 0.0
	if thrown:
		var dir := _aim_dir()
		var v := dir * THROW_SPEED * (1.0 if _held_time > 0.2 else TAP_THROW)
		# 把玩家自己的速度叠进去：跑着扔应该比站着扔更快，这是身体惯性。
		v += _player.velocity
		var dv := v - b.linear_velocity
		var imp := dv * b.mass
		if imp.length() > MAX_IMPULSE:
			imp = imp.normalized() * MAX_IMPULSE
		b.apply_central_impulse(imp)
		spd = v.length()

	_bus.emit("grab.release", {"id": _api.content_id(handle), "handle": handle,
			"speed": spd, "thrown": thrown})
	handle = 0


## 每物理帧调用。纯 PD 控制，没有一处改 Transform —— 这一点很重要：
## 直接写 position 的"抓取"会穿过一切东西。
func update(delta: float) -> void:
	if body == null:
		return
	if not is_instance_valid(body):
		body = null
		handle = 0
		return

	_held_time += delta

	var origin := _origin()
	var target := origin + _aim_dir() * hold_distance + _right() * SIDE_OFFSET - Vector3.UP * DROP_OFFSET
	var center := _center(body)

	if center.distance_to(origin) > BREAK_DISTANCE:
		release(false)
		return

	var want := (target - center) * SPRING
	if want.length() > MAX_PULL_SPEED:
		want = want.normalized() * MAX_PULL_SPEED

	var acc := (want - body.linear_velocity) * DAMPING
	# 加速度上限随质量衰减 —— 这一行就是"重"的全部来源。
	var acc_cap := HOLD_ACCEL / (1.0 + body.mass * MASS_SAG)
	if acc.length() > acc_cap:
		acc = acc.normalized() * acc_cap

	body.apply_central_force(acc * body.mass)
	# 抑制自转，否则拖着走的箱子会一路翻跟头，看着像失控而不是被抓住。
	body.angular_velocity *= max(0.0, 1.0 - 6.0 * delta)
