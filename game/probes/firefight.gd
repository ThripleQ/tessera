extends SceneTree

## 枪探针：内容 → 装配 → 开火 → 扣血 → 死亡计数 → 弹药 → 后坐 → 枪的可见性。
##
## 为什么单独一步：第 6 步验的是**撞击**伤害（箱子以 8 m/s 砸中），
## 而子弹不是物理体，它是一条射线。两条伤害路径长得像，但错的不是同一处：
## 撞击那条靠 `world.impacts` 队列，射线这条靠 `vitals.damage()` 直接调用。
## 只验其中一条，另一条可以在"探针全绿"的情况下彻底不通。
##
## 六条各错各的：
##   数值来自内容 —— 枪上的伤害 / 弹匣必须等于 TOML 里的数，
##                   而不是引擎里某个恰好相同的常量
##   打中会疼    —— 一发之后血量正好少了 damage
##   打死会记    —— 血量归零之后离开世界，而且击杀数 +1
##   会打空      —— 弹匣打光之后开不出枪，换弹之后又满了
##   后坐会回    —— 抬起是真的，回来也是真的（只有抬没有回 = 准星永久跑偏）
##   视角分离    —— 第一人称看得见枪，第三人称看不见（否则镜头后面飘着一把枪）
##
## 时序分帧：射线要等物理世界有位置，开火要等冷却，换弹要等时间。
## 但**不等真实时间** —— 这里直接拿 `tick(大 dt)` 快进，
## 否则一条断言要等 3 秒，而"等真实时间"的探针在慢机器上会变成随机失败。

var _main
var _f := 0
var _gun = null
var _vitals = null
var _rb: RigidBody3D = null
var _hp_before := 0
var _damage := 0
var _bodies_before := 0

var _content_ok := false
var _hit_ok := false
var _kill_ok := false
var _ammo_ok := false
var _recoil_ok := false
var _view_anim_ok := false
var _view_ok := false


func _initialize() -> void:
	_main = load("res://main.tscn").instantiate()
	root.add_child(_main)


func _process(_delta: float) -> bool:
	_f += 1

	if _f == 8:
		_content_ok = _check_content()
	if _f == 20:
		_stage_target()
	if _f == 22:
		_one_shot()
	if _f == 24:
		_check_hit()
	if _f == 26:
		_one_shot()
	if _f == 30:
		_check_kill()
	if _f == 32:
		_check_ammo()
	if _f == 34:
		_check_recoil()
	if _f == 35:
		_check_view_anim()
	if _f == 36:
		_check_view()
		return _report()
	return false


## 枪是从内容装出来的吗。断言的是"引擎读到了内容里的数"，
## 不是"某个数字恰好等于 25"—— 后者会在内容调平衡那天假红。
func _check_content() -> bool:
	_gun = _main._player._gun
	_vitals = _main._systems.vitals()
	if _gun == null:
		print("GUN 没有枪：`kind = \"weapon\"` 的内容没被装上")
		return false
	var ids: PackedStringArray = _main.pack.ids_of_kind("weapon")
	if ids.is_empty():
		print("GUN 内容里一把 weapon 都没有")
		return false
	var comps: Dictionary = _main.pack.components_of(_gun.weapon_id)
	var w: Dictionary = comps.get("wieldable", {})
	_damage = int(w.get("damage", -1))
	var ok: bool = _damage == _gun.damage \
		and int(w.get("mag", 0)) == _gun.mag_size \
		and absf(1.0 / float(w.get("rate", 1.0)) - _gun.interval) < 0.001 \
		and _gun.ammo == _gun.mag_size
	print("GUN 数值来自内容：%s（伤害 %d / 弹匣 %d / 间隔 %.3f 秒 / 开局满弹 %s）"
		% ["是" if ok else "不是", _gun.damage, _gun.mag_size, _gun.interval,
			"是" if _gun.ammo == _gun.mag_size else "不是"])
	return ok


