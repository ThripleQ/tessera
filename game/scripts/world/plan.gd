extends RefCounted

## 世界计划。纯数据，不碰节点。
##
## 为什么单独一个类：无头自检只需要"世界长什么样"的数字，不需要任何节点。
## 把计划塞在 Node3D 里，自检就会 new 出一堆不入树的节点，退出时泄漏一堆
## ERROR —— 而真正的失败会被这些噪音淹掉。
##
## 分层：Pack（读数据）→ Plan（排世界）→ WorldRoot（建节点）。
## 每一层只依赖上一层，改一层不会牵动另一层。

const MESH_LIB = preload("res://scripts/world/mesh_lib.gd")

## 房间之间留的走道。这是引擎的布局规则，不是内容。
const ROOM_GAP := 12.0

## room_id -> {room_id, bounds, floor_size, items:[{mesh, xform, color}]}
var rooms: Dictionary = {}
var skipped: Array[String] = []


func build(pack) -> void:
	rooms.clear()
	skipped.clear()

	var cursor_x := 0.0
	for room_id in pack.ids_of_kind("room"):
		var comps: Dictionary = pack.entities[room_id].get("components", {})
		var room_comp: Dictionary = comps.get("room", {})
		var size_x := float(room_comp.get("size_x", 24.0))
		var size_z := float(room_comp.get("size_z", 24.0))
		if size_x <= 0.0 or size_z <= 0.0:
			_note_skip("房间 `%s` 尺寸非法" % room_id)
			continue

		var origin := Vector3(cursor_x, 0.0, -size_z * 0.5)
		var room := {
			"room_id": room_id,
			"bounds": AABB(origin, Vector3(size_x, 6.0, size_z)),
			"floor_size": Vector2(size_x, size_z),
			"items": [],
		}
		_fill_room(room, pack, room_id, comps, origin, Vector2(size_x, size_z))
		rooms[room_id] = room
		cursor_x += size_x + ROOM_GAP


## 房间里的东西全部来自 spawner 组件。没有 spawner 的房间就是块空地——
## 引擎不会自作主张往里塞东西，那就等于引擎在决定"有什么"了。
func _fill_room(room: Dictionary, pack, room_id: String, comps: Dictionary,
		origin: Vector3, size: Vector2) -> void:
	var spawner: Dictionary = comps.get("spawner", {})
	if spawner.is_empty():
		return

	var arch_id := String(spawner.get("archetype", ""))
	var count := int(spawner.get("count", 0))
	var radius := float(spawner.get("radius", 10.0))
	if count <= 0:
		return
	if not pack.entities.has(arch_id):
		_note_skip("房间 `%s` 的 spawner 指向不存在的内容 `%s`" % [room_id, arch_id])
		return

	var model: Dictionary = pack.entities[arch_id].get("components", {}).get("model", {})
	if model.is_empty():
		_note_skip("原型 `%s` 没有 model 组件（抽象基类不能直接摆）" % arch_id)
		return

	var arch_comps: Dictionary = pack.entities[arch_id].get("components", {})
	var collider: Dictionary = arch_comps.get("collider", {})
	# 只有声明了 collider 且 dynamic 的东西才是刚体。引擎判断依据全在数据里，
	# 不知道它叫"木箱"还是别的什么。
	var is_dynamic := not collider.is_empty() and bool(collider.get("dynamic", false))
	var spawn_height := float(spawner.get("height", 0.0))
	# 静态物体没有"下落"这回事，给它一个空中起点只会变成悬空的错误摆设。
	if not is_dynamic:
		spawn_height = 0.0

	var mesh_id := String(model.get("mesh", ""))
	if MESH_LIB.build(mesh_id) == null:
		_note_skip("网格 `%s` 引擎没实现几何，房间 `%s` 的内容被跳过" % [mesh_id, room_id])
		return
	var color: Color = pack.palette_color(String(model.get("palette", "default")))

	# 每个房间独立种子：以后加一个房间，不会改变已有房间的随机序列。
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(room_id)

	# 散布半径不能超出房间，否则怪会站到地板外面去。
	var max_r: float = max(1.0, min(radius, min(size.x, size.y) * 0.5 - 2.0))
	var center := Vector3(origin.x + size.x * 0.5, 0.0, origin.z + size.y * 0.5)

	for i in count:
		var ang := rng.randf() * TAU
		# sqrt 让点在圆内均匀分布，否则会全挤在圆心
		var dist := sqrt(rng.randf()) * max_r
		# 起始高度带一点抖动，落下来的样子才不会像一排同时松手的升降机
		var drop := spawn_height * rng.randf_range(0.55, 1.0) if is_dynamic else 0.0
		var pos := center + Vector3(cos(ang) * dist, drop, sin(ang) * dist)
		var basis := Basis(Vector3.UP, rng.randf() * TAU)
		room["items"].append({
			"mesh": mesh_id,
			"xform": Transform3D(basis, pos),
			"color": color,
			"collider": collider,
			"dynamic": is_dynamic,
		})


func _note_skip(msg: String) -> void:
	push_warning(msg)
	skipped.append(msg)


func instance_count() -> int:
	var n := 0
	for room_id in rooms:
		n += (rooms[room_id]["items"] as Array).size()
	return n


## 静态部分：每块里出现过的网格种类数之和。同网格同块合成一次提交。
func batch_count() -> int:
	var n := 0
	for room_id in rooms:
		var seen := {}
		for item in rooms[room_id]["items"]:
			if not item["dynamic"]:
				seen[item["mesh"]] = true
		n += seen.size()
	return n


func dynamic_count() -> int:
	var n := 0
	for room_id in rooms:
		for item in rooms[room_id]["items"]:
			if item["dynamic"]:
				n += 1
	return n


## 有碰撞体但钉住的物体数：会挡住玩家，但不参与模拟。
func solid_static_count() -> int:
	var n := 0
	for room_id in rooms:
		for item in rooms[room_id]["items"]:
			if not item["dynamic"] and not (item["collider"] as Dictionary).is_empty():
				n += 1
	return n


## 动态部分：每个刚体占一个 MeshInstance，没法合批 —— 这是"物理身份"的价格。
## 沙盒里同屏几十个刚体是常态，所以这个数字必须显示出来，不能藏。
func dynamic_draw_count() -> int:
	return dynamic_count()


func triangle_count() -> int:
	var t := 0
	for room_id in rooms:
		for item in rooms[room_id]["items"]:
			t += MESH_LIB.triangles_of(String(item["mesh"]))
	return t


func per_mesh() -> Dictionary:
	var out: Dictionary = {}
	for room_id in rooms:
		for item in rooms[room_id]["items"]:
			var m := String(item["mesh"])
			out[m] = int(out.get(m, 0)) + 1
	return out


func summary() -> String:
	var lines: Array[String] = []
	lines.append("世界：%d 个块（一个房间一块）" % rooms.size())
	lines.append("实例 %d 个，三角形 %d" % [instance_count(), triangle_count()])
	lines.append("  静态 %d 次提交（合批）＋ 动态 %d 次（刚体各自一格）"
		% [batch_count(), dynamic_draw_count()])
	lines.append("  刚体 %d 个，钉住的障碍 %d 个" % [dynamic_count(), solid_static_count()])
	var pm := per_mesh()
	if not pm.is_empty():
		var keys := pm.keys()
		keys.sort()
		var parts: Array[String] = []
		for k in keys:
			parts.append("%s×%d" % [k, int(pm[k])])
		lines.append("  按网格：%s" % ", ".join(parts))
	for s in skipped:
		lines.append("  ! %s" % s)
	return "\n".join(lines)
