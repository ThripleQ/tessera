extends RefCounted

## 物理。把计划里的 collider 数据变成碰撞体与刚体。
##
## 这一层只认形状、尺寸、质量，不认任何内容名字。判断"这东西会不会掉"
## 的依据只有一个：数据里有没有声明 dynamic（铁律 2）。
##
## 为什么单独一层：渲染要合批（静态），物理要独立身份（动态），两者需求相反。
## 混在一个文件里，迟早会出现"为了让物理跑起来把合批拆了"这种倒退。

const ASSETS = preload("res://scripts/world/assets.gd")
const MESH_LIB = preload("res://scripts/world/mesh_lib.gd")

## 契约只给一个"特征尺寸"，胶囊的总高要么由内容给，要么按人形比例推。
## 2.8 不是魔法数字：直径 0.6 的碰撞体总高 1.68，正好裹住 1.72 米的主角。
## 需要精确形状的内容应该用 box 并显式给 height。
const CAPSULE_SLENDERNESS := 2.8


static func height_of(collider: Dictionary) -> float:
	var kind := String(collider.get("shape", "capsule"))
	var size := float(collider.get("size", 0.5))
	var h := float(collider.get("height", 0.0))
	if h > 0.0:
		return h
	if kind == "sphere":
		return size
	if kind == "box":
		return size
	return size * CAPSULE_SLENDERNESS


static func shape_of(collider: Dictionary) -> Shape3D:
	var kind := String(collider.get("shape", "capsule"))
	var size := float(collider.get("size", 0.5))
	var h := height_of(collider)

	match kind:
		"box":
			var box := BoxShape3D.new()
			box.size = Vector3(size, h, size)
			return box
		"sphere":
			var ball := SphereShape3D.new()
			ball.radius = size * 0.5
			return ball
		_:
			var cap := CapsuleShape3D.new()
			cap.radius = size * 0.5
			# 胶囊的总高必须 ≥ 两倍半径，否则 Godot 会警告并把它压扁。
			cap.height = max(h, cap.radius * 2.0 + 0.01)
			return cap


## 钉住的障碍物：挡住玩家，但不参与模拟，也不需要逐帧更新变换。
## 它的视觉仍然走 MultiMesh 合批 —— 一个看不见的碰撞体比一个可见的网格便宜得多。
static func make_static(item: Dictionary) -> StaticBody3D:
	var collider: Dictionary = item["collider"]
	var body := StaticBody3D.new()
	body.name = "solid"
	var cs := CollisionShape3D.new()
	cs.shape = shape_of(collider)
	# 内容的原点在脚底，形状的中心在高度一半处。
	cs.position = Vector3(0.0, height_of(collider) * 0.5, 0.0)
	body.add_child(cs)
	body.transform = item["xform"]
	return body


## 刚体：会掉、会滚、能被推被扔。
## 它没法进合批——MultiMesh 的所有实例共用一个节点，而物理需要每个物体一个身份。
## 所以每个刚体都是一次独立提交。这是"物理"的价格，必须如实报出来。
static func make_dynamic(item: Dictionary) -> RigidBody3D:
	var collider: Dictionary = item["collider"]
	var h := height_of(collider)
	var body := RigidBody3D.new()
	body.name = "rigid"
	body.transform = item["xform"]
	body.mass = float(collider.get("mass", 5.0))
	# 内容 id 只作为元数据挂在身上。引擎从不读它做判断，
	# 但 mod 需要知道"我抓到的是什么"—— 这是内容侧的知识，不是引擎的。
	body.set_meta("content_id", String(item.get("id", "")))
	# 原点在底面，质心在几何中心。不显式指定的话，Godot 会围着底面转，
	# 扔出去的时候物体会像陀螺一样甩，而不是像箱子一样翻。
	body.center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	body.center_of_mass = Vector3(0.0, h * 0.5, 0.0)
	# 扔出去的初速可以很快，不连续检测会直接穿墙。
	body.continuous_cd = true

	# 会走的东西不许翻倒。它是个"站着的"，不是个"滚着的" ——
	# 转向由 locomotion 控制（只写 yaw），物理不该把它甩得四脚朝天。
	#
	# 判断依据是**数据**（`move.speed > 0`），不是形状、更不是名字（铁律 2）。
	# 反过来说：一个没有 move 的胶囊是桶，它就该滚。
	var mv: Dictionary = item.get("components", {}).get("move", {})
	if float(mv.get("speed", 0.0)) > 0.0:
		body.lock_rotation = true

	var cs := CollisionShape3D.new()
	cs.shape = shape_of(collider)
	cs.position = Vector3(0.0, h * 0.5, 0.0)
	body.add_child(cs)

	var visual := MeshInstance3D.new()
	visual.name = "visual"
	visual.mesh = ASSETS.mesh(String(item["mesh"]))
	visual.material_override = MESH_LIB.toon_material_for(item["color"])
	body.add_child(visual)
	return body


## 房间地板。顶面正好在 y=0 —— 内容的原点就在地表，差一点所有东西都会浮着或陷进去。
static func make_floor(origin: Vector3, size: Vector2) -> StaticBody3D:
	const THICKNESS := 0.6
	var body := StaticBody3D.new()
	body.name = "floor_body"
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(size.x, THICKNESS, size.y)
	cs.shape = box
	cs.position = Vector3(size.x * 0.5, -THICKNESS * 0.5, size.y * 0.5)
	body.add_child(cs)
	body.position = origin
	return body


## 世界底板的碰撞。没有它，玩家走出房间就会掉进虚空 ——
## 房间之间是留了走道的，走道没有地板，只有引擎铺的那块视觉底板。
## 底板给碰撞不算"内容参与玩法"：它只是兜住玩家，不让世界边界变成死亡陷阱。
static func make_ground(center: Vector3, size: Vector2) -> StaticBody3D:
	const THICKNESS := 1.0
	var body := StaticBody3D.new()
	body.name = "ground_body"
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(size.x, THICKNESS, size.y)
	cs.shape = box
	cs.position = Vector3(0.0, -THICKNESS * 0.5 - 0.02, 0.0)
	body.add_child(cs)
	body.position = center
	return body
