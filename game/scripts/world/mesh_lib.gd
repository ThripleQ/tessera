extends RefCounted

## 程序化低模几何。
##
## 这是唯一允许"引擎认识具体名字"的地方之一，理由：网格几何本来就是引擎的实现，
## 不是内容。契约说世界有哪几种 mesh（schema.meshes），这里说引擎能画出几种；
## 两者之差由自检报出来，不会静默变成空场景。
##
## 几何全部由 BoxMesh / CylinderMesh 拼成，三角形数与 registry.MESHES 的规划值对齐。
##   humanoid_lowpoly  8 盒 = 96 tri
##   shade_lowpoly     六棱台 + 头盒 = 48 tri
##   prop_crate        1 盒 = 12 tri
##   prop_pillar       2 盒 = 24 tri
##   prop_gem          2 个四棱锥（cylinder 4 段）= 40 tri
##   prop_blade        3 盒 = 36 tri
##
## 网格是引擎的实现细节，所以这里允许出现具体名字（见铁律 2 的例外条款）。

const TOON_SHADER = preload("res://scripts/render/toon.gdshader")
const OUTLINE_SHADER = preload("res://scripts/render/outline.gdshader")

const IMPLEMENTED: Array[String] = [
	"humanoid_lowpoly",
	"shade_lowpoly",
	"prop_crate",
	"prop_pillar",
	"prop_gem",
	"prop_blade",
	"player_lowpoly",
]

static var _mesh_cache: Dictionary = {}
static var _shared_material: ShaderMaterial = null


static func implemented() -> PackedStringArray:
	return PackedStringArray(IMPLEMENTED)


## 契约声明了、但引擎画不出来的网格。空 = 全覆盖。
static func missing(declared: PackedStringArray) -> PackedStringArray:
	var out: Array[String] = []
	for m in declared:
		if not IMPLEMENTED.has(m):
			out.append(m)
	return PackedStringArray(out)


## 所有实例共用一份材质。颜色靠 MultiMesh 的 instance color，不靠材质数量。
##
## 描边走 next_pass：同一次提交的几何会被再画一遍背面，所以每批多一次提交。
## 这是卡通渲染的固定成本，不是可以优化掉的东西。
static func material() -> ShaderMaterial:
	if _shared_material == null:
		_shared_material = ShaderMaterial.new()
		_shared_material.shader = TOON_SHADER
		var ol := ShaderMaterial.new()
		ol.shader = OUTLINE_SHADER
		_shared_material.next_pass = ol
	return _shared_material


## 单独一份卡通材质，按 (配色, 描边) **共用**。
##
## 以前这里是"每次都 new 一份"：一个刚体一份，一件静态物一份。23 个东西
## 就是 23 份 ShaderMaterial —— 而它们的差别只有一个颜色参数。
## 显卡那边每换一份材质就是一次状态切换，材质数直接决定提交的代价。
##
## 共用带来的唯一风险是**改色会波及同色的其它实例**，所以就地改色必须先走
## `unshare()`（`api.tint` 已经这么做了）。这不是防御性代码：一个 mod 给
## 自己的箱子染色，结果把所有木箱都染了，是最难被解释成"特性"的那种 bug。
##
## outline <= 0 时连描边 pass 都不挂 —— 地板这种大面积平面加描边只会脏。
static var _color_mats: Dictionary = {}
static var _shared_ids: Dictionary = {}


static func toon_material_for(color: Color, outline: float = 0.014) -> ShaderMaterial:
	var key := "%d|%.4f" % [color.to_rgba32(), outline]
	var hit = _color_mats.get(key, null)
	if hit != null:
		return hit
	var m := ShaderMaterial.new()
	m.shader = TOON_SHADER
	m.set_shader_parameter("base_color", color)
	if outline > 0.0:
		var ol := ShaderMaterial.new()
		ol.shader = OUTLINE_SHADER
		ol.set_shader_parameter("width", outline)
		m.next_pass = ol
	_color_mats[key] = m
	_shared_ids[m.get_instance_id()] = true
	return m


