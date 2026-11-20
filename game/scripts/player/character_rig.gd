extends Node3D

## 玩家的**外观**：优先用带动画的角色资产，拿不到就退回程序化几何。
##
## 为什么单独一个文件：player.gd 管的是"手感"（加速度、土狼时间、推刚体），
## 这个管的是"看起来是谁"。混在一起，加一个动画状态就会把物理分支挤出 300 行，
## 而那个文件是每次调手感都要打开的地方。
##
## 这一层不认识任何角色的具体名字：id 由 player 传进来，动画名由
## `ASSETS.CHARACTER_CLIPS` 映射。换角色 = 换 id，不用改这里一行。
##
## **它不是一个"骨骼动画系统"**：没有混合树、没有 IK、没有根运动重定向。
## 只有"按速度挑一个片段、按实际速度调播放倍率"。这是刻意的 ——
## 手上只有 76 个现成片段，先把人从"滑行"救成"走路"，别提前造动画中间件。

const ASSETS = preload("res://scripts/world/assets.gd")
const CHARACTER_ASSETS = preload("res://scripts/world/character_assets.gd")
const GAIT = preload("res://scripts/world/gait.gd")

## 速度分界。用**实际**水平速度判，不用输入意图 ——
## 于是被箱子推着走、从斜坡滑下来，也会播放走路。
##
## 只在"没有可用步速档位"（资产缺失）时才会用到 RUN_AT ——
## 有档位时选哪条片段由 `choose_gait()` 按速度自动决定。
const MOVE_AT := 0.35
const RUN_AT := 5.2
## 交叉淡入时长。太短会"啪"地硬切，太长会滑步。
const BLEND := 0.18
## 落地动作锁定时间：跳一次落地播 0.3 秒，期间不接受别的状态。
## 不锁的话下一帧就会切回 idle，那个动作等于没播。
const LAND_LOCK := 0.30

## 播放倍率的上下限。1.0 = 资产原始节奏。
##
## 倍率只做**微调**：升速靠换片段（一档一档升），不是把同一条播快。
## 这两个数的真正作用是**给每一档划出势力范围**：
##   片段可用区间 = [片段速度 × 下限, 片段速度 × 上限]
## 相邻档的区间必须重叠，整条速度带才没有缝 —— 有缝的那一段，
## 无论选哪一档倍率都会被夹住，于是脚重新开始滑。
##
## 以 Knight 的三档为例（0.55 / 1.43 / 2.42 m/s）：
##   0.34–0.93 ｜ 0.89–2.43 ｜ 1.50–4.12   → 0.34 到 4.12 全程无缝
## 上限 1.70 约等于 190 步/分，再高就不像人了。
## **想跑更快不是调这两个数，是往资产里加一条更快的动画。**
const RATE_MIN := 0.62
const RATE_MAX := 1.70

## 资产朝向修正。glTF 里角色的前向按惯例是 +Z，Godot 的前向是 -Z，
## 差半圈。这个值错了的症状很好认：人永远背对移动方向倒着滑。
const ASSET_YAW := PI

var _ap: AnimationPlayer
var _char_id := ""
var _state := ""
var _asset := false
var _on_floor := true
var _lock := 0.0
var _tiers: Array = []
var _gait: Dictionary = {}
var _clip := ""
var _rate := 1.0
var _slide := 0.0


