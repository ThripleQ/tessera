extends SceneTree

## 步态连续性探针（第 18 步）：从静止到冲刺，这一路上脚到底干不干净。
##
## 第 15 步测的是"匀速走的时候脚不打滑"。它答不了本轮要问的三件事：
##   起步 —— 身体从 0 加速到走速，这段里脚有没有滑
##   换档 —— 走路切跑步那一帧，脚有没有"跳"一下
##   停车 —— 从走速减到 0，这段里脚有没有滑
##
## 这三件事的共同点是**它们发生在时间上**，而速度数字一个都测不出来：
## 脚跳 10 厘米时，速度依然是 1.04 m/s，滑移依然是 0.005 m/s。
## 所以量的是"每一帧脚在世界里挪了多远"，而不是任何一条曲线。
##
## 换档跳脚是本轮的主角。走路和跑步是两条动画，腿的摆动位置对不上，
## 硬切的那一帧脚会跳一下 —— 这是"不流畅"里最刺眼的一项，
## 而它一点都不影响速度。解法是切换时对齐相位（见 character_rig 的 _switch）。
##
## 因此探针必须**逐帧**推进真实播放器，并把脚骨的世界位置一帧一帧记下来。
## 时间由探针自己积分（seek 定位），不靠自然播放 —— 自然播放的帧率不可控，
## 而"跳了 0.08 米"和"跳了 0.09 米"之间的差别会被采样抖动盖掉。
##
## 探针里角色**没有真的移动**（位移是虚拟的），所以脚的世界位移就是
## "脚相对身体的位移"：脚钉在地上时它应该等于身体走过的距离，
## 两者相等 = 完全不打滑。

const STRIDE = preload("res://scripts/world/stride.gd")

## 一帧（物理帧）。探针自己积分，不用真实物理 —— 无头下的帧率不可控。
const DT := 1.0 / 60.0
## 换档那一帧，脚多挪了的上限（米）。
## 走一步约 0.7 m、脚步周期约 0.5 s，一帧约 0.023 m；
## 没对齐时是半步（0.2~0.4 m），差着一个量级。
const JUMP_TOL := 0.10
## 有牙：把相位对齐关掉后，脚跳必须超过这个数（米）。
## 不做这个对照，上面那条可能只是在说"两条动画的脚本来就离得近"。
const JUMP_MIN := 0.15
## 只认真正的脚掌骨。`foot_bones` 会把 control-* / IK-* / toes 一并返回（12 根），
## 而"最低的那根"每帧在这些骨之间跳 —— 支撑脚判定永远在换，一次都统计不上。
const FOOT_PREFIX := "foot."

var _main
var _player
var _rig
var _ap: AnimationPlayer
var _skel: Skeleton3D
var _feet: Array[int] = []
var _binds := {}
var _ok := true
var _frames := 0

## 模拟状态
var _last_clip := ""
var _prev_pos: Array = []
var _cur_pos: Array = []
var _jump_aligned := 0.0


func _initialize() -> void:
	_main = load("res://main.tscn").instantiate()
	root.add_child(_main)


func _say(tag: String, text: String, good: bool) -> void:
	if not good:
		_ok = false
	print("FLOW %s：%s（%s）" % [tag, text, good])


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames != 6:
		return false
	if not _find():
		print("FLOW RESULT FAIL")
		quit(1)
		return true
	# 停掉玩家物理：它每帧都会把姿态刷回待机，我们的采样就全乱了。
	_player.set_physics_process(false)
	_check_start_speed()
	_check_slip("起步", _ramp(_start_speed(), _walk_speed(), 40))
	_check_slip("停车", _ramp(_walk_speed(), 0.0, 40))
	_check_switch()
	_check_teeth()
	print("FLOW RESULT %s" % ("OK" if _ok else "FAIL"))
	quit(0 if _ok else 1)
	return true


