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
## 只有"按速度挑一个片段、按 0.18 秒交叉淡入"。这是刻意的 ——
## 手上只有 76 个现成片段，先把人从"滑行"救成"走路"，别提前造动画中间件。

const ASSETS = preload("res://scripts/world/assets.gd")
const CHARACTER_ASSETS = preload("res://scripts/world/character_assets.gd")

## 速度分界。用**实际**水平速度判，不用输入意图 ——
## 于是被箱子推着走、从斜坡滑下来，也会播放走路。
const MOVE_AT := 0.35
const RUN_AT := 5.2
## 交叉淡入时长。太短会"啪"地硬切，太长会滑步。
const BLEND := 0.18
## 落地动作锁定时间：跳一次落地播 0.3 秒，期间不接受别的状态。
## 不锁的话下一帧就会切回 idle，那个动作等于没播。
const LAND_LOCK := 0.30

## 资产朝向修正。glTF 里角色的前向按惯例是 +Z，Godot 的前向是 -Z，
## 差半圈。这个值错了的症状很好认：人永远背对移动方向倒着滑。
const ASSET_YAW := PI

var _ap: AnimationPlayer
var _char_id := ""
var _state := ""
var _asset := false
var _on_floor := true
var _lock := 0.0


## 返回 true 表示用上了带动画的资产；false 表示退回了程序化几何。
## 调用方拿这个值决定要不要再画"眼睛"这类只有几何版才需要的东西。
func setup(char_id: String, fallback_color: Color, fallback_eye: Color) -> bool:
	_char_id = char_id
	var c := CHARACTER_ASSETS.character(char_id)
	if c["ok"] and c["root"] != null:
		var root: Node3D = c["root"]
		add_child(root)
		_ap = root.find_child("AnimationPlayer", true, false) as AnimationPlayer
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
func _setup_clips(ap: AnimationPlayer) -> void:
	var looped := ["Idle", "Walking_", "Running_", "Sit_", "Lie_", "Blocking"]
	for clip_name in ap.get_animation_list():
		var a := ap.get_animation(clip_name)
		if a == null:
			continue
		var should_loop := false
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
	elif speed < RUN_AT:
		play("walk")
	else:
		play("run")


func play(want: String) -> void:
	if not _asset or want == _state:
		return
	var clip: String = CHARACTER_ASSETS.CHARACTER_CLIPS.get(want, "")
	if clip.is_empty() or not _ap.has_animation(clip):
		return
	_state = want
	_ap.play(clip, BLEND)


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
