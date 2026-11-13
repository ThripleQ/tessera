extends CharacterBody3D

## 第三人称角色控制器。
##
## 身份：这是**玩家**，不是相机。它会掉、会撞、会被挡住。
##
## 手感由三个不起眼的东西决定，玩家永远感知不到它们的存在，但一去掉就会觉得"僵"：
##   COYOTE_TIME  走出平台边缘后的 0.12 秒内还能起跳
##   JUMP_BUFFER  落地前的 0.12 秒内按跳跃，落地瞬间自动起跳
##   AIR_ACCEL    空中的方向修正力只有地面的 1/5，跳出去就必须为落点负责
## 这三个是"看起来粗糙但手感好"的典型例子：它们不增加任何视觉效果。

const MESH_LIB = preload("res://scripts/world/mesh_lib.gd")
const GRAB = preload("res://scripts/player/grab.gd")

const WALK_SPEED := 4.6
const SPRINT_SPEED := 8.2
const GROUND_ACCEL := 16.0
const AIR_ACCEL := 3.5
const JUMP_VELOCITY := 6.6
const GRAVITY := 17.0
const COYOTE_TIME := 0.12
const JUMP_BUFFER := 0.12
const TURN_RATE := 13.0

const MOUSE_SENS := 0.0022
const PITCH_MIN := -1.10
const PITCH_MAX := 0.40
const ARM_LENGTH := 3.8
const HEAD_HEIGHT := 1.40

const BODY_RADIUS := 0.30
const BODY_HEIGHT := 1.68

## 推刚体的力度。CharacterBody3D 默认只是被挡住，不会推动 RigidBody——
## 不给冲量的话，"物理世界"会变成"一堵会掉的墙"。
const PUSH_STRENGTH := 2.2

## 主角配色。玩家的外观属于引擎，不是内容 —— 将来做"换角色皮肤"才走内容层。
const PLAYER_COLOR := Color(0.46, 0.72, 0.96)
const EYE_COLOR := Color(0.10, 0.11, 0.18)

var _yaw := 0.0
var _pitch := -0.16
var _coyote := 0.0
var _buffer := 0.0
var _captured := false
var _arm: SpringArm3D
var _camera: Camera3D
var _visual: Node3D
var _grabber

## 由 main 在 add_child 之前注入。玩家不自己去找总线 ——
## 依赖由装配层给，组件之间不互相伸手（structure.md 四）。
var hooks = null
var api = null

## 菜单类 UI 打开时置真。玩家的输入必须能被整体接管 ——
## 否则鼠标在选菜单，视角在后面跟着转，选完发现自己转了半圈。
var input_blocked := false


## 接管 / 交还输入。交出控制权时把鼠标放出来，收回时重新捕获 ——
## 这两件事必须一起做，只做一半会留下"能动但点了没反应"的状态。
func set_input_blocked(blocked: bool) -> void:
	input_blocked = blocked
	_buffer = 0.0
	if blocked:
		_captured = false
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	else:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		_captured = true


func _ready() -> void:
	var shape := CapsuleShape3D.new()
	shape.radius = BODY_RADIUS
	shape.height = BODY_HEIGHT
	var col := CollisionShape3D.new()
	col.shape = shape
	# 原点在脚底，胶囊中心在身高一半处。
	col.position = Vector3(0.0, BODY_HEIGHT * 0.5, 0.0)
	add_child(col)

	_visual = Node3D.new()
	_visual.name = "visual"
	add_child(_visual)
	var mesh := MeshInstance3D.new()
	mesh.mesh = MESH_LIB.build("player_lowpoly")
	mesh.material_override = MESH_LIB.toon_material_for(PLAYER_COLOR, 0.013)
	_visual.add_child(mesh)

	# 眼睛。听上去是个无关紧要的细节，但它决定了"这是一坨人形"还是"这是个角色"：
	# 动漫风的脸全靠眼睛定位，没有它，再准的头身比也只是一根柱子。
	# 用 unshaded 纯色块，因为眼睛不该参与光照计算 —— 它本来就是个符号。
	var eye_mat := StandardMaterial3D.new()
	eye_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	eye_mat.albedo_color = EYE_COLOR
	for side in [-1.0, 1.0]:
		var eye := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(0.062, 0.082, 0.022)
		eye.mesh = box
		eye.material_override = eye_mat
		eye.position = Vector3(side * 0.055, 1.548, -0.128)
		_visual.add_child(eye)

	var head := Node3D.new()
	head.name = "head"
	head.position = Vector3(0.0, HEAD_HEIGHT, 0.0)
	add_child(head)

	_arm = SpringArm3D.new()
	_arm.name = "arm"
	_arm.spring_length = ARM_LENGTH
	_arm.margin = 0.25
	# 不让弹簧臂被玩家自己的胶囊弹开。
	_arm.add_excluded_object(get_rid())
	head.add_child(_arm)

	_camera = Camera3D.new()
	_camera.name = "camera"
	_camera.fov = 72.0
	_camera.current = true
	_arm.add_child(_camera)

	_grabber = GRAB.new()
	_grabber.setup(self, _camera, hooks, api)

	rotation.y = _yaw
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_captured = true