## 要就地改这份材质之前先调它：共享的那份会被复制成私有的一份，其余照旧共用。
##
## 不复制就会变成"改一个，改一片"。复制是有代价的（这份材质不再和同色的东西
## 共用状态），但只有真的被染色的那几件付这个代价 —— 而绝大多数东西一辈子不染色。
static func unshare(mat: ShaderMaterial) -> ShaderMaterial:
	if mat == null:
		return null
	if not _shared_ids.has(mat.get_instance_id()):
		return mat
	var copy := mat.duplicate() as ShaderMaterial
	_shared_ids.erase(mat.get_instance_id())
	return copy


## 共享材质有几种。探针用它设回归红线：配色是有限的，材质数就该跟着配色走，
## 而不是跟着物体数量走。
static func shared_material_count() -> int:
	return _color_mats.size()


static func build(mesh_id: String) -> ArrayMesh:
	if _mesh_cache.has(mesh_id):
		return _mesh_cache[mesh_id]

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	match mesh_id:
		"humanoid_lowpoly":
			# 8 个盒子：躯干 / 头 / 双臂 / 双腿 / 胸甲 / 护肩。原点在脚底。
			_box(st, Vector3(0.50, 0.70, 0.30), Vector3(0.00, 1.00, 0.00))
			_box(st, Vector3(0.28, 0.28, 0.28), Vector3(0.00, 1.52, 0.00))
			_box(st, Vector3(0.16, 0.60, 0.16), Vector3(-0.34, 1.02, 0.00))
			_box(st, Vector3(0.16, 0.60, 0.16), Vector3(0.34, 1.02, 0.00))
			_box(st, Vector3(0.18, 0.70, 0.18), Vector3(-0.13, 0.35, 0.00))
			_box(st, Vector3(0.18, 0.70, 0.18), Vector3(0.13, 0.35, 0.00))
			_box(st, Vector3(0.42, 0.34, 0.06), Vector3(0.00, 1.12, -0.17))
			_box(st, Vector3(0.72, 0.12, 0.30), Vector3(0.00, 1.38, 0.00))
		"shade_lowpoly":
			# 六棱台袍子 + 一个头盒。袍子底边必须贴地（y=0），
			# 否则远处看会像悬空的漏斗。头要够大，不然整只像一顶帽子。
			_cylinder(st, 0.32, 0.52, 1.28, Vector3(0.00, 0.64, 0.00))
			_box(st, Vector3(0.34, 0.34, 0.34), Vector3(0.00, 1.44, 0.00))
		"prop_crate":
			_box(st, Vector3(0.80, 0.80, 0.80), Vector3(0.00, 0.40, 0.00))
		"prop_pillar":
			_box(st, Vector3(0.50, 2.20, 0.50), Vector3(0.00, 1.10, 0.00))
			_box(st, Vector3(0.70, 0.16, 0.70), Vector3(0.00, 2.28, 0.00))
		"prop_gem":
			# 两个四棱锥对扣的钻石。骨符是"捡起来的小东西"，
			# 用箱子的形状会让人以为它能坐。宝石要一眼是宝石。
			_cylinder(st, 0.0, 0.21, 0.26, Vector3(0.00, 0.31, 0.00), 4)   # 上半：尖朝上
			_cylinder(st, 0.21, 0.0, 0.18, Vector3(0.00, 0.09, 0.00), 4)   # 下半：尖朝下
		"prop_blade":
			# 一把躺在地上的剑：剑身 + 护手 + 剑柄。原点在底面中心，
			# 躺倒的姿态不用旋转就成立 —— 摆出来的东西本来就该躺在地上，
			# 立着的剑只会被撞倒，然后所有人花时间想"它为什么立着"。
			_box(st, Vector3(0.075, 0.045, 0.82), Vector3(0.00, 0.045, -0.17))  # 剑身
			_box(st, Vector3(0.24, 0.05, 0.07), Vector3(0.00, 0.045, 0.28))     # 护手
			_box(st, Vector3(0.065, 0.055, 0.24), Vector3(0.00, 0.045, 0.44))   # 剑柄
		"player_lowpoly":
			# 主角。全身 1.72 米、约 6.5 头身 —— 这个比例是"动漫感"的第一来源，
			# 比多边形数重要得多：4 头身不管怎么打光都像玩具，6.5 头身哪怕全是色块
			# 也一眼是动漫角色。
			# 原点在脚底，**朝 -Z**（Godot 里相机和角色的前向都是 -Z，反过来会让
			# 第三人称相机永远对着脸）。
			_sphere(st, 0.135, Vector3(0.0, 1.585, 0.0), 0.96)                # 头
			_box(st, Vector3(0.245, 0.075, 0.275), Vector3(0.0, 1.700, -0.005))  # 头顶发
			_box(st, Vector3(0.235, 0.040, 0.05), Vector3(0.0, 1.662, -0.126))   # 刘海
			_box(st, Vector3(0.215, 0.30, 0.085), Vector3(0.0, 1.500, 0.100))    # 脑后长发
			_box(st, Vector3(0.045, 0.26, 0.05), Vector3(-0.128, 1.465, -0.020)) # 左鬓
			_box(st, Vector3(0.045, 0.26, 0.05), Vector3(0.128, 1.465, -0.020))  # 右鬓
			_cylinder(st, 0.055, 0.060, 0.09, Vector3(0.0, 1.445, 0.0), 8)    # 颈
			_cylinder(st, 0.150, 0.115, 0.32, Vector3(0.0, 1.260, 0.0), 8)    # 胸
			_box(st, Vector3(0.075, 0.10, 0.26), Vector3(-0.163, 1.395, 0.0)) # 左肩
			_box(st, Vector3(0.075, 0.10, 0.26), Vector3(0.163, 1.395, 0.0))  # 右肩
			_cylinder(st, 0.105, 0.100, 0.14, Vector3(0.0, 1.030, 0.0), 8)    # 腰
			_cylinder(st, 0.110, 0.235, 0.19, Vector3(0.0, 0.865, 0.0), 8)    # 裙摆
			for side in [-1.0, 1.0]:
				var x: float = side * 0.078
				_cylinder(st, 0.072, 0.062, 0.36, Vector3(x, 0.600, 0.0), 6)  # 大腿
				_cylinder(st, 0.058, 0.050, 0.40, Vector3(x, 0.210, 0.0), 6)  # 小腿
				_box(st, Vector3(0.10, 0.07, 0.20), Vector3(x, 0.035, -0.030)) # 脚
				var ax: float = side * 0.212
				_cylinder(st, 0.055, 0.050, 0.28, Vector3(ax, 1.280, 0.0), 6) # 上臂
				_cylinder(st, 0.048, 0.044, 0.28, Vector3(ax, 1.020, 0.0), 6) # 前臂
				_box(st, Vector3(0.075, 0.09, 0.08), Vector3(ax, 0.855, 0.0)) # 手
		_:
			push_error("网格 `%s` 在契约里存在，但引擎没有实现几何" % mesh_id)
			return null

	var mesh := st.commit()
	_mesh_cache[mesh_id] = mesh
	return mesh


