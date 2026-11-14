extends RefCounted

## 移动与行为。让 `move` 和 `ai` 从死数据变成真的会走的东西。
##
## 每件会动的东西每帧做两件事：
##   1. 由 brain 决定"想去哪儿"
##   2. 把这个意图写成**速度**（只写水平分量，竖直交给重力）
##
## 为什么写速度而不是改位置：这些东西是刚体。直接改 transform 会把物理
## 推到一边去 —— 箱子推不动它、它也推不动箱子，"扔个箱子砸它"这条链路
## 就断了，而那正是这个项目的核心手感。写速度则一切照旧：它会被撞开、
## 会被箱子压住、会从斜坡上滚下去、能被抓起来扔出去。
##
## 它**不知道血量的存在**，vitals 也不知道移动。两个系统只通过组件交流 ——
## 这条规则在契约的 `check_system_order` 里，理由是：一旦两个系统互相认识，
## 它们的执行顺序就成了隐式依赖，而顺序一改行为就变，且没有任何提示。

const system_name := "locomotion"

var world = null
var player = null
var pack = null

var _t := 0.0


func setup(w, p, pk) -> void:
	world = w
	player = p
	pack = pk


func step(dt: float) -> void:
	if world == null or pack == null:
		return
	_t += dt
	for rb in world.bodies:
		if not is_instance_valid(rb):
			continue
		var comps: Dictionary = pack.components_of(String(rb.get_meta("content_id", "")))
		var mv: Dictionary = comps.get("move", {})
		var speed := float(mv.get("speed", 0.0))
		if speed <= 0.0:
			continue

		var want: Vector3 = _intent(rb, comps, speed, float(mv.get("wander", 0.0)))
		# 只改水平速度。竖直方向是重力的事 —— 写成 0 的话，
		# 下落、跳跃、被顶起来全都不见了，东西会像贴在地上一样滑。
		#
		# 显式写类型不是保守：`world` 是 untyped 的，`for rb in world.bodies`
		# 里的 `rb` 是 Variant，`:=` 推不出类型 —— 而这个 Parse Error
		# **只在真正加载这个文件的时侯炸**（游戏或探针），编译期完全没有提示。
		var v: Vector3 = rb.linear_velocity
		rb.linear_velocity = Vector3(want.x, v.y, want.z)

		if want.length_squared() > 0.01:
			# 只转 yaw。lock_rotation 已经保证它不会被物理甩翻，
			# 这里负责让它面对想去的方向。直接写 rotation 是刻意的：
			# 对一个锁了旋转的刚体来说，角速度那条路走不通。
			rb.rotation = Vector3(0.0, atan2(want.x, want.z), 0.0)


## 这一帧想去哪儿。返回速度向量（长度就是 speed，方向是意图）。
func _intent(rb: RigidBody3D, comps: Dictionary, speed: float, wander: float) -> Vector3:
	var ai: Dictionary = comps.get("ai", {})
	var brain := String(ai.get("brain", "idle"))
	var me: Vector3 = rb.global_position
	var home: Vector3 = rb.get_meta("home", me)

	var to_home := home - me
	to_home.y = 0.0
	# 栓绳优先于一切脑回路：离家太远就先回家。
	# 没有这条，charger 会一路追出地图，然后卡在世界边缘转圈。
	if to_home.length() > float(ai.get("leash", 30.0)):
		return to_home.normalized() * speed

	var aggro := float(ai.get("aggro_radius", 8.0))
	match brain:
		"charger":
			# 追的条件写成"距离不大于 0 就追"的话，玩家站在原点会永远被追 ——
			# 因为距离为 0 时 normalized() 是零向量。所以这里先看有没有目标。
			var to_p := _to_player(me)
			if player != null and to_p.length() <= aggro:
				return _flat(to_p).normalized() * speed
			return _wander(me, home, speed, wander)
		"ambusher":
			# 伏击：没进仇恨半径就一动不动。和 patrol 的区别是
			# "平时静止"，这正是 ambusher 这个名字的全部含义。
			var to_p := _to_player(me)
			if player != null and to_p.length() <= aggro:
				return _flat(to_p).normalized() * speed
			return Vector3.ZERO
		"patrol":
			return _wander(me, home, speed, wander)
		_:
			# idle，以及任何没实现的 brain。不认识的 brain 宁可不动 ——
			# 让它随便走起来，比让它站着危险得多。
			return Vector3.ZERO


## 游荡：绕着家门口走一个慢圆，半径是内容里的 `move.wander`。
##
## 用确定性的正弦而不是随机数：随机数会让存档往返探针的数字每次都不一样，
## 而"同一条命令跑两次结果不同"是探针最不能有的性质。
## 相位从 instance id 取，于是它们不会同步踏步。
func _wander(me: Vector3, home: Vector3, speed: float, amplitude: float) -> Vector3:
	if amplitude <= 0.0:
		return Vector3.ZERO
	# 相位从"家在哪儿"算出来，于是同一房间里每件东西的步调都不一样。
	var phase := float(abs(int(home.x * 7.0) + int(home.z * 13.0)) % 997) * 0.013
	var ang := _t * 0.25 + phase
	var target := home + Vector3(sin(ang), 0.0, cos(ang)) * amplitude
	var to := _flat(target - me)
	if to.length() < 0.4:
		return Vector3.ZERO
	return to.normalized() * speed * 0.7


func _to_player(me: Vector3) -> Vector3:
	if player == null:
		return Vector3.ZERO
	return player.global_position - me


func _flat(v: Vector3) -> Vector3:
	return Vector3(v.x, 0.0, v.z)
