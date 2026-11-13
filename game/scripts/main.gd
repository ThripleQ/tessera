extends Node3D

## 入口。只做组装，不写业务逻辑（见 AGENTS.md 铁律 3）。
## 无头自检：godot --headless --path game -- --selftest
##
## 用 preload 而不是 class_name：全局类需要编辑器导入一遍才注册，
## 而 CI 里的无头模式没跑过编辑器。preload 不依赖任何缓存。
##
## 三层的组装顺序：Pack（读数据）→ Plan（排世界）→ WorldRoot（建节点）。
## 自检只走到 Plan，一个节点都不建。

const PACK_SCRIPT = preload("res://scripts/content/pack.gd")
const PLAN_SCRIPT = preload("res://scripts/world/plan.gd")
const WORLD_SCRIPT = preload("res://scripts/world/world_root.gd")
const MESH_LIB = preload("res://scripts/world/mesh_lib.gd")
const CAMERA_SCRIPT = preload("res://scripts/player/fly_camera.gd")

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
	var declared_meshes := PackedStringArray(pack.schema.get("meshes", {}).keys())
	var missing := MESH_LIB.missing(declared_meshes)
	if not missing.is_empty():
		printerr("自检失败：契约里有这些网格但引擎没实现几何：%s" % ", ".join(missing))
		ok = false

	if plan.instance_count() <= 0:
		printerr("自检失败：世界是空的（房间填不出东西，检查 spawner 指向的原型）")
		ok = false

	print("网格实现 %d / 契约 %d 种" % [MESH_LIB.implemented().size(), declared_meshes.size()])
	if ok:
		print("自检通过")
	return ok


## 场景组装：环境 + 主光 + 世界 + 相机。全部是引擎的"怎么跑"。
func _setup_scene() -> void:
	add_child(_make_environment())
	add_child(_make_sun())

	var world = WORLD_SCRIPT.new()
	world.name = "world"
	add_child(world)
	world.realize(plan)

	var cam = CAMERA_SCRIPT.new()
	cam.name = "fly_camera"
	add_child(cam)
	cam.position = _start_position(world)
	cam.look_at(_start_target(world))
	cam.current = true
	world.attach_camera(cam)


func _make_environment() -> WorldEnvironment:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.13, 0.15, 0.19)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.62, 0.68, 0.80)
	env.ambient_light_energy = 1.0
	env.fog_enabled = true
	env.fog_light_color = Color(0.16, 0.18, 0.24)
	env.fog_density = 0.004

	var node := WorldEnvironment.new()
	node.name = "environment"
	node.environment = env
	return node


func _make_sun() -> DirectionalLight3D:
	var sun := DirectionalLight3D.new()
	sun.name = "sun"
	sun.rotation_degrees = Vector3(-52.0, -38.0, 0.0)
	sun.light_energy = 1.5
	sun.light_color = Color(1.0, 0.95, 0.86)
	sun.shadow_enabled = false
	return sun


## 开场站在第一个房间边缘往里看，第一眼就能看见内容。
func _first_room_bounds(world) -> AABB:
	for room_id in world.chunks:
		return world.chunks[room_id].bounds
	return AABB(Vector3.ZERO, Vector3(24, 6, 24))


func _start_position(world) -> Vector3:
	var b := _first_room_bounds(world)
	var c := b.get_center()
	return Vector3(c.x, 2.4, c.z + b.size.z * 0.34)


func _start_target(world) -> Vector3:
	var b := _first_room_bounds(world)
	var c := b.get_center()
	return Vector3(c.x, 1.2, c.z)
