extends SceneTree

## 阵容探针（第 16 步）：世界里的**别人**真的在走。
##
## 第 14 步已经把资产目录里每个角色单独体检过一遍（骨架、片段、身高、手上零件、
## 步态档位）—— 但那证明的是"拿得起来"。把它们放进世界、让它们自己走，
## 是另一条链：`character_assets` → `character_rig` → `gait` → 物理 → 动画。
##
## 这条链唯一会静默坏掉的症状，正是这一层要消灭的那个：**人站着平移**。
## 功能全对、状态名全对、日志全绿，画面上是一个人贴着地面飘。
## 所以这里不看名字、不看日志，只量两件事：位置挪了多远、骨头动没动。
##
## 三件事：
##   出场 —— 目录里除了玩家用的那个，其余都在场（新丢一个 glb 就自动多一个人）
##   两棵 —— 同一份资产能被同时要两次（节点只能有一个父节点，
##           顺手缓存复用会让"多一个人"变成"玩家不见了"）
##   在走 —— 一秒之后位置真的变了，而且骨骼在动

## 观察时长与最小位移。按**秒**算不按帧：无头模式几百帧每秒，
## 按帧数计会得到一个"几乎没动"的假红。
const WATCH_SECONDS := 1.0
const MIN_TRAVEL := 0.15
## 世界最多放几个人。和 main.gd 的 CAST_MAX 是同一个数 —— 探针要算"该来几个"。
const CAST_MAX := 4

const CHARACTERS = preload("res://scripts/world/character_assets.gd")

var _main
var _npcs: Array = []
var _pos_a: Array = []
var _bones_a: Array = []
var _t := 0.0
var _f := 0
var _watched := false
var _ok := true


func _initialize() -> void:
	_main = load("res://main.tscn").instantiate()
	root.add_child(_main)


func _say(tag: String, text: String, good: bool) -> void:
	if not good:
		_ok = false
	print("CAST %s：%s（%s）" % [tag, text, good])


func _process(delta: float) -> bool:
	_f += 1
	if _f == 4:
		_check_multi_instance()
		if not _find_cast():
			print("CAST RESULT FAIL")
			quit(1)
			return true
		_sample()
		_t = 0.0
		return false
	if _npcs.is_empty() or _watched:
		return false
	_t += delta
	if _t >= WATCH_SECONDS:
		_watched = true
		_check_walk()
		print("CAST RESULT %s" % ("OK" if _ok else "FAIL"))
		quit(0 if _ok else 1)
		return true
	return false


## 同一份资产要两次，必须是两棵**不同的**树。
##
## 防的是一个很容易顺手写出来的"优化"：把加载好的 root 缓存起来复用。
## 节点只能有一个父节点 —— 复用会让第二个使用者把第一个人从世界里拽走，
## 而症状是"多了一个人之后，玩家不见了"，没有报错。
func _check_multi_instance() -> void:
	var ids := CHARACTERS.character_ids()
	if ids.is_empty():
		_say("两棵", "资产目录为空", false)
		return
	var id := String(ids[0])
	var a := CHARACTERS.character(id)
	var b := CHARACTERS.character(id)
	var ap_a := _find_ap(a["root"])
	var ap_b := _find_ap(b["root"])
	_say("两棵", "%s 要两次 → 两棵%s树、两个%s播放器"
		% [id, "" if a["root"] != b["root"] else "同一棵",
			"" if ap_a != ap_b else "同一个"],
		a["ok"] and b["ok"] and a["root"] != b["root"]
		and a["root"] != null and b["root"] != null and ap_a != ap_b)
	if a["root"] != null:
		(a["root"] as Node).free()
	if b["root"] != null:
		(b["root"] as Node).free()


func _find_ap(root) -> AnimationPlayer:
	if root == null:
		return null
	for n in (root as Node).find_children("*", "AnimationPlayer", true, false):
		return n as AnimationPlayer
	return null


func _find_cast() -> bool:
	var cast: Node = _main.get_node_or_null("world/cast")
	if cast == null:
		_say("出场", "world 下没有 cast 节点", false)
		return false
	_npcs = []
	for c in cast.get_children():
		if c is CharacterBody3D:
			_npcs.append(c)
	# 该来几个：目录里除了"玩家正在用的那个"，其余都该在场。
	var skip := ""
	var player = _main.get_node_or_null("player")
	if player != null:
		var rig = player.get_node_or_null("visual/rig")
		if rig != null:
			skip = String(rig.character_id())
	var want := 0
	for id in CHARACTERS.character_ids():
		if String(id) != skip:
			want += 1
	var names: Array[String] = []
	var all_asset := true
	for n in _npcs:
		names.append(String(n.char_id))
		if not bool(n.uses_asset):
			all_asset = false
	_say("出场", "玩家用 %s，别人 %d 个（该来 %d）：%s"
		% [skip, _npcs.size(), mini(want, CAST_MAX), ", ".join(names)],
		_npcs.size() == mini(want, CAST_MAX) and _npcs.size() >= 1 and all_asset)
	return _npcs.size() >= 1


func _sample() -> void:
	_pos_a.clear()
	_bones_a.clear()
	for n in _npcs:
		_pos_a.append((n as Node3D).global_position)
		_bones_a.append(_bones(n))


func _bones(npc) -> Array:
	var out: Array = []
	var rig = npc.get_node_or_null("visual/rig")
	if rig == null:
		return out
	for n in rig.find_children("*", "Skeleton3D", true, false):
		var sk := n as Skeleton3D
		for i in sk.get_bone_count():
			out.append(sk.get_bone_global_pose(i).origin)
		break
	return out


## 走了多远 + 骨头动没动 + 播的是不是移动态。
##
## 三条缺一不可：只测位移，走过去的是块砖也算；只测骨骼，原地播挥手也算；
## 只测状态名，名字对了腿没动也算 —— 这正是第 14 轮踩过的那个坑。
func _check_walk() -> void:
	for i in _npcs.size():
		var npc = _npcs[i]
		var moved: float = (npc as Node3D).global_position.distance_to(_pos_a[i])
		var now := _bones(npc)
		var before: Array = _bones_a[i]
		var moved_bones := 0
		for j in mini(now.size(), before.size()):
			if (now[j] as Vector3).distance_to(before[j] as Vector3) > 0.001:
				moved_bones += 1
		var rig = npc.get_node_or_null("visual/rig")
		var state := "?" if rig == null else String(rig.state())
		_say("走", "%s 走了 %.2f m，%d/%d 根骨在动（%s，请求 %.2f m/s）"
			% [npc.char_id, moved, moved_bones, now.size(), state,
				float(npc.walk_speed())],
			moved >= MIN_TRAVEL and moved_bones > 0 and state != "idle")
