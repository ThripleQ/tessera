extends SceneTree

## 受击反馈探针（第 19 步）：打中之后，"打中了"这件事有没有被传达出去。
##
## 上一轮把枪做出来了，但它只回答"掉了几滴血"。这一轮问的是另一件事：
## **玩家怎么知道刚才那一枪打中了？**
##
## 三条反馈，各能独立坏掉，所以分开量：
##   看得见 —— 准心上的命中标记会闪一下（不看这个，玩家不知道打没打中）
##   摸得着 —— 怪被打中会往后退（不看这个，打中跟打偏长得一样）
##   停得住 —— 怪被打中会愣一下，不该继续走（不看这个，挨打的人若无其事）
##
## 最后一条"有牙"对照最要紧：**关掉受击反应之后，怪必须不退。**
## 不做这个对照，"怪会退"可能只是因为它在游荡（`wander` 让怪本来就走走停停），
## 而那与挨打无关。控制变量的办法是把怪放远一点、让它的脑子不往玩家这边，
## 然后对比"挨一枪"和"没挨那一枪"。
##
## 为什么要单独一步，而不是并进第 17 步（枪）：
## 第 17 步验的是**射速 / 伤害 / 弹药 / 后坐**这些数值规则；
## 这一步验的是**反馈**，它们坏掉的方式完全不同 ——
## 数值对但没有反馈，玩家会觉得"这枪没劲"，但探针全绿。
## 两者混在一步里，就会出现"第 17 步绿了所以枪没问题"的错觉。

const MAIN_TSCN := "res://main.tscn"

## 受击反应在刚体身上的 meta 键。与引擎侧同名（见 vitals.gd / locomotion.gd）。
## 探针读它是为了**看状态**，不是为了改状态。
const META_REACT := "hit_react_state"

## 一帧多少秒。探针自己积分（快进 tick），不等真实时间 ——
## 否则一条断言要等 0.35 秒，整套验收就多出好几秒。
const DT := 1.0 / 60.0

## 怪挨打之后**至少**要往后退这么快的速度（m/s）。
## 内容给的是 2.5 m/s 的初始推力，0.35 秒里线性衰减到 0，
## 峰值就在第一帧（≈2.5 m/s）。取 1.0 是给衰减留余量 ——
## 这条量的是"有没有反应"，不是"反应有多准"（后者归内容，作者想调就改 TOML）。
const PUSH_MIN_SPEED := 1.0
## 有牙：把受击反应清掉之后，往后退的速度必须**明显**比有反应时小。
## 有反应时峰值约 2.5 m/s，所以没反应时应该低于 0.3 m/s
## （怪自己冲向玩家只会让这个数更小，不会更大）。
const NO_PUSH_SPEED := 0.30
## 内容里给的愣住时长（秒）。探针要按它来快进同样久。
const STUN_SECONDS := 0.35

var _main
var _gun = null
var _vitals = null
var _rb: RigidBody3D = null
var _target_ok := false
var _hit_marker_ok := false
var _push_ok := false
var _stun_ok := false
var _no_push_ok := false

## 记录：挨枪之前的几个数
var _before := Vector3.ZERO
## 挨打之后还在往玩家那边凑的帧数（愣住时应该接近 0）
var _approaching_frames := 0
## 挨枪之后速度峰值（用来判断"退"是不是真退）
var _peak_back := 0.0


func _initialize() -> void:
	_main = load(MAIN_TSCN).instantiate()
	root.add_child(_main)


func _say(tag: String, text: String, good: bool) -> void:
	print("REACT %s：%s（%s）" % [tag, text, "true" if good else "false"])


func _process(_delta: float) -> bool:
	# 用帧当节拍器：每一帧做一件事，顺序写死，便于读。
	match _frame:
		4:
			_stage()
		6:
			_shoot()
		8:
			_measure_push()
			_measure_stun()
			_check_marker()
		10:
			_check_no_push()
			_report()
			return true
	_frame += 1
	return false


var _frame := 0


