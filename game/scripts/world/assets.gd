extends RefCounted

## 资源覆盖层：把"某个网格长什么样"从引擎手里交给一个文件夹。
##
## 这是三层开放里的第三层（外观开放，ADR 0003 定的路线，0012 落地）。
## 约定优于配置：mod 目录里放 `assets/meshes/<网格 id>.gltf`（或 .glb），
## 那个网格就换成文件里的几何；没放的东西回退到 `mesh_lib.gd` 的程序化几何。
##
## 为什么不引入"资源清单"或新 kind：
##   * 资源包不该声明新 id，它只覆盖已有槽位 —— MC 资源包就是这样。
##     加一种新形状是另一件事（契约 / 编译器），不该混进这一层。
##   * 路径不是内容里写的一个字符串，而是**目录枚举出来的文件名**。
##     于是天然不存在 `../../etc/passwd` 这种逃逸：文件名里没有路径分隔符，
##     data 级 mod 默认放行也不会读到 mod 目录之外的任何东西。
##   * 拼错文件名会被当成"孤儿资源"报出来，而不是静默失效 ——
##     装了却什么都没发生是最难查的一类问题。
##
## 层级：和 mesh_lib 同域。它是"问几何"的统一入口，别的域只认它，
## 不再直接 preload mesh_lib 的 build/triangles_of。

const MESH_LIB = preload("res://scripts/world/mesh_lib.gd")

const ASSET_SUBDIR := "assets/meshes"
const MESH_EXTS: Array[String] = ["gltf", "glb"]

## 静态而不是实例：调用点（plan / chunk / world_root / solids / player / 探针）
## 原来都是 `MESH_LIB.build()` 这样的静态调用，换成 `ASSETS.mesh()` 最小改动，
## 也避免把资源层一路注入到五六个类里。
static var _overrides: Dictionary = {}      # mesh_id -> {path, mod}
static var _loaded: Dictionary = {}          # mesh_id -> ArrayMesh
static var _known: Dictionary = {}           # 契约里合法的 mesh_id
static var _problems: Array[String] = []
static var _configured := false


## 由 main.gd 在 mod 合并之后、排世界之前调用。
## 顺序即优先级：后加载的 mod 覆盖先加载的（ADR 0003）。
static func configure(mod_units: Array, pack) -> void:
	_overrides.clear()
	_loaded.clear()
	_known.clear()
	_problems.clear()
	_configured = true

	for mesh_id in pack.schema.get("meshes", {}):
		_known[String(mesh_id)] = true

	for unit in mod_units:
		if not (unit is Dictionary):
			continue
		var u: Dictionary = unit as Dictionary
		var scanned := scan(String(u.get("dir", "")), String(u.get("id", "?")), _known)
		for mesh_id in scanned["overrides"]:
			_overrides[mesh_id] = scanned["overrides"][mesh_id]
		for p in scanned["problems"]:
			_problems.append(String(p))


## 纯函数，单独给探针测边界用：不碰全局状态。
## 返回 {overrides: {mesh_id: {path, mod}}, problems: [String]}
static func scan(mod_dir: String, mod_id: String, known: Dictionary) -> Dictionary:
	var out: Dictionary = {"overrides": {}, "problems": []}
	if mod_dir.is_empty():
		return out
	var root := mod_dir.trim_suffix("/") + "/" + ASSET_SUBDIR
	if not DirAccess.dir_exists_absolute(root):
		return out

	var d := DirAccess.open(root)
	if d == null:
		out["problems"].append("mod `%s` 的 %s 打不开" % [mod_id, ASSET_SUBDIR])
		return out

	var files := d.get_files()
	files.sort()
	for f in files:
		var name := String(f)
		var ext := name.get_extension().to_lower()
		if not MESH_EXTS.has(ext):
			# glTF 常带外部 .bin / 贴图，它们不是覆盖入口，安静跳过。
			continue
		var mesh_id := name.get_basename()
		if not known.has(mesh_id):
			out["problems"].append(
				"mod `%s` 的资源 `%s` 对应的网格 `%s` 不在契约里（文件名拼错？）"
				% [mod_id, name, mesh_id])
			continue
		out["overrides"][mesh_id] = {"path": root + "/" + name, "mod": mod_id, "file": name}
	return out