## 返回 true 表示用上了带动画的资产；false 表示退回了程序化几何。
## 调用方拿这个值决定要不要再画"眼睛"这类只有几何版才需要的东西。
func setup(char_id: String, fallback_color: Color, fallback_eye: Color) -> bool:
	_char_id = char_id
	var c := CHARACTER_ASSETS.character(char_id)
	if c["ok"] and c["root"] != null:
		var root: Node3D = c["root"]
		add_child(root)
		_ap = root.find_child("AnimationPlayer", true, false) as AnimationPlayer
		# 步速档位：加载资产时已经按骨骼实测算过一次（gait.gd 的 measure）。
		# 这里只是取用，不重新测 —— 测量必须只有一处真相。
		_gait = GAIT.from_table(c.get("locomotion", {}))
		if bool(_gait.get("ok", false)):
			_tiers = _gait["tiers"]
		if _ap != null:
			_setup_clips(_ap)
		var anims: PackedStringArray = c["animations"]
		if _ap != null and anims.size() > 0:
			_asset = true
			rotation.y = ASSET_YAW
			play("idle")
			return true
		# 场景出来了但没有动画：形状至少是对的，留着比删掉好。
		rotation.y = ASSET_YAW
		return false
	_build_fallback(fallback_color, fallback_eye)
	return false


## glTF 的片段没有循环标志，Godot 一律给 LOOP_NONE。
## 不显式设一遍，走路会在第一秒定格成"抬着一条腿的雕像"。
##
## 除了名字前缀，**测出来的移动档位一律强制循环**：名字不是契约（换个包可能叫
## Sprint_A），而"这段动画在往一个方向匀速走"是测出来的事实。
func _setup_clips(ap: AnimationPlayer) -> void:
	var looped := ["Idle", "Walking_", "Running_", "Sit_", "Lie_", "Blocking"]
	var by_gait: Array[String] = []
	for e in _tiers:
		by_gait.append(String(e["clip"]))
	for clip_name in ap.get_animation_list():
		var a := ap.get_animation(clip_name)
		if a == null:
			continue
		var should_loop := by_gait.has(String(clip_name))
		if not should_loop:
			for prefix in looped:
				if clip_name.begins_with(prefix):
					should_loop = true
					break
		a.loop_mode = Animation.LOOP_LINEAR if should_loop else Animation.LOOP_NONE


func uses_asset() -> bool:
	return _asset


func character_id() -> String:
	return _char_id


func state() -> String:
	return _state


func clip_count() -> int:
	if _ap == null:
		return 0
	return _ap.get_animation_list().size()


## 按速度与落地状态挑片段。每物理帧调一次，同一状态里是空操作。
func update_locomotion(speed: float, on_floor: bool, vy: float, delta: float) -> void:
	var landed := on_floor and not _on_floor
	_on_floor = on_floor
	if landed and speed < RUN_AT:
		play("land")
		_lock = LAND_LOCK
	if _lock > 0.0:
		_lock -= delta
		if _lock > 0.0:
			return
	if not on_floor:
		# 上升用起跳动作，下落用空中循环。不这样分，跳起来会一直播起跳，
		# 而那个动作只有 0.3 秒，之后人物就定格在半空。
		play("jump_up" if vy > 0.3 else "jump_air")
		return
	if speed < MOVE_AT:
		play("idle")
	elif _tiers.is_empty():
		# 没有档位信息（老资产 / 测不出来）：退回按阈值二选一，倍率 1.0。
		play("walk" if speed < RUN_AT else "run")
	else:
		_play_gait(speed)


## 给定实际速度，选哪条片段、用多大倍率。
##
## 选法：挑"需要的倍率最接近 1"的那条，用**对数**距离而不是差值 ——
## 0.5→1.0 和 2.0→4.0 对人是同样程度的失配，对减法不是。
##
## 倍率 = 实际速度 / 该片段隐含速度，于是 `片段速度 × 倍率 == 实际速度`，
## 支撑脚相对身体的后退速率正好抵消身体前进 —— 脚就钉在地上了。
## 这不是"看起来差不多"，是流水账：位移对不上多少，脚就滑多少。
##
## 返回 {"clip", "rate", "index", "slide"}。slide（m/s）是倍率被上下限夹住后
## 补不掉的那部分 —— 只在极端速度下非零，正常情况下恒为 0。
##
## 公开：探针要逐点验"请求速度 == 片段速度 × 倍率"，只验状态名会假绿
## （名字对了、倍率错了，脚照样打滑）。
func choose_gait(speed: float) -> Dictionary:
	if _tiers.is_empty():
		return {"clip": "", "rate": 1.0, "index": 0, "slide": speed}
	var best := 0
	var best_d := INF
	for i in _tiers.size():
		var cs := maxf(float(_tiers[i]["speed"]), 0.001)
		var d := absf(log(maxf(speed, 0.001) / cs))
		if d < best_d:
			best_d = d
			best = i
	var sel := maxf(float(_tiers[best]["speed"]), 0.001)
	var rate := clampf(speed / sel, RATE_MIN, RATE_MAX)
	return {
		"clip": String(_tiers[best]["clip"]),
		"rate": rate,
		"index": best,
		"slide": speed - sel * rate,
	}


