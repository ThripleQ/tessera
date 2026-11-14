extends RefCounted

## 系统调度。每帧按固定顺序跑一遍引擎自带的系统。
##
## 为什么要有这个壳：契约里 `system()` 早就声明了"系统有优先级、有读写集"，
## 但引擎一直**没有一个跑它的地方** —— 那是一句没有兑现的承诺。
## 装置先有，才轮得到开放（L4 让 mod 注册自己的系统时，插进的就是这张表）。
##
## 顺序就是优先级，而且顺序必须是确定的：
##   locomotion  先决定"想去哪儿"并写速度
##   vitals      再结算这一帧受的伤、回血、死亡、掉落
## 反过来的话，一个东西会在同一帧里"先死掉再走出一步"。
##
## 两个系统**不许互相认识**，只通过组件交流（契约 `check_system_order` 那条规则）。
## 所以 locomotion 不知道血量的存在，vitals 不知道移动的存在 ——
## 它们各自只读自己那几个组件。

const LOCOMOTION = preload("res://scripts/systems/locomotion.gd")
const VITALS = preload("res://scripts/systems/vitals.gd")

var world = null
var player = null
var api = null
var bus = null
var pack = null

var _systems: Array = []
## 给探针看：这一帧跑了几个系统。少了它，"系统根本没跑"会一直是绿的。
var frames := 0


func setup(w, p, a, b, pk) -> void:
	world = w
	player = p
	api = a
	bus = b
	pack = pk

	var loco = LOCOMOTION.new()
	loco.setup(world, player, pack)
	var vit = VITALS.new()
	vit.setup(world, api, bus, pack)
	_systems = [loco, vit]


func step(dt: float) -> void:
	frames += 1
	for s in _systems:
		s.step(dt)


func summary() -> String:
	var names: Array[String] = []
	for s in _systems:
		names.append(String(s.system_name))
	return "系统：%d 个（%s）· 已跑 %d 帧" % [_systems.size(), ", ".join(names), frames]
