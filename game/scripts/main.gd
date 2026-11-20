extends Node3D

## 入口。只做组装，不写业务逻辑（见 AGENTS.md 铁律 3）。
## 无头自检：godot --headless --path game -- --selftest
##
## 用 preload 而不是 class_name：全局类需要编辑器导入一遍才注册，
## 而 CI 里的无头模式没跑过编辑器。preload 不依赖任何缓存。
##
## 组装顺序：Pack（读数据）→ Plan（排世界）→ WorldRoot（建节点）→ Player（能玩）。
## 自检只走到 Plan，一个节点都不建。

const PACK_SCRIPT = preload("res://scripts/content/pack.gd")
const PLAN_SCRIPT = preload("res://scripts/world/plan.gd")
const WORLD_SCRIPT = preload("res://scripts/world/world_root.gd")
const PLAYER_SCRIPT = preload("res://scripts/player/player.gd")
const BUS_SCRIPT = preload("res://scripts/hooks/bus.gd")
const API_SCRIPT = preload("res://scripts/hooks/api.gd")
const LOADER = preload("res://scripts/mods/loader.gd")
const REGISTRY = preload("res://scripts/mods/registry.gd")
const SAVE = preload("res://scripts/save/store.gd")
const SPAWN_MENU = preload("res://scripts/ui/spawn_menu.gd")
const RETICLE = preload("res://scripts/ui/reticle.gd")
const SYSTEMS = preload("res://scripts/systems/runner.gd")
const ASSETS = preload("res://scripts/world/assets.gd")
const CHARACTER_ASSETS = preload("res://scripts/world/character_assets.gd")
const SELFTEST = preload("res://scripts/dev/selftest.gd")

const PACK_PATH := "res://content.pack.json"

## tick 的固定节拍。mod 拿不到每帧的机会 —— 那是帧率的敌人，
## 而且绝大多数 mod 想做的事（计时、巡视、状态更新）0.25 秒完全够。
const TICK_INTERVAL := 0.25

var pack
var plan
var bus
var api
var mods: Dictionary = {}
## 已合并进来的 mod 单元，交给 loader 找脚本。
var mod_units: Array[Dictionary] = []
## 基础内容里带可执行代码的实体数（kind="script" / kind="system"）。
## 必须为 0：基础内容永远被信任，它一旦能带代码，就等于有一条通道
## 绕过 mod 的授权闸门。
var base_scripts := 0
## 被授权闸门挡下的 mod 数。自检里必须为 0 —— 否则"行为开放"这条通道
## 在这一轮里根本没被验证到，而验收照样是绿的。
var mod_blocked := 0

var _tick_acc := 0.0
var _frames := 0
var _world = null
var _player = null
## 系统层。move / ai / health / loot 由它每帧执行 ——
## 在此之前那些组件是死数据：菜单里的骨行者放下去是个雕像。
var _systems = null


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var selftest := "--selftest" in args

	pack = PACK_SCRIPT.new()
	if not pack.load_from(PACK_PATH):
		get_tree().quit(1)
		return
	print(pack.summary())
	# L3 的 script 与 L4 的 system 都是可执行代码。基础内容永远被信任，
	# 它一旦能带任一种，就等于有一条绕过 mod 授权闸门的通道。
	base_scripts = pack.ids_of_kind("script").size() + pack.ids_of_kind("system").size()

	# mod 必须合并进 pack 之后再排世界，否则新内容根本不会出现在世界里。
	_mount_mods(args)

	# 资源覆盖必须在排世界之前配置：plan 要问三角形数，world 要问几何。
	# 这里只喂**已启用**的 mod —— 未授权的 mod 连外貌也不该生效，
	# 授权闸门要么全开要么全关，半开等于绕过去。
	ASSETS.configure(mod_units, pack)
	print(ASSETS.summary())
	# 角色是另一层资产（带动画的树），摘要分开打印 ——
	# 玩家换成什么、有几个片段，开局第一屏就该看得见。
	print(CHARACTER_ASSETS.character_summary())

	plan = PLAN_SCRIPT.new()
	plan.build(pack)
	print(plan.summary())

	# 总线先而立：事件声明的唯一来源是契约快照，不是代码里的字符串。
	bus = BUS_SCRIPT.new(pack.schema.get("hooks", {}))
	api = API_SCRIPT.new(pack)
	bus.api = api
	print(bus.summary())

	# 加载脚本必须在建世界之前。entity.spawn 从第一个刚体就开始发，
	# 晚一步加载就会漏掉整局的第一次生成，而且没有任何提示。
	mods = LOADER.load_all(mod_units, bus)
	for line in mods["loaded"]:
		print("mod 载入：%s" % line)
	for e in mods["errors"]:
		printerr("mod 加载失败：%s" % e)
	print("mod 系统：编译 %d 个（交给系统调度器）" % (mods.get("systems", []) as Array).size())
	print(bus.summary())

	if selftest:
		# 自检住在自己的域里：它怀疑的是"拼起来的东西对不对"，
		# 而不是"怎么拼"。混在装配代码里，最典型的退化是自检迁就实现。
		var ok: bool = SELFTEST.run(self)
		get_tree().quit(0 if ok else 1)
		return

	_setup_scene()


