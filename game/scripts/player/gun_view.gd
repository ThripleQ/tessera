extends Node3D

## 第一人称里的那把枪。**它只负责"看起来",不负责"打中"** ——
## 射速、伤害、后坐在 `gun.gd`，摆位、动画、枪口火焰在这里。
##
## 为什么分开：视图模型的坐标是相机空间（右下、贴脸、跟着画面抖），
## 而弹道是世界空间。混在一个文件里，最典型的 bug 是"用枪模型的位置发射线"，
## 于是子弹从膝盖飞出去。现在两边**只共享一个点**：`muzzle_world()` ——
## 枪口在世界里的位置，子弹和曳光都从这里出发。

const GUN_FLASH = preload("res://scripts/player/gun_flash.gd")
##
## 模型来自 J-Toastie（CC-BY 3.0，见 assets/ASSETS.md）：AKM + 绑骨手臂，
## 自带 Idle / Shoot / Reload 三段动画。**手臂是模型的一部分，不是另画的** ——
## 上一版只有一根光枪，看起来像"漂浮的木头"，缺的就是这双手。
## 换了模型之后，换弹、抬枪这些动作不用再手写，动画师已经调好了。

## 模型路径。它不走 `assets.gd` 的资源覆盖：枪是玩家手里的视图模型，
## 不在世界里，也不该被"丢个文件进来换外观"的规则改掉 ——
## 那条规则换的是**世界里的网格**（第 11 步守着它）。
const MODEL_SUBDIR := "assets/weapons/akm_fps.glb"

## 模型文件整体被放大了 336.5 倍，但蒙皮的绑定矩阵又把其中大半吃了回去 ——
## 真正画到屏幕上的有效倍率约 54 倍（量出来的；336.5 只是节点上的数字）。
## 这里再乘 0.026，枪身约 0.42 × 54 × 0.026 ≈ 0.59 米，数值是量出来的。
##
## 为什么比真枪短：视图模型贴着脸，按真实长度摆会占掉半个屏幕。
## 第一人称游戏全都这么缩，玩家不会觉得枪小，只会觉得"我举着它"。
const GUN_SCALE := 0.026

## 静止位置：相机坐标系，右 17 cm、下 13.5 cm、贴脸 13 cm。
## 枪身沿 -Z 延伸，枪口落在画面右侧偏低处；枪托从相机身后穿出去，
## 近处裁剪会切掉它 —— 这正好是我们要的（看不见贴着镜头的部分）。
const REST_POS := Vector3(0.19, -0.17, -0.28)
## 绕 Y 转 90° 让模型的 +X（枪口方向）朝 -Z。再加 3° 往画面中心收，
## 让枪口停在准星右下方而不是一路顶到屏幕边上。
const REST_YAW := 1.5708 + 0.05
## 一点点侧倾。完全正着摆像 CAD 截图，人拿枪不会那么直。
const REST_ROLL := -0.035

## 开火时的后坐位移（米）与抬头（弧度）。 Shoot 动画本身也有后坐，
## 这里给的是一点点额外的"贴脸感"—— 全部交给动画会让枪像固定在轨道上。
const KICK_BACK := 0.022
const KICK_RISE := 0.030
const KICK_RETURN := 13.0

## 走路时枪的晃动。幅度按速度缩放，站着不动时只剩呼吸。
const BOB_SCALE := 0.010
const BREATH_SCALE := 0.0012

## 鼠标转身时枪会"甩"一下再回来：惯性。系数是每像素的偏移量，
## 100 像素的快速转身约让枪横移 1.2 厘米。
const SWAY_PER_PX := 0.00012
const SWAY_MAX := 0.028
const SWAY_RETURN := 11.0

var _model: Node3D = null
var _anim: AnimationPlayer = null
var _player = null
var _camera: Camera3D = null
var _clip_idle := ""
var _clip_shoot := ""
var _clip_reload := ""

var _kick := 0.0
var _flash = null
## 枪口在相机空间里的位置。**这是量出来的，不是猜的**：
## 1280×720、FOV 78 下，枪口在画面上落在 (795, 430)；
## 按那个像素反投影到 0.52 米深处，得到 (0.181, -0.082, -0.52)。
##
## 为什么不从网格包围盒算：这个模型的骨架带非等比缩放，蒙皮又把
## 336.5 倍的父节点变换吃掉了一半，硬算出来的枪口会飘在枪管旁边。
## 看不出来就量一遍 —— 比在四个坐标系之间猜快得多。
const MUZZLE_VIEW_POS := Vector3(0.181, -0.082, -0.52)

## 枪口在**模型局部**坐标里的位置。开局用上面的相机空间坐标反推一次 ——
## 之后模型怎么转，枪口都跟着走，火焰和曳光不用再猜。
var _muzzle_local := Vector3.ZERO
## 这一帧准心落在哪（相机空间）。由 `gun.gd` 每帧喂进来。
var _aim_local := Vector3.ZERO
var _has_aim := false

var _sway := Vector2.ZERO
var _bob_phase := 0.0
var _breath_phase := 0.0


