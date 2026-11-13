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

const PACK_PATH := "res://content.pack.json"

## tick 的固定节拍。mod 拿不到每帧的机会 —— 那是帧率的敌人，
## 而且绝大多数 mod 想做的事（计时、巡视、状态更新）0.25 秒完全够。
const TICK_INTERVAL := 0.25

var pack
var plan
var bus
var api
var mods: Dictionary = {}

var _tick_acc := 0.0
var _frames := 0


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var selftest := "--selftest" in args

	pack = PACK_SCRIPT.new()
	if not pack.load_from(PACK_PATH):
		get_tree().quit(1)
		return
	print(pack.summary())

	plan = PLAN_SCRIPT.new()
	plan.build(pack)
	print(plan.summary())

	# 总线先而立：事件声明的唯一来源是契约快照，不是代码里的字符串。
	bus = BUS_SCRIPT.new(pack.schema.get("hooks", {}))
	api = API_SCRIPT.new(pack)
	bus.api = api
	print(bus.summary())

	# 加载 mod 必须在建世界之前。entity.spawn 从第一个刚体就开始发，
	# 晚一步加载就会漏掉整局的第一次生成，而且没有任何提示。
	mods = LOADER.load_all(pack, LOADER.content_root(), bus)
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
	print("行为：mod %d 个（%d 处挂载）/ 契约钩子 %d 个"
		% [mods.get("files", 0), bus.handler_count(), declared.size()])
	if ok:
		print("自检通过")
	return ok


## 场景组装：环境 + 主光 + 世界 + 玩家。全部是引擎的"怎么跑"。
func _setup_scene() -> void:
	add_child(_make_environment())
	add_child(_make_sun())

	var world = WORLD_SCRIPT.new()
	world.name = "world"
	world.bus = bus
	world.api = api
	# mod 造出来的东西挂在世界下，跟着世界一起释放。
	api.attach_world(world)
	add_child(world)
	world.realize(plan)

	var player = PLAYER_SCRIPT.new()
	player.name = "player"
	# 注入必须在入树之前：_ready 里要拿它们初始化抓取器。
	# 组件之间不互相伸手，依赖由装配层给。
	player.hooks = bus
	player.api = api
	add_child(player)
	player.position = _start_position(world)
	world.attach_camera(player.camera())

	# 世界就绪：刚体已全部生成，玩家已就位。mod 在这里做一次性初始化。
	bus.emit("world.ready", {
		"rooms": plan.rooms.size(),
		"entities": plan.instance_count(),
		"player_pos": player.global_position,
	})


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
