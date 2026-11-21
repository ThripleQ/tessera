extends Node3D

## 第一人称里的那把枪。**它只负责"看起来",不负责"打中"** ——
## 射速、伤害、后坐在 `gun.gd`，摆位、动画、枪口火焰在这里。
##
## 为什么分开：视图模型的坐标是相机空间（右下、贴脸、跟着画面抖），
## 而弹道是世界空间（从相机发出、打到墙为止）。混在一个文件里，
## 最典型的 bug 是"用枪模型的位置发射线"，于是子弹从膝盖飞出去。
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

## 枪口火焰存在多久。0.07 秒 = 四帧 —— 长了就变成"枪嘴里有团火在烧"。
## 它不是一个特效，是一个**证据**：枪口这个位置真的放出了东西。
const FLASH_TIME := 0.07

## 枪口在骨架空间里的位置（模型原始单位，未乘 336.5）。
## 枪管沿 +X 到 0.156 结束，取 0.158 让火焰完全露出枪口。
const MUZZLE_BONE_POS := Vector3(0.158, -0.002, -0.012)

var _model: Node3D = null
var _anim: AnimationPlayer = null
var _player = null
var _clip_idle := ""
var _clip_shoot := ""
var _clip_reload := ""

var _kick := 0.0
var _flash := 0.0
var _flash_node: Node3D = null
var _flash_light: OmniLight3D = null
## 枪口在相机空间里的位置。**这是量出来的，不是猜的**：
## 1280×720、FOV 78 下，枪口在画面上落在 (795, 430)；
## 按那个像素反投影到 0.52 米深处，得到 (0.181, -0.082, -0.52)。
##
## 为什么不从网格包围盒算：这个模型的骨架带非等比缩放，蒙皮又把
## 336.5 倍的父节点变换吃掉了一半，硬算出来的枪口会飘在枪管旁边。
## 看不出来就量一遍 —— 比在四个坐标系之间猜快得多。
const MUZZLE_VIEW_POS := Vector3(0.181, -0.082, -0.52)

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

	_setup_anim()
	_make_flash()


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


## 枪口在相机空间里的位置。叠上举枪姿势的偏移（晃动、后坐），
## 火焰就会跟着枪一起动。骨骼动画那一两厘米的后坐不管：火焰只亮 70 毫秒。
func muzzle_position() -> Vector3:
	if _model == null:
		return MUZZLE_VIEW_POS
	return MUZZLE_VIEW_POS + (_model.position - REST_POS)


## 枪口那一小片亮：两片加法混合的软光斑 + 一盏只亮三帧的点光。
##
## **它挂在视图模型下，不是挂在枪的模型节点里。** 模型缩到 0.026 倍，
## 子节点的坐标和尺寸会跟着缩 —— 第一版把火焰做成模型的子节点，
## 结果它只有 2 厘米大，而且位置挪到了枪口以内，在画面里根本找不到。
func _make_flash() -> void:
	_flash_node = Node3D.new()
	_flash_node.name = "muzzle_flash"
	_flash_node.visible = false
	add_child(_flash_node)

	_add_flash_quad(Vector2(0.085, 0.085), Color(1.0, 0.93, 0.72, 1.0), 0.0)
	_add_flash_quad(Vector2(0.045, 0.045), Color(1.0, 0.78, 0.38, 0.9), 0.6)

	_flash_light = OmniLight3D.new()
	_flash_light.light_color = Color(1.0, 0.80, 0.45)
	_flash_light.light_energy = 1.3
	_flash_light.omni_range = 2.0
	_flash_light.shadow_enabled = false
	_flash_light.visible = false
	add_child(_flash_light)


## 一片软光斑。用程序生成的径向渐变而不是贴图：
## 项目不为一个 3 帧的特效多带一张 png，而且渐变在哪个分辨率下都不糊。
func _add_flash_quad(size: Vector2, tint: Color, spin: float) -> void:
	var mi := MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = size
	mi.mesh = quad
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	# 不测深度：枪口那片必须在枪身之前画出来，否则它会被枪管自己挡住，
	# 而画面上看起来像"火焰没触发"（第一版就是这样，找了半天）。
	mat.no_depth_test = true
	mat.albedo_color = tint
	mat.albedo_texture = _glow_texture()
	mi.material_override = mat
	mi.rotation.z = spin
	_flash_node.add_child(mi)


func _glow_texture() -> GradientTexture2D:
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 0.35, 1.0])
	g.colors = PackedColorArray([
		Color(1.0, 1.0, 1.0, 1.0),
		Color(1.0, 0.86, 0.5, 0.55),
		Color(1.0, 0.45, 0.1, 0.0),
	])
	var tex := GradientTexture2D.new()
	tex.gradient = g
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.5)
	tex.fill_to = Vector2(1.0, 0.5)
	tex.width = 64
	tex.height = 64
	return tex


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
	_flash = FLASH_TIME
	if _flash_node != null:
		# 每发换个角度和大小：同一个贴片连闪十次会被看成"屏幕在抖"。
		_flash_node.rotation.z = randf() * TAU
		_flash_node.scale = Vector3.ONE * randf_range(0.85, 1.25)
		_flash_node.visible = true
	if _flash_light != null:
		_flash_light.light_energy = randf_range(1.0, 1.6)
		_flash_light.visible = true
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
		if _flash_node != null:
			_flash_node.visible = false
		if _flash_light != null:
			_flash_light.visible = false


func tick(delta: float) -> void:
	if _flash > 0.0:
		_flash -= delta
		if _flash <= 0.0:
			if _flash_node != null:
				_flash_node.visible = false
			if _flash_light != null:
				_flash_light.visible = false

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
	_model.position = REST_POS + offset
	_model.rotation = Vector3(
		KICK_RISE * _kick + _sway.y * 0.55,
		REST_YAW,
		REST_ROLL - _sway.x * 0.8 + breath.y * 0.4)

	if _flash_node != null:
		# 火焰跟着枪口走。模型每帧都被举枪姿势重摆，所以这里重新算一次，
		# 而不是只在开始时算一次 —— 否则晃动时火焰会飘在枪管旁边。
		var muzzle := muzzle_position()
		_flash_node.position = muzzle
		if _flash_light != null:
			_flash_light.position = muzzle


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


func _mesh_named(n: Node, want: String) -> MeshInstance3D:
	if n is MeshInstance3D and String(n.name) == want:
		return n as MeshInstance3D
	for c in n.get_children():
		var r := _mesh_named(c, want)
		if r != null:
			return r
	return null