func _unhandled_input(event: InputEvent) -> void:
	if input_blocked:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			if _captured:
				# 按住左键抓住，松手扔出去。这是沙盒里最自然的一对动作。
				_grabber.press()
			else:
				# 没捕获鼠标时，左键的职责是先把鼠标要回来。
				Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
				_captured = true
		elif _captured:
			_grabber.release(true)
	elif event is InputEventKey and event.physical_keycode == KEY_ESCAPE and event.pressed:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		_captured = false
	elif event is InputEventMouseMotion and _captured:
		_yaw -= event.relative.x * MOUSE_SENS
		_pitch = clamp(_pitch - event.relative.y * MOUSE_SENS, PITCH_MIN, PITCH_MAX)
	elif event is InputEventKey and event.physical_keycode == KEY_SPACE and event.pressed:
		# 不直接起跳，只记一次"意图"。由物理帧判断当时到底能不能跳。
		_buffer = JUMP_BUFFER
	elif event is InputEventKey and event.physical_keycode == KEY_R and event.pressed:
		# 轻轻放下，不给冲量。想摆东西时必须有这个 —— 否则每次都是扔。
		_grabber.release(false)


func _physics_process(delta: float) -> void:
	rotation.y = _yaw
	_arm.rotation.x = _pitch

	if is_on_floor():
		_coyote = COYOTE_TIME
	else:
		_coyote = max(0.0, _coyote - delta)
		velocity.y -= GRAVITY * delta

	_buffer = max(0.0, _buffer - delta)
	if _buffer > 0.0 and _coyote > 0.0:
		velocity.y = JUMP_VELOCITY
		_buffer = 0.0
		_coyote = 0.0

	var wish := Vector3.ZERO if input_blocked else _wish_direction()
	var speed := SPRINT_SPEED if Input.is_physical_key_pressed(KEY_SHIFT) else WALK_SPEED
	var target := wish * speed
	var accel := GROUND_ACCEL if is_on_floor() else AIR_ACCEL

	var flat := Vector3(velocity.x, 0.0, velocity.z)
	flat = flat.lerp(target, clamp(accel * delta, 0.0, 1.0))
	velocity.x = flat.x
	velocity.z = flat.z

	if wish.length_squared() > 0.001:
		# 身体转向移动方向，相机方向不受影响 —— 所以视觉是独立的子节点。
		var move_yaw := atan2(-wish.x, -wish.z)
		_visual.rotation.y = lerp_angle(_visual.rotation.y, move_yaw - _yaw,
				clamp(TURN_RATE * delta, 0.0, 1.0))

	move_and_slide()
	_push_bodies(delta)
	# 抓取在 move_and_slide 之后跑：手上的东西永远以"玩家已经落到哪儿"为准，
	# 而不是以玩家上一帧的位置为准。
	_grabber.update(delta)


## 推开挡路的刚体。
##
## CharacterBody3D 撞上 RigidBody3D 时默认只会被挡住 —— 箱子一动不动，
## 玩家会以为"这游戏没有物理"。所以要主动给冲量，并且按玩家当时的速度给，
## 慢走轻推、冲刺撞飞。
func _push_bodies(delta: float) -> void:
	var speed := Vector2(velocity.x, velocity.z).length()
	if speed < 0.4:
		return
	for i in get_slide_collision_count():
		var hit := get_slide_collision(i)
		var body = hit.get_collider()
		if body is RigidBody3D:
			var push := -hit.get_normal() * speed * PUSH_STRENGTH * delta * 60.0
			# 作用在接触点上，箱子才会转，而不是整体平移。
			body.apply_impulse(push, hit.get_position() - body.global_position)


## 相机朝向决定"前"在哪。所以输入不是世界方向，要过一遍 player 的 basis。
func _wish_direction() -> Vector3:
	var ix := 0.0
	var iz := 0.0
	if Input.is_physical_key_pressed(KEY_W):
		iz -= 1.0
	if Input.is_physical_key_pressed(KEY_S):
		iz += 1.0
	if Input.is_physical_key_pressed(KEY_D):
		ix += 1.0
	if Input.is_physical_key_pressed(KEY_A):
		ix -= 1.0
	if ix == 0.0 and iz == 0.0:
		return Vector3.ZERO
	var dir := transform.basis * Vector3(ix, 0.0, iz)
	dir.y = 0.0
	return dir.normalized()


func camera() -> Camera3D:
	return _camera


## 抓取器。给探针和调试用 —— 玩法本身不通过这个访问，输入直接喂给它。
func grabber():
	return _grabber


## 存档用：玩家在世界里的"姿势"。
##
## 只存位置和两个角度，不存速度 —— 读档时正在飞的玩家应该落地，
## 而不是保留着上次退出那一刻的动量继续飞。那种"还原得太真"反而更怪。
func pose() -> Dictionary:
	return {"pos": global_position, "yaw": _yaw, "pitch": _pitch}


func set_pose(p: Dictionary) -> void:
	var pos = p.get("pos", null)
	if pos is Vector3:
		global_position = pos
		# 速度必须清掉：否则读档瞬间角色会带着上一局的速度冲出去，
		# 而这个"上一局"其实是上一次启动时的事。
		velocity = Vector3.ZERO
	_yaw = float(p.get("yaw", 0.0))
	_pitch = clamp(float(p.get("pitch", -0.16)), PITCH_MIN, PITCH_MAX)
	rotation.y = _yaw
	if _arm != null:
		_arm.rotation.x = _pitch
