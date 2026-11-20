extends RefCounted

## 生命、受伤、死亡、掉落。让 `health` / `loot` 从死数据变成真规则。
##
## 伤害来源只有一个：**撞击**。这个项目里没有"攻击力"这种抽象数值 ——
## 一个箱子以 8 m/s 砸中你就是会疼。这和"抓 / 放 / 堆 / 扔"是同一件事的
## 两面：能扔得出去，就要能砸出后果。所以伤害是物理的产物，不是数值系统的产物。
##
## 死了掉东西，掉什么由内容里的掉落表决定（`loot.table` → 一条 loot_table 内容）。
## 掉落**走 `api.spawn`**，和玩家手动放东西同一个通道、同一个预算。
## 后果是世界满了的时候掉不出来（东西直接消失）。这是刻意的：
## 两条造物通道意味着两个预算，而两个预算一定会一个紧一个松 ——
## 到时候"mod 的东西能无限放、玩家的不能"这类倒退就会出现。
##
## 它**不知道移动的存在**，locomotion 也不知道血量。两个系统只通过组件交流。

const system_name := "vitals"

## 受伤的撞击速度门槛。低于这个速度只是碰了一下，不算挨打。
## 门槛不能太低：怪物自己走路撞到箱子也会记一次撞击，太低会让它莫名其妙死掉。
const DAMAGE_MIN_SPEED := 6.0

## 速度 → 伤害的换算。8 m/s 砸上去 = 12 点，45 血的骨行者要砸四下。
const DAMAGE_PER_SPEED := 1.5

## 当前血量挂在身上（meta），不是存在这里。
## 理由：东西被删掉的时候血量要跟着消失，而存档不该存血量 ——
## 血量是内容的初始值加玩家的后果，重开一局就该重来。
const META_HP := "hp"

var world = null
var api = null
var bus = null
var pack = null

## 这一局死了几只。给 HUD 看，也给探针看 —— "会死"早就验过了，
## "死了几只有没有被记下来"是另一件事。
var kills := 0


func setup(w, a, b, pk) -> void:
	world = w
	api = a
	bus = b
	pack = pk


## 从**非撞击**来的伤害入口：枪的射线打中之后走这里。
##
## 为什么需要它：`step()` 只认 `world.impacts`（物理撞击），而子弹不是物理体 ——
## 它是一条射线。硬把射线塞进 impacts 会让"撞击"这个概念既指 8 m/s 的箱子，
## 又指一发光，而它们的速度、来源、过滤规则全不一样。
##
## 返回 `{ok, hp}`：ok=false 表示"这东西不会疼"（墙、地板、没血量的箱子）。
## 调用方据此决定准星要不要亮、计数要不要加 —— 引擎不替它判断"这是不是敌人"。
func damage(node, amount: int) -> Dictionary:
	if node == null or not is_instance_valid(node):
		return {"ok": false}
	if not (node is RigidBody3D):
		return {"ok": false}
	if amount <= 0:
		return {"ok": false}
	var rb := node as RigidBody3D
	var comps: Dictionary = pack.components_of(String(rb.get_meta("content_id", "")))
	if not comps.has("health"):
		return {"ok": false}
	_hurt(rb, amount)
	return {"ok": true, "hp": _hp_of(rb, comps)}


