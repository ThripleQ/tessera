extends MeshInstance3D

## 准星。画在**手那条射线打到的地方**，不是屏幕中心。
##
## 为什么不做屏幕正中的一个十字：第三人称相机在身后 3.8 米，屏幕中心和手
## 的射线指向的不是同一个点。画在屏幕中心会骗人 —— 玩家对着一个准星，
## 东西却从旁边拿走。准星是射线的显示，不是射线的定义。
##
## 两个状态，颜色区分：
##   亮青 = 那件东西是我的，右键能收（或左键能抓）
##   灰白 = 那是房间/地板，右键什么也不会发生
##
## 为什么值得为这个状态花代码：没有它，玩家要在"为什么这次没反应"上试三次，
## 而这三次里他会以为游戏坏了。反馈不是装饰，是让人敢按键的东西。
##
## 为什么还要一圈黑边：这个世界的配色就是大块的青和橙，而准星经常落在
## 自己的角色身上（第三人称，往脚下瞄）。青环画在青衣服上等于没画 ——
## 这不是理论问题，是截图暴露的：环一直在，只是看不见。

const COLOR_ACTIVE := Color(0.30, 0.95, 1.0, 0.95)
const COLOR_IDLE := Color(0.92, 0.94, 0.98, 0.55)
## 外圈的黑边。它必须**不透明**：半透明的边等于把对比度又还回去了。
const COLOR_RIM := Color(0.04, 0.05, 0.09, 0.85)
## 贴到表面上抬一点点，否则环和面共面会闪（z-fighting）。
const SURFACE_LIFT := 0.02

var hands = null
## 第三人称的落点指示。第一人称下它必须消失 —— 它画在射线落点上，
## 而第一人称的相机就在头里，落点常常只有一两米远，圈会糊满半个屏幕。
## 第一人称的准心是 `crosshair.gd`（画在屏幕上），两者别混。
var player = null

var _mat: StandardMaterial3D
var _rim: MeshInstance3D
var _pulse := 0.0


func _make_torus(inner: float, outer: float) -> TorusMesh:
	var t := TorusMesh.new()
	t.inner_radius = inner
	t.outer_radius = outer
	# 环不能太圆：这是卡通渲染的世界，一个 64 段的完美圆环会显得比周围的东西"更精细"。
	t.rings = 20
	t.ring_segments = 6
	return t


func _ready() -> void:
	# 黑边是子节点：它跟着父节点的 transform 走，不需要第二份位置计算。
	_rim = MeshInstance3D.new()
	_rim.name = "rim"
	# 黑边要**只露在外面一圈**，不能垫在下面当底 ——
	# 两块几乎一样大的环叠起来读作"一个带黑底的白点"，
	# 而玩家需要的是"一个圈指着某处"，不是"一个点"。
	_rim.mesh = _make_torus(0.150, 0.204)
	var rim_mat := StandardMaterial3D.new()
	rim_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	rim_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	rim_mat.no_depth_test = true
	rim_mat.albedo_color = COLOR_RIM
	_rim.material_override = rim_mat
	add_child(_rim)

	mesh = _make_torus(0.108, 0.165)

	_mat = StandardMaterial3D.new()
	# unshaded：准星是 UI，不该被火柴光和色阶影响 —— 暗处的准星消失是最差的。
	_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	# **不测深度。** 这一条不是偷懒：第三人称相机在背后，玩家往脚下瞄的时候，
	# 准星正好落在自己背影后面 —— 一个"被自己挡住的目标指示器"等于没有。
	# 环永远画在它该在的位置（射线第一个撞到的表面上），所以画在最上层是对的：
	# 它和目标之间只可能隔着玩家自己。
	_mat.no_depth_test = true
	_mat.albedo_color = COLOR_IDLE
	material_override = _mat
	visible = false


func _process(delta: float) -> void:
	if hands == null or (player != null and bool(player.is_first_person())):
		visible = false
		return
	var p: Dictionary = hands.place_point()
	if not bool(p.get("ok", false)):
		# 打不到东西时不画。留着上一帧的位置比不画更糟：
		# 那是一个"看起来指着某处、其实什么都没指"的圈。
		visible = false
		return

	visible = true
	var normal: Vector3 = p.get("normal", Vector3.UP)
	var pos: Vector3 = p.get("pos", Vector3.ZERO)
	# 环的轴是 Y，把它转到法线上 —— 贴地时是水平圈，贴墙时是竖直圈。
	global_transform = Transform3D(
		Basis(Quaternion(Vector3.UP, normal)), pos + normal * SURFACE_LIFT)

	# 能收的东西微微呼吸一下。这一下不是为了好看：静止的圈在杂乱场景里
	# 很难被注意到，而"能不能按"是玩家每两秒要判断一次的事。
	var active: bool = hands.can_collect()
	_pulse += delta
	var target := COLOR_ACTIVE if active else COLOR_IDLE
	if active:
		target.a = 0.75 + 0.2 * sin(_pulse * 6.0)
	_mat.albedo_color = _mat.albedo_color.lerp(target, clamp(delta * 14.0, 0.0, 1.0))