## 玩家由 `gun.gd` 在入树前注入：要读速度和落地状态来做晃动。
func bind(player) -> void:
	_player = player


func _ready() -> void:
	var path: String = ProjectSettings.globalize_path("res://") \
			.path_join("..").path_join(MODEL_SUBDIR)
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	if doc.append_from_file(path, state) != OK:
		push_error("枪的模型读不出来：%s（枪会隐形的，但游戏照跑）" % path)
		return
	var root := doc.generate_scene(state)
	if root == null:
		push_error("枪的模型生不成场景：%s" % path)
		return
	_model = root
	_model.name = "model"
	add_child(_model)
	_model.scale = Vector3.ONE * GUN_SCALE
	_model.rotation = Vector3(0.0, REST_YAW, REST_ROLL)
	_model.position = REST_POS
	# 模型自带的骨骼动画只驱动骨架；外层这套变换是我们自己的"举枪姿势"。
	_model.set_meta("view_model", true)
	# 反推枪口在模型局部坐标里的位置。相机空间那个数是量出来的（见上），
	# 这里把它换算回模型自己的空间；之后旋转、晃动都不会让它跑掉。
	_camera = get_parent() as Camera3D
	_muzzle_local = _model.transform.affine_inverse() * MUZZLE_VIEW_POS

	_setup_anim()
	_flash = GUN_FLASH.new()
	add_child(_flash)


## 找到三段动画并按用途命名。名字里带 `|`（glTF 的 "Armature|Idle"），
## 所以按后缀匹配 —— 换一版导出工具/前缀改名时不用改代码。
func _setup_anim() -> void:
	_anim = _find(_model, "AnimationPlayer") as AnimationPlayer
	if _anim == null:
		push_error("枪的模型没有动画：换弹和开火会变成静止画面")
		return
	for name in _anim.get_animation_list():
		var tail: String = String(name).to_lower()
		var bar := tail.rfind("|")
		if bar >= 0:
			tail = tail.substr(bar + 1)
		if tail == "idle":
			_clip_idle = name
		elif tail == "shoot":
			_clip_shoot = name
		elif tail == "reload":
			_clip_reload = name
	if _clip_idle.is_empty() or _clip_shoot.is_empty() or _clip_reload.is_empty():
		push_error("枪的动画不全（idle=%s shoot=%s reload=%s）"
			% [_clip_idle, _clip_shoot, _clip_reload])
		return
	# Idle 是循环的；Shoot / Reload 只播一遍。
	var idle := _anim.get_animation(_clip_idle)
	idle.loop_mode = Animation.LOOP_LINEAR
	# 换动作时给一点点过渡，硬切会在肩部看到一帧抽搐。
	_anim.playback_default_blend_time = 0.05
	_anim.play(_clip_idle)


## 枪口在相机空间里的位置。模型每帧被举枪姿势重摆，所以从模型变换反算 ——
## 不是"静止位置 + 偏移"，那样枪一转向火焰就会飘。
func muzzle_position() -> Vector3:
	if _model == null:
		return MUZZLE_VIEW_POS
	return _model.transform * _muzzle_local


## 枪口在世界里的位置。曳光弹、子弹的起点都用它 —— 眼睛看到的枪口
## 和子弹飞出来的地方必须是同一个点。
func muzzle_world() -> Vector3:
	return to_global(muzzle_position())


## 枪口该指向哪。传世界坐标；每帧由 `gun.gd` 用准心的落点喂进来。
func aim_at_world(point: Vector3) -> void:
	if _camera == null:
		return
	_aim_local = _camera.to_local(point)
	_has_aim = true


## 枪管（模型 +X）在世界里的方向。探针用它检查"枪口是不是真的对着准心"。
func barrel_world() -> Vector3:
	if _model == null:
		return Vector3.ZERO
	return (_model.global_transform.basis * Vector3.RIGHT).normalized()


## 鼠标转视角。给多少像素就甩多少 —— 由玩家在输入里调用，
## 因为只有它知道鼠标这一帧真的动了多少。
func look(relative: Vector2) -> void:
	# 视角往右转，枪因为惯性落在左边；往下看，枪往上飘。
	_sway.x = clampf(_sway.x - relative.x * SWAY_PER_PX, -SWAY_MAX, SWAY_MAX)
	_sway.y = clampf(_sway.y + relative.y * SWAY_PER_PX, -SWAY_MAX, SWAY_MAX)


## 开一枪。只改目标值，真正的位移每帧插值 —— 直接设位置会"啪"地跳，
## 而玩家能看出来的枪感全在那几帧里。
func kick() -> void:
	_kick = 1.0
	if _flash != null:
		_flash.flash(muzzle_position())
	if _anim != null and not _clip_shoot.is_empty():
		# 换弹优先：换弹动画播到一半被开火打断，看起来像手在抽筋。
		if _anim.current_animation != _clip_reload:
			_anim.speed_scale = 1.0
			_anim.play(_clip_shoot)
			_anim.queue(_clip_idle)


