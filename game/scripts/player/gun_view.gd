extends Node3D

## 第一人称里的那把枪。**它只负责"看起来",不负责"打中"** ——
## 射速、伤害、后坐在 `gun.gd`，摆位和后坐位移在这里。
##
## 为什么分开：视图模型的坐标是相机空间（右下、贴脸、跟着画面抖），
## 而弹道是世界空间（从相机发出、打到墙为止）。混在一个文件里，
## 最典型的 bug 是"用枪模型的位置发射线"，于是子弹从膝盖飞出去。
##
## 模型来自 Quaternius（CC0，见 assets/ASSETS.md）：单网格、无骨骼、无动画。
## 它的原点是**枪托那一端**，长轴沿 +X，所以这里要绕 Y 转 90° 让枪口朝 -Z。

## 模型路径。它不走 `assets.gd` 的资源覆盖：枪是玩家手里的视图模型，
## 不在世界里，也不该被"丢个文件进来换外观"的规则改掉 ——
## 那条规则换的是**世界里的网格**（第 11 步守着它）。
const MODEL_SUBDIR := "assets/weapons/rifle.glb"

## 模型自带 100 倍缩放（骨架和网格都挂在一个放大节点下）。这里再乘 0.18，
## 得到一把 0.52 米长的步枪 —— 数值是量出来的（原始包围盒 2.9 m）。
##
## 为什么比真枪短：视图模型贴着脸，按真实长度摆会占掉半个屏幕。
## 第一人称游戏全都这么缩，玩家不会觉得枪小，只会觉得"我举着它"。
const GUN_SCALE := 0.18
## 静止位置：相机坐标系，右 17 cm、下 12.5 cm、贴脸 2 cm。
## 枪身从原点向 -Z 延伸，枪口落在画面右下偏中。
const REST_POS := Vector3(0.17, -0.125, -0.02)
const REST_ROT := Vector3(0.0, 1.5708, 0.0)

## 开火时的后坐位移（米）与抬头（弧度）。它和相机的后坐是两件事：
## 相机后坐决定"打哪儿"，模型后坐决定"看起来在打"。
const KICK_BACK := 0.055
const KICK_RISE := 0.055
const KICK_RETURN := 11.0

## 枪口火焰存在多久。0.05 秒 = 两三帧 —— 长了就变成"枪嘴里有团火在烧"。
## 它不是一个特效，是一个**证据**：枪口这个位置真的放出了东西。
const FLASH_TIME := 0.05

var _kick := 0.0
var _flash := 0.0
var _flash_node: MeshInstance3D = null


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
	add_child(root)
	scale = Vector3.ONE * GUN_SCALE
	position = REST_POS
	rotation = REST_ROT
	# 枪不该被贴到墙上时穿帮 —— 它的位置永远是相机空间的一个固定点。
	# 近处裁剪会切掉枪托，这正好是我们要的（看不见贴着镜头的部分）。
	root.set_meta("view_model", true)
	_kick = 0.0
	_make_flash()


## 枪口那一小片亮。用 QuadMesh 而不是粒子：这里只需要"闪一下"，
## 粒子系统在这个尺度上只会变成一团糊在镜头上的灰。
##
## **它挂在相机下，不是挂在枪下面。** 枪自身缩到 0.18 倍，子节点的坐标
## 和尺寸会跟着缩 —— 第一版把火焰做成枪的子节点，结果它只有 2 厘米大，
## 而且位置挪到了枪口以内 0.1 米处，在画面里根本找不到。
func _make_flash() -> void:
	var host: Node3D = get_parent() as Node3D
	if host == null:
		return
	_flash_node = MeshInstance3D.new()
	_flash_node.name = "muzzle_flash"
	var quad := QuadMesh.new()
	quad.size = Vector2(0.055, 0.055)
	_flash_node.mesh = quad
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	# 不测深度：枪口那片必须在枪身之前画出来，否则它会被枪管自己挡住，
	# 而画面上看起来像"火焰没触发"（第一版就是这样，找了半天）。
	mat.no_depth_test = true
	mat.albedo_color = Color(1.0, 0.86, 0.45, 0.95)
	_flash_node.material_override = mat
	# 相机空间：枪管末端大约在右下偏中（枪 0.52 米长，起点在 x=0.17/y=-0.125）。
	_flash_node.position = Vector3(0.25, -0.118, -0.52)
	_flash_node.visible = false
	host.add_child(_flash_node)


## 开一枪。只改目标值，真正的位移每帧插值 —— 直接设位置会"啪"地跳，
## 而玩家能看出来的枪感全在那几帧里。
func kick() -> void:
	_kick = 1.0
	_flash = FLASH_TIME
	if _flash_node != null:
		# 每发换个角度和大小：同一个贴片连闪十次会被看成"屏幕在抖"。
		_flash_node.rotation.z = randf() * TAU
		_flash_node.scale = Vector3.ONE * randf_range(0.8, 1.25)
		_flash_node.visible = true


## 只在该看见它的时候看见它。第三人称下这把枪挂在相机上，
## 会变成"画面右下角飘着一把没人的枪" —— 而且它比玩家本人还显眼。
func set_shown(shown: bool) -> void:
	visible = shown
	# 火焰是相机的孩子（不跟着枪缩），所以得单独关 —— 否则第三人称下
	# 枪藏起来了，枪口还悬着一片亮。
	if _flash_node != null and not shown:
		_flash_node.visible = false


func tick(delta: float) -> void:
	if _flash > 0.0:
		_flash -= delta
		if _flash <= 0.0 and _flash_node != null:
			_flash_node.visible = false
	if _kick <= 0.0:
		return
	_kick = maxf(0.0, _kick - delta * KICK_RETURN)
	position = REST_POS + Vector3(0.0, 0.0, KICK_BACK * _kick)
	rotation = REST_ROT + Vector3(-KICK_RISE * _kick, 0.0, 0.0)
