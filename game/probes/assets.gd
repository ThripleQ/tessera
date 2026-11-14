extends SceneTree

## 外观开放探针：一个文件夹里的模型，是不是真的盖掉了引擎内置的几何。
##
## 守的是「换外貌不用改代码」这件事本身，不是某个具体模型：
##   发现  —— 已启用 mod 的 assets/meshes/ 被扫到，覆盖项在契约里，无坏文件
##   执行  —— 覆盖后的三角形数 ≠ 内置规划值；世界里刚体的视觉网格
##            **就是**资源层给出的那个对象（不是另一份内置几何）
##   回退  —— 没被覆盖的网格仍然等于契约里的三角形数
##   边界  —— 拼错文件名会被记成孤儿、非模型文件被忽略、后加载的 mod 优先
##
## 和别的探针一样，这里不认识任何内容 id：被覆盖的网格名、示例资源的内容
## 都从 pack / 资源层的数据里找。示例 mod 改名字、换模型都不会让它假红。

const ASSETS = preload("res://scripts/world/assets.gd")
const MESH_LIB = preload("res://scripts/world/mesh_lib.gd")
const LOADER = preload("res://scripts/mods/loader.gd")

var _main
var _f := 0


func _initialize() -> void:
	_main = load("res://main.tscn").instantiate()
	root.add_child(_main)


func _process(_delta: float) -> bool:
	_f += 1
	if _f < 8:
		return false

	var ok := true
	var declared: Dictionary = _main.pack.schema.get("meshes", {})
	var covered: Dictionary = ASSETS.overrides()
	var problems: Array[String] = ASSETS.problems()

	# ---- 发现 ----------------------------------------------------------
	var found_ok: bool = not covered.is_empty() and problems.is_empty()
	for mid in covered:
		if not declared.has(String(mid)):
			found_ok = false
	print("ASSET 发现：覆盖 %d 种 / 问题 %d 条（%s）"
		% [covered.size(), problems.size(), found_ok])

	# ---- 执行：真的换了几何 ---------------------------------------------
	var chosen := ""
	var traded_ok: bool = not covered.is_empty()
	for mid in covered:
		var id := String(mid)
		if chosen.is_empty():
			chosen = id
		var want := int(declared.get(id, 0))
		var got: int = ASSETS.triangles_of(id)
		var built: int = MESH_LIB.triangles_of(id)
		if got <= 0 or got == want or got == built:
			traded_ok = false
		print("ASSET 换几何：%s 内置 %d tri → 外部 %d tri（契约 %d）（%s）"
			% [id, built, got, want, got > 0 and got != want])
	if chosen.is_empty():
		traded_ok = false

	# 世界里的刚体视觉网格**必须就是**资源层缓存的那一个 ArrayMesh 对象。
	# 用引用相等而不是数三角形：只要有一个调用点漏改回 MESH_LIB.build()，
	# 这里就会是另一份对象，断言立刻红 —— 这正是要防的静默回退。
	var external: ArrayMesh = ASSETS.mesh(chosen)
	var visual_ok := false
	var bodies: Array = _main._world.bodies
	for b in bodies:
		if b == null or not is_instance_valid(b):
			continue
		var v = b.get_node_or_null("visual")
		if v is MeshInstance3D and (v as MeshInstance3D).mesh == external:
			visual_ok = true
			break

	# plan 的负载数字按资源层实测算，不能还抱着契约里那个内置规划值。
	var expect := 0
	var per_mesh: Dictionary = _main.plan.per_mesh()
	for m in per_mesh:
		expect += int(per_mesh[m]) * ASSETS.triangles_of(String(m))
	var plan_tris: int = _main.plan.triangle_count()
	var budget_ok: bool = expect == plan_tris and plan_tris > 0
	print("ASSET 世界：刚体视觉用外部几何 %s / 负载 %d tri（按实测算 %s）"
		% [visual_ok, plan_tris, budget_ok])

	# ---- 回退：没被覆盖的网格照旧 ---------------------------------------
	var fallback_ok := true
	var fallback_n := 0
	for mid in declared:
		var id := String(mid)
		if covered.has(id):
			continue
		fallback_n += 1
		if ASSETS.triangles_of(id) != int(declared[id]):
			fallback_ok = false
	print("ASSET 回退：%d 种未覆盖网格与契约一致（%s）" % [fallback_n, fallback_ok])

	# ---- 边界 -----------------------------------------------------------
	var guard_ok := _guard(declared, chosen)

	ok = found_ok and traded_ok and visual_ok and budget_ok and fallback_ok and guard_ok
	print("ASSET RESULT %s（发现 %s / 换几何 %s / 世界 %s / 回退 %s / 边界 %s）"
		% ["OK" if ok else "FAIL",
			"OK" if found_ok else "FAIL", "OK" if traded_ok else "FAIL",
			"OK" if (visual_ok and budget_ok) else "FAIL",
			"OK" if fallback_ok else "FAIL", "OK" if guard_ok else "FAIL"])
	quit(0 if ok else 1)
	return false


