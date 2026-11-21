extends Node3D

## 枪口那一下亮：两片加法混合的软光斑 + 一盏只亮几帧的点光。
##
## 单独一个文件，因为它是"开火长什么样"，和"枪怎么举、怎么瞄"无关。
## 第一人称和第三人称将来都能复用它 —— 火焰不该知道枪是从哪个视角看的。
##
## **挂在视图模型下，不是挂在枪的模型节点里。** 模型缩到 0.026 倍，
## 子节点的坐标和尺寸会跟着缩 —— 第一版把火焰做成模型的子节点，
## 结果它只有 2 厘米大，而且位置挪到了枪口以内，在画面里根本找不到。

## 亮多久。0.07 秒 = 四帧 —— 长了就变成"枪嘴里有团火在烧"。
const FLASH_TIME := 0.07

var _light: OmniLight3D = null
var _life := 0.0


func _ready() -> void:
	name = "muzzle_flash"
	visible = false
	set_process(false)
	_add_quad(Vector2(0.085, 0.085), Color(1.0, 0.93, 0.72, 1.0), 0.0)
	_add_quad(Vector2(0.045, 0.045), Color(1.0, 0.78, 0.38, 0.9), 0.6)
	_light = OmniLight3D.new()
	_light.light_color = Color(1.0, 0.80, 0.45)
	_light.light_energy = 1.3
	_light.omni_range = 2.0
	_light.shadow_enabled = false
	_light.visible = false
	add_child(_light)


## 亮一下。位置由调用方给（枪口），每发换个角度和大小 ——
## 同一个贴片连闪十次会被看成"屏幕在抖"。
func flash(at: Vector3) -> void:
	position = at
	rotation.z = randf() * TAU
	scale = Vector3.ONE * randf_range(0.85, 1.25)
	visible = true
	if _light != null:
		_light.light_energy = randf_range(1.0, 1.6)
		_light.visible = true
	_life = FLASH_TIME
	set_process(true)


## 跟着枪口走。晃枪/抬枪时火焰不能留在原地。
func follow(at: Vector3) -> void:
	if visible:
		position = at


## 立刻藏起来（切第三人称、枪收起来时）。
func hide_flash() -> void:
	_life = 0.0
	visible = false
	set_process(false)
	if _light != null:
		_light.visible = false


func _process(delta: float) -> void:
	_life -= delta
	if _life <= 0.0:
		hide_flash()


## 一片软光斑。用程序生成的径向渐变而不是贴图：
## 项目不为一个 3 帧的特效多带一张 png，而且渐变在哪个分辨率下都不糊。
func _add_quad(size: Vector2, tint: Color, spin: float) -> void:
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
	add_child(mi)


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