func step(dt: float) -> void:
	if world == null or pack == null:
		return

	for hit in world.impacts:
		if not (hit is Dictionary):
			continue
		var rb = hit.get("node", null)
		if rb == null or not is_instance_valid(rb):
			continue
		var spd := float(hit.get("speed", 0.0))
		if spd < DAMAGE_MIN_SPEED:
			continue
		_hurt(rb, int(round(spd * DAMAGE_PER_SPEED)))
	world.impacts.clear()

	# 先收集再删。迭代 `world.bodies` 的同时调 remove_thing 会改动那个数组，
	# 而那类 bug 的表现是"有时候漏掉一个"——最难查的一类。
	var dead: Array[RigidBody3D] = []
	for rb in world.bodies:
		if not is_instance_valid(rb):
			continue
		var comps: Dictionary = pack.components_of(String(rb.get_meta("content_id", "")))
		if not comps.has("health"):
			continue
		var regen := float(comps.get("health", {}).get("regen", 0.0))
		if regen > 0.0:
			# 每秒回血，按帧折算。不做成"每秒一跳"是因为
			# 那会让回血在帧率变化时忽快忽慢，而血量不该跟着帧率走。
			_heal(rb, regen * dt)
		# 没有 hp 记录 = 满血，而满血的东西不可能死。
		# 掉血的唯一来源是撞击（走 `_hurt`），它一定会写下这条记录。
		# 所以这里可以直接跳过 —— 省掉的是每只怪每帧一次 meta 查询
		# 加两次组件字典取值，而它们 99.9% 的帧都在回答"我还活着"。
		if not rb.has_meta(META_HP):
			continue
		if int(rb.get_meta(META_HP)) <= 0:
			dead.append(rb)
	for rb in dead:
		_die(rb)


func _hurt(rb: RigidBody3D, amount: int) -> void:
	if amount <= 0:
		return
	var comps: Dictionary = pack.components_of(String(rb.get_meta("content_id", "")))
	if not comps.has("health"):
		return
	var hp := _hp_of(rb, comps) - amount
	rb.set_meta(META_HP, hp)


func _heal(rb: RigidBody3D, amount: float) -> void:
	var comps: Dictionary = pack.components_of(String(rb.get_meta("content_id", "")))
	var mx := _max_of(comps)
	var hp := _hp_of(rb, comps)
	if hp >= mx:
		return
	rb.set_meta(META_HP, minf(float(hp) + amount, float(mx)))


## 死了：先掉东西，再离开世界。
##
## 顺序很重要。反过来的话掉落物的生成位置还没等算出来，那个节点就已经
## queue_free 了 —— 东西掉在原点，而日志显示一切正常。
func _die(rb: RigidBody3D) -> void:
	var cid := String(rb.get_meta("content_id", ""))
	var comps: Dictionary = pack.components_of(cid)
	var at: Vector3 = rb.global_position
	kills += 1
	_drop_loot(comps, at)
	world.remove_thing(rb)


## 掉落。每条独立掷点，所以 0 件、1 件、2 件都可能 ——
## 沙盒的乐趣是地上的东西**变多**，而不是每次刚好一件。
func _drop_loot(comps: Dictionary, at: Vector3) -> void:
	var loot: Dictionary = comps.get("loot", {})
	var table_id := String(loot.get("table", ""))
	if table_id.is_empty():
		return
	if randf() > float(loot.get("chance", 0.0)):
		return

	var table: Dictionary = pack.entity_of(table_id)
	var entries = table.get("entries", [])
	if not (entries is Array):
		return
	for ent in entries:
		if not (ent is Dictionary):
			continue
		if randf() > float(ent.get("chance", 0.0)):
			continue
		var drop_id := String(ent.get("id", ""))
		if drop_id.is_empty() or api == null:
			continue
		# 往上抬一点点再放，让它自己落下来。
		# 贴着地面生成的话，掉落物会和尸体的碰撞体叠在一起，
		# 物理一解算就把它弹飞到天上去。
		api.spawn(drop_id, at + Vector3(0.0, 0.4, 0.0), 0.0)


func _hp_of(rb: RigidBody3D, comps: Dictionary) -> int:
	if rb.has_meta(META_HP):
		return int(rb.get_meta(META_HP))
	# 开局血量：契约说 `hp = 0` 表示满血，所以 0 不是"零血"而是"没填"。
	var raw := int(comps.get("health", {}).get("hp", 0))
	var hp := raw if raw > 0 else _max_of(comps)
	rb.set_meta(META_HP, hp)
	return hp


func _max_of(comps: Dictionary) -> int:
	return maxi(1, int(comps.get("health", {}).get("max", 1)))