## 换档位不等于换状态名：第 0 档叫 walk，往上都算 run。
## 名字是给人看的，选哪条片段是 `choose_gait()` 算的。
func _play_gait(speed: float) -> void:
	var pick := choose_gait(speed)
	var want: String = "walk" if int(pick["index"]) == 0 else "run"
	if want != _state:
		_state = want
		_clip = String(pick["clip"])
		_ap.play(_clip, BLEND)
	# 同一状态里速度一直在变，倍率必须每帧跟住 —— 只在换片段时设一次，
	# 加速过程中脚就会滑起来（而状态名全对，看不出来）。
	_rate = float(pick["rate"])
	_slide = float(pick["slide"])
	_ap.speed_scale = _rate


func play(want: String) -> void:
	if not _asset or want == _state:
		return
	var clip: String = CHARACTER_ASSETS.CHARACTER_CLIPS.get(want, "")
	if clip.is_empty() or not _ap.has_animation(clip):
		return
	_state = want
	_clip = clip
	_rate = 1.0
	_slide = 0.0
	_ap.speed_scale = 1.0
	_ap.play(clip, BLEND)


## 这个角色该用多快的速度走 / 冲刺（由它自己的动画反推）。
## 0 表示测不出来 —— 调用方必须退回默认速度，不许拿 0 当速度。
func gait_walk() -> float:
	return float(_gait.get("walk", 0.0))


func gait_run() -> float:
	return float(_gait.get("run", 0.0))


func tier_count() -> int:
	return _tiers.size()


func current_clip() -> String:
	return _clip


func current_rate() -> float:
	return _rate


## 当前这一刻"补不掉的滑动"（m/s）。正常恒为 0；非零说明请求速度超出了
## 这套动画能撑的范围，此时要么换资产，要么接受脚在滑 —— 但不能假装没这回事。
func current_slide() -> float:
	return _slide


## 没有角色资产时的外观：原来的程序化低模 + 两点眼睛。
##
## 这条分支必须留着，而且必须**能用** —— 它是"资产目录被删掉"时唯一的退路。
## 一个装不上就满屏空白的加载器，比没有加载器更糟。
func _build_fallback(color: Color, eye_color: Color) -> void:
	var mesh := MeshInstance3D.new()
	mesh.name = "fallback_body"
	mesh.mesh = ASSETS.mesh("player_lowpoly")
	mesh.material_override = _fallback_material(color)
	add_child(mesh)

	# 眼睛。只有几何版需要：资产版的脸在贴图里。
	var eye_mat := StandardMaterial3D.new()
	eye_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	eye_mat.albedo_color = eye_color
	for side in [-1.0, 1.0]:
		var eye := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(0.062, 0.082, 0.022)
		eye.mesh = box
		eye.material_override = eye_mat
		eye.position = Vector3(side * 0.055, 1.548, -0.128)
		add_child(eye)


func _fallback_material(color: Color) -> ShaderMaterial:
	# 走 assets.gd 的材质共用表，不自己 new：第 13 步的红线是
	# "材质数跟着配色走，不跟着物体数走"，绕开它就会悄悄多一份。
	return ASSETS.toon_material(color, 0.013)
