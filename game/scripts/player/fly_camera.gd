extends Camera3D

## 自由飞行相机。P0-b 阶段的观察工具 —— 还不是玩家。
##
## 真玩家的角色控制器（碰撞、重力、站得住、抓东西）属于 P1。
## 现在需要的是能飞、能转、能看清画面，好判断"内容真的被画出来了吗"。
##
## 左键捕获鼠标转视角，Esc 释放。WASD 平移，空格/Ctrl 上下，Shift 加速。

const SPEED := 9.0
const SPEED_FAST := 26.0
const SENSITIVITY := 0.0022
const PITCH_LIMIT := 1.45

var _yaw := 0.0
var _pitch := 0.0
var _captured := false
var _synced := false


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
			_captured = true
		else:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
			_captured = false
	elif event is InputEventMouseMotion and _captured:
		_yaw -= event.relative.x * SENSITIVITY
		_pitch = clampf(_pitch - event.relative.y * SENSITIVITY, -PITCH_LIMIT, PITCH_LIMIT)
		rotation = Vector3(_pitch, _yaw, 0.0)
	elif event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		_captured = false


func _process(delta: float) -> void:
	# 延迟同步：外面可能用 look_at() 定了初始朝向，那要等入树之后才成立。
	if not _synced:
		_yaw = rotation.y
		_pitch = rotation.x
		_synced = true

	var dir := Vector3.ZERO
	if Input.is_physical_key_pressed(KEY_W):
		dir -= transform.basis.z
	if Input.is_physical_key_pressed(KEY_S):
		dir += transform.basis.z
	if Input.is_physical_key_pressed(KEY_A):
		dir -= transform.basis.x
	if Input.is_physical_key_pressed(KEY_D):
		dir += transform.basis.x
	if Input.is_physical_key_pressed(KEY_SPACE):
		dir += Vector3.UP
	if Input.is_physical_key_pressed(KEY_CTRL):
		dir -= Vector3.UP
	if dir == Vector3.ZERO:
		return

	var speed := SPEED_FAST if Input.is_physical_key_pressed(KEY_SHIFT) else SPEED
	position += dir.normalized() * speed * delta
