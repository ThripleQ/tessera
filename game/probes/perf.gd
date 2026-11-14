extends SceneTree

## 帧时探针：跑固定帧数，算出平均每帧花了多少毫秒。
##
## **不设断言。** 这台开发机没有 GPU（`/dev/dri` 不存在），Godot 只能软件光栅 ——
## 帧时的绝对值在别的机器上毫无意义，拿它设阈值只会得到一个天天翻脸的红灯。
## 它的用途只有一个：**同机回归**。哪天数字突然涨了三倍，说明有人往每帧里
## 塞了贵东西，而那正是"功能全绿但游戏卡了"这类问题唯一露出头的地方。
##
## 负载数字（实例 / 三角形 / 提交 / 刚体）也一起打出来：帧时涨了的时候，
## 第一件事是分清"东西变多了"还是"每件东西变贵了" —— 前者是内容问题，
## 后者是实现问题，两者的修法完全相反。
##
## 预热帧不算：前 30 帧里有场景装配、材质编译、物理稳定，
## 把它们算进去会让数字忽高忽低，回归比较失去意义。

const WARMUP := 30
const FRAMES := 300
const MESH_LIB = preload("res://scripts/world/mesh_lib.gd")

var _f := 0
var _last_usec := 0
var _samples: Array[float] = []
var _main


func _initialize() -> void:
	_main = load("res://main.tscn").instantiate()
	root.add_child(_main)


func _process(_delta: float) -> bool:
	_f += 1
	var now := Time.get_ticks_usec()
	if _last_usec > 0 and _f > WARMUP:
		_samples.append(float(now - _last_usec) / 1000.0)
	_last_usec = now

	if _f >= WARMUP + FRAMES:
		_report()
		quit(0)
	return false


func _report() -> void:
	if _samples.is_empty():
		print("PERF 没采到样本 —— 探针本身坏了，这个数字不能信")
		return
	_samples.sort()
	var total := 0.0
	for s in _samples:
		total += s
	var avg := total / float(_samples.size())
	var p95: float = _samples[int(float(_samples.size()) * 0.95)]
	var worst: float = _samples[_samples.size() - 1]
	print("PERF 帧时 %d 帧：平均 %.2f ms / p95 %.2f / 最差 %.2f"
		% [_samples.size(), avg, p95, worst])

	var world = _main._world
	var api = _main.api
	var pack = _main.pack
	var instances := 0
	var tris := 0
	var batches := 0
	for room_id in world.chunks:
		var chunk = world.chunks[room_id]
		instances += chunk.instance_count()
		tris += chunk.triangle_count()
		batches += chunk.batch_count()
	# 刚体的实例和三角形都不在块的合批里，得单独数 —— 少了这一段，
	# 负载行会比自检少一截，两份数字对不上就没法互相印证了。
	for rb in world.bodies:
		if not is_instance_valid(rb):
			continue
		instances += 1
		var cid := String(rb.get_meta("content_id", ""))
		var mesh_id := String(pack.entities.get(cid, {}).get("components", {})
			.get("model", {}).get("mesh", ""))
		if mesh_id != "":
			tris += MESH_LIB.triangles_of(mesh_id)
	print("PERF 负载：实例 %d / 三角形 %d / 静态提交 %d / 刚体 %d / 静态物 %d / 预算已用 %d"
		% [instances, tris, batches, world.bodies.size(), world.props.size(),
			api.budget_used()])
	if DisplayServer.get_name() == "headless":
		print("PERF 说明：**无头**跑的，不含渲染 —— 这是逻辑 + 物理的开销，不是画面开销")
	else:
		print("PERF 说明：带显示跑的，含渲染；软件光栅下绝对值不代表真实显卡，只和同机历史比")