## 把一只会走的东西摆到正前方 3 米并冻住。
## 不去转视角、不去猜准星对着谁 —— 那条路会在"怪正在走"上失败，
## 而失败的是时序而不是枪。
func _stage_target() -> void:
	var bodies: Array = _main._world.bodies
	if bodies.is_empty():
		print("GUN 世界里没有刚体，无法布置靶子")
		return
	_bodies_before = bodies.size()
	# 挑有血量的那个：枪的链路只对"会疼的东西"有意义。
	for rb in bodies:
		var comps: Dictionary = _main.pack.components_of(
			String((rb as Node).get_meta("content_id", "")))
		if not comps.has("health"):
			continue
		_rb = rb as RigidBody3D
		_hp_before = _hp_of(_rb, comps)
		break
	if _rb == null:
		print("GUN 世界里没有带 health 的刚体")
		return
	_rb.freeze = true
	_rb.global_position = _main._player.global_position + Vector3(0.0, 0.0, -3.0)
	_rb.linear_velocity = Vector3.ZERO
	print("GUN 靶子：%s，血量 %d，摆在正前方 3 米"
		% [_rb.get_meta("content_id", ""), _hp_before])


func _one_shot() -> void:
	if _gun == null:
		return
	# 先快进一秒清掉上一发的冷却 —— 否则这一枪根本不会响，
	# 而"没响"看起来和"没打中"一模一样（第一版就这么误判过：
	# 第二枪其实没出膛，探针却以为是打歪了）。
	# 快进时扳机是松的，所以不会顺手打出一发。
	_gun.tick(1.0)
	# 走真实输入路径：扳机 → tick → 开火。直接调 `_fire()` 就绕过了
	# 射速与空弹匣的守卫，而那两条正是这把枪的规矩。
	_gun.trigger(true)
	_gun.tick(0.001)
	_gun.trigger(false)


func _check_hit() -> void:
	if _rb == null or not is_instance_valid(_rb):
		return
	var hp := _hp(_rb)
	_hit_ok = hp == _hp_before - _damage
	print("GUN 打中会疼：血量 %d → %d（期望 -%d：%s）"
		% [_hp_before, hp, _damage, "是" if _hit_ok else "不是"])


func _check_kill() -> void:
	# 不能写成 `if _rb == null: return`：对象被释放之后，那个引用在 Godot 里
	# **就等于 null**，于是这条检查会在"打死了"这个最该庆祝的时刻直接返回，
	# 打印都不给一句。第一版就是这样，结果看起来像"没打死"。
	var gone: bool = _rb == null or not is_instance_valid(_rb) \
		or not _main._world.bodies.has(_rb)
	var kills := int(_vitals.kills) if _vitals != null else 0
	_kill_ok = gone and kills > 0
	print("GUN 打死会记：尸身%s，击杀数 %d，刚体 %d → %d（%s）"
		% ["离场" if gone else "还在", kills, _bodies_before, _main._world.bodies.size(),
			"是" if _kill_ok else "不是"])


## 弹匣打空、换弹、又是满的。
##
## 快进用 `tick(big_dt)` 而不是等：一条断言等 3.3 秒，整套验收就多 3.3 秒，
## 而"等真实时间"在慢机器上会变成随机失败。
func _check_ammo() -> void:
	if _gun == null:
		return
	# 先把弹匣清到 1，再打一发，走"最后一发"这条边。
	_gun.tick(1.0)
	_gun.ammo = 1
	_gun.trigger(true)
	_gun.tick(0.001)
	_gun.trigger(false)
	var empty: bool = _gun.ammo == 0
	# 空弹匣再扣扳机：必须**打不出子弹**（宁可什么都不发生，也不能有无限子弹）。
	# 这里比的是"开了几枪"而不是 `ammo == 0` —— 因为 tick 会顺手触发换弹，
	# 那一瞬间的弹匣状态取决于自动换弹走到哪一步，拿它当断言会测到实现细节。
	_gun.tick(1.0)
	var shots_before: int = _gun.shots
	_gun.trigger(true)
	_gun.tick(0.001)
	_gun.trigger(false)
	var no_bullet: bool = _gun.shots == shots_before
	# 上面那一下已经让它进入换弹。等换弹时间过完，弹匣应该又满了。
	_gun.tick(_gun.reload_time + 0.05)
	var refilled: bool = _gun.ammo == _gun.mag_size
	_ammo_ok = empty and no_bullet and refilled
	print("GUN 会打空：打到 0 %s / 空时没子弹 %s / 自己装填 %s（%d/%d）"
		% ["是" if empty else "不是", "是" if no_bullet else "不是",
			"是" if refilled else "不是", _gun.ammo, _gun.mag_size])