## 唯一的"问几何"入口。覆盖优先，失败**不静默回退**：
## 一个装了却没生效的资源包比直接报错更难查，所以坏文件会让 problems 非空，
## 由无头自检和探针判红。
static func mesh(mesh_id: String) -> ArrayMesh:
	if _loaded.has(mesh_id):
		return _loaded[mesh_id]
	if _overrides.has(mesh_id):
		var entry: Dictionary = _overrides[mesh_id]
		var m := _load_gltf(String(entry["path"]), mesh_id, String(entry["mod"]))
		if m == null:
			return null
		_loaded[mesh_id] = m
		return m
	var built := MESH_LIB.build(mesh_id)
	if built != null:
		_loaded[mesh_id] = built
	return built


static func triangles_of(mesh_id: String) -> int:
	var m := mesh(mesh_id)
	if m == null:
		return 0
	var t := 0
	for s in m.get_surface_count():
		var arr := m.surface_get_arrays(s)
		var idx = arr[Mesh.ARRAY_INDEX]
		t += (idx.size() if idx != null else arr[Mesh.ARRAY_VERTEX].size()) / 3
	return t


## 契约声明了但引擎画不出来的网格。委托内置实现：覆盖的 mesh 本来就在契约里。
static func missing(declared: PackedStringArray) -> PackedStringArray:
	return MESH_LIB.missing(declared)


static func implemented() -> PackedStringArray:
	return MESH_LIB.implemented()


static func covered(mesh_id: String) -> bool:
	return _overrides.has(mesh_id)


static func overrides() -> Dictionary:
	return _overrides.duplicate(true)


static func problems() -> Array[String]:
	return _problems.duplicate()


static func configured() -> bool:
	return _configured


static func summary() -> String:
	if _overrides.is_empty():
		return "资源覆盖：无（全部使用引擎内置几何）"
	var ids := _overrides.keys()
	ids.sort()
	var parts: Array[String] = []
	for mesh_id in ids:
		var e: Dictionary = _overrides[mesh_id]
		parts.append("%s ← %s/%s（实测 %d tri）"
			% [mesh_id, e["mod"], e["file"], triangles_of(String(mesh_id))])
	return "资源覆盖 %d 种：%s" % [parts.size(), ", ".join(parts)]


# ---------------------------------------------------------------- glTF 加载

## Godot 内置解析器，纯 CPU，无头下可用（已实测：外部 .gltf → ArrayMesh）。
## 不做导入器、不走 res://：文件就在 mod 目录的磁盘绝对路径上。
static func _load_gltf(path: String, mesh_id: String, mod_id: String) -> ArrayMesh:
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	var err: int = doc.append_from_file(path, state)
	if err != OK:
		_problems.append("mod `%s` 的网格 `%s` 解析失败（%s，err=%d）" % [mod_id, mesh_id, path, err])
		return null

	var root := doc.generate_scene(state)
	if root == null:
		_problems.append("mod `%s` 的网格 `%s` 生成不出场景（%s）" % [mod_id, mesh_id, path])
		return null

	# 节点变换要累积应用：现成资源常把 mesh 挂在带 scale / 旋转的节点下，
	# 只取几何不取变换，模型会大小不对、朝向不对。
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_append_tree(root, Transform3D(), st)

	# generate_scene 造出的节点不在场景树里，必须显式释放。
	# 忘了这一步，退出时会泄漏一堆 RID，被 no_engine_errors 判成引擎报错。
	root.free()

	var out := st.commit()
	if out.get_surface_count() == 0:
		_problems.append("mod `%s` 的网格 `%s` 里没有任何三角形（%s）" % [mod_id, mesh_id, path])
		return null
	return out


static func _append_tree(node: Node, parent_xform: Transform3D, st: SurfaceTool) -> void:
	var xf := parent_xform
	if node is Node3D:
		xf = parent_xform * (node as Node3D).transform
	if node is MeshInstance3D:
		var src: Mesh = (node as MeshInstance3D).mesh
		if src != null:
			for s in src.get_surface_count():
				st.append_from(src, s, xf)
	for child in node.get_children():
		_append_tree(child, xf, st)
