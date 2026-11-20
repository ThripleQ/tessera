extends SceneTree

## 性能预算探针：守的是**结构**，不是毫秒。
##
## 为什么不能守毫秒：这台机器没有 GPU，无头主循环自己就有 ~6.8 ms 的地板
## （空场景实测），墙上帧时测不出 1 ms 级的差别。项目之前把那个数字当基线
## 追了好几轮，实际上一直在测环境。
##
## 能守的是和机器无关的东西 —— 它们才是真实显卡上贵不贵的原因：
##   共享  同一种配色的东西必须共用同一份材质（不是每件一份）
##   隔离  染色必须只影响自己（共用材质最容易踩的坑，也是唯一的副作用）
##   视锥  一帧只建一次（逐件重建 = 每帧几十次分配）
##   材质  O(配色) 而不是 O(物体数)：数量必须远小于被引用次数
##   剔除  新旧写法同机对拍，新的必须更快
##   孤儿  退出前不该有游离节点
##
## 这些一旦退步，帧时间会在真实显卡上悄悄涨，而所有功能验收照样是绿的。

const CULLING = preload("res://scripts/world/culling.gd")

const COST_RUNS := 80
const COST_BATCHES := 3

var _main
var _f := 0
var _pair: Array[RigidBody3D] = []
var _shared_before: bool = false
var _isolated: bool = false
## 拿来"再造几件"用的内容 id。取世界上已有的刚体，所以不认识任何具体名字。
var _spawn_id := ""


func _initialize() -> void:
	_main = load("res://main.tscn").instantiate()
	root.add_child(_main)


func _process(_delta: float) -> bool:
	_f += 1
	if _f == 6:
		_setup_tint()
	if _f == 10:
		_restore_tint()
	if _f == 14:
		_report()
		quit(0)
	return false


## 找两个**同内容**的刚体：它们配色相同，所以按设计必须共用一份材质。
## 不认识任何具体 id —— 从世界里的刚体里挑，内容换了也照样能跑。
func _setup_tint() -> void:
	var by_id: Dictionary = {}
	for rb in _main._world.bodies:
		if rb == null or not is_instance_valid(rb):
			continue
		var cid := String(rb.get_meta("content_id", ""))
		if cid.is_empty() or int(rb.get_meta("handle", 0)) <= 0:
			continue
		if by_id.has(cid):
			_pair = [by_id[cid], rb]
			break
		by_id[cid] = rb
	if _pair.size() != 2:
		return
	_spawn_id = String(_pair[0].get_meta("content_id", ""))
	var a: MeshInstance3D = (_pair[0] as RigidBody3D).get_node_or_null("visual")
	var b: MeshInstance3D = (_pair[1] as RigidBody3D).get_node_or_null("visual")
	if a == null or b == null:
		return
	_shared_before = a.material_override != null and a.material_override == b.material_override

	# **先把 B 的材质与颜色记下来**，再去染 A。顺序反了的话，"B 有没有变"
	# 就成了拿改完之后的值和改完之后的值比 —— 永远相等，永远绿。
	var b_mat_before = b.material_override
	var b_color_before := _color_of(b)
	var want := Color(1.0, 0.2, 0.2)

	_main.api.tint(int(_pair[0].get_meta("handle", 0)), want)

	var a2: MeshInstance3D = (_pair[0] as RigidBody3D).get_node("visual")
	var b2: MeshInstance3D = (_pair[1] as RigidBody3D).get_node("visual")
	var a_mat = a2.material_override
	var b_mat = b2.material_override
	# 隔离成立 = A 拿到了自己的材质且真的变色；B 的材质对象和颜色一样没动。
	_isolated = a_mat != b_mat \
		and _color_of(a2).is_equal_approx(want) \
		and b_mat == b_mat_before \
		and _color_of(b2).is_equal_approx(b_color_before)


func _restore_tint() -> void:
	if _pair.size() == 2:
		_main.api.reset_tint(int(_pair[0].get_meta("handle", 0)))


static func _color_of(mi: MeshInstance3D) -> Color:
	if mi == null or not (mi.material_override is ShaderMaterial):
		return Color(-1, -1, -1)
	var c = (mi.material_override as ShaderMaterial).get_shader_parameter("base_color")
	return c if c is Color else Color(-1, -1, -1)


## 剔除的两种写法，同机对拍。差异只来自"视锥建了几遍"。
func _cost_culling() -> Dictionary:
	var world = _main._world
	var cam: Camera3D = _main._player.camera()
	var boxes: Array[AABB] = []
	for room_id in world.chunks:
		boxes.append((world.chunks[room_id] as Node3D).get("bounds"))
	for p in world.props:
		if is_instance_valid(p):
			boxes.append(CULLING.ball(p.global_position, 1.5))
	for rb in world.bodies:
		if is_instance_valid(rb):
			boxes.append(CULLING.ball(rb.global_position, 1.5))
	if boxes.is_empty() or cam == null:
		return {"old": 0.0, "new": 0.0, "items": 0}
	var old_ms := INF
	var new_ms := INF
	for batch in COST_BATCHES:
		var t0 := Time.get_ticks_usec()
		for i in COST_RUNS:
			for b in boxes:
				CULLING.should_draw(cam, b)
		old_ms = minf(old_ms, float(Time.get_ticks_usec() - t0) / 1000.0 / float(COST_RUNS))
		t0 = Time.get_ticks_usec()
		for i in COST_RUNS:
			var snap: Dictionary = CULLING.snapshot(cam)
			for b in boxes:
				CULLING.should_draw_in(snap, b)
		new_ms = minf(new_ms, float(Time.get_ticks_usec() - t0) / 1000.0 / float(COST_RUNS))
	return {"old": old_ms, "new": new_ms, "items": boxes.size()}