## 开始换弹。总时长来自内容（TOML 的 reload），动画按它变速 ——
## 弹匣 1.7 秒装满，动画就 1.7 秒演完，不多不少。
func reload_started(total: float) -> void:
	if _anim == null or _clip_reload.is_empty():
		return
	var clip := _anim.get_animation(_clip_reload)
	var speed := 1.0
	if total > 0.05 and clip != null and clip.length > 0.05:
		speed = clip.length / total
	_anim.speed_scale = clampf(speed, 0.5, 3.0)
	_anim.play(_clip_reload)
	_anim.queue(_clip_idle)


## 换弹被别的状态顶掉（比如切视角）时回到待机。
func reload_finished() -> void:
	if _anim == null or _clip_idle.is_empty():
		return
	if _anim.current_animation == _clip_reload:
		_anim.speed_scale = 1.0
		_anim.play(_clip_idle)


## 只在该看见它的时候看见它。第三人称下这把枪挂在相机上，
## 会变成"画面右下角飘着一把没人的枪" —— 而且它比玩家本人还显眼。
func set_shown(shown: bool) -> void:
	visible = shown
	# 火焰和点光也是相机空间的东西，单独关 —— 否则第三人称下
	# 枪藏起来了，枪口还悬着一片亮。
	if not shown:
		_has_aim = false
		if _flash != null:
			_flash.hide_flash()


func tick(delta: float) -> void:
	if _model == null:
		return

	# 惯性回位。指数逼近，快速甩枪时枪在画面里划一小段弧。
	_sway = _sway.lerp(Vector2.ZERO, clampf(delta * SWAY_RETURN, 0.0, 1.0))
	if _kick > 0.0:
		_kick = maxf(0.0, _kick - delta * KICK_RETURN)

	# 呼吸和走路晃动。速度从玩家身上读 —— 枪不猜"我该不该晃"，
	# 它只回答"这个人现在动得多快"。
	var speed := 0.0
	var grounded := true
	if _player != null and is_instance_valid(_player):
		var v: Vector3 = _player.velocity
		speed = Vector2(v.x, v.z).length()
		grounded = _player.is_on_floor()
	_breath_phase += delta * 1.7
	_bob_phase += delta * (3.0 + speed * 1.6)
	var moving: float = clampf(speed / 4.0, 0.0, 1.0) if grounded else 0.0
	var bob := Vector2(
		cos(_bob_phase * 0.5) * BOB_SCALE * moving,
		sin(_bob_phase) * BOB_SCALE * moving)
	var breath := Vector2(
		cos(_breath_phase) * BREATH_SCALE * 0.5,
		sin(_breath_phase) * BREATH_SCALE)

	var offset := Vector3(
		_sway.x + bob.x,
		_sway.y + bob.y + breath.y,
		KICK_BACK * _kick)
	var rot := Vector3(
		KICK_RISE * _kick + _sway.y * 0.55,
		REST_YAW,
		REST_ROLL - _sway.x * 0.8 + breath.y * 0.4)
	var xf := Transform3D(
		Basis.from_euler(rot) * Basis.from_scale(Vector3.ONE * GUN_SCALE),
		REST_POS + offset)
	if _has_aim:
		xf = _aimed(xf)
	_model.transform = xf

	if _flash != null:
		# 火焰跟着枪口走。有了 `_aimed()`，这里拿到的就是枪管真正的末端。
		_flash.follow(_model.transform * _muzzle_local)


## 把枪管转到准心落点上。**绕枪口旋转** —— 枪口不动，火焰和曳光才接得上；
## 否则每瞄一次，枪口就在画面里挪几厘米。
##
## 为什么不是"把整把枪转过去"：枪托会甩到脸上，而且准心和枪口本来
## 只差几度（3 米处约 3.5°），绕枪口转是最小、最自然的修正。
func _aimed(xf: Transform3D) -> Transform3D:
	var m: Vector3 = xf * _muzzle_local
	var want := (_aim_local - m).normalized()
	var barrel: Vector3 = (xf.basis * Vector3.RIGHT).normalized()
	if want.length_squared() < 0.5 or barrel.dot(want) > 0.99999:
		return xf
	var q := Quaternion(barrel, want)
	var nb := Basis(q) * xf.basis
	return Transform3D(nb, m - nb * _muzzle_local)


## 探针用的只读快照：模型装上了没有、现在播的是哪一段。
func model_ok() -> bool:
	return _model != null and _anim != null


func current_clip() -> String:
	return _anim.current_animation if _anim != null else ""


func has_clip(tail: String) -> bool:
	if _anim == null:
		return false
	for name in _anim.get_animation_list():
		var low := String(name).to_lower()
		var bar := low.rfind("|")
		if bar >= 0:
			low = low.substr(bar + 1)
		if low == tail:
			return true
	return false


func _find(n: Node, cls: String):
	if n.is_class(cls):
		return n
	for c in n.get_children():
		var r = _find(c, cls)
		if r != null:
			return r
	return null