## 发现 → 授权 → 合并。三步都"先看清楚，再动手"。
##
## 合并放在这里而不是 registry 里，是因为它要动 pack 对象 ——
## registry 只回答"谁能进来"，不该拥有修改世界的权力。
func _mount_mods(args: PackedStringArray) -> void:
	var found := REGISTRY.discover(LOADER.search_paths())
	_apply_trust(args, found["candidates"])

	var resolved := REGISTRY.resolve(found, REGISTRY.load_settings())
	for e in resolved["errors"]:
		printerr("mod 扫描失败：%s" % e)
	for w in resolved["warnings"]:
		print("mod 提示：%s" % w)

	for cand in resolved["blocked"]:
		printerr("mod `%s` 未授权：它带可执行代码，而 Godot 没有 GDScript 沙箱（ADR 0003）。"
			% cand["id"])
		printerr("  信任它就跑一次： ./run.sh --trust=%s" % cand["id"])

	var units: Array[Dictionary] = []
	for cand in resolved["enabled"]:
		# 扩展声明必须先并进 schema，再校验内容 —— 否则 mod 自带的
		# `[components.<新组件>]` 会被当成「契约里没有的组件」。
		var ext: Dictionary = cand.get("extensions", {})
		var problems: Array[String] = pack.apply_extension(ext, String(cand["id"]))
		problems.append_array(pack.validate_entities(cand["entities"]))
		if not problems.is_empty():
			for p in problems:
				printerr("mod `%s` 被拒绝：%s" % [cand["id"], p])
			continue
		var merged: Dictionary = pack.merge_entities(cand["entities"])
		var overwritten: Array = merged["overwritten"]
		var note := "%s[%s] %d 条" % [cand["id"], cand["level"], merged["merged"]]
		var ext_comps: Dictionary = ext.get("components", {})
		var ext_systems: Dictionary = ext.get("systems", {})
		if not ext_comps.is_empty() or not ext_systems.is_empty():
			note += "，扩展 %d 组件 / %d 系统" % [ext_comps.size(), ext_systems.size()]
		if not overwritten.is_empty():
			note += "，覆写 %d 条（%s）" % [overwritten.size(), ", ".join(overwritten)]
		print("mod 合并：%s" % note)
		units.append(cand)

	mod_units = units
	mod_blocked = resolved["blocked"].size()
	print(REGISTRY.describe(resolved))


## 显式授权。没有 UI 之前，命令行就是那道开关 —— 而且它比 UI 更诚实：
## 玩家必须自己敲出这个 mod 的 id，不能靠一路点"下一步"过去。
func _apply_trust(args: PackedStringArray, candidates: Array) -> void:
	var ids: Array[String] = []
	for a in args:
		var arg := String(a)
		if not arg.begins_with("--trust="):
			continue
		var id := arg.trim_prefix("--trust=")
		if id == "all":
			# 只在明说的情况下才全信任，而且照样逐个记进名单 ——
			# 下次不给这个参数时，授权依然有效，因为它们是具体的 id。
			for c in candidates:
				if c["level"] == "script":
					ids.append(String(c["id"]))
			continue
		var hit := false
		for c in candidates:
			if String(c["id"]) == id:
				hit = true
		if not hit:
			printerr("--trust=%s：没有这个 mod（现有：%s）"
				% [id, ", ".join(_mod_ids(candidates))])
			continue
		ids.append(id)

	if ids.is_empty():
		return
	if REGISTRY.trust(ids):
		print("已授权：%s（记在 %s，下次不用再给这个参数）"
			% [", ".join(ids), REGISTRY.SETTINGS_PATH])


