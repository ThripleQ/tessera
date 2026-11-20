extends SceneTree

## 步态探针（第 15 步）：走起来脚到底滑不滑。
##
## 守四件事，每一件都会静默坏掉：
##   档位   —— 资产点名的每条步态都测出了速度，且能当直行用（不是挥刀那种抖动）
##   无缝   —— 0.35~4.0 m/s 之间**任意**速度都能落到某档的自然区间，倍率不被夹住
##   不打滑 —— 按该档真实播放时，支撑脚相对身体的后撤速率 == 玩家实际速度
##   有牙   —— 故意用错倍率，第三条必须失败
##
## 第三条是重点，也是唯一能证明"不打滑"的量。它的物理定义很简单：
## 支撑脚站在地上不动，身体往前走 —— 那么脚相对身体的后退速率就等于身体速度。
## 如果两者不等，差值就是脚在世界里真实滑动的速度，一个像素都骗不了人。
##
## 验它必须用**真实播放器驱动骨架**，不能拿测量结果自己和自己对：
## 这里用 `seek()` 把动画时间推到指定位置，读 Skeleton3D 的实际姿态。
## 那条链路（曲线求值 → 播放器 → 骨架 → 缩放）任何一环错了，数就对不上。

const STRIDE = preload("res://scripts/world/stride.gd")
const CHARACTERS = preload("res://scripts/world/character_assets.gd")
const GAIT = preload("res://scripts/world/gait.gd")

## 打滑容差：脚在世界里的水平速度 ≤ 请求速度的这个比例。
const SLIP_TOL := 0.08
## 采样步长（墙上时间）。120 Hz 对 0.4~1.1 秒的循环够密。
const SAMPLE_DT := 1.0 / 120.0
## 速度带扫描范围与步长。
const SCAN_FROM := 0.35
const SCAN_TO := 4.00
const SCAN_STEP := 0.05

var _main
var _player
var _rig
var _ap: AnimationPlayer
var _skel: Skeleton3D
var _f := 0
var _ok := true


func _initialize() -> void:
	_main = load("res://main.tscn").instantiate()
	root.add_child(_main)


func _say(tag: String, text: String, good: bool) -> void:
	if not good:
		_ok = false
	print("LOCO %s：%s（%s）" % [tag, text, good])


func _process(_delta: float) -> bool:
	_f += 1
	if _f != 6:
		return false
	if not _find():
		print("LOCO RESULT FAIL")
		quit(1)
		return true
	# 停掉玩家物理，否则它每帧都会把姿态刷回 idle。
	_player.set_physics_process(false)
	_check_tiers()
	_check_band()
	_check_player_speed()
	_check_slip()
	print("LOCO RESULT %s" % ("OK" if _ok else "FAIL"))
	quit(0 if _ok else 1)
	return true


func _find() -> bool:
	# 按名字找，不按类型找。"main 的第一个 CharacterBody3D 就是玩家"是条隐式约定：
	# 世界里的别人（NPC）今天挂在 world 下面，所以还没撞上；哪天有人把某个
	# CharacterBody3D 直接挂到 main 下，这里就会悄悄取错对象 ——
	# 症状只是几条数对不上，不报错。
	_player = _main.get_node_or_null("player")
	if _player == null:
		print("LOCO 找不到玩家")
		return false
	_rig = _player.get_node_or_null("visual/rig")
	if _rig == null:
		print("LOCO 玩家身上没有 visual/rig")
		return false
	for n in _rig.find_children("*", "AnimationPlayer", true, false):
		_ap = n as AnimationPlayer
		break
	for n in _rig.find_children("*", "Skeleton3D", true, false):
		_skel = n as Skeleton3D
		break
	if _ap == null or _skel == null:
		print("LOCO 找不到播放器或骨架")
		return false
	return true


func _check_tiers() -> void:
	var id := String(_rig.character_id())
	var loco: Dictionary = CHARACTERS.character_meta(id).get("locomotion", {})
	var g := GAIT.from_table(loco)
	var src := String(loco.get("source", ""))
	_say("来源", "步态由%s给出（%d 档）" % [src if not src.is_empty() else "未知", _rig.tier_count()],
		_rig.tier_count() >= 2 and src == "声明")
	var tiers: Array = g.get("tiers", [])
	var parts: Array[String] = []
	var mono := true
	var prev := -1.0
	for e in tiers:
		var spd := float(e["speed"])
		parts.append("%s %.2f" % [e["clip"], spd])
		if spd <= prev:
			mono = false
		prev = spd
	_say("档位", " / ".join(parts) + " m/s", mono and tiers.size() == _rig.tier_count())


## 速度带无缝：任意速度都能被某一档零滑覆盖，且倍率不被夹住。
func _check_band() -> void:
	var worst_slide := 0.0
	var worst_at := 0.0
	var min_rate := 99.0
	var max_rate := 0.0
	var v := SCAN_FROM
	while v <= SCAN_TO:
		var pick: Dictionary = _rig.choose_gait(v)
		var s := absf(float(pick["slide"]))
		if s > worst_slide:
			worst_slide = s
			worst_at = v
		min_rate = minf(min_rate, float(pick["rate"]))
		max_rate = maxf(max_rate, float(pick["rate"]))
		v += SCAN_STEP
	_say("无缝", "%.2f~%.2f m/s 全程最大失配 %.3f m/s（@%.2f），倍率 %.2f~%.2f"
		% [SCAN_FROM, SCAN_TO, worst_slide, worst_at, min_rate, max_rate],
		worst_slide <= 0.02)


