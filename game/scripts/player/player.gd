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
const HANDS = preload("res://scripts/player/hands.gd")
const BAG = preload("res://scripts/player/bag.gd")
## 求方向、推箱子这两块纯物理活儿住在 motion.gd —— 它不认识视角和枪。
const MOTION = preload("res://scripts/player/motion.gd")

## 玩家用哪个角色资产。这个名字就是 `assets/characters/` 下的文件名。
## 换角色只改这一行 —— 不用碰骨架、动画、材质，那些都在资产层归一化好了。
##
## 2026-11-21：默认改成**法师**。用户点名"man 好之前用法师就行" ——
## 上一任候选 `man` 的走路动画是原地踏步（一个循环脚只走 2 毫米），
## 当主角会一路滑步，已经从目录里撤掉。法师的步态是量出来的（1.04 / 4.48 m/s），
## 先用它顶着，等找到动作合格的现代人再换。
const CHARACTER_ID := "mage"

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

## 视角（第一/第三人称、俯仰、后坐回位）住在自己那个文件里。
## 它和"怎么动"是两件事 —— 混在一起时最典型的退化是"为了让镜头好看去改
## 物理参数"，而两个问题的解法看起来都像"调一个数"。
const VIEW = preload("res://scripts/player/view.gd")
## 外观（骨架、步速、换角色）也在自己那个文件里 —— 它不知道胶囊和输入，
## 只回答"这套腿一秒钟能走多远"。
const SKIN = preload("res://scripts/player/skin.gd")
const HEAD_HEIGHT := 1.40

const BODY_RADIUS := 0.30
const BODY_HEIGHT := 1.68

## 主角配色。玩家的外观属于引擎，不是内容 —— 将来做"换角色皮肤"才走内容层。
const PLAYER_COLOR := Color(0.46, 0.72, 0.96)
const EYE_COLOR := Color(0.10, 0.11, 0.18)

var _view
var _coyote := 0.0
var _buffer := 0.0
var _captured := false
var _arm: SpringArm3D
var _camera: Camera3D
var _visual: Node3D
var _skin
var _hands
var _bag
var _gun = null
## 实际使用的移动速度。开局等于常量，`_apply_gait()` 会把它们改成动画反推值。
var _walk_speed := WALK_SPEED
var _sprint_speed := SPRINT_SPEED
## 起步初速度：从静止到动，第一步就有速度（走速的 70%）。0 = 不给。
## 理由见 `_physics_process` 里那一段 —— 这是"起步像真人"和"起步像机器人"的分界。
var _start_speed := 0.0
## 停车阈值：速度低于它就直接归零，不让它以极慢的速度继续往前飘。
##
## 这个数不是随手定的：最低那档步态 0.73 m/s × 倍率下限 0.45 = **0.33 m/s**。
## 比它慢时倍率会被下限夹住 —— 动画还在往前送，身体却已经慢下来，
## 脚就在身后拖着走（滑步）。所以要在被夹住之前就停。
var _stop_speed := 0.30

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
	_skin = SKIN.new()
	_skin.remember_colors(PLAYER_COLOR, EYE_COLOR)
	if _skin.build(_visual, CHARACTER_ID, PLAYER_COLOR, EYE_COLOR):
		print("玩家外观：%s（%d 个动画片段）" % [CHARACTER_ID, _skin.clip_count()])
		_apply_gait()
	else:
		print("玩家外观：角色 `%s` 用不了，退回内置几何" % CHARACTER_ID)

	var head := Node3D.new()
	head.name = "head"
	head.position = Vector3(0.0, HEAD_HEIGHT, 0.0)
	add_child(head)

	_arm = SpringArm3D.new()
	_arm.name = "arm"
	_arm.margin = 0.25
	# 不让弹簧臂被玩家自己的胶囊弹开。
	_arm.add_excluded_object(get_rid())
	head.add_child(_arm)

	_camera = Camera3D.new()
	_camera.name = "camera"
	_camera.fov = 78.0
	_camera.current = true
	_arm.add_child(_camera)

	_bag = BAG.new()
	_hands = HANDS.new()
	_hands.setup(self, _camera, hooks, api, world, _bag)

	# 视角必须在相机和外观都建好之后装：它一上来就要按模式摆好，
	# 否则第一帧是"第三人称的相机 + 看不见的自己"，然后才跳过来。
	_view = VIEW.new()
	_view.setup(self, _arm, _camera, _visual)

	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_captured = true


