extends SceneTree

## 角色资产探针：玩家身上那个"人"，是不是真的在动。
##
## 守的不是"某个模型好不好看"，而是五件会静默坏掉的事：
##   结构  —— 资产加载出了带动画的树（有 AnimationPlayer、有骨骼、有名有姓的片段）
##   尺寸  —— 脚底贴地、身高等于胶囊（错了的症状：人陷进地里或浮在半空）
##   材质  —— 全部 surface 换成了卡通着色（漏一个就是一块 PBR 白模混在卡通世界里）
##   回退  —— 资产目录被删掉时，游戏仍然能跑（装不上就满屏空白，比没有更糟）
##   动    —— 骨骼真的在动，不只是 AnimationPlayer 在计时
##
## 最后一条是重点。前四条都可能"全绿但人是滑的"：
## 动画名对了、播放器在跑、骨骼纹丝不动，画面上就是一个人贴着地面平移 ——
## 这正是这一轮要消灭的那个症状。所以这里直接采样骨骼姿势、跨帧比较。

const CHARACTERS = preload("res://scripts/world/character_assets.gd")
const RIG = preload("res://scripts/player/character_rig.gd")

const WANT_CLIPS := ["Idle", "Walking_A", "Running_A", "Jump_Start", "Jump_Idle", "Jump_Land"]
const HEIGHT_TOL := 0.03

var _main
var _player
var _rig
var _ap: AnimationPlayer
var _skel: Skeleton3D
var _f := 0
var _pose_a: Array = []
var _pose_b: Array = []
var _ok := true


func _initialize() -> void:
	_main = load("res://main.tscn").instantiate()
	root.add_child(_main)


func _say(tag: String, text: String, good: bool) -> void:
	if not good:
		_ok = false
	print("CHAR %s：%s（%s）" % [tag, text, good])


func _process(_delta: float) -> bool:
	_f += 1
	if _f == 6:
		if not _find_rig():
			print("CHAR RESULT FAIL")
			quit(1)
			return true
		_check_structure()
		_check_size()
		_check_material()
		_check_fallback()
		# 停掉玩家的物理，否则它每帧都按"没输入"把状态刷回 idle，
		# 这里想验的状态机就永远看不到。
		_player.set_physics_process(false)
		# 玩家开局是"落地"那一刻，land 会锁 0.3 秒；不先解掉，
		# 下面这条就会被锁挡住，测出来的不是状态机而是落地动作。
		_rig.set("_lock", 0.0)
		_rig.set("_on_floor", true)
		# 用资产反推出来的走路速度，不用写死的数 —— 写死的话人一换就假红，
		# 而这条断言想验的是"状态机会不会按速度分档"，不是"速度是不是 4.0"。
		var w: float = _rig.gait_walk()
		_rig.update_locomotion(w, true, 0.0, 0.016)
		_say("走路", "速度 %.2f m/s → %s" % [w, _rig.state()], _rig.state() == "walk")
	elif _f == 14:
		# 等 8 帧：交叉淡入是 0.18 秒，太早采样会拿到几乎没变的姿势。
		_pose_a = _sample_pose()
	elif _f == 22:
		_pose_b = _sample_pose()
		_check_motion()
		_check_states()
		print("CHAR RESULT %s" % ("OK" if _ok else "FAIL"))
		quit(0 if _ok else 1)
		return true
	return false


func _find_rig() -> bool:
	for c in _main.get_children():
		if c is CharacterBody3D:
			_player = c
			break
	if _player == null:
		print("CHAR 结构：找不到玩家（CharacterBody3D）")
		return false
	_rig = _player.get_node_or_null("visual/rig")
	if _rig == null:
		print("CHAR 结构：玩家身上没有 visual/rig")
		return false
	for n in _rig.find_children("*", "AnimationPlayer", true, false):
		_ap = n as AnimationPlayer
		break
	for n in _rig.find_children("*", "Skeleton3D", true, false):
		_skel = n as Skeleton3D
		break
	return true


