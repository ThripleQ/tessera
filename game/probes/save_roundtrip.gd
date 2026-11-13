extends SceneTree

## 存档探针：真的推一个箱子、存、再推、读，看它回不回到存的那一刻。
##
## 为什么必须真跑：无头自检只走到 Plan 层，不实例化玩家、不跑物理，
## 所以 store.gd 里的坐标编码、刚体重建、handle 作废全都不在它的覆盖范围里。
## 这类代码的错法是"看起来存了，读回来差一点"，只有对比数字能发现。

const SAVE = preload("res://scripts/save/store.gd")

var _main
var _f := 0
var _target: RigidBody3D = null
var _saved := Vector3.ZERO
var _saved_id := ""


func _initialize() -> void:
	_main = load("res://main.tscn").instantiate()
	root.add_child(_main)


func _process(_delta: float) -> bool:
	_f += 1

	if _f == 5:
		print("SAVE 刚体数 %d" % _main._world.bodies.size())

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
		print("SAVE 刚体数 %d" % _main._world.bodies.size())
		print("SAVE 玩家位置 %s" % _main._player.global_position)

		# 三件事全对才算通过：位置回来了、数量没变、玩家也回来了。
		var count_ok: bool = _main._world.bodies.size() == 14
		var pos_ok := diff < 0.15
		var player_ok: bool = _main._player.global_position.distance_to(Vector3(500, 50, 500)) > 1.0
		print("RESULT 位置 %s / 数量 %s / 玩家 %s"
			% ["OK" if pos_ok else "FAIL", "OK" if count_ok else "FAIL",
				"OK" if player_ok else "FAIL"])
		var all_ok := pos_ok and count_ok and player_ok
		# 通过了就删掉探针自己的存档。失败时留着 —— 那时候它是证据。
		if all_ok:
			DirAccess.remove_absolute(ProjectSettings.globalize_path(SAVE.path()))
		quit(0 if all_ok else 1)

	return false
