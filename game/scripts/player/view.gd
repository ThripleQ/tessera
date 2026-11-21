extends RefCounted

## 视角。第一 / 第三人称、俯仰范围、后坐力回位 —— 全在这里。
##
## 为什么单独一个文件：它和"怎么动"是两件事，而它们曾经挤在一个 449 行的
## `player.gd` 里。混在一起时最典型的退化是"为了让镜头好看去改物理参数"——
## 两个问题的解法看起来都像"调一个数"。
##
## 一条不能省的分离：**后坐力加在相机上，不加在身体上**。
## 加在身体上，连发时人会被推着转向，走路方向跟着枪口漂。
##
## **第一人称不画自己**，但胶囊、影子、步态状态机一样在跑 ——
## 第 14/15/16 步验的是"这个人会不会动"，不是"你看不看得见他"。

## 第三人称的俯仰范围：往下看得多、往上看得少（相机在身后，抬头会穿进身体）。
const PITCH_MIN_TP := -1.10
const PITCH_MAX_TP := 0.40
## 第一人称要比第三人称宽松得多：抬头打天上的、低头看脚下都是正常动作。
const PITCH_MIN_FP := -1.45
const PITCH_MAX_FP := 1.15
## 弹簧臂长度。第三人称镜头在身后这么远。
const ARM_LENGTH := 3.8
## 第三人称镜头从右肩上方看，不是正对后脑勺。
##
## 为什么必须偏：法师的帽子有一米宽。镜头正对背后时，帽檐 + 袍子
## 把右手里的枪挡得干干净净 —— 于是"第三人称也有枪"只是代码里的事实，
## 玩家看不见。偏到右肩之后，枪就在画面右下角，和第一人称的位置呼应。
const SHOULDER := Vector3(0.55, 0.10, 0.0)
const MOUSE_SENS := 0.0022
## 后坐回位的速度（每秒逼近比例）。8 在 60 帧下约 0.2 秒归位 ——
## 快到"能连发"，慢到"能看见枪抬起来又落下"。
const RECOIL_RETURN := 8.0

## 默认第一人称。这是 FPS 项目，第一眼就该是"手里有枪"。
var first_person := true
var yaw := 0.0
var pitch := -0.16

## 后坐力不是"改一下 pitch 就完事"——pitch 是鼠标的意图，后坐是枪的代价。
## 两者分开存，回位之后玩家瞄的那个点还在原处。
var _recoil_pitch := 0.0
var _recoil_yaw := 0.0

var _player: Node3D
var _arm: SpringArm3D
var _camera: Camera3D
var _visual: Node3D


func setup(player: Node3D, arm: SpringArm3D, camera: Camera3D, visual: Node3D) -> void:
	_player = player
	_arm = arm
	_camera = camera
	_visual = visual
	apply()


## 按当前模式摆相机与可见性。
func apply() -> void:
	if _arm == null:
		return
	_arm.spring_length = 0.0 if first_person else ARM_LENGTH
	# 偏移加在弹簧臂的**根部**，不是相机上：SpringArm3D 每帧会把直接子节点
	# 摆到 (0, 0, spring_length)，写在相机上的 x 会被它覆盖掉。
	# 根部偏移在两种视角下都是"眼睛"的位置，第一人称必须回正 ——
	# 视图模型的枪口是按"相机在眼睛上"量出来的。
	_arm.position = Vector3.ZERO if first_person else SHOULDER
	if _visual != null:
		_visual.visible = not first_person
	pitch = clampf(pitch, PITCH_MIN_FP if first_person else PITCH_MIN_TP,
			PITCH_MAX_FP if first_person else PITCH_MAX_TP)


## 鼠标转视角。只在鼠标被捕获时由玩家调用。
func look(relative: Vector2) -> void:
	yaw -= relative.x * MOUSE_SENS
	pitch = clampf(pitch - relative.y * MOUSE_SENS,
			PITCH_MIN_FP if first_person else PITCH_MIN_TP,
			PITCH_MAX_FP if first_person else PITCH_MAX_TP)


func add_recoil(p: float, y: float) -> void:
	_recoil_pitch += p
	_recoil_yaw += y


## 每物理帧：回位并写进节点。后坐只加在 arm 上，玩家本体的 yaw 不受影响。
func tick(delta: float) -> void:
	if _player == null or _arm == null:
		return
	var k := clampf(delta * RECOIL_RETURN, 0.0, 1.0)
	_recoil_pitch = lerpf(_recoil_pitch, 0.0, k)
	_recoil_yaw = lerpf(_recoil_yaw, 0.0, k)
	_player.rotation.y = yaw
	_arm.rotation.x = pitch + _recoil_pitch
	_arm.rotation.y = _recoil_yaw


func toggle() -> bool:
	first_person = not first_person
	apply()
	return first_person


func camera() -> Camera3D:
	return _camera