## 玩家真的用了动画反推出来的速度，而不是那份凭手感写死的常量。
func _check_player_speed() -> void:
	var walk: float = _rig.gait_walk()
	var run: float = _rig.gait_run()
	var pw: float = float(_player.get("_walk_speed"))
	var pr: float = float(_player.get("_sprint_speed"))
	_say("玩家速度", "走 %.2f / 冲 %.2f（档位反推 %.2f / %.2f）"
		% [pw, pr, walk, run],
		absf(pw - walk) <= 0.01 and absf(pr - run) <= 0.01)


## 打滑实测：请求速度 → 选档 → 按该档倍率真实播放 → 量支撑脚的后撤速率。
func _check_slip() -> void:
	var cases: Array[float] = [
		_rig.gait_walk(),
		(_rig.gait_walk() + _rig.gait_run()) * 0.5,
		_rig.gait_run(),
	]
	var detail: Array[String] = []
	var all := true
	for want in cases:
		_drive(want)
		var clip: String = _rig.current_clip()
		var rate: float = _rig.current_rate()
		var got := _playback_speed(clip, rate)
		if got < 0.0:
			_say("不打滑", "%.2f m/s → 量不出来（%s）" % [want, clip], false)
			all = false
			continue
		var slip := absf(want - got)
		if slip > want * SLIP_TOL:
			all = false
		detail.append("%.2f→%s×%.2f 实测 %.2f（滑 %.3f）"
			% [want, clip, rate, got, slip])
	_say("不打滑", " ｜ ".join(detail), all)
	_check_teeth(cases)


## 有牙验证：同一片段故意按倍率 1.0 播，测出来的速度必须明显偏离请求速度。
## 不这样验一次，上面那条"不打滑"可能只是在测量自己。
func _check_teeth(cases: Array[float]) -> void:
	var want: float = cases[cases.size() - 1]
	_drive(want)
	var clip: String = _rig.current_clip()
	var wrong := _playback_speed(clip, 1.0)
	if wrong < 0.0:
		_say("有牙", "对照量不出来（%s）" % clip, false)
		return
	var gap := absf(want - wrong)
	_say("有牙", "同片段按倍率 1.0 播 → 实测 %.2f，与请求 %.2f 差 %.2f m/s"
		% [wrong, want, gap], gap > want * 0.15)


## 按"玩家正在以这个速度在地面上跑"驱动状态机。
##
## 每步都要先清掉落地锁：开局 `_on_floor` 是 false，第一次调用会被判成"刚落地"，
## 于是锁 0.3 秒播 Jump_Land —— 之后所有采样都在测落地动作，而且**状态名看着很正常**。
func _drive(speed: float) -> void:
	_rig.set("_lock", 0.0)
	_rig.set("_on_floor", true)
	_rig.update_locomotion(speed, true, 0.0, 0.016)


## 按指定倍率真实播放一条片段，量出"支撑脚相对身体的后退速率"（m/s，已乘缩放）。
## 失败返回 -1.0。
func _playback_speed(clip: String, rate: float) -> float:
	var a := _ap.get_animation(clip)
	if a == null or rate <= 0.001:
		return -1.0
	var length := a.length
	var scale := float(CHARACTERS.character_meta(String(_rig.character_id())).get("scale", 1.0))
	var feet := STRIDE.foot_bones(_skel)
	if feet.is_empty():
		return -1.0
	# 一个循环在墙上时间里是 length/rate 秒；按 SAMPLE_DT 采样。
	var n := int(round(length / rate / SAMPLE_DT))
	if n < 16:
		return -1.0

	var ys: Array = []
	var zs: Array = []
	for i in feet.size():
		ys.append([])
		zs.append([])
	_ap.play(clip)
	for k in n:
		var t := fmod(float(k) * SAMPLE_DT * rate, length)
		_ap.seek(t, true)
		for i in feet.size():
			var p := _skel.get_bone_global_pose(feet[i]).origin
			ys[i].append(p.y)
			zs[i].append(p.z)

	var total := 0.0
	var counted := 0
	for i in feet.size():
		var s := _support_slope(ys[i], zs[i])
		if s == INF:
			continue
		total += absf(s)
		counted += 1
	if counted == 0:
		return -1.0
	return (total / float(counted)) * scale


## 支撑相里 z 的斜率（单位/秒）。返回 INF 表示这只脚量不出来。
##
## 与 stride.gd 是**两套独立实现**：那边用曲线求值，这边读播放器驱动后的真实骨骼。
## 故意不共用，否则就是拿一个函数验证它自己。
func _support_slope(ys: Array, zs: Array) -> float:
	var n := ys.size()
	if n < 16:
		return INF
	var ymin: float = ys[0]
	var ymax: float = ys[0]
	for y in ys:
		ymin = minf(ymin, y)
		ymax = maxf(ymax, y)
	var travel := ymax - ymin
	if travel < 0.0005:
		return INF
	var thr := ymin + travel * 0.30

	# 最长连续支撑段（环形，可跨循环边界）。
	var best_len := 0
	var best_start := 0
	for start in n:
		if float(ys[start]) > thr:
			continue
		var run := 0
		while run < n and float(ys[(start + run) % n]) <= thr:
			run += 1
		if run > best_len:
			best_len = run
			best_start = start
	if best_len < 4:
		return INF

	var cnt := float(best_len)
	var mx := (cnt - 1.0) * 0.5
	var mz := 0.0
	for k in best_len:
		mz += float(zs[(best_start + k) % n])
	mz /= cnt
	var num := 0.0
	var den := 0.0
	for k in best_len:
		var dx := float(k) - mx
		num += dx * (float(zs[(best_start + k) % n]) - mz)
		den += dx * dx
	if den <= 0.0:
		return INF
	return (num / den) / SAMPLE_DT