func _report() -> void:
	var ok := true

	# ---- 共享：同内容的两件必须共用同一份材质 -------------------------
	var share_ok: bool = _shared_before
	print("BUDGET 共享：同内容刚体共用一份材质（%s）" % share_ok)
	ok = ok and share_ok

	# ---- 隔离：染色只改自己 -------------------------------------------
	print("BUDGET 隔离：染色只影响自己（%s）" % _isolated)
	ok = ok and _isolated

	# ---- 视锥：一帧最多建一次 ------------------------------------------
	var builds: int = CULLING.frustum_builds
	var frames: int = maxi(1, Engine.get_process_frames())
	var frustum_ok: bool = builds > 0 and builds <= frames
	print("BUDGET 视锥：%d 次构建 / %d 帧（每帧最多一次：%s）"
		% [builds, frames, frustum_ok])
	ok = ok and frustum_ok

	# ---- 材质：**不随物体数量增长** -------------------------------------
	#
	# 不写"材质数 ≤ 某个数"：内容多加一种配色就该多一份材质，那是正常的，
	# 写死的阈值会在内容长大时变成假红灯（这个项目已经吃过一次教训）。
	# 真正要守的是"每件物体各造一份"这个退化 —— 那就直接去测它：
	# 再造几件同样的东西，材质份数**必须一份都不涨**。
	var stats_before: Dictionary = _material_stats(root)
	var added := 0
	if not _spawn_id.is_empty():
		var at: Vector3 = _main._player.global_position + Vector3(1.5, 0.6, -1.5)
		for i in 6:
			var r: Dictionary = _main.api.spawn(_spawn_id, at + Vector3(0, 0, 0.9 * i), 0.0)
			if bool(r.get("ok", false)):
				added += 1
	var stats_after: Dictionary = _material_stats(root)
	var mat_ok: bool = added > 0 \
		and int(stats_after["unique"]) == int(stats_before["unique"]) \
		and int(stats_before["uses"]) > int(stats_before["unique"])
	print("BUDGET 材质：%d 份 / 引用 %d 次；再造 %d 件后仍是 %d 份（不随物体增长：%s）"
		% [int(stats_before["unique"]), int(stats_before["uses"]), added,
			int(stats_after["unique"]), mat_ok])
	ok = ok and mat_ok

	# ---- 剔除：新写法必须比旧写法快 ------------------------------------
	var cull: Dictionary = _cost_culling()
	var cull_ok: bool = float(cull["new"]) < float(cull["old"])
	print("BUDGET 剔除：%d 件 旧 %.3f ms → 新 %.3f ms（新更快：%s）"
		% [int(cull["items"]), float(cull["old"]), float(cull["new"]), cull_ok])
	ok = ok and cull_ok

	# ---- 孤儿：退出前不该有游离节点 ------------------------------------
	var orphans: int = int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT))
	var orphan_ok: bool = orphans == 0
	print("BUDGET 孤儿节点：%d（必须为 0：%s）" % [orphans, orphan_ok])
	ok = ok and orphan_ok

	print("BUDGET RESULT %s（共享 %s / 隔离 %s / 视锥 %s / 材质 %s / 剔除 %s / 孤儿 %s）"
		% ["OK" if ok else "FAIL", share_ok, _isolated, frustum_ok, mat_ok, cull_ok, orphan_ok])


static func _material_stats(node_root: Node) -> Dictionary:
	var seen: Dictionary = {}
	var uses := 0
	var stack: Array[Node] = [node_root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c in n.get_children():
			stack.append(c)
		if n is MeshInstance3D:
			var mi := n as MeshInstance3D
			# 三层都要看：material_override 是整节点覆盖，surface_override 是逐面覆盖，
			# diff 自带的材质在 mesh 里。原来只写了 `mi.material` —— 那个属性根本不存在，
			# 之前没炸是因为全世界都有 material_override，三元短路掉了右半边。
			var m: Material = mi.material_override
			if m == null:
				m = mi.get_surface_override_material(0)
			if m == null and mi.mesh != null:
				m = mi.mesh.surface_get_material(0)
			if m != null:
				uses += 1
				seen[m.get_instance_id()] = true
		elif n is MultiMeshInstance3D:
			var mm := n as MultiMeshInstance3D
			if mm.material_override != null:
				uses += 1
				seen[mm.material_override.get_instance_id()] = true
	return {"uses": uses, "unique": seen.size()}
