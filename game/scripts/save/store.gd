extends RefCounted

## 存档：只存**玩家改动过的东西**，不存世界本身。
##
## 世界是内容（TOML）决定的，重跑一次就有；存档要保住的是玩家的动作 —— 
## 箱子被推到哪里、玩家站在哪、mod 造出来什么、他自己摆下了什么。所以这里没有房间、
## 没有地面、没有房间自带的静态障碍：那些是内容的形状，改了内容就该跟着变，
## 不该被旧存档钉住。
##
## 这条分界的关键在"谁放的"：房间里的柱子和玩家放的柱子长得一样、数据也一样，
## 但它们归属不同 —— 前者是内容的形状，后者是玩家的动作。
## 世界用 `props` 把后者单独记着，存档只抄 `props`，不抄 chunk。
##
## 一旦把静态世界也存进去，改一个房间的尺寸就要写迁移代码，
## 而那种迁移是最没价值的复杂度：它保护的是"上次的样子"，不是"上次的成果"。
##
## 格式是 JSON 而不是二进制：存档要能被打开看、被人手改、被 diff。
## 一个玩家把自己的箱子坐标改错，游戏应该告诉他哪里不对，而不是拒绝加载整个文件。

const DIR := "user://saves"
const SLOT := "slot0.json"
## 2：加了 props（玩家摆下的静态物）。1 的存档照样能读 ——
## 拒绝一个只少了一个列表的旧存档，对玩家来说是"我的进度没了"，
## 而那种损失换来的只是我们少写三行迁移代码。
const VERSION := 2
const READABLE := [1, 2]


## 存档路径。允许环境变量覆盖，只有一个用途：**让验收不去动玩家真正的存档**。
## 一个会覆盖玩家进度的测试迟早会被关掉，而关掉的测试等于没有。
static func path() -> String:
	var slot := OS.get_environment("TESSERA_SAVE_SLOT")
	if slot.is_empty():
		slot = SLOT
	return DIR + "/" + slot


static func exists() -> bool:
	return FileAccess.file_exists(path())


# ---------------------------------------------------------------- 采集

## 返回 {version, saved_at, player, bodies, props}。只读，不写盘 ——
## "采集"和"落盘"分开，自检才能在不碰硬盘的情况下验证世界能不能被完整描述。
static func collect(world, player) -> Dictionary:
	var bodies: Array = []
	var props: Array = []
	var skipped := 0

	for rb in world.bodies:
		if not is_instance_valid(rb):
			continue
		var id := String(rb.get_meta("content_id", ""))
		if id.is_empty():
			# 没有内容 id 就重建不出来。这只会发生在有人绕过 Pack.item_for
			# 自己造了刚体 —— 与其存一条读回来变成空白的东西，不如不存。
			skipped += 1
			continue
		bodies.append({
			"id": id,
			"p": _vec(rb.global_position),
			"q": _quat(rb.global_transform.basis.get_rotation_quaternion()),
			"v": _vec(rb.linear_velocity),
			"w": _vec(rb.angular_velocity),
		})

	# 玩家摆下的静态物。没有速度、没有 handle，只有一个位置和一个朝向。
	# 注意这里读的是 world.props，不是 chunk —— 房间自带的障碍不在里面，也不该在。
	for node in world.props:
		if not is_instance_valid(node):
			continue
		var pid := String(node.get_meta("content_id", ""))
		if pid.is_empty():
			skipped += 1
			continue
		props.append({
			"id": pid,
			"p": _vec(node.global_position),
			"q": _quat(node.global_transform.basis.get_rotation_quaternion()),
		})

	var pose: Dictionary = player.pose()
	return {
		"version": VERSION,
		"saved_at": Time.get_datetime_string_from_system(true),
		"player": {
			"pos": _vec(pose["pos"]),
			"yaw": float(pose["yaw"]),
			"pitch": float(pose["pitch"]),
		},
		"bodies": bodies,
		"props": props,
		"unaddressable": skipped,
	}


# ---------------------------------------------------------------- 落盘 / 读盘

static func write(save: Dictionary) -> bool:
	DirAccess.make_dir_recursive_absolute(DIR)
	var f := FileAccess.open(path(), FileAccess.WRITE)
	if f == null:
		push_error("写不了存档 %s" % path())
		return false
	f.store_string(JSON.stringify(save, " "))
	f.close()
	return true