## 边界全用 `scan()` 纯函数 + 一次可恢复的 `configure()`：
## 临时目录落在 build/（gitignore），每次探针覆盖写，不进版本库。
func _guard(declared: Dictionary, chosen: String) -> bool:
	var known: Dictionary = {}
	for mid in declared:
		known[String(mid)] = true

	var base: String = LOADER.content_root() + "/build/probe_assets"
	var dir_a: String = base + "/a"
	var dir_b: String = base + "/b"
	var src := ""
	for mid in ASSETS.overrides():
		src = String((ASSETS.overrides()[mid] as Dictionary).get("path", ""))
		break
	if src.is_empty() or chosen.is_empty():
		return false

	var sample: String = FileAccess.get_file_as_string(src)
	if sample.is_empty():
		return false

	# untyped 数组元素别用 := 接：GDScript 推不出类型，会在加载脚本那一刻
	# Parse Error（编译期完全没提示）。这一步踩过，见 docs/status.md 坑列表。
	var dirs: Array[String] = [dir_a, dir_b]
	for d in dirs:
		var meshes: String = d + "/assets/meshes"
		DirAccess.make_dir_recursive_absolute(meshes)
		_write(meshes + "/" + chosen + ".gltf", sample)
		if d == dir_a:
			# 拼错文件名：会被当成孤儿，而不是静默失效。
			_write(meshes + "/typo_not_a_mesh.gltf", sample)
			# 非模型扩展名：glTF 常带的 .bin / 贴图，安静跳过。
			_write(meshes + "/readme.png", "not a model")

	var scanned: Dictionary = ASSETS.scan(dir_a, "probe_a", known)
	var orphans: Array = scanned["problems"]
	var orphan_ok: bool = orphans.size() == 1 \
		and (scanned["overrides"] as Dictionary).has(chosen) \
		and String(orphans[0]).contains("不在契约里")
	var ignored_ok: bool = not String(orphans[0] if not orphans.is_empty() else "").contains("readme.png")

	# 后加载的 mod 压过先加载的（ADR 0003）。测完立刻恢复真实装配，
	# 免得后面的断言看到的是临时目录。
	ASSETS.configure([{"dir": dir_a, "id": "probe_a"},
		{"dir": dir_b, "id": "probe_b"}], _main.pack)
	var owner1 := String((ASSETS.overrides().get(chosen, {}) as Dictionary).get("mod", ""))
	ASSETS.configure([{"dir": dir_b, "id": "probe_b"},
		{"dir": dir_a, "id": "probe_a"}], _main.pack)
	var owner2 := String((ASSETS.overrides().get(chosen, {}) as Dictionary).get("mod", ""))
	var priority_ok: bool = owner1 == "probe_b" and owner2 == "probe_a"
	ASSETS.configure(_main.mod_units, _main.pack)

	print("ASSET 边界：孤儿被记 %s / 非模型被忽略 %s / 后加载优先 %s→%s（%s）"
		% [orphan_ok, ignored_ok, owner1, owner2,
			orphan_ok and ignored_ok and priority_ok])
	return orphan_ok and ignored_ok and priority_ok


func _write(path: String, text: String) -> void:
	var f: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if f != null:
		f.store_string(text)
		f.close()
