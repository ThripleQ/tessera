extends SceneTree

## 帧时与成本探针。
##
## **这台机器的墙上帧时不能当基线。** 空场景跑同样的循环也是 6.8 ms ——
## 也就是说"平均 6.90 ms"里几乎全是无头主循环自己的节流，游戏加的活儿被埋在里面。
## 项目之前把那个数字当基线追了好几轮，实际上一直在测环境。
##
## 所以这里分三份报，可靠性从高到低：
##   1. **结构指标**（节点 / 材质 / 绘制项 / 物理活跃物体 / 接触对）
##      和机器无关，可以当回归红线。材质数是 O(配色) 还是 O(物体数)，
##      在真实显卡上就是提交次数的差别。
##   2. **成本对拍**（同一次运行里，把新旧两种写法各跑 200 遍计时）
##      它测的是"我们的代码跑一次要多久"，不受主循环节流影响。
##   3. **墙上帧时**（只做参考，不设断言）
##      数值会被无头循环的地板压住，涨了也不能直接当成退步 —— 但大涨一定有原因。
##
## 预热帧不算：前 30 帧里有场景装配、材质编译、物理稳定。

const WARMUP := 30
const FRAMES := 300
const ASSETS = preload("res://scripts/world/assets.gd")
const CULLING = preload("res://scripts/world/culling.gd")
const HANDS = preload("res://scripts/player/hands.gd")

## 成本对拍跑多少遍。**取多批里的最小值**，不是平均值：
## 这台机器的调度噪声很大（同一段代码平均 0.13 / 0.21 / 0.27 ms 都出现过），
## 而噪声只会让测量**变慢**、不会让代码变快 —— 所以最小值最接近真实成本。
## 这是所有微基准的通用做法，不是这里的特殊技巧。
const COST_RUNS := 120
const COST_BATCHES := 5

var _f := 0
var _last_usec := 0
var _samples: Array[float] = []
## 引擎自己的两个计时器。总帧时只说明"慢"，这两个才说明"谁慢"。
var _proc_samples: Array[float] = []
var _phys_samples: Array[float] = []
var _main


func _initialize() -> void:
	_main = load("res://main.tscn").instantiate()
	root.add_child(_main)


func _process(_delta: float) -> bool:
	_f += 1
	# 压力填充放在第一帧，不放在 _initialize：那时 _main 刚入树，
	# `_ready` 还没跑完，世界和 api 都还是空的 —— 会静默什么都不做。
	# 这也正是它第一版没生效的原因（打印都没出现，因为提前 return 了）。
	if _f == 1 and "--stress" in OS.get_cmdline_user_args():
		_stress_fill()
	var now := Time.get_ticks_usec()
	if _last_usec > 0 and _f > WARMUP:
		_samples.append(float(now - _last_usec) / 1000.0)
		_proc_samples.append(
			float(Performance.get_monitor(Performance.TIME_PROCESS)) * 1000.0)
		_phys_samples.append(
			float(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS)) * 1000.0)
	_last_usec = now

	if _f >= WARMUP + FRAMES:
		_report()
		quit(0)
	return false


static func _avg(a: Array[float]) -> float:
	if a.is_empty():
		return 0.0
	var t := 0.0
	for v in a:
		t += v
	return t / float(a.size())


## 把世界填到**预算上限**再测。
##
## 预算上限（96 件）不是随便定的数字：它是玩家和 mod 能造多少东西的硬顶，
## 所以"最坏情况"是可枚举的 —— 可以现在测出来，而不是等玩家撞上。
## 只在 `--stress` 下跑，默认验收的负载必须和玩家平时看到的一致。
##
## 摆在离地很近的位置，让它们一开始就几乎静止：压力测的是"东西多"，
## 不是"一起从天上掉下来"那种一次性的物理爆发。
func _stress_fill() -> void:
	var pack = _main.pack
	var api = _main.api
	var world = _main._world
	if pack == null or api == null or world == null:
		push_error("压力模式：世界还没装配好")
		return
	var pick := ""
	for id in pack.spawnables():
		if pack.places_as_rigid(String(id)):
			pick = String(id)
			break
	if pick.is_empty():
		push_error("压力模式：内容里没有任何刚体可造")
		return
	var b: AABB = world.start_bounds()
	var made := 0
	var guard := 0
	while api.budget_left() > 0 and guard < 400:
		guard += 1
		var x: float = b.position.x + 1.0 + float(guard % 8) * 1.2
		var z: float = b.position.z + 1.0 + float(guard / 8) * 1.2
		var r: Dictionary = api.spawn(pick, Vector3(x, 0.45, z), 0.0)
		if bool(r.get("ok", false)):
			made += 1
	print("PERF 压力模式：额外造了 %d 件 %s（预算已用 %d / 刚体 %d）"
		% [made, pick, api.budget_used(), world.bodies.size()])


