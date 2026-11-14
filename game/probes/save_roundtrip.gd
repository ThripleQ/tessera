extends SceneTree

## 存档探针：真的推一个箱子、放下一个固定物、存、再推、读，看世界回不回得去。
##
## 为什么必须真跑：无头自检只走到 Plan 层，不实例化玩家、不跑物理，
## 所以 store.gd 里的坐标编码、刚体重建、handle 作废全都不在它的覆盖范围里。
## 这类代码的错法是"看起来存了，读回来差一点"，只有对比数字能发现。
##
## 两条路各测一遍：动态刚体（存位置+速度）和静态物（只存位置）。
## 只测动态的话，静态那条会一直"看起来能用"，直到有人真的放下一个柱子再关窗口。
##
## 背包也要测：它装的东西**不在世界里**，所以世界那份记录永远不会提到它们。
## 不测的话，"关一次窗口捡的东西全没了"会一直存在，而且没人会想到是存档的锅。

const SAVE = preload("res://scripts/save/store.gd")

var _main
var _f := 0
var _target: RigidBody3D = null
var _saved := Vector3.ZERO
var _saved_id := ""
var _static_saved := Vector3.ZERO
var _static_id := ""
var _stack_id := ""
var _stack_n := 0
## 存档那一刻的刚体数。断言用它而不是一个写死的数字 ——
## 内容一变（比如怪物从"钉住的障碍"改成刚体），绝对计数就红了，
## 而那不是存档坏了。真正要验的是"读档前后一样多"。
var _n_saved := 0


## 挑一个**没有生命**的刚体当推箱子的目标。
##
## 为什么不直接用 bodies[0]：现在怪也是刚体了，而系统会让它走、会让它死。
## 拿一只怪当"位置要精确复原"的目标，等于在测存档的同时也测了 AI 的行为 ——
## 那不是这条探针该验的事，失败了也不知道该怪谁。
## 挑选依据是**数据**（有没有 health 组件），不是名字（铁律 2）。
func _pick_target() -> RigidBody3D:
	for rb in _main._world.bodies:
		if not is_instance_valid(rb):
			continue
		var comps: Dictionary = _main.pack.components_of(String(rb.get_meta("content_id", "")))
		if not comps.has("health"):
			return rb
	return _main._world.bodies[0]


func _initialize() -> void:
	_main = load("res://main.tscn").instantiate()
	root.add_child(_main)


## 探针也不能认识内容 id（铁律 2 对探针一样有效）：
## 从可摆放清单里挑第一个"不会动"的，而不是写死一个名字。
## 顺带这也是一条断言 —— 如果一条静态内容都没有，下面的测试就该炸。
func _pick_static() -> String:
	for id in _main.pack.spawnables():
		if not _main.pack.places_as_rigid(id):
			return id
	return ""