## 返回 {} 表示没有存档、或者读不出来。读不出来要**报错**而不是当没有 ——
## "存档没了"和"存档读不了"对玩家是两件完全不同的事。
static func read() -> Dictionary:
	if not exists():
		return {}
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path()))
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("存档不是合法 JSON：%s" % path())
		return {}
	return parsed


# ---------------------------------------------------------------- 还原

## 把存档写回世界。返回 {cleared, spawned, placed, missing:[id], error}。
##
## 顺序有讲究：先清空再重建。反过来的话旧的那些会和新的一起留在世界里，
## 而且每读一次档数量就涨一轮 —— 这种 bug 只在读档两次以上才出现。
static func apply(save: Dictionary, world, player, pack) -> Dictionary:
	var ver := int(save.get("version", 0))
	if ver not in READABLE:
		return {"error": "存档版本 %d，本引擎能读 %s" % [ver, str(READABLE)]}

	var cleared: int = world.clear_spawned()
	# mod 手里的 handle 全部作废：它们指向的刚体已经不存在了。
	# 留着的话 mod 下一次 api.pos(h) 会去读一个已释放的对象。
	if world.api != null:
		world.api.forget_all()

	var spawned := 0
	var placed := 0
	var missing: Array[String] = []

	for rec in save.get("bodies", []):
		var id := String(rec.get("id", ""))
		# 内容可能已经不在了：mod 被卸载、原型被改名。
		# 跳过但记账 —— 玩家会发现"我的箱子少了一半"，必须能告诉他为什么。
		var item: Dictionary = pack.item_for(id, _xform(rec))
		if item.is_empty():
			if not (id in missing):
				missing.append(id)
			continue
		var rb = world.add_dynamic(item)
		if rb == null:
			continue
		rb.linear_velocity = _to_vec(rec.get("v", []))
		rb.angular_velocity = _to_vec(rec.get("w", []))
		# 认领进预算。不认领的话读一次档额度就清零，玩家能把上次删掉的东西
		# 再造一遍 —— 那不是预算，那是个计数器。
		if world.api != null:
			world.api.adopt(rb)
		spawned += 1

	# 静态物。它当初被存下的那一刻是静态的，但现在还静不静**由内容说了算** ——
	# 有人改了那个原型的 dynamic，读档就该跟着变成刚体（铁律 2）。
	# 所以这里不读存档里的"类型"，重新按内容判断一次。
	for rec in save.get("props", []):
		var pid := String(rec.get("id", ""))
		var pitem: Dictionary = pack.item_for(pid, _xform(rec))
		if pitem.is_empty():
			if not (pid in missing):
				missing.append(pid)
			continue
		if bool(pitem["dynamic"]):
			var rb2 = world.add_dynamic(pitem)
			if rb2 != null:
				if world.api != null:
					world.api.adopt(rb2)
				spawned += 1
		else:
			var node = world.add_static(pitem)
			if node != null:
				if world.api != null:
					world.api.adopt(node)
				placed += 1

	var p: Dictionary = save.get("player", {})
	player.set_pose({
		"pos": _to_vec(p.get("pos", [])),
		"yaw": float(p.get("yaw", 0.0)),
		"pitch": float(p.get("pitch", -0.16)),
	})

	return {"cleared": cleared, "spawned": spawned, "placed": placed,
		"missing": missing, "error": ""}


# ---------------------------------------------------------------- 编码

## 存成数组而不是对象：JSON 里 {x:..,y:..,z:..} 比 [..] 长三倍，
## 而有几千个刚体的时候这个差别是能感觉到的。
static func _vec(v: Vector3) -> Array:
	return [snappedf(v.x, 0.001), snappedf(v.y, 0.001), snappedf(v.z, 0.001)]


static func _quat(q: Quaternion) -> Array:
	return [snappedf(q.x, 0.0001), snappedf(q.y, 0.0001),
		snappedf(q.z, 0.0001), snappedf(q.w, 0.0001)]


static func _to_vec(a) -> Vector3:
	if not (a is Array) or (a as Array).size() < 3:
		return Vector3.ZERO
	return Vector3(float(a[0]), float(a[1]), float(a[2]))


static func _xform(rec: Dictionary) -> Transform3D:
	var pos := _to_vec(rec.get("p", []))
	var q = rec.get("q", [])
	if (q is Array) and (q as Array).size() >= 4:
		return Transform3D(Basis(Quaternion(float(q[0]), float(q[1]), float(q[2]), float(q[3]))), pos)
	return Transform3D(Basis(), pos)