## 后坐：抬起是真的，回来也是真的。
##
## 只验"抬起了"不够 —— 只抬不回的症状是"打一梭子之后准星永久偏高"，
## 而那在单发探针里完全看不出来。
func _check_recoil() -> void:
	if _gun == null:
		return
	var view = _main._player._view
	# 先把冷却和后坐都清干净，再打一枪 —— 否则读到的是上一轮的残留。
	_gun.tick(1.0)
	var before := float(view._recoil_pitch)
	_gun.trigger(true)
	_gun.tick(0.001)
	_gun.trigger(false)
	var up := float(view._recoil_pitch)
	# 快进一秒：RECOIL_RETURN 8/s 下应该基本归位。
	for i in 60:
		view.tick(1.0 / 60.0)
	var back := absf(float(view._recoil_pitch))
	_recoil_ok = up > before + 0.001 and back < 0.02
	print("GUN 后坐会回：抬头 %.3f → %.3f 弧度，一秒后剩 %.4f（%s）"
		% [before, up, back, "是" if _recoil_ok else "不是"])


## 视图模型真的装上了吗 —— 而且三段动画都在。
##
## 这条守的不是"模型好看"，是"美术换了文件之后，代码还认得它"。
## 之前的枪是一根没有动画的网格；现在换成了带骨骼的 AKM，
## 如果动画名改了、骨架没了、或者模型悄悄加载失败，枪会变成
## 一把静止的模型（甚至隐形），而"开火/换弹全绿"的旧断言一个都不会红。
func _check_view_anim() -> void:
	if _gun == null or _gun._view == null:
		return
	var v = _gun._view
	var loaded: bool = v.model_ok() and v.has_clip("idle") \
		and v.has_clip("shoot") and v.has_clip("reload")
	var shoot := false
	var reload := false
	if loaded:
		# 先清冷却，再走真实扳机路径打一发。
		_gun.tick(1.0)
		_gun.ammo = _gun.mag_size
		_gun.trigger(true)
		_gun.tick(0.001)
		_gun.trigger(false)
		shoot = v.current_clip().to_lower().ends_with("shoot")
		# 再把弹匣留一发，触发换弹。
		_gun.ammo = 1
		_gun.tick(1.0)
		_gun.reload()
		reload = v.current_clip().to_lower().ends_with("reload")
	_view_anim_ok = loaded and shoot and reload
	print("GUN 视图模型：装上 %s / 三段动画 %s / 开火播 Shoot %s / 换弹播 Reload %s（%s）"
		% ["是" if v.model_ok() else "不是",
			"是" if v.has_clip("idle") and v.has_clip("shoot") and v.has_clip("reload") else "不是",
			"是" if shoot else "不是", "是" if reload else "不是",
			"是" if _view_anim_ok else "不是"])


## 枪只在该看见它的时候出现。
func _check_view() -> void:
	if _gun == null or _gun._view == null:
		return
	var fp: bool = _main._player.is_first_person()
	var shown_fp: bool = (_gun._view as Node3D).visible
	_main._player.toggle_view()
	var shown_tp: bool = (_gun._view as Node3D).visible
	_main._player.toggle_view()
	_view_ok = fp and shown_fp and not shown_tp
	print("GUN 视角分离：第一人称看得到 %s / 第三人称看得到 %s（%s）"
		% ["是" if shown_fp else "不是", "是" if shown_tp else "不是",
			"是" if _view_ok else "不是"])


func _hp(rb: RigidBody3D) -> int:
	return int(rb.get_meta("hp", 0)) if rb.has_meta("hp") else _hp_before


func _hp_of(rb: RigidBody3D, comps: Dictionary) -> int:
	if rb.has_meta("hp"):
		return int(rb.get_meta("hp"))
	var h: Dictionary = comps.get("health", {})
	var raw := int(h.get("hp", 0))
	return raw if raw > 0 else maxi(1, int(h.get("max", 1)))


func _report() -> bool:
	var ok: bool = _content_ok and _hit_ok and _kill_ok and _ammo_ok \
		and _recoil_ok and _view_anim_ok and _view_ok
	print("GUN RESULT %s（数值来自内容 %s / 打中会疼 %s / 打死会记 %s / 会打空 %s / 后坐会回 %s / 视图动画 %s / 视角分离 %s）"
		% ["OK" if ok else "FAIL",
			"OK" if _content_ok else "FAIL",
			"OK" if _hit_ok else "FAIL",
			"OK" if _kill_ok else "FAIL",
			"OK" if _ammo_ok else "FAIL",
			"OK" if _recoil_ok else "FAIL",
			"OK" if _view_anim_ok else "FAIL",
			"OK" if _view_ok else "FAIL"])
	quit(0 if ok else 1)
	return ok