static func triangles_of(mesh_id: String) -> int:
	var m := build(mesh_id)
	if m == null:
		return 0
	var total := 0
	for s in m.get_surface_count():
		var arrays := m.surface_get_arrays(s)
		var idx = arrays[Mesh.ARRAY_INDEX]
		total += (idx.size() if idx != null else arrays[Mesh.ARRAY_VERTEX].size()) / 3
	return total


static func _box(st: SurfaceTool, size: Vector3, at: Vector3) -> void:
	var m := BoxMesh.new()
	m.size = size
	st.append_from(m, 0, Transform3D(Basis(), at))


static func _cylinder(st: SurfaceTool, r_top: float, r_bottom: float, h: float,
		at: Vector3, segments: int = 6) -> void:
	var m := CylinderMesh.new()
	m.top_radius = r_top
	m.bottom_radius = r_bottom
	m.height = h
	m.radial_segments = segments
	m.rings = 1
	st.append_from(m, 0, Transform3D(Basis(), at))


## 低段数球体。8×4 段约 64 三角形，比同尺寸的盒子贵，但头必须是圆的 ——
## 方脑袋会立刻把 6.5 头身拉回"积木人"。
static func _sphere(st: SurfaceTool, r: float, at: Vector3, squash: float = 1.0) -> void:
	var m := SphereMesh.new()
	m.radius = r
	m.height = r * 2.0 * squash
	m.radial_segments = 8
	m.rings = 4
	st.append_from(m, 0, Transform3D(Basis(), at))
