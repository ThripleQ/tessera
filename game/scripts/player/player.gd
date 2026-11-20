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

const ASSETS = preload("res://scripts/world/assets.gd")
const MESH_LIB = preload("res://scripts/world/mesh_lib.gd")
const CHARACTER_ASSETS = preload("res://scripts/world/character_assets.gd")
const RIG = preload("res://scripts/player/character_rig.gd")
const HANDS = preload("res://scripts/player/hands.gd")
const BAG = preload("res://scripts/player/bag.gd")

## 玩家用哪个角色资产。这个名字就是 `assets/characters/` 下的文件名。
## 换角色只改这一行 —— 不用碰骨架、动画、材质，那些都在资产层归一化好了。
const CHARACTER_ID := "knight"

## 兜底速度：**只在角色资产缺失、拿不到步速档位时**才用得上。
##
## 有资产时这两个数会被动画反推出来的速度覆盖（见 `_apply_gait`）。
## 4.6 / 8.2 是第十四轮凭手感定的，而 Knight 的动画只隐含 0.55 / 2.42 ——
## 差 8 倍和 3.4 倍，那就是"腿在迈、人在冰上滑"的全部原因。
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
var _rig
var _hands
var _bag
## 实际使用的移动速度。开局等于常量，`_apply_gait()` 会把它们改成动画反推值。
var _walk_speed := WALK_SPEED
var _sprint_speed := SPRINT_SPEED

## 收进背包的时候发一下。UI 靠它给反馈 —— 玩家不需要信号，
## 但"按了之后屏幕上有东西动"是"这个键有用"的唯一证据。
## 用信号而不是让玩家直接持有 UI：UI 依赖玩家（要读血量、位置），
## 玩家再依赖 UI 就成了互相牵着，而它们中间的装配层就是 main。
signal collected(content_id: String)

## 换了角色。UI 靠它给一句提示 —— 玩家看不见控制台，而"按了没反应"
## 和"换成了同一个角色"在画面上是同一件事，所以必须说出来。
signal character_changed(char_id: String)

## 由 main 在 add_child 之前注入。玩家不自己去找总线 ——
## 依赖由装配层给，组件之间不互相伸手（structure.md 四）。
var hooks = null
var api = null
## 世界。玩家要它只做一件事：拆掉对着的东西。
## 不通过 api 转一道手是因为 api 是给 mod 的接口，而这里的动作从玩家发起。
var world = null

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

	# 外观：先试带动画的角色资产，拿不到就退回程序化几何。
	# 这条回退不是防御性代码 —— 资产目录是可以整个删掉的，删掉之后游戏
	# 必须还能跑，哪怕人重新变成一个会滑的方块。装不上就满屏空白，比没有更糟。
	_rig = RIG.new()
	_rig.name = "rig"
	_visual.add_child(_rig)
	if _rig.setup(CHARACTER_ID, PLAYER_COLOR, EYE_COLOR):
		print("玩家外观：%s（%d 个动画片段）" % [CHARACTER_ID, _rig.clip_count()])
		_apply_gait()
	else:
		print("玩家外观：角色 `%s` 用不了，退回内置几何" % CHARACTER_ID)

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

	_bag = BAG.new()
	_hands = HANDS.new()
	_hands.setup(self, _camera, hooks, api, world, _bag)

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
				_hands.press()
			else:
				# 没捕获鼠标时，左键的职责是先把鼠标要回来。
				Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
				_captured = true
		elif _captured:
			_hands.release(true)
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT:
		# 右键把对着的东西**收进背包**（不是删掉）。
		#
		# 有了这个动作，"生成预算"才是可以还回去的：在此之前玩家放满 96 件
		# 之后沙盒就死了，只能重启。能放不能收，不叫沙盒。
		# 而收进背包（而不是销毁）是同一件事的另一半：删掉不可逆，玩家就不敢
		# 动自己刚摆好的东西 —— 那只是从另一个方向把沙盒锁死。
		if event.pressed and _captured:
			var got: String = _hands.collect()
			if not got.is_empty():
				collected.emit(got)
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
		_hands.release(false)
	elif event is InputEventKey and event.physical_keycode == KEY_F8 and event.pressed:
		# 换角色。听起来像玩法，其实是**验收**：见 cycle_character()。
		cycle_character()