## 切换视角。返回切换之后是不是第一人称。
##
## 顺带是玩法上的切换：第一人称左键开火，第三人称左键抓东西 ——
## 两套动作共用一个键，但它们的语境完全不同，混在一起会互相打断。
func toggle_view() -> bool:
	var fp: bool = _view.toggle()
	# 换视角时松扳机、放下手里的东西：第三人称抓着箱子切到第一人称，
	# 箱子会顶在脸上，而玩家会以为是"画面出错了"。
	if _gun != null:
		_gun.trigger(false)
		_gun.set_shown(fp)
	if _hands != null and fp:
		_hands.release(false)
	return fp


## 后坐力。由枪在每一发之后调用 —— 玩家自己不知道枪的存在，
## 所以这里只收两个角度，怎么来的不关它的事。
func add_recoil(pitch: float, yaw: float) -> void:
	_view.add_recoil(pitch, yaw)


## 把枪装到手上。由装配层在入树之后调用。
func attach_gun(gun) -> void:
	_gun = gun
	if _gun != null:
		_gun.setup_view(_camera)
		_gun.set_shown(_view.first_person)


func _unhandled_input(event: InputEvent) -> void:
	if input_blocked:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			if _captured:
				if _view.first_person and _gun != null:
					# 第一人称：左键是扳机。抓取在这个视角下没有意义 ——
					# 你连自己的手都看不见，抓住的箱子糊在脸上。
					_gun.trigger(true)
				else:
					# 按住左键抓住，松手扔出去。这是沙盒里最自然的一对动作。
					_hands.press()
			else:
				# 没捕获鼠标时，左键的职责是先把鼠标要回来。
				Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
				_captured = true
		elif _captured:
			if _view.first_person and _gun != null:
				_gun.trigger(false)
			else:
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
		_view.look(event.relative)
	elif event is InputEventKey and event.physical_keycode == KEY_SPACE and event.pressed:
		# 不直接起跳，只记一次"意图"。由物理帧判断当时到底能不能跳。
		_buffer = JUMP_BUFFER
	elif event is InputEventKey and event.physical_keycode == KEY_R and event.pressed:
		if _view.first_person and _gun != null:
			_gun.reload()
		else:
			# 轻轻放下，不给冲量。想摆东西时必须有这个 —— 否则每次都是扔。
			_hands.release(false)
	elif event is InputEventKey and event.physical_keycode == KEY_V and event.pressed:
		# 第一 / 第三人称。玩法上是"开枪"和"搬东西"两个模式，
		# 验收上是"能看见自己"和"看不见自己"。
		toggle_view()
	elif event is InputEventKey and event.physical_keycode == KEY_F8 and event.pressed:
		# 换角色。听起来像玩法，其实是**验收**：见 cycle_character()。
		cycle_character()


## 让移动速度跟着动画走，而不是让动画去追速度。
##
## 这是"脚不打滑"的全部秘密：只调播放倍率只能修一半，因为真正错的是**速度本身**。
## 腿迈多快，人就跑多快 —— 速度不是凭感觉定的数，是"这套动画的步幅 × 步频"
## 算出来的（ADR 0015）。换角色包，速度自动跟着变。
func _apply_gait() -> void:
	if _skin.walk_speed <= 0.0 or _skin.run_speed <= _skin.walk_speed:
		print("移动速度：拿不到步速档位，用默认 %.1f / %.1f m/s" % [_walk_speed, _sprint_speed])
		return
	_walk_speed = _skin.walk_speed
	_sprint_speed = _skin.run_speed
	# 起步初速 = 走速的 70%。给少了像慢动作起步，给多了像被人一把推出去。
	# 只在真的量到档位时才给 —— 兜底速度（4.6 / 8.2）是写死的，用它起步会窜出去。
	_start_speed = _walk_speed * 0.7
	print("移动速度：走路 %.2f / 冲刺 %.2f m/s（由 %d 档动画反推）"
		% [_walk_speed, _sprint_speed, _skin.tier_count()])


