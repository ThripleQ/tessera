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

const PACK_PATH := "res://content.pack.json"

var pack
var plan


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

	if selftest:
		var ok: bool = _selftest()
		get_tree().quit(0 if ok else 1)
		return

	_setup_scene()


func _selftest() -> bool:
	var ok := true

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
	if ok:
		print("自检通过")
	return ok


## 场景组装：环境 + 主光 + 世界 + 玩家。全部是引擎的"怎么跑"。
func _setup_scene() -> void:
	add_child(_make_environment())
	add_child(_make_sun())

	var world = WORLD_SCRIPT.new()
	world.name = "world"
	add_child(world)
	world.realize(plan)

	var player = PLAYER_SCRIPT.new()
	player.name = "player"
	add_child(player)
	player.position = _start_position(world)
	world.attach_camera(player.camera())


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