## 摆一个靶子：一只带血量的怪，放到玩家正前方 4 米，冻住（不让它自己走）。
##
## 冻住是必须的：怪本来就会游荡（`wander`），它自己在动的话，
## "挨打之后往后挪了多少"就分不清是挨打推的还是它自己在走。
func _stage() -> void:
	_gun = _main._player._gun
	_vitals = _main._systems.vitals()
	if _gun == null:
		print("REACT 靶子：没有枪")
		return
	var bodies: Array = _main._world.bodies
	for rb in bodies:
		var comps: Dictionary = _main.pack.components_of(
			String((rb as Node).get_meta("content_id", "")))
		if not comps.has("health"):
			continue
		_rb = rb as RigidBody3D
		break
	if _rb == null:
		print("REACT 靶子：世界里没有带 health 的刚体")
		return
	_rb.freeze = true
	_rb.global_position = _main._player.global_position + Vector3(0.0, 0.0, -4.0)
	_rb.linear_velocity = Vector3.ZERO
	# 挨打之前的位置与速度基线。基线必须是"打之前"，不然量的是
	# "从哪儿到哪儿"，而不是"挨打让它挪了多远"。
	_before = _rb.global_position
	_target_ok = true
	print("REACT 靶子：%s，摆在正前方 4 米，冻住"
		% _rb.get_meta("content_id", ""))


## 开一枪。走真实输入路径：扳机 → tick → 开火。
func _shoot() -> void:
	if _gun == null or _rb == null:
		return
	# 清冷却再打，否则这一枪根本不会响，而"没响"和"没打中"看起来一样。
	_gun.tick(1.0)
	_gun.trigger(true)
	_gun.tick(0.001)
	_gun.trigger(false)
	# 挨打之后刚体被冻着（freeze = true），所以速度得由引擎的物理写入 ——
	# 冻住的刚体不响应冲量，但**直接写 linear_velocity 仍然有效**
	# （写的是状态，不是冲量）。这里先解冻，让它能真的动。
	_rb.freeze = false
	_before = _rb.global_position
	# 挨打之后刚体身上该有一份"受击状态"。**先把它读出来** ——
	# 不看这一步的话，"反应没生效"和"反应生效了但探针没量对"分不开。
	var st: Dictionary = _rb.get_meta(META_REACT, {})
	print("REACT 挨打后的状态：%s" % str(st))


## 挨打之后的每一帧：量它退了多少、有没有愣住。
##
## **量速度，不量位置** —— 这是本探针最关键的一处技术选择。
## 位置（`global_position`）只有物理服务器真正步进时才会变，
## 而这里的快进是在 `_process` 回调里同步跑完的，物理插不进来：
## 第一版量位置，结果恒等于 0.000 m，看起来像"受击反应没生效"。
## 速度（`linear_velocity`）是 locomotion **直接写**的，不等物理，所以立刻能读到。
##
## 快进用系统层的 step（真实路径），而不是直接调 vitals ——
## 因为"反应"这件事要在**正常跑起来的世界里**成立，
## 绕开系统层去调内函数，测的就不是游戏里的那条路。
func _measure_push() -> void:
	if _rb == null:
		return
	# 挨打之后的 0.35 秒逐帧快进：每一帧记速度。
	for i in 21:
		_main._systems.step(DT)
		var v := _rb.linear_velocity
		# 往后 = 远离玩家（玩家在 z=0，靶子在 z=-4，所以后退是 z 变小）。
		_peak_back = maxf(_peak_back, -v.z)
		# 愣住 = **不再主动靠近玩家**。
		#
		# 为什么不用"速度接近 0"：挨打时怪正被推着往后走，
		# 速度一点都不小 —— 拿"速度小"当判据，量到的永远是 1 帧
		#（推力一上来就超标）。而"愣住"的本质是
		# **它自己的走动意图被清掉了**：怪本来在冲向玩家（+z 方向），
		# 愣住之后那个分量应该归零。推力是 -z（往后），
		# 所以"还在靠近玩家"就是 +z 那一半。
		if v.z > 0.05:
			_approaching_frames += 1


