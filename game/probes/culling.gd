extends SceneTree

## 剔除探针：确认"这一帧画谁"的判定真的在判，而且判得对。
##
## 为什么值得单独一个探针：剔除坏起来不报错。该剔的没剔，验收照样全绿，
## 只是帧时慢慢涨；把看得见的剔掉了，也没有任何一行日志会提 ——
## 玩家只看到世界在闪。两种都得靠断言抓。
##
## 四条断言各错各的：
##   记账 —— 每件东西都被判过一次，没有谁被漏掉（漏掉 = 永远在画）
##   远处 —— 超出视距就不画。这条走的是**距离**那条路
##   侧面 —— 在视距内、但在视野锥体外。这条走的是**视锥**那条路
##            只测远处的话，视锥写坏也发现不了（因为距离先把它拦了）
##   前方 —— 视野正中必须在画。这条守"剔得太狠"
##   对拍 —— 拿 Godot 自己的 `is_position_in_frustum` 当标准答案，
##            和我施加的 visible 比。culling.gd 里那两个符号写反过两次，
##            两次都不报错，只能靠这条当场红
##
## 时序上故意**分帧**：调视角和造东西都要等一帧才生效（同帧读到的是旧状态）。
## 这个坑在生成菜单探针上踩过一次，这里直接按"改一帧、读一帧"排。

## 离玩家多远算"看不见"。比 VISIBLE_RANGE 远得多，谁也不会争。
const FAR := 400.0
## 横向偏移。60 米侧向 + 12 米前方，夹角约 79°，远超 70° 视野的半角。
const SIDE := 60.0
## 视野正中的检验距离。远超免剔区（6m），近到不可能跑出视野。
const MID := 12.0

var _main
var _f := 0
var _far_node: Node3D = null
var _side_node: Node3D = null
var _mid_node: Node3D = null
var _far_id := ""
var _tally_ok := false
var _far_ok := false
var _side_ok := false
var _mid_ok := false
var _cross_ok := false


func _initialize() -> void:
	_main = load("res://main.tscn").instantiate()
	root.add_child(_main)


## 探针也不许认识内容 id（铁律 2 对探针一样有效）：
## 从可摆放清单里挑第一个"钉住不动"的，而不是写死一个名字。
func _pick_static() -> String:
	for id in _main.pack.spawnables():
		if not _main.pack.places_as_rigid(id):
			return id
	return ""


func _process(_delta: float) -> bool:
	_f += 1

	if _f == 8:
		# 记账：判定必须覆盖到每一件东西。
		# 块 + 刚体 + 静态物 = 应判数；shown + hidden = 实判数。两者相等
		# 才说明没有谁被漏掉。漏掉的表现是"它永远在画"，而这在数字上看不见。
		var st: Dictionary = _main._world.cull_stats
		var expect: int = _main._world.chunks.size() + _main._world.bodies.size() \
			+ _main._world.props.size()
		var got: int = int(st.get("shown", 0)) + int(st.get("hidden", 0))
		_tally_ok = expect > 0 and got == expect
		print("CULL 记账：应判 %d，实判 %d（画 %d + 剔 %d）：%s"
			% [expect, got, int(st.get("shown", 0)), int(st.get("hidden", 0)),
				_tally_ok])

	if _f == 16:
		# 三件静态物，三个判据。都用同一个内容 id —— 剔除不看内容，
		# 所以拿什么来测都一样，这也顺带守着"按 id 判断"这种歪路。
		_far_id = _pick_static()
		var fwd: Vector3 = -_main._player.camera().global_transform.basis.z
		fwd.y = 0.0
		if fwd.length() < 0.01:
			fwd = Vector3.FORWARD
		fwd = fwd.normalized()
		var right: Vector3 = fwd.cross(Vector3.UP).normalized()
		var base: Vector3 = _main._player.global_position

		var r1: Dictionary = _main.api.spawn(_far_id, base + fwd * FAR, 0.0)
		_far_node = _main._world.props[-1] if bool(r1.get("ok", false)) else null
		var r2: Dictionary = _main.api.spawn(_far_id, base + fwd * MID + right * SIDE, 0.0)
		_side_node = _main._world.props[-1] if bool(r2.get("ok", false)) else null
		var r3: Dictionary = _main.api.spawn(_far_id, base + fwd * MID, 0.0)
		_mid_node = _main._world.props[-1] if bool(r3.get("ok", false)) else null
		print("CULL 立三件：远处 %s / 侧面 %s / 前方 %s（静态物 %d）"
			% [r1.get("ok", false), r2.get("ok", false), r3.get("ok", false),
				_main._world.props.size()])

	if _f == 24:
		# 读结果。前面已经过了 8 帧，_process 至少跑过一次，
		# visible 是判定的产物而不是默认值。
		var st: Dictionary = _main._world.cull_stats
		_far_ok = _alive(_far_node) and not _far_node.visible
		_side_ok = _alive(_side_node) and not _side_node.visible
		_mid_ok = _alive(_mid_node) and _mid_node.visible
		print("CULL 远处（%s，%.0f 米）：%s（必须被剔：%s）"
			% [_far_id, FAR, _state(_far_node), _far_ok])
		print("CULL 侧面（%s，偏 %.0f 米）：%s（必须被剔：%s）"
			% [_far_id, SIDE, _state(_side_node), _side_ok])
		print("CULL 前方（%s，%.0f 米）：%s（必须在画：%s）"
			% [_far_id, MID, _state(_mid_node), _mid_ok])
		print("CULL 本帧：画 %d / 剔 %d"
			% [int(st.get("shown", 0)), int(st.get("hidden", 0))])

		# 对拍：拿引擎自己的视锥测试当标准答案。
		# 侧面和前方两件都比 —— 前方那件在免剔区外、侧面那件在视锥外，
		# culling.gd 里符号写反时，这两件里必然有一件和 Godot 不一致。
		var cam: Camera3D = _main._player.camera()
		var pairs: Array = [["侧面", _side_node], ["前方", _mid_node]]
		var agree := true
		for pair in pairs:
			var n: Node3D = pair[1] as Node3D
			if not _alive(n):
				agree = false
				continue
			var godot_says: bool = cam.is_position_in_frustum(n.global_position)
			var i_say: bool = n.visible
			if godot_says != i_say:
				agree = false
			print("CULL 对拍 %s：Godot=%s 我=%s" % [
				pair[0], "在" if godot_says else "不在", "在" if i_say else "不在"])
		_cross_ok = agree

		for n in [_far_node, _side_node, _mid_node]:
			if _alive(n):
				_main._world.remove_thing(n)

		var ok: bool = _tally_ok and _far_ok and _side_ok and _mid_ok and _cross_ok
		print("CULL RESULT %s（记账 %s / 远处不画 %s / 侧面不画 %s / 前方在画 %s / 对拍 %s）"
			% ["OK" if ok else "FAIL",
				"OK" if _tally_ok else "FAIL",
				"OK" if _far_ok else "FAIL",
				"OK" if _side_ok else "FAIL",
				"OK" if _mid_ok else "FAIL",
				"OK" if _cross_ok else "FAIL"])
		quit(0 if ok else 1)

	return false


func _alive(n: Node3D) -> bool:
	return n != null and is_instance_valid(n)


## 状态给人看。探针的失败信息是下一个 agent 唯一的线索，
## "FAIL" 两个字什么也说明不了。
func _state(n: Node3D) -> String:
	if not _alive(n):
		return "没造出来"
	return "在画" if n.visible else "看不见"
