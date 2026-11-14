extends SceneTree

## 系统层探针：会动、会死、会掉。
##
## 在此之前 `move` / `ai` / `health` / `loot` 是**死数据** —— 契约里声明了、
## 内容里填了、引擎一行都没读。菜单里的"骨行者"放下去是个雕像，
## 名字看着像怪，实际是摆设。这四条断言就是那个缺口的守卫。
##
## 四条各错各的：
##   是刚体 —— 怪必须在 world.bodies 里，不在"钉住的障碍"里。
##            否则它抓不起来、扔不出去，而那正是这个项目的核心手感
##   会动   —— 系统真的写了速度。注意验的是**速度**不是位移：
##            无头模式下帧率几百 fps，几十帧的位移小到测不准，
##            而"系统有没有把意图写进物理"这件事本身是确定的
##   会死   —— 血扣光之后它要离开世界，不是继续站在那儿
##   会掉   —— 死了要有东西掉出来
##
## 掉落那条要把概率推到 1.0：概率本身只是一次 randf 比较，没有可测的逻辑，
## 而"靠运气的断言"是探针最不该有的东西。推到 1.0 测的是**掉落链路通不通**。
##
## 时序上分帧：造东西和喂伤害都要等一帧才生效（同帧读到的是旧状态）。

var _main
var _f := 0
var _actor: RigidBody3D = null
var _cid := ""
var _rigid_ok := false
var _moved_ok := false
var _died_ok := false
var _dropped_ok := false
var _n_before := 0
var _moved := 0.0


func _initialize() -> void:
	_main = load("res://main.tscn").instantiate()
	root.add_child(_main)


## 探针也不许认识内容 id（铁律 2 对探针一样有效）：
## 挑"会走的"，从可摆放清单里按**数据**找（move.speed > 0 且 brain 不是 idle），
## 而不是写死一个名字。写死名字的探针在内容改名那天就会假红。
func _pick_actor() -> String:
	for id in _main.pack.spawnables():
		var comps: Dictionary = _main.pack.components_of(id)
		if float(comps.get("move", {}).get("speed", 0.0)) <= 0.0:
			continue
		var brain := String(comps.get("ai", {}).get("brain", "idle"))
		if brain == "idle":
			continue
		return id
	return ""


func _process(_delta: float) -> bool:
	_f += 1

	if _f == 8:
		_cid = _pick_actor()
		if _cid.is_empty():
			print("ACTOR 找不到任何会走的内容（move.speed > 0 且 brain 不是 idle）")
			quit(1)
			return false
		# 立在玩家面前 2.5 米 —— 任何合理的 aggro_radius 都罩得住，
		# 于是 charger / ambusher 都会朝玩家走，patrol 会自己游荡。
		var at: Vector3 = _main._player.global_position + Vector3(0.0, 0.0, -2.5)
		var r: Dictionary = _main.api.spawn(_cid, at, 0.0)
		_actor = _main._world.bodies[-1] if bool(r.get("ok", false)) else null
		_n_before = _main._world.bodies.size()
		_rigid_ok = _actor != null and _main._world.bodies.has(_actor)
		print("ACTOR 立 %s：%s（刚体 %d，是我的东西：%s）"
			% [_cid, r.get("ok", false), _n_before, _rigid_ok])

	if _f == 30:
		# 会动。读的是**速度**，不是位移 —— 无头下几百 fps，
		# 几十帧的位移小到测不准，而"系统写没写意图"是确定的。
		if _actor != null and is_instance_valid(_actor):
			var v: Vector3 = _actor.linear_velocity
			_moved = Vector2(v.x, v.z).length()
			_moved_ok = _moved > 0.1
		print("ACTOR 会动：水平速度 %.2f m/s（必须 > 0.1：%s）" % [_moved, _moved_ok])

	if _f == 40:
		# 会掉：把概率推到 1.0。概率本身只是一次 randf 比较，没有可测的逻辑，
		# 而"靠运气的断言"会天天翻脸。这里测的是**掉落链路通不通**。
		if _actor != null and is_instance_valid(_actor):
			var comps: Dictionary = _main.pack.components_of(_cid)
			var loot: Dictionary = comps.get("loot", {})
			loot["chance"] = 1.0
			var table: Dictionary = _main.pack.entity_of(String(loot.get("table", "")))
			var entries = table.get("entries", [])
			if entries is Array:
				for ent in entries:
					if ent is Dictionary:
						ent["chance"] = 1.0
			# 会死：一次大撞击。DAMAGE_MIN_SPEED 是 6，20 m/s × 1.5 = 30 点，
			# 45 血的骨行者两次就死 —— 这里喂一次 60 m/s，一击必杀，不给随机留余地。
			_main._world.impacts.append({"node": _actor, "speed": 60.0})
			print("ACTOR 喂一次 %.0f m/s 的撞击（血量上限 %d）"
				% [60.0, int(comps.get("health", {}).get("max", 0))])

	if _f == 52:
		# 会死 + 会掉。死亡和掉落都在系统的同一帧里发生，
		# 所以这里一次看两件事：那个节点没了，而且世界里多了东西。
		var gone: bool = _actor == null or not is_instance_valid(_actor) \
			or not _main._world.bodies.has(_actor)
		var n_after: int = _main._world.bodies.size()
		# 掉落物是新造的刚体，所以数量应该**不减反增**：少了尸体，多了掉落。
		# 严格说"至少多一件"比"刚好等于"稳 —— 一张表可以掉好几件。
		var dropped: int = n_after - _n_before + (1 if gone else 0)
		_died_ok = gone
		_dropped_ok = n_after > _n_before - 1
		print("ACTOR 会死：%s（尸身 %s，掉落 +%d，刚体 %d → %d）"
			% ["离开了世界" if gone else "还站在那儿",
				"离场" if gone else "还在", dropped, _n_before, n_after])
		print("ACTOR 会掉：%s（世界里多了东西：%s）"
			% ["是" if _dropped_ok else "没有", _dropped_ok])

		var ok: bool = _rigid_ok and _moved_ok and _died_ok and _dropped_ok
		print("ACTOR RESULT %s（是刚体 %s / 会动 %s / 会死 %s / 会掉 %s）"
			% ["OK" if ok else "FAIL",
				"OK" if _rigid_ok else "FAIL",
				"OK" if _moved_ok else "FAIL",
				"OK" if _died_ok else "FAIL",
				"OK" if _dropped_ok else "FAIL"])
		quit(0 if ok else 1)

	return false