## 让移动速度跟着动画走，而不是让动画去追速度。
##
## 这是"脚不打滑"的全部秘密，也是最容易被忽略的一步：只调播放倍率只能修一半，
## 因为真正错的是**速度本身**。人跑 4.6 m/s，而这套动画最快只画到 2.42 m/s，
## 想对上就得把倍率拉到 1.9 倍 —— 腿每秒迈 285 步，那不是跑步，是蜂鸟。
##
## 所以反过来：腿迈多快，人就跑多快。速度不再是一个凭感觉的数字，
## 它是"这套动画的步幅 × 步频"算出来的。换角色包，速度自动跟着变。
func _apply_gait() -> void:
	var walk: float = _rig.gait_walk()
	var run: float = _rig.gait_run()
	if walk <= 0.0 or run <= walk:
		print("移动速度：拿不到步速档位，用默认 %.1f / %.1f m/s" % [_walk_speed, _sprint_speed])
		return
	_walk_speed = walk
	_sprint_speed = run
	print("移动速度：走路 %.2f / 冲刺 %.2f m/s（由 %d 档动画反推）"
		% [walk, run, _rig.tier_count()])


## 换下一个角色（F8）。返回换上的是谁，空串表示没换成。
##
## 这不是"换装系统"，是**通道的验收**：如果加一个角色需要改代码，
## 那么"丢个文件夹就能玩"这句话就是假的。所以这里的角色名单只有一个来源 ——
## `assets/characters/` 目录里有什么文件，就能按什么顺序挨个试。
##
## 顺便也是最省事的验证方式：不用改常量、不用重启，
## 按一下就能看出"新角色的身高、朝向、步态、装备"是不是自动对上了。
##
## 速度必须跟着重算：不同角色包腿不一样长，沿用上一个角色的速度就是让它滑。
func cycle_character() -> String:
	var ids := CHARACTER_ASSETS.character_ids()
	if ids.size() < 2:
		return ""
	# `_rig` 是 untyped 的，这一句必须显式写 String：`:=` 推不出来，
	# 而那个 Parse Error 只在真正加载这个文件的时候才炸（游戏或探针）。
	var cur: String = _rig.character_id()
	var at: int = ids.find(cur)
	# 找不到当前角色（第一次跑、或者那个文件被删了）时从头开始。
	var next := String(ids[0] if at < 0 else ids[(at + 1) % ids.size()])
	if not _rig.swap(next, PLAYER_COLOR, EYE_COLOR):
		return ""
	_apply_gait()
	print("玩家外观：%s（%d 个动画片段）" % [next, _rig.clip_count()])
	character_changed.emit(next)
	return next


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
	var speed := _sprint_speed if Input.is_physical_key_pressed(KEY_SHIFT) else _walk_speed
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
	# 动画跟着**真实速度**走，不跟着输入走。用输入意图判会出现那种穿帮：
	# 贴着墙按 W，腿在跑、人没动。而被箱子推着走的时候，腿也该迈。
	var flat_speed := Vector2(velocity.x, velocity.z).length()
	_rig.update_locomotion(flat_speed, is_on_floor(), velocity.y, delta)
	# 抓取在 move_and_slide 之后跑：手上的东西永远以"玩家已经落到哪儿"为准，
	# 而不是以玩家上一帧的位置为准。
	_hands.update(delta)


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
func hands():
	return _hands


## 背包。存档要抄它，菜单要读它，所以它得能被拿到。
func bag():
	return _bag


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
