extends RefCounted

## 系统调度。引擎自带系统与 mod 声明的系统跑在同一张有序表里。
##
## 引擎侧的顺序就是优先级，而且必须是确定的：
##   locomotion  先决定"想去哪儿"并写速度
##   vitals      再结算这一帧受的伤、回血、死亡、掉落
## 反过来的话，一个东西会在同一帧里"先死掉再走出一步"。
##
## L4 的 mod 系统从 priority=100 起：引擎自带规则先跑完，再按
## (priority, id) 的确定顺序跑外部规则。它们拿到的不是节点，
## 而是 system_api.gd 那个只认 handle 与组件字段的上下文（ADR 0011）。
##
## 两个系统**不许互相认识**，只通过组件交流（契约 `check_system_order` 那条规则）。
## 所以 locomotion 不知道血量的存在，vitals 不知道移动的存在 ——
## 它们各自只读自己那几个组件。

const LOCOMOTION = preload("res://scripts/systems/locomotion.gd")
const VITALS = preload("res://scripts/systems/vitals.gd")
const SYSTEM_API = preload("res://scripts/mods/system_api.gd")
const EXTENSION_STATE = preload("res://scripts/mods/extension_state.gd")

var world = null
var player = null
var api = null
var bus = null
var pack = null

var _systems: Array = []
var _mod_systems: Array[Dictionary] = []
var _state = null
## 血量系统单独留一份引用：枪要往它身上递"这一发打中了谁"。
## 走的是和装配层同样的口子（main 把 `vitals()` 交给玩家），
## 而不是让枪自己去 `_systems` 里翻 —— 数组的顺序不该成为接口。
var _vitals = null
## 给探针看：每个 mod 系统自己的上下文。引擎运行时不会把它交给别人。
var contexts: Array = []
## 给探针看：这一帧跑了几个系统。少了它，"系统根本没跑"会一直是绿的。
var frames := 0


func setup(w, p, a, b, pk, mod_systems: Array) -> void:
	world = w
	player = p
	api = a
	bus = b
	pack = pk

	var loco = LOCOMOTION.new()
	loco.setup(world, player, pack)
	var vit = VITALS.new()
	vit.setup(world, api, bus, pack)
	_vitals = vit
	_systems = [loco, vit]

	_state = EXTENSION_STATE.new()
	var by_id: Dictionary = {}
	for raw_entry in mod_systems:
		if raw_entry is Dictionary:
			by_id[String((raw_entry as Dictionary).get("id", ""))] = raw_entry

	var ext_section: Dictionary = pack.schema.get("extensions", {})
	var specs: Dictionary = ext_section.get("systems", {})
	for item in _ordered_specs(specs):
		var sid := String(item["id"])
		var spec: Dictionary = item["spec"]
		if not by_id.has(sid):
			push_error("系统 `%s` 在 schema 里但没有编译出实例" % sid)
			continue
		var entry: Dictionary = by_id[sid]
		var ctx = SYSTEM_API.new()
		ctx.setup(spec, pack, api, _state)
		contexts.append(ctx)
		_mod_systems.append({
			"id": sid,
			"period": float(spec.get("period", 0.25)),
			"acc": 0.0,
			"ctx": ctx,
			"inst": entry.get("instance", null),
		})


## 按 (priority, id) 排序。不用 lambda：无头模式下少一类解析差异，
## 而且字典遍历顺序不保证，顺序靠猜的规则迟早会在两台机器上不一样。
static func _ordered_specs(specs: Dictionary) -> Array[Dictionary]:
	var ids: Array = specs.keys()
	ids.sort()
	var out: Array[Dictionary] = []
	for sid in ids:
		var spec: Dictionary = specs.get(sid, {})
		var item: Dictionary = {
			"id": String(sid),
			"priority": int(spec.get("priority", 0)),
			"spec": spec,
		}
		var inserted := false
		for i in out.size():
			var other: Dictionary = out[i]
			var before := int(item["priority"]) < int(other["priority"])
			if int(item["priority"]) == int(other["priority"]):
				before = String(item["id"]) < String(other["id"])
			if before:
				out.insert(i, item)
				inserted = true
				break
		if not inserted:
			out.append(item)
	return out


func step(dt: float) -> void:
	frames += 1
	for s in _systems:
		s.step(dt)
	if _state != null:
		_state.prune(api)

	for i in _mod_systems.size():
		var e: Dictionary = _mod_systems[i]
		var period := float(e["period"])
		var acc := float(e["acc"]) + dt
		if acc < period:
			e["acc"] = acc
			_mod_systems[i] = e
			continue
		# 一帧最多补一次节拍。掉帧时故意不追补一串：
		# 那会让卡顿变成「规则突然跑十遍」，把卡顿放大成雪崩。
		if acc > period * 2.0:
			acc = 0.0
		else:
			acc -= period
		e["acc"] = acc
		var ctx = e["ctx"]
		ctx.dt = period
		ctx.frame = frames
		var inst = e["inst"]
		if inst != null and inst.has_method("step"):
			inst.call("step", ctx, api)
		_mod_systems[i] = e


func extension_systems_count() -> int:
	return _mod_systems.size()


## 血量系统。给 HUD 读击杀数、给枪递伤害 —— 两者都由装配层转手。
func vitals():
	return _vitals


## 给探针读「这个系统到底写没写进自定义状态」，不是给 mod 的接口。
func extension_value(handle: int, component: String, field: String):
	if _state == null:
		return null
	return _state.value(handle, component, field)


func summary() -> String:
	var names: Array[String] = []
	for s in _systems:
		names.append(String(s.system_name))
	for e in _mod_systems:
		names.append(String(e["id"]))
	return "系统：%d 个引擎 + %d 个 mod（%s）· 已跑 %d 帧" \
		% [_systems.size(), _mod_systems.size(), ", ".join(names), frames]