func _find() -> bool:
	_player = _main.get_node_or_null("player")
	if _player == null:
		print("FLOW 找不到玩家")
		return false
	_rig = _player.get_node_or_null("visual/rig")
	if _rig == null:
		print("FLOW 玩家身上没有 visual/rig")
		return false
	for n in _rig.find_children("*", "AnimationPlayer", true, false):
		_ap = n as AnimationPlayer
		break
	for n in _rig.find_children("*", "Skeleton3D", true, false):
		_skel = n as Skeleton3D
		break
	if _ap == null or _skel == null:
		print("FLOW 找不到播放器或骨架")
		return false
	for b in STRIDE.foot_bones(_skel):
		if String(_skel.get_bone_name(b)).begins_with(FOOT_PREFIX):
			_feet.append(b)
	if _feet.is_empty():
		print("FLOW 找不到脚掌骨")
		return false
	# 播放器的自动推进交给探针：引擎自己也会 advance 一次，
	# 两边都推进的话，每帧走的时间就不是我们给的那一点了。
	_ap.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	_binds = _bind_poses()
	return true


## 起步初速：静止时按方向，第一步就该迈出去。
##
## 少了它会怎样：速度低于阈值时播的是**待机**，脚不动而身体在往前飘 ——
## 那是"滑着走"。而速度从 0 慢慢爬的话，动画倍率会小到 0.2，
## 脚步变成慢动作，像机器人起步。两个症状同一个原因：起步时没有速度。
func _check_start_speed() -> void:
	var s := _start_speed()
	var w := _walk_speed()
	_say("起步初速", "%.2f m/s（走速 %.2f 的 %.0f%%）" % [s, w, 100.0 * s / maxf(w, 0.001)],
		s > 0.35 and absf(s - w * 0.7) < 0.02)


## 一段速度序列：从 a 匀速加/减到 b。
func _ramp(a: float, b: float, frames: int) -> Array[float]:
	var out: Array[float] = []
	for i in frames:
		out.append(lerpf(a, b, float(i) / float(maxi(frames - 1, 1))))
	return out


## 起步 / 停车：这一段里脚有没有滑。
##
## 这里量的是**倍率被上下限夹住的那部分**（rig 的 `current_slide()`）。
##
## 为什么不直接量脚：试过，量不准。支撑脚在动画里相对身体后撤的速度
## 正好等于身体速度，而摆动脚高达 2.8 m/s；"哪只脚贴地"判不出支撑 ——
## 摆动脚经过最低点时也是贴地的（实测 i=02：贴地却速率 2.7）。
## 挑错脚就会把摆动当成滑步，起步时量到 1.7 m/s 的"滑"——那是量法错了。
##
## 而"倍率对齐 ⇒ 支撑脚钉在地上"这条推论，第 15 步已经用**两套独立实现**
## 验过（曲线求值 vs 真实播放器驱动骨架）。这一步不重复它，
## 它只守**起步与停车这两个新区间特有的风险**：
## 速度低到某个程度，倍率会被下限夹住 —— 动画还在往前送，身体已经慢下来，
## 脚就在身后拖着走。停车那段的滑移就是这么来的。
##
## 起步初速（> MOVE_AT）保证起步第一帧就播走路而不是待机：
## 待机时脚不动而身体在往前飘，那是"滑着走"。
func _check_slip(tag: String, speeds: Array[float]) -> void:
	_reset()
	var worst := 0.0
	var at := 0.0
	for i in speeds.size():
		var v: float = speeds[i]
		# 和 player.gd 同一套规则：慢到一定程度就归零，不再往前飘。
		if v < _stop_speed():
			v = 0.0
		_advance(v)
		if v < 0.35:
			# 已经切到待机（脚不动），倍率不再是这一帧的事。
			continue
		var s := absf(float(_rig.current_slide()))
		if s > worst:
			worst = s
			at = v
	_say(tag, "全程补不掉的滑移 %.3f m/s（@%.2f m/s）" % [worst, at], worst <= 0.05)


## 换档那一帧，脚有没有跳。
##
## 做法：先稳定走一段，再把速度直接抬到冲刺档（跨档），
## 比对切换前后**同一只脚**的位置，多出来的就是跳。
func _check_switch() -> void:
	_reset()
	for i in 24:
		_advance(_walk_speed())
	_advance(_run_speed())
	_jump_aligned = _excess()
	_say("换档", "走路→跑步那一帧，脚多挪了 %.3f m" % _jump_aligned, _jump_aligned <= JUMP_TOL)