## 材质去重。**同一份材质被两件东西共用**，显卡那边就是一次状态切换；
## 每件各一份则是 N 次。无头模式下这个数字不影响帧时，但它决定真实显卡上
## 的提交次数 —— 所以必须单独报出来。
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
			var m = mi.material_override if mi.material_override != null else mi.material
			if m != null:
				uses += 1
				seen[m.get_instance_id()] = true
		elif n is MultiMeshInstance3D:
			var mm := n as MultiMeshInstance3D
			if mm.material_override != null:
				uses += 1
				seen[mm.material_override.get_instance_id()] = true
	return {"uses": uses, "unique": seen.size()}


## 剔除的两种写法，同机对拍。
##
##   old —— 逐件调 `should_draw()`，每件内部都会重建一次视锥
##   new —— 一帧建一次快照，逐件复用
##
## 差异只来自"视锥建了几遍"，所以这个数字就是那次改动的净收益。
## 它每帧都要跑一次，是"东西变多时最先变贵"的那类代码。
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
	var n := boxes.size()
	if n == 0 or cam == null:
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
	return {"old": old_ms, "new": new_ms, "items": n}


## 系统步进成本：locomotion + vitals + 全部 mod 系统，跑一拍要多久。
## 这是"内容变多时最先爆"的一项 —— 它按刚体数线性增长。
func _cost_systems() -> float:
	var runner = _main._systems
	if runner == null:
		return 0.0
	var best := INF
	for batch in COST_BATCHES:
		var t0 := Time.get_ticks_usec()
		for i in COST_RUNS:
			runner.step(1.0 / 60.0)
		best = minf(best, float(Time.get_ticks_usec() - t0) / 1000.0 / float(COST_RUNS))
	return best


func _report() -> void:
	if _samples.is_empty():
		print("PERF 没采到样本 —— 探针本身坏了，这个数字不能信")
		return

	# 计数先快照：下面的成本对拍会反复调这些路径，会把计数器刷成假数字。
	var frustum_built: int = CULLING.frustum_builds
	var rays_cast: int = HANDS.ray_builds
	var frames_run: int = maxi(1, Engine.get_process_frames())

	_samples.sort()
	var total := 0.0
	for s in _samples:
		total += s
	var avg := total / float(_samples.size())
	var p95: float = _samples[int(float(_samples.size()) * 0.95)]
	var worst: float = _samples[_samples.size() - 1]

	var world = _main._world
	var api = _main.api
	var pack = _main.pack
	var instances := 0
	var tris := 0
	var batches := 0
	for room_id in world.chunks:
		var chunk = world.chunks[room_id]
		instances += chunk.instance_count()
		tris += chunk.triangle_count()
		batches += chunk.batch_count()
	for rb in world.bodies:
		if not is_instance_valid(rb):
			continue
		instances += 1
		var cid := String(rb.get_meta("content_id", ""))
		var mesh_id := String(pack.entities.get(cid, {}).get("components", {})
			.get("model", {}).get("mesh", ""))
		if mesh_id != "":
			tris += ASSETS.triangles_of(mesh_id)

	var mats: Dictionary = _material_stats(root)
	var cull: Dictionary = _cost_culling()
	var sys_ms: float = _cost_systems()

	print("PERF 负载：实例 %d / 三角形 %d / 静态提交 %d / 刚体 %d / 静态物 %d / 预算已用 %d"
		% [instances, tris, batches, world.bodies.size(), world.props.size(),
			api.budget_used()])
	print("PERF 结构：节点 %d / 孤儿节点 %d / 材质 %d 份（被引用 %d 次）/ 物理活跃物体 %d / 接触对 %d"
		% [int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
			int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)),
			int(mats["unique"]), int(mats["uses"]),
			int(Performance.get_monitor(Performance.PHYSICS_3D_ACTIVE_OBJECTS)),
			int(Performance.get_monitor(Performance.PHYSICS_3D_COLLISION_PAIRS))])
	print("PERF 每帧：视锥构建 %.2f 次 / 视线射线 %.2f 次（视锥该是 1.00；射线 2~3 次属正常）"
		% [float(frustum_built) / float(frames_run),
			float(rays_cast) / float(frames_run)])
	print("PERF 成本：剔除 %d 件 旧写法 %.3f ms → 新写法 %.3f ms（省 %.0f%%）"
		% [int(cull["items"]), float(cull["old"]), float(cull["new"]),
			(100.0 * (1.0 - float(cull["new"]) / maxf(0.0001, float(cull["old"]))))])
	print("PERF 成本：系统步进一拍 %.3f ms（%d 个刚体，locomotion + vitals + mod 系统）"
		% [sys_ms, world.bodies.size()])
	print("PERF 帧时 %d 帧：平均 %.2f ms / p95 %.2f / 最差 %.2f（拆账 process %.2f / physics %.2f）"
		% [_samples.size(), avg, p95, worst, _avg(_proc_samples), _avg(_phys_samples)])
	if DisplayServer.get_name() == "headless":
		print("PERF 说明：**无头**主循环本身有 ~6.8 ms 地板（空场景实测），"
			+ "所以帧时只做参考；结构指标与成本对拍才是可比的。")
	else:
		print("PERF 说明：带显示跑的，含渲染；软件光栅下绝对值不代表真实显卡，只和同机历史比")