func _check_structure() -> void:
	_say("结构", "用上资产 %s，%d 个片段" % [_rig.character_id(), _rig.clip_count()],
		_rig.uses_asset() and _rig.clip_count() >= 10)
	var missing: Array[String] = []
	for c in WANT_CLIPS:
		if _ap == null or not _ap.has_animation(c):
			missing.append(c)
	_say("片段", "必需 %d 个，缺 %s" % [WANT_CLIPS.size(),
		"无" if missing.is_empty() else ", ".join(missing)], missing.is_empty())
	var bones := 0 if _skel == null else _skel.get_bone_count()
	_say("骨架", "%d 根骨骼" % bones, bones > 0)


func _check_size() -> void:
	var body: Node3D = null
	for c in _rig.get_children():
		if c is Node3D:
			body = c as Node3D
			break
	if body == null:
		_say("身高", "资产根节点缺失", false)
		return
	var meta := CHARACTERS.character_meta(String(_rig.character_id()))
	var want: float = CHARACTERS.CHARACTER_TARGET_HEIGHT
	var got: float = float(meta.get("scaled_height", 0.0))
	var foot: float = float(meta.get("foot", 99.0))
	_say("身高", "归一化 %.3f m（目标 %.2f），绑定姿势脚底 %.3f" % [got, want, foot],
		absf(got - want) <= 0.01 and absf(foot) <= 0.01)

	# 当前包围盒只做"没陷地 / 没差一个量级"的粗检。
	# 动画一播，手臂抬起、披风摆开都会改变它 —— 拿它做精确断言会假红。
	var box := CHARACTERS.character_box(body)
	_say("落地", "%s 当前 y[%.3f .. %.3f]" % [body.name, box.position.y, box.end.y],
		box.position.y > -0.06 and box.size.y > want * 0.85 and box.size.y < want * 1.25)


func _check_material() -> void:
	var total := 0
	var bad := 0
	for n in _rig.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi.mesh == null or not mi.visible:
			continue
		for i in mi.mesh.get_surface_count():
			total += 1
			if not (mi.get_surface_override_material(i) is ShaderMaterial):
				bad += 1
	_say("材质", "可见 surface %d 个，非卡通 %d 个" % [total, bad], total > 0 and bad == 0)


func _check_fallback() -> void:
	var r := RIG.new() as Node3D
	var used: bool = r.setup("__probe_no_such_character__", Color.WHITE, Color.BLACK)
	var has_fallback := r.get_node_or_null("fallback_body") != null
	r.free()
	_say("回退", "未知角色 → 内置几何 %s" % ("在" if has_fallback else "不在"),
		not used and has_fallback)


func _sample_pose() -> Array:
	var out: Array = []
	if _skel == null:
		return out
	for i in _skel.get_bone_count():
		out.append(_skel.get_bone_global_pose(i).origin)
	return out


func _check_motion() -> void:
	if _pose_a.is_empty() or _pose_b.is_empty():
		_say("动", "采不到骨骼姿势", false)
		return
	var moved := 0
	var n: int = mini(_pose_a.size(), _pose_b.size())
	for i in n:
		if (_pose_a[i] as Vector3).distance_to(_pose_b[i] as Vector3) > 0.001:
			moved += 1
	_say("动", "%d / %d 根骨骼在两帧之间移动" % [moved, n], moved > 0)


func _check_states() -> void:
	# 分档阈值不再写死：走 / 跑两条用资产反推的速度，中间那条落在两档之间，
	# 具体选哪条片段由 choose_gait() 按对数距离决定（第 15 步会逐个速度点验）。
	var w: float = _rig.gait_walk()
	var r: float = _rig.gait_run()
	var cases := [
		{"speed": 0.0, "floor": true, "vy": 0.0, "want": "idle"},
		{"speed": w, "floor": true, "vy": 0.0, "want": "walk"},
		{"speed": r, "floor": true, "vy": 0.0, "want": "run"},
		{"speed": 0.0, "floor": false, "vy": 5.0, "want": "jump_up"},
		{"speed": 0.0, "floor": false, "vy": -3.0, "want": "jump_air"},
	]
	var all := true
	var got: Array[String] = []
	for c in cases:
		# 每次换状态都清掉落地锁，否则会停在 land 上不动。
		_rig.set("_lock", 0.0)
		_rig.set("_on_floor", bool(c["floor"]))
		_rig.update_locomotion(float(c["speed"]), bool(c["floor"]), float(c["vy"]), 0.016)
		got.append(String(_rig.state()))
		if String(_rig.state()) != String(c["want"]):
			all = false
	_say("状态机", ", ".join(got), all)