## 有牙：把相位对齐关掉，同一次换档必须跳得明显更多。
##
## 不做这个对照，"脚没跳"可能只是因为走路和跑步的脚本来离得近 ——
## 那样的结论不能用来证明相位对齐有用。
func _check_teeth() -> void:
	_rig.set("_align_phase", false)
	_reset()
	for i in 24:
		_advance(_walk_speed())
	_advance(_run_speed())
	var jump := _excess()
	_rig.set("_align_phase", true)
	_say("有牙", "关掉相位对齐后，脚多挪了 %.3f m（对齐时 %.3f）" % [jump, _jump_aligned],
		jump >= JUMP_MIN and jump > _jump_aligned * 1.5)


## 推进一帧：按给定速度驱动状态机，然后让播放器前进一帧。
##
## 用 `advance` 而不是 `seek`：seek 会**打断交叉淡化**（blend 期间 seek
## 根本不驱动骨架，实测），那样量到的"脚在动"全是假的。
## advance 受 speed_scale 影响，而 speed_scale 正是 rig 按速度设的倍率。
##
## 切片段那一帧不 advance：相位对齐已经把新片段 seek 到对齐位置了，
## 再往前推一帧会把对齐结果抹掉 —— 那一帧要量的正是"跳了多少"。
func _advance(speed: float) -> bool:
	_prev_pos = _cur_pos.duplicate()
	_rig.set("_lock", 0.0)
	_rig.set("_on_floor", true)
	_rig.update_locomotion(speed, true, 0.0, DT)
	var clip := String(_rig.current_clip())
	var switched := clip != _last_clip
	_last_clip = clip
	if switched:
		# 切换帧：rig 已经把新片段定位好了（对齐过，或保留在旧位置）。
		# 这里再 seek 一次**当前**位置，只为把骨架姿态应用到这一帧 ——
		# play() 本身不会立刻改骨架（实测），不 seek 的话量到的还是上一帧的姿势，
		# "有牙"那条就会量成 0.000（假的通过）。
		_ap.seek(_ap.get_current_animation_position(), true)
	else:
		_ap.advance(DT)
	_cur_pos.clear()
	for b in _feet:
		_cur_pos.append(_bone_pos(b))
	return switched


## 某只脚的世界位置（乘绑定矩阵换算到网格空间）。
func _bone_pos(bone: int) -> Vector3:
	var g := _skel.get_bone_global_pose(bone)
	if _binds.has(bone):
		return (g * (_binds[bone] as Transform3D)).origin
	return g.origin


## 换档那一帧，脚多挪了多少（米）。
##
## 角色在探针里没有真的移动，所以脚的世界位移就是"脚相对身体的位移"。
## 相位对齐正确时，换档那一帧两条动画停在**同一个步相位** → 脚的位置几乎不变。
## 没对齐时新片段从头播 → 位置差是半步（几十厘米）。
func _excess() -> float:
	if _cur_pos.is_empty() or _prev_pos.size() != _cur_pos.size():
		return 999.0
	var worst := 0.0
	for i in _cur_pos.size():
		var d: Vector3 = _cur_pos[i] - _prev_pos[i]
		worst = maxf(worst, Vector2(d.x, d.z).length())
	return worst


## 重新开始一段模拟：时间、上一段片段、脚的位置都清掉。
func _reset() -> void:
	_last_clip = ""
	_prev_pos.clear()
	_cur_pos.clear()


func _walk_speed() -> float:
	return float(_player.get("_walk_speed"))


func _run_speed() -> float:
	return float(_player.get("_sprint_speed"))


func _start_speed() -> float:
	return float(_player.get("_start_speed"))


func _stop_speed() -> float:
	return float(_player.get("_stop_speed"))


## 骨骼 → 绑定矩阵（从角色身上第一份蒙皮网格取）。
func _bind_poses() -> Dictionary:
	var out := {}
	for n in _rig.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi.skin == null:
			continue
		for i in mi.skin.get_bind_count():
			var bone := mi.skin.get_bind_bone(i)
			if bone >= 0:
				out[bone] = mi.skin.get_bind_pose(i)
		if not out.is_empty():
			return out
	return out
