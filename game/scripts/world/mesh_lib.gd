extends RefCounted

## 程序化低模几何。
##
## 这是唯一允许"引擎认识具体名字"的地方之一，理由：网格几何本来就是引擎的实现，
## 不是内容。契约说世界有哪几种 mesh（schema.meshes），这里说引擎能画出几种；
## 两者之差由自检报出来，不会静默变成空场景。
##
## 几何全部由 BoxMesh / CylinderMesh 拼成，三角形数与 registry.MESHES 的规划值对齐：
##   humanoid_lowpoly  8 盒 = 96 tri
##   shade_lowpoly     六棱台 24 + 头 12 = 36 tri
##   prop_crate        1 盒 = 12 tri
##   prop_pillar       2 盒 = 24 tri

const IMPLEMENTED: Array[String] = [
	"humanoid_lowpoly",
	"shade_lowpoly",
	"prop_crate",
	"prop_pillar",
]

static var _mesh_cache: Dictionary = {}
static var _shared_material: StandardMaterial3D = null


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
static func material() -> StandardMaterial3D:
	if _shared_material == null:
		_shared_material = StandardMaterial3D.new()
		# MultiMesh 的 instance color 走顶点色通道，不开启这个开关它不会调制 albedo，
		# 整个世界会变成一片白。
		_shared_material.vertex_color_use_as_albedo = true
		_shared_material.roughness = 0.92
		_shared_material.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	return _shared_material


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


static func _cylinder(st: SurfaceTool, r_top: float, r_bottom: float, h: float, at: Vector3) -> void:
	var m := CylinderMesh.new()
	m.top_radius = r_top
	m.bottom_radius = r_bottom
	m.height = h
	m.radial_segments = 6
	m.rings = 1
	st.append_from(m, 0, Transform3D(Basis(), at))
