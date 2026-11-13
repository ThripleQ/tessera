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
		var pos := center + Vector3(cos(ang) * dist, 0.0, sin(ang) * dist)
		var basis := Basis(Vector3.UP, rng.randf() * TAU)
		room["items"].append({
			"mesh": mesh_id,
			"xform": Transform3D(basis, pos),
			"color": color,
		})


func _note_skip(msg: String) -> void:
	push_warning(msg)
	skipped.append(msg)


func instance_count() -> int:
	var n := 0
	for room_id in rooms:
		n += (rooms[room_id]["items"] as Array).size()
	return n


## 提交次数 = 每块里出现过的网格种类数之和。同网格同块合成一次提交。
func batch_count() -> int:
	var n := 0
	for room_id in rooms:
		var seen := {}
		for item in rooms[room_id]["items"]:
			seen[item["mesh"]] = true
		n += seen.size()
	return n


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
	lines.append("实例 %d 个，提交 %d 次，三角形 %d"
		% [instance_count(), batch_count(), triangle_count()])
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