func _mod_ids(candidates: Array) -> Array[String]:
	var out: Array[String] = []
	for c in candidates:
		out.append(String(c["id"]))
	return out


## 场景组装：环境 + 主光 + 世界 + 玩家。全部是引擎的"怎么跑"。
func _setup_scene() -> void:
	get_tree().auto_accept_quit = false
	add_child(_make_environment())
	add_child(_make_sun())

	_world = WORLD_SCRIPT.new()
	_world.name = "world"
	_world.bus = bus
	_world.api = api
	# mod 造出来的东西挂在世界下，跟着世界一起释放。
	api.attach_world(_world)
	add_child(_world)
	_world.realize(plan)

	_player = PLAYER_SCRIPT.new()
	_player.name = "player"
	# 注入必须在入树之前：_ready 里要拿它们初始化手。
	# 组件之间互相不伸手，依赖由装配层给。
	_player.hooks = bus
	_player.api = api
	_player.world = _world
	add_child(_player)
	_player.position = _start_position(_world)
	_world.attach_camera(_player.camera())

	# 系统层在世界和玩家都就位之后才能跑：它要读 world.bodies，
	# 而那个数组在 realize 之后才有人。晚一帧启动没关系，缺了它全盘皆输。
	_systems = SYSTEMS.new()
	_systems.setup(_world, _player, api, bus, pack, mods.get("systems", []))

	# 菜单要在玩家之后建：它要接管玩家输入。
	var menu = SPAWN_MENU.new()
	menu.name = "spawn_menu"
	menu.pack = pack
	menu.api = api
	menu.player = _player
	menu.bag = _player.bag()
	# 背包要认识内容：堆叠上限和价值是内容定义的（pickup 组件），
	# 引擎不写死数值。必须在读档之前接上 —— 读档要按上限压回手改过的存档。
	_player.bag().pack = pack
	add_child(menu)
	# 收东西的反馈走信号，不让玩家直接持有 UI ——
	# UI 依赖玩家（要读位置），玩家再依赖 UI 就绕成了环。
	_player.collected.connect(menu.on_collected)

	# 准星是手那条射线的显示。它挂在 main 而不是 world 下：
	# 它不是世界的一部分（不进存档、不参与物理），只是玩家看见的一个指示。
	var reticle = RETICLE.new()
	reticle.name = "reticle"
	reticle.hands = _player.hands()
	add_child(reticle)

	# 读档必须在世界和玩家都已就位之后：它要替换整个世界里的刚体，
	# 并把玩家挪回上次站的地方。
	if "--fresh" in OS.get_cmdline_user_args():
		print("跳过读档（--fresh）")
	else:
		_resume()

	# 世界就绪：刚体已全部生成，玩家已就位。mod 在这里做一次性初始化。
	bus.emit("world.ready", {
		"rooms": plan.rooms.size(),
		"entities": plan.instance_count(),
		"player_pos": _player.global_position,
	})


## 读档。读不出来时**不能**当成"没有存档"——那会让玩家以为世界丢了，
## 而实际上只是这一次读不进来。两者对玩家是完全不同的两件事。
func _resume() -> void:
	if not SAVE.exists():
		return
	var save := SAVE.read()
	if save.is_empty():
		printerr("存档读不出来：%s —— 这次从头开始（原文件没动）" % SAVE.path())
		return
	var r: Dictionary = SAVE.apply(save, _world, _player, pack)
	var err := String(r.get("error", ""))
	if not err.is_empty():
		printerr("读档失败：%s" % err)
		return
	var missing: Array = r["missing"]
	var line := "读档：恢复 %d 个刚体 + %d 个静态物（清掉 %d 个），背包 %d 件" \
		% [r["spawned"], r["placed"], r["cleared"], r.get("carried", 0)]
	if not missing.is_empty():
		# 内容不在了（mod 被卸载、原型改名）。玩家有权知道自己的东西为什么少了。
		line += "  —— %d 种内容找不到，已跳过：%s" % [missing.size(), ", ".join(missing)]
	print(line)