## 换下一个角色（F8）。返回换上的是谁，空串表示没换成。
##
## 顺便也是最省事的验证方式：不用改常量、不用重启，
## 按一下就能看出"新角色的身高、朝向、步态、装备"是不是自动对上了。
func cycle_character() -> String:
	var next: String = _skin.cycle()
	if next.is_empty():
		return ""
	# 速度必须跟着重算：不同角色包腿不一样长，沿用上一个角色的速度就是让它滑。
	_apply_gait()
	print("玩家外观：%s（%d 个动画片段）" % [next, _skin.clip_count()])
	character_changed.emit(next)
	return next


func _physics_process(delta: float) -> void:
	# 视角自己回位、自己写节点。后坐只加在相机上，不加在身体上：
	# 否则连发时人会被"推着转向"，走路方向跟着枪口漂，手感立刻变糊。
	_view.tick(delta)

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

	var wish := Vector3.ZERO if input_blocked else MOTION.wish_direction(transform.basis)
	var speed := _sprint_speed if Input.is_physical_key_pressed(KEY_SHIFT) else _walk_speed
	var target := wish * speed
	var accel := GROUND_ACCEL if is_on_floor() else AIR_ACCEL

	var flat := Vector3(velocity.x, 0.0, velocity.z)
	if wish.length_squared() > 0.01 and is_on_floor():
		# 起步：真人第一步就迈出去，不是从 0 慢慢爬。
		# 爬的过程里动画倍率会小到 0.2 —— 脚在动但动得像慢动作；
		# 而速度低于阈值时播的是**待机**，脚不动身体在飘，看着像滑着走。
		# 所以从静止起步时直接给一个初速度，之后再由加速曲线往上走。
		if flat.length() < 0.05 and _start_speed > 0.0:
			flat = wish * _start_speed
		flat = flat.lerp(target, clamp(accel * delta, 0.0, 1.0))
	else:
		# 松手：减速到停。到阈值以下直接归零 —— 再慢下去倍率会趋 0，
		# 变成慢动作刹车，而身体还在以极慢的速度往前飘。
		flat = flat.lerp(Vector3.ZERO, clamp(accel * delta, 0.0, 1.0))
		if flat.length() < _stop_speed:
			flat = Vector3.ZERO
	velocity.x = flat.x
	velocity.z = flat.z

	if wish.length_squared() > 0.001:
		# 身体转向移动方向，相机方向不受影响 —— 所以视觉是独立的子节点。
		var move_yaw := atan2(-wish.x, -wish.z)
		_visual.rotation.y = lerp_angle(_visual.rotation.y, move_yaw - _view.yaw,
				clamp(TURN_RATE * delta, 0.0, 1.0))

	move_and_slide()
	MOTION.push_bodies(self, delta)
	# 动画跟着**真实速度**走，不跟着输入走。用输入意图判会出现那种穿帮：
	# 贴着墙按 W，腿在跑、人没动。而被箱子推着走的时候，腿也该迈。
	var flat_speed := Vector2(velocity.x, velocity.z).length()
	_skin.rig.update_locomotion(flat_speed, is_on_floor(), velocity.y, delta)
	# 抓取在 move_and_slide 之后跑：手上的东西永远以"玩家已经落到哪儿"为准，
	# 而不是以玩家上一帧的位置为准。
	_hands.update(delta)
	if _gun != null:
		_gun.tick(delta)


func camera() -> Camera3D:
	return _camera


## 现在是不是第一人称。准星、落点圈、手里的枪都靠它决定露不露面 ——
## 三个部件各自去读 `_view` 会让"视角"这件事有三个入口，
## 所以它们统一问玩家这一句。
func is_first_person() -> bool:
	return _view != null and _view.first_person


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
	return {"pos": global_position, "yaw": _view.yaw, "pitch": _view.pitch}


func set_pose(p: Dictionary) -> void:
	var pos = p.get("pos", null)
	if pos is Vector3:
		global_position = pos
		# 速度必须清掉：否则读档瞬间角色会带着上一局的速度冲出去，
		# 而这个"上一局"其实是上一次启动时的事。
		velocity = Vector3.ZERO
	_view.yaw = float(p.get("yaw", 0.0))
	# 俯仰不直接写：夹紧范围取决于当前是第一还是第三人称，交给视角自己判。
	_view.pitch = float(p.get("pitch", -0.16))
	_view.apply()
