extends CharacterBody3D

## 世界里的**别人**：走同一套角色通道，只是路线不同。
##
## 它存在的第一个目的是验收：证明"角色资产"不是玩家一个人的特例 ——
## 同一份 glb 能被玩家和布景**同时**使用，各自测步速、各自播动画、互不干扰。
## 第二个目的才是好看：地穴里除了你一个人都没有，那不像一个地方，像一块布景。
##
## 为什么不合并进 player.gd 加个 `is_npc` 参数：那个文件里从头到尾是
## "输入 → 愿望方向 → 加速度 → 相机朝向"，NPC 一条都不需要，只需要"往这个点走"。
## 塞进去之后每次调手感都得绕过一堆分支，而调手感恰恰是最常打开它的原因。
##
## 为什么复用 character_rig.gd 而不是另写一份：那一层里全是踩过的坑
## （glTF 片段默认不循环、资产朝向差半圈、换档按对数距离选、倍率要每帧跟住）。
## 复制一份 = 把坑复制一遍，而且以后修一个地方会漏掉另一个。
##
## 它**不认识任何具体的角色名字**：id 由调用方给，速度由资产自己测出来
## （`gait_walk()`）。所以新丢一个 glb 进资产目录，它走起来就自动是对的。

const RIG = preload("res://scripts/player/character_rig.gd")

const GRAVITY := 17.0
const TURN_RATE := 5.0
const BODY_RADIUS := 0.30
const BODY_HEIGHT := 1.68

## 没有步速档位时（老资产 / 测不出来）走多快。和玩家的兜底速度同一种性质：
## 只在"腿的速度不知道"时用，知道了就让腿说了算。
const FALLBACK_SPEED := 1.1

## 动画速度的平滑系数。不能直接用逐帧位移速度 —— 它会抖，
## 抖到 `MOVE_AT`（0.35）上下就在 idle 和 walk 之间闪，人看着像在抽搐。
const SMOOTH := 6.0
## 实际位移低于期望的这个比例，就当成"被挡住了"，动画减速到停。
## 不然一个卡在墙角的骷髅会在原地原地踏步到天荒地老。
const BLOCKED_RATIO := 0.55

var char_id := ""
var uses_asset := false

var _rig
var _center := Vector3.ZERO
var _radius := 3.0
var _angle := 0.0
var _speed := FALLBACK_SPEED
var _anim_speed := 0.0


## 站在圆周的哪个点上绕圈。`phase` 是起始角度（弧度），用来把几个人错开 ——
## 两个同相位的角色会叠在一起走成一个人。
##
## 必须在入树之后调用：`global_position` 在树外只是本地坐标。
func setup(id: String, center: Vector3, radius: float, phase: float) -> bool:
	char_id = id
	_center = center
	_radius = maxf(radius, 0.6)
	_angle = phase
	global_position = _center + Vector3(cos(_angle), 0.0, sin(_angle)) * _radius

	# 一样高的胶囊：玩家能撞到它，不会穿过去。
	var shape := CapsuleShape3D.new()
	shape.radius = BODY_RADIUS
	shape.height = BODY_HEIGHT
	var col := CollisionShape3D.new()
	col.shape = shape
	col.position = Vector3(0.0, BODY_HEIGHT * 0.5, 0.0)
	add_child(col)

	var visual := Node3D.new()
	visual.name = "visual"
	add_child(visual)
	_rig = RIG.new()
	_rig.name = "rig"
	visual.add_child(_rig)
	# 兜底色和眼睛：这件资产装不上时它得变成一个能看的方块，不是空白。
	uses_asset = _rig.setup(char_id, Color(0.56, 0.58, 0.64), Color(0.85, 0.30, 0.22))
	var walk: float = _rig.gait_walk()
	_speed = walk if walk > 0.0 else FALLBACK_SPEED
	print("世界里的角色：%s（%s，走 %.2f m/s）"
		% [char_id, "资产" if uses_asset else "几何", _speed])
	return uses_asset


func walk_speed() -> float:
	return _speed


## 沿圆周走。位置是**解析算出来的**（角度 → 圆周上的点），不是积分出来的 ——
## 后者每帧差一点点，走十分钟就漂到房间外面去了。
func _physics_process(delta: float) -> void:
	if _rig == null:
		return
	if is_on_floor():
		velocity.y = 0.0
	else:
		velocity.y -= GRAVITY * delta

	var before := global_position
	_angle = wrapf(_angle + _speed / _radius * delta, 0.0, TAU)
	var target := _center + Vector3(cos(_angle), 0.0, sin(_angle)) * _radius
	var step := target - before
	step.y = 0.0
	# 一帧最多走"自己速度 × 时间"那么远。从墙里被弹出来时，
	# 目标点可能在几米之外，不夹住的话下一帧人会瞬移过去。
	var reach := _speed * delta
	if step.length() > reach:
		step = step.normalized() * reach
	var safe := maxf(delta, 0.0001)
	velocity.x = step.x / safe
	velocity.z = step.z / safe
	move_and_slide()

	# 动画跟着**实际走了多远**，不跟着"打算走多远" —— 被箱子挡住时
	# 腿应该停下来，而不是在原地空踏。用实际位移而不是 `velocity`：
	# 后者是意图，撞上东西的瞬间还没被解算。
	var moved := Vector2(global_position.x - before.x, global_position.z - before.z).length() / safe
	var want := _speed if moved > _speed * BLOCKED_RATIO else 0.0
	_anim_speed = lerpf(_anim_speed, want, clampf(SMOOTH * delta, 0.0, 1.0))
	_rig.update_locomotion(_anim_speed, is_on_floor(), velocity.y, delta)

	if _anim_speed > 0.05 and step.length_squared() > 0.000001:
		var yaw := atan2(-step.x, -step.z)
		rotation.y = lerp_angle(rotation.y, yaw, clampf(TURN_RATE * delta, 0.0, 1.0))