func _save_now(quiet: bool) -> void:
	if _world == null or _player == null:
		return
	var save := SAVE.collect(_world, _player)
	if not SAVE.write(save):
		return
	if not quiet:
		print("已保存：%d 个刚体 + %d 个静态物 + 背包 %d 件 -> %s"
			% [(save["bodies"] as Array).size(), (save["props"] as Array).size(),
				(save["bag"] as Array).size(), SAVE.path()])


## F5 存、F9 读。手动存档先于自动存档存在，理由很实在：
## 调试时要能"回到刚才那一刻"，自动存档给不了这个。
func _input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	match (event as InputEventKey).physical_keycode:
		KEY_F5:
			_save_now(false)
		KEY_F9:
			_resume()


## 关窗口时保存。这是玩家唯一一定会做的"结束动作"——
## 没有它，"关了再开东西就没了"会让整个沙盒看起来是个玩具。
func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		_save_now(true)
		get_tree().quit()



## 系统层挂在物理帧上，不是渲染帧：移动要写速度、伤害来自撞击，
## 两件事都发生在物理步里。挂在渲染帧上的话，帧率一变行为就变。
func _physics_process(delta: float) -> void:
	if _systems != null:
		_systems.step(delta)


## 固定节拍的 tick。用累加器而不是"每 N 帧"，因为帧率会变，节拍不该跟着变。
func _process(delta: float) -> void:
	if bus == null:
		return
	_tick_acc += delta
	while _tick_acc >= TICK_INTERVAL:
		_tick_acc -= TICK_INTERVAL
		_frames += 1
		bus.emit("tick", {"dt": TICK_INTERVAL, "frame": _frames})


## 卡通渲染要的是"天光充足、阴影明确"，不是写实的那种暗调氛围。
## 背景用天空蓝而不是黑，是因为大片暗背景会把角色的暗部染色吃掉，
## 人物的剪影就糊在背景里了。
func _make_environment() -> WorldEnvironment:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.52, 0.72, 0.92)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.66, 0.78, 0.98)
	# 环境光必须压低：卡通渲染的暗部是由色阶的 shade_tint 决定的，
	# 环境光一大就把暗部冲淡，色阶就没了，画面回到"平淡的写实"。
	env.ambient_light_energy = 0.26
	env.fog_enabled = true
	env.fog_light_color = Color(0.60, 0.74, 0.90)
	env.fog_density = 0.0022

	var node := WorldEnvironment.new()
	node.name = "environment"
	node.environment = env
	return node


## 主光开阴影：卡通渲染里阴影是"硬边"的另一半，没有它，所有东西都像贴纸。
## Compatibility 下阴影只有一张深度图，比 Forward+ 便宜得多，这是选它的理由之一。
func _make_sun() -> DirectionalLight3D:
	var sun := DirectionalLight3D.new()
	sun.name = "sun"
	sun.rotation_degrees = Vector3(-48.0, -36.0, 0.0)
	# 3.0 看起来很高，但 light() 里除以了 PI，净系数约 0.95 ——
	# 卡通渲染要让亮面直接显示 albedo 原色，所以这个值不是"过亮"。
	sun.light_energy = 3.0
	sun.light_color = Color(1.0, 0.97, 0.90)
	sun.shadow_enabled = true
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
	sun.directional_shadow_max_distance = 60.0
	return sun


## 开场站在第一个房间靠后的位置，面朝房间中心 —— 第一眼就能看见内容。
func _start_position(world) -> Vector3:
	var b: AABB = world.start_bounds()
	var c := b.get_center()
	return Vector3(c.x, 0.3, c.z + b.size.z * 0.30)