func _process(_delta: float) -> bool:
	_f += 1

	if _f == 5:
		print("SAVE 刚体数 %d / 静态物 %d"
			% [_main._world.bodies.size(), _main._world.props.size()])

	if _f == 20:
		# 玩家亲手放下一个固定物，位置离房间中心远一点，方便读档后认出来。
		_static_id = _pick_static()
		var at: Vector3 = _main._player.global_position + Vector3(1.5, 0.0, 1.5)
		var r: Dictionary = _main.api.spawn(_static_id, at, 0.35)
		_static_saved = at
		print("SAVE 放下固定物 %s：%s（静态物 %d）"
			% [_static_id, r.get("ok", false), _main._world.props.size()])

	if _f == 30:
		# 背包里塞一件。这里直接记账而不是走右键收：这一条验的是**存档**，
		# 而"收"那条链路由 spawn_menu 探针负责（它走的是真射线）。
		# 两条链路各自有主，重复测会让失败原因变模糊。
		_main._player.bag().add(_static_id)
		# 可堆叠的东西也要活过一次存读。只测单件的话，"×20 读回来变 ×1"
		# 这种批量丢失会一直藏着 —— 而它的表现是玩家攒了一背包只剩一件。
		_stack_id = ""
		for id in _main.pack.spawnables():
			if _main.pack.stack_limit(id) > 0:
				_stack_id = id
				break
		if not _stack_id.is_empty():
			for i in 3:
				_main._player.bag().add(_stack_id)
			_stack_n = _main._player.bag().count(_stack_id)
		print("SAVE 背包：%s（%d 件）"
			% [_main._player.bag().describe(), _main._player.bag().total()])

	if _f == 90:
		_target = _pick_target()
		_saved_id = String(_target.get_meta("content_id"))
		print("SAVE 目标 %s 起始 %s" % [_saved_id, _target.global_position])
		_target.apply_central_impulse(Vector3(22, 7, 0))

	if _f == 150:
		_saved = _target.global_position
		_n_saved = _main._world.bodies.size()
		print("SAVE 推动后 %s" % _saved)
		_main._save_now(false)
		# 再推一次，制造"存档之后世界又变了"的状态。
		# 不做这一步的话，读档前后本来就一样，测试等于什么都没验。
		_target.apply_central_impulse(Vector3(-38, 12, 0))

	if _f == 205:
		var moved: Vector3 = _main._world.bodies[0].global_position
		print("SAVE 存档之后又推了一把 %s（差 %.2f 米）"
			% [moved, moved.distance_to(_saved)])
		_main._player.set_pose({"pos": Vector3(500, 50, 500), "yaw": 1.2, "pitch": 0.0})
		_main._resume()

	if _f == 212:
		# 回位差不看"第 0 个"，而是**在同类里找离存档位置最近的那个**。
		#
		# 原来直接读 bodies[0]，因为那时候 14 个刚体全是木箱、顺序稳定。
		# 怪变成刚体之后顺序就不是原来那个了 —— 读档后的 bodies[0] 可能是只怪，
		# 于是"位置差 32 米"这个假失败出现过一次，而存档其实是好的。
		# 断言要问的是"东西回没回到它该在的地方"，不是"数组的第一个是谁"。
		var back := 999.0
		var found := 0
		for rb in _main._world.bodies:
			if not is_instance_valid(rb):
				continue
			if String(rb.get_meta("content_id", "")) != _saved_id:
				continue
			found += 1
			back = minf(back, rb.global_position.distance_to(_saved))
		print("SAVE 读档后同类 %d 个，最近回位差 %.3f 米" % [found, back])
		print("SAVE 刚体数 %d / 静态物 %d"
			% [_main._world.bodies.size(), _main._world.props.size()])
		print("SAVE 玩家位置 %s" % _main._player.global_position)

		# 固定物也要回来。它没有物理身份，所以只能靠 props 的位置判断 ——
		# 而"少了那根柱子"这件事，玩家一眼就看得出来。
		var static_diff := 999.0
		if _main._world.props.size() > 0:
			static_diff = _main._world.props[0].global_position.distance_to(_static_saved)
		print("SAVE 固定物回位差 %.3f 米" % static_diff)
		print("SAVE 读档后背包：%s" % _main._player.bag().describe())

		# 五件事全对才算通过：位置回来了、数量没变、玩家也回来了、固定物也在、背包也在。
		# 数量用**存档那一刻**的数字当基准，不用写死的常数 ——
		# 内容一变绝对计数就红，而那不是存档坏了。
		var count_ok: bool = _main._world.bodies.size() == _n_saved
		var pos_ok := back < 0.15
		var player_ok: bool = _main._player.global_position.distance_to(Vector3(500, 50, 500)) > 1.0
		var static_ok: bool = _main._world.props.size() == 1 and static_diff < 0.05
		var bag_ok: bool = _main._player.bag().count(_static_id) == 1
		# 可堆叠的那批必须一件不少地回来（3 件还是 3 件，不是 1 件）。
		var stack_ok: bool = _stack_id.is_empty() \
			or _main._player.bag().count(_stack_id) == _stack_n
		bag_ok = bag_ok and stack_ok
		print("RESULT 位置 %s / 数量 %s / 玩家 %s / 固定物 %s / 背包 %s"
			% ["OK" if pos_ok else "FAIL", "OK" if count_ok else "FAIL",
				"OK" if player_ok else "FAIL", "OK" if static_ok else "FAIL",
				"OK" if bag_ok else "FAIL"])
		var all_ok := pos_ok and count_ok and player_ok and static_ok and bag_ok
		# 通过了就删掉探针自己的存档。失败时留着 —— 那时候它是证据。
		if all_ok:
			DirAccess.remove_absolute(ProjectSettings.globalize_path(SAVE.path()))
		quit(0 if all_ok else 1)

	return false