## 挨打之后退了多少、有没有愣住。
func _measure_stun() -> void:
	if _rb == null:
		return
	_push_ok = _peak_back >= PUSH_MIN_SPEED
	_say("会退", "挨一枪往后退的速度峰值 %.2f m/s，至少要 %.2f m/s"
		% [_peak_back, PUSH_MIN_SPEED], _push_ok)
	# 挨打之后的 21 帧里，它一次都不该再往玩家那边凑。
	# 允许 2 帧是为了容一次采样抖动。
	_stun_ok = _approaching_frames <= 2
	_say("会愣", "挨打后 %d 帧还在往玩家那边凑（21 帧里最多允许 2 帧）"
		% _approaching_frames, _stun_ok)


## 命中标记：准心上那个 X 有没有被点亮。
##
## 查的是**准心自己记的剩余时间**，不是枪的命中数 ——
## 因为这一条要回答的是"玩家看得见吗"，而看得见的那个东西住在准心里。
func _check_marker() -> void:
	var cross = _main.get_node_or_null("crosshair")
	if cross == null:
		_say("命中标记", "准心节点不存在", false)
		return
	var lit := float(cross._hit) > 0.0
	_hit_marker_ok = lit
	_say("命中标记", "准心上的命中标记亮着 %s（剩余 %.3f 秒）"
		% ["是" if lit else "不是", float(cross._hit)], lit)


## 有牙：让这只怪**没有受击反应**，再挨一枪 —— 这次它必须**不被推开**。
##
## 不做这个对照，"会退"可能只是怪自己在动（ambusher 会冲向玩家）。
##
## **对照的做法是把内容里的 `knockback` 改成 0**，而不是清 meta。
## 第一版试过清 meta，结果量到 2.50 m/s —— 因为清掉之后**再开枪**，
## `_react` 又把它完整写了一遍（0.35 秒的全新反应）。
## 也就是说那个对照根本没关掉任何东西，它量的是"第二次挨打"。
## 对照要关掉的必须是**反应本身**，而反应由内容决定。
##
## 为什么量"后退速度"而不是"位移"：怪本来就在冲向玩家（1.1 m/s），
## 所以总位移里混着它自己的走动，量不出击退那一部分。
## 而"往远离玩家的方向的速度"是干净的 —— 怪自己走只会让这个数**变小**。
func _check_no_push() -> void:
	if _rb == null:
		return
	# 把内容里的 knockback 临时改成 0（改的是 pack 里的那一份，
	# 探针跑完就结束，不影响磁盘上的内容包）。
	var cid := String(_rb.get_meta("content_id", ""))
	var comps: Dictionary = _main.pack.entities[cid]["components"]
	var saved := float(comps["hit_react"].get("knockback", 0.0))
	comps["hit_react"]["knockback"] = 0.0
	comps["hit_react"]["stun"] = 0.0
	_rb.global_position = _before
	_rb.linear_velocity = Vector3.ZERO
	# 同样打一枪，同样快进同样多帧。
	if _gun != null:
		_gun.tick(1.0)
		_gun.trigger(true)
		_gun.tick(0.001)
		_gun.trigger(false)
	var peak := 0.0
	for i in 21:
		_main._systems.step(DT)
		peak = maxf(peak, -_rb.linear_velocity.z)
	# 改回去（探针跑完就结束，但改回去是为了让后面的断言读到的还是原值）。
	comps["hit_react"]["knockback"] = saved
	comps["hit_react"]["stun"] = STUN_SECONDS
	_no_push_ok = peak <= NO_PUSH_SPEED
	_say("有牙", "把 knockback 改成 0 再挨一枪，往后退的速度峰值 %.2f m/s（有反应时 %.2f m/s），必须 <= %.2f m/s"
		% [peak, _peak_back, NO_PUSH_SPEED], _no_push_ok)


func _report() -> bool:
	var ok := _target_ok and _hit_marker_ok and _push_ok and _stun_ok and _no_push_ok
	print("REACT RESULT %s（靶子 %s / 命中标记 %s / 会退 %s / 会愣 %s / 有牙 %s）"
		% ["OK" if ok else "FAIL",
			"OK" if _target_ok else "FAIL",
			"OK" if _hit_marker_ok else "FAIL",
			"OK" if _push_ok else "FAIL",
			"OK" if _stun_ok else "FAIL",
			"OK" if _no_push_ok else "FAIL"])
	quit(0 if ok else 1)
	return ok
