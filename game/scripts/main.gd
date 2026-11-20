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
const MOUNT = preload("res://scripts/mods/mount.gd")
const SAVE = preload("res://scripts/save/store.gd")
const SPAWN_MENU = preload("res://scripts/ui/spawn_menu.gd")
const RETICLE = preload("res://scripts/ui/reticle.gd")
const CROSSHAIR = preload("res://scripts/ui/crosshair.gd")
const SYSTEMS = preload("res://scripts/systems/runner.gd")
const ASSETS = preload("res://scripts/world/assets.gd")
const CHARACTER_ASSETS = preload("res://scripts/world/character_assets.gd")
const SKYLIGHT = preload("res://scripts/world/skylight.gd")
const NPC = preload("res://scripts/player/npc.gd")
const GUN = preload("res://scripts/player/gun.gd")
const HUD = preload("res://scripts/ui/hud.gd")
const SELFTEST = preload("res://scripts/dev/selftest.gd")

const PACK_PATH := "res://content.pack.json"

## 世界里最多出现几个"别人"。见 `_add_cast()`。
const CAST_MAX := 4

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


## 发现 → 授权 → 合并，全在 `mods/mount.gd` 里。入口只接收结果 ——
## 装配顺序是入口的职责，判定规则不是。
func _mount_mods(args: PackedStringArray) -> void:
	var mounted := MOUNT.run(pack, args)
	mod_units = mounted["units"]
	mod_blocked = int(mounted["blocked"])


## 场景组装：天光 + 世界 + 人 + 玩家。全部是引擎的"怎么跑"。
func _setup_scene() -> void:
	get_tree().auto_accept_quit = false
	add_child(SKYLIGHT.environment())
	add_child(SKYLIGHT.sun())

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
	_add_cast()

	# 系统层在世界和玩家都就位之后才能跑：它要读 world.bodies，
	# 而那个数组在 realize 之后才有人。晚一帧启动没关系，缺了它全盘皆输。
	_systems = SYSTEMS.new()
	_systems.setup(_world, _player, api, bus, pack, mods.get("systems", []))

	# 枪必须在系统层之后：它往血量系统递伤害，而血量系统是系统层建的。
	# 也不能更早 —— 那就要把 vitals 变成"先建好再注入"，多一层没人需要的间接。
	_wire_gun()

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
	# 换角色的提示走同一条路：玩家发信号，装配层接给 UI，两方互不认识。
	_player.character_changed.connect(menu.on_character_changed)

	# 准星是手那条射线的显示。它挂在 main 而不是 world 下：
	# 它不是世界的一部分（不进存档、不参与物理），只是玩家看见的一个指示。
	var reticle = RETICLE.new()
	reticle.name = "reticle"
	reticle.hands = _player.hands()
	reticle.player = _player
	add_child(reticle)

	# 第一人称的准心。它和上面那个落点圈是两件事，见 crosshair.gd 开头。
	var cross = CROSSHAIR.new()
	cross.name = "crosshair"
	cross.player = _player
	add_child(cross)

	# 读档：**默认不读**。训练场每次打开都该是干净的 —— 上一局打剩的三只骷髅
	# 和一地掉落，会让"我打了多久、准不准"这件事没法比较。
	# 想接着上次玩就显式给 --resume；关窗口时的自动存档仍然在写。
	if "--resume" in OS.get_cmdline_user_args():
		_resume()
	else:
		print("干净开局（默认）。接着上次玩：./run.sh --resume")

	# 世界就绪：刚体已全部生成，玩家已就位。mod 在这里做一次性初始化。
	bus.emit("world.ready", {
		"rooms": plan.rooms.size(),
		"entities": plan.instance_count(),
		"player_pos": _player.global_position,
	})


## 给玩家一把枪，并把屏幕上的读数接上。
##
## 用哪把枪由内容决定：`kind = "weapon"` 的内容里按 id 排序取第一把，
## 命令行 `--weapon=<id>` 可以指定。引擎不认识 "rifle" 这个名字 ——
## 加一把新枪只需要写一个 TOML（铁律 1/2）。
func _wire_gun() -> void:
	var weapon := _pick_weapon()
	if weapon.is_empty():
		print("没有找到任何 weapon 内容 —— 这次没有枪")
		return
	var gun = GUN.new()
	# vitals 是系统层建的，这里只是把引用递过去 —— 枪不知道它住在哪。
	if not gun.setup(_player, _player.camera(), pack, weapon, _systems.vitals()):
		printerr("武器 `%s` 装不上，这次没有枪" % weapon)
		return
	_player.attach_gun(gun)
	print("手里的枪：%s（伤害 %d / 射速 %.1f 发秒 / 弹匣 %d / 射程 %.0f m）"
		% [weapon, gun.damage, 1.0 / gun.interval, gun.mag_size, gun.reach])

	var hud = HUD.new()
	hud.name = "hud"
	hud.gun = gun
	hud.vitals = _systems.vitals()
	add_child(hud)


## 挑一把枪。名单来自内容，不来自常量 —— 这一行就是"武器也是数据"。
func _pick_weapon() -> String:
	var ids: PackedStringArray = pack.ids_of_kind("weapon")
	if ids.is_empty():
		return ""
	for a in OS.get_cmdline_user_args():
		var arg := String(a)
		if not arg.begins_with("--weapon="):
			continue
		var want := arg.trim_prefix("--weapon=")
		if ids.has(want):
			return want
		printerr("--weapon=%s：内容里没有这把枪（现有：%s）" % [want, ", ".join(ids)])
	return String(ids[0])


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


## 世界里放几个"别人"。
##
## **按资产目录来**：目录里有几个角色就出场几个 —— 新丢一个 glb 进去不用改这里一行。
## 玩家自己用的那个排在外：同一个角色在眼前出现两次，人会以为那是自己的镜像。
##
## 摆位不写死坐标，从开场房间的尺寸算圆周半径。于是换一个房间、换一张地图，
## 他们自动挪到合适的位置上；半径也夹了上下限，小房间里不会挤成一根绳，
## 大房间里不会绕着墙根走。
##
## 上限 4 个：这一层是"世界里有人"，不是"人山人海的场景"。
## 真的要做人群，那是另一件事（合批、剔除、行为），不该顺手做掉。
func _add_cast() -> void:
	# 别人待在别的房间。训练场是打枪的地方，站着几个打不动的路人
	# 会挡住枪线，而"他们为什么不还手"是个回答不了的问题。
	var b: AABB = _world.cast_bounds()
	var center := Vector3(b.get_center().x, 0.0, b.get_center().z)
	var radius := clampf(minf(b.size.x, b.size.z) * 0.25, 1.8, 4.5)
	var room := Node3D.new()
	room.name = "cast"
	_world.add_child(room)
	var i := 0
	for id in CHARACTER_ASSETS.character_ids():
		if i >= CAST_MAX:
			break
		if String(id) == PLAYER_SCRIPT.CHARACTER_ID:
			continue
		var npc = NPC.new()
		npc.name = "npc_%s" % id
		# 入树之后才能 setup：里面要写 global_position。
		room.add_child(npc)
		npc.setup(String(id), center, radius, TAU * float(i) / 3.0)
		i += 1
	print("世界里有 %d 个别人（半径 %.1f m 绕圈）" % [i, radius])


## 开场站在第一个房间靠后的位置，面朝房间中心 —— 第一眼就能看见内容。
func _start_position(world) -> Vector3:
	var b: AABB = world.start_bounds()
	var c := b.get_center()
	return Vector3(c.x, 0.3, c.z + b.size.z * 0.30)
