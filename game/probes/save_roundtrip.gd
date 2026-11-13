extends SceneTree

## 存档探针：真的推一个箱子、放下一个固定物、存、再推、读，看世界回不回得去。
##
## 为什么必须真跑：无头自检只走到 Plan 层，不实例化玩家、不跑物理，
## 所以 store.gd 里的坐标编码、刚体重建、handle 作废全都不在它的覆盖范围里。
## 这类代码的错法是"看起来存了，读回来差一点"，只有对比数字能发现。
##
## 两条路各测一遍：动态刚体（存位置+速度）和静态物（只存位置）。
## 只测动态的话，静态那条会一直"看起来能用"，直到有人真的放下一个柱子再关窗口。

const SAVE = preload("res://scripts/save/store.gd")

var _main
var _f := 0
var _target: RigidBody3D = null
var _saved := Vector3.ZERO
var _saved_id := ""
var _static_saved := Vector3.ZERO
var _static_id := ""


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

	if _f == 90:
		_target = _main._world.bodies[0]
		_saved_id = String(_target.get_meta("content_id"))
		print("SAVE 目标 %s 起始 %s" % [_saved_id, _target.global_position])
		_target.apply_central_impulse(Vector3(22, 7, 0))

	if _f == 150:
		_saved = _target.global_position
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
		var back: Vector3 = _main._world.bodies[0].global_position
		var diff := back.distance_to(_saved)
		print("SAVE 读档后 %s（与存档差 %.3f 米）" % [back, diff])
		print("SAVE 刚体数 %d / 静态物 %d"
			% [_main._world.bodies.size(), _main._world.props.size()])
		print("SAVE 玩家位置 %s" % _main._player.global_position)

		# 固定物也要回来。它没有物理身份，所以只能靠 props 的位置判断 ——
		# 而"少了那根柱子"这件事，玩家一眼就看得出来。
		var static_diff := 999.0
		if _main._world.props.size() > 0:
			static_diff = _main._world.props[0].global_position.distance_to(_static_saved)
		print("SAVE 固定物回位差 %.3f 米" % static_diff)

		# 四件事全对才算通过：位置回来了、数量没变、玩家也回来了、固定物也在。
		var count_ok: bool = _main._world.bodies.size() == 14
		var pos_ok := diff < 0.15
		var player_ok: bool = _main._player.global_position.distance_to(Vector3(500, 50, 500)) > 1.0
		var static_ok: bool = _main._world.props.size() == 1 and static_diff < 0.05
		print("RESULT 位置 %s / 数量 %s / 玩家 %s / 固定物 %s"
			% ["OK" if pos_ok else "FAIL", "OK" if count_ok else "FAIL",
				"OK" if player_ok else "FAIL", "OK" if static_ok else "FAIL"])
		var all_ok := pos_ok and count_ok and player_ok and static_ok
		# 通过了就删掉探针自己的存档。失败时留着 —— 那时候它是证据。
		if all_ok:
			DirAccess.remove_absolute(ProjectSettings.globalize_path(SAVE.path()))
		quit(0 if all_ok else 1)

	return false
