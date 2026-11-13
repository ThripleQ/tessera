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
const MESH_LIB = preload("res://scripts/world/mesh_lib.gd")
const PLAYER_SCRIPT = preload("res://scripts/player/player.gd")
const BUS_SCRIPT = preload("res://scripts/hooks/bus.gd")
const API_SCRIPT = preload("res://scripts/hooks/api.gd")
const LOADER = preload("res://scripts/mods/loader.gd")
const REGISTRY = preload("res://scripts/mods/registry.gd")
const SAVE = preload("res://scripts/save/store.gd")

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
## 基础内容里带 kind="script" 的实体数。必须为 0：基础内容永远被信任，
## 它一旦能带脚本，就等于有一条通道绕过了 mod 的授权闸门。
var base_scripts := 0
## 被授权闸门挡下的 mod 数。自检里必须为 0 —— 否则"行为开放"这条通道
## 在这一轮里根本没被验证到，而验收照样是绿的。
var mod_blocked := 0

var _tick_acc := 0.0
var _frames := 0
var _world = null
var _player = null


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var selftest := "--selftest" in args

	pack = PACK_SCRIPT.new()
	if not pack.load_from(PACK_PATH):
		get_tree().quit(1)
		return
	print(pack.summary())
	base_scripts = pack.ids_of_kind("script").size()

	# mod 必须合并进 pack 之后再排世界，否则新内容根本不会出现在世界里。
	_mount_mods(args)

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
	print(bus.summary())

	if selftest:
		var ok: bool = _selftest()
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
		printerr("mod `%s` 未授权：它带脚本，而 Godot 没有 GDScript 沙箱（ADR 0003）。"
			% cand["id"])
		printerr("  信任它就跑一次： ./run.sh --trust=%s" % cand["id"])

	var units: Array[Dictionary] = []
	for cand in resolved["enabled"]:
		var problems: Array[String] = pack.validate_entities(cand["entities"])
		if not problems.is_empty():
			for p in problems:
				printerr("mod `%s` 被拒绝：%s" % [cand["id"], p])
			continue
		var merged: Dictionary = pack.merge_entities(cand["entities"])
		var overwritten: Array = merged["overwritten"]
		var note := "%s[%s] %d 条" % [cand["id"], cand["level"], merged["merged"]]
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


func _selftest() -> bool:
	var ok := true

	# 钩子：契约声明的 == 引擎真发的。
	# 只声明不发是撒谎（mod 挂了钩子永远等不到），只发不声明是绕过契约。
	# 这条检查的价值不在于今天，而在于以后有人加了钩子却忘了接线的那一刻。
	var declared := PackedStringArray(pack.schema.get("hooks", {}).keys())
	declared.sort()
	var emitted := PackedStringArray(BUS_SCRIPT.EMITTED)
	emitted.sort()
	if declared != emitted:
		printerr("自检失败：钩子声明与引擎发出不一致\n  契约：%s\n  引擎：%s"
			% [", ".join(declared), ", ".join(emitted)])
		ok = false

	# mod 编译失败必须在 CI 就暴露。玩家装了个坏 mod 当然会炸，
	# 但我们自己仓库里的 mod 挂了却一路绿灯，那才是灾难。
	for e in mods.get("errors", []):
		printerr("自检失败：mod 加载错误 —— %s" % e)
		ok = false

	# 带脚本的 mod 一个都没跑起来，说明验收没测到行为开放。
	# 这种"绿得毫无意义"的通过比红的更危险，所以必须当成失败。
	if mod_blocked > 0:
		printerr("自检失败：%d 个带脚本的 mod 未被授权，脚本通道没被验证到"
			% mod_blocked)
		printerr("  验收里应该显式授权：./check.sh 会给 --trust。见 docs/decisions/0008")
		ok = false

	# 基础内容不许带脚本：基础内容永远被信任（它在仓库里、随引擎发布），
	# 一旦它能带脚本，就存在一条绕过授权闸门的通道 —— 而且是最好用的那条。
	if base_scripts > 0:
		printerr("自检失败：基础内容里有 %d 条 kind=\"script\"。脚本必须来自 mod 目录" % base_scripts)
		ok = false

	# 边界校验：内容用到的每个组件，契约里必须声明过。
	# 编译期已经查过一遍，这里再查是防"旧 pack 配新引擎"这类错配 ——
	# 那种情况下编译期检查根本没跑过。
	var declared_comps := {}
	for c in pack.declared_components():
		declared_comps[c] = true
	for c in pack.used_components():
		if not declared_comps.has(c):
			printerr("自检失败：内容引用了契约里不存在的组件 `%s`" % c)
			ok = false

	# 契约里有这个网格，引擎就必须画得出来。缺一个都算失败 ——
	# 否则那个东西会静默地从世界里消失，没有任何人会发现。
	var declared_meshes: Dictionary = pack.schema.get("meshes", {})
	var missing := MESH_LIB.missing(PackedStringArray(declared_meshes.keys()))
	if not missing.is_empty():
		printerr("自检失败：契约里有这些网格但引擎没实现几何：%s" % ", ".join(missing))
		ok = false

	# 三角形数必须与实测一致。改了几何却忘了改契约，预算就会在无人察觉的情况下失真，
	# 而"预算失真"是这个项目最不能接受的一种错误 —— 它让人以为世界还装得下。
	for mesh_id in declared_meshes:
		var want := int(declared_meshes[mesh_id])
		var got: int = MESH_LIB.triangles_of(String(mesh_id))
		if want != got:
			printerr("自检失败：网格 `%s` 契约写 %d 三角形，引擎实测 %d" % [mesh_id, want, got])
			ok = false

	if plan.instance_count() <= 0:
		printerr("自检失败：世界是空的（房间填不出东西，检查 spawner 指向的原型）")
		ok = false

	# 每个房间都必须有地板，否则玩家走进去会直接掉进虚空。
	for room_id in plan.rooms:
		var fs: Vector2 = plan.rooms[room_id]["floor_size"]
		if fs.x <= 0.0 or fs.y <= 0.0:
			printerr("自检失败：房间 `%s` 没有地板尺寸，玩家会掉下去" % room_id)
			ok = false

	print("网格实现 %d / 契约 %d 种" % [MESH_LIB.implemented().size(), declared_meshes.size()])
	print("物理：刚体 %d / 障碍 %d / 地板 %d 块"
		% [plan.dynamic_count(), plan.solid_static_count(), plan.rooms.size()])
	print("行为：mod %d 个 / 脚本 %d 个 / 挂载 %d 处 / 契约钩子 %d 个"
		% [mod_units.size(), mods.get("files", 0), bus.handler_count(), declared.size()])
	if ok:
		print("自检通过")
	return ok


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
	# 注入必须在入树之前：_ready 里要拿它们初始化抓取器。
	# 组件之间互相不伸手，依赖由装配层给。
	_player.hooks = bus
	_player.api = api
	add_child(_player)
	_player.position = _start_position(_world)
	_world.attach_camera(_player.camera())

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
	var line := "读档：恢复 %d 个物体（清掉 %d 个）" % [r["spawned"], r["cleared"]]
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
		print("已保存：%d 个物体 -> %s" % [(save["bodies"] as Array).size(), SAVE.path()])


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
