extends RefCounted

## 手里那把枪的规矩：什么时候能开、一发放出什么、打中了谁。
##
## 所有的数都来自**内容**（`content/weapon/*.toml` 的 `wieldable` 组件）。
## 这个文件里没有一个"9 发/秒"或"25 点伤害"——那是内容作者的笔。
## 想让它更抖？改 TOML。想要一把散弹枪？再写一个 TOML，不用碰这里一行。
##
## 三件不属于它的事，故意的：
##   看得见的那把枪     → `gun_view.gd`（相机空间，跟着画面抖）
##   相机往哪抬         → `player.add_recoil()`（玩家自己不知道枪存在）
##   谁掉了多少血       → `vitals.damage()`（它不认识血量系统）
##
## 这条分界不是洁癖。全部塞进来之后，最典型的事故是"为了让枪看起来更猛，
## 把伤害也乘上后坐系数"——数值和表现的耦合就是这样长出来的。

const GUN_VIEW = preload("res://scripts/player/gun_view.gd")
const GUN_WORLD = preload("res://scripts/player/gun_world.gd")
const SFX_SUBDIR := "assets/sfx"
## 曳光存在多久。0.06 秒 = 三四帧 —— 够看见"从枪口出去"，
## 又不会在墙上挂一条持久的激光线。
const TRACER_TIME := 0.06

## 打中了"会疼的东西"时发一次。**这个信号只说"打中了"，不说打中的是谁。**
##
## 为什么不给详情：枪是唯一知道射线打到哪儿的东西，而 UI 需要的只是
## "该给玩家一个反馈了"—— 玩家看得见自己打中的是谁，不需要 UI 再播一遍。
## 带一份详情过去只会诱使 UI 去显示具体目标，那是 HUD 的活，不是准心的。
signal hit_confirmed

var _player = null
var _camera: Camera3D = null
var _pack = null
var _vitals = null
var _view: Node3D = null
## 第三人称的枪。挂在角色外观下，第一人称时跟着外观一起藏。
var _world_view: Node3D = null
## 当前这把枪可不可见（第一人称 true）。准心瞄点只在这个视角下更新。
var _shown := true
## 曳光弹节点与共享资源。开火是高频动作，每发 new 一个材质会把
## "材质数不随物体增长"那条红线踩回去。
var _tracers: Array = []
var _tracer_mesh: BoxMesh = null
var _tracer_mat: StandardMaterial3D = null
## 探针用：最近一发从哪到哪。起点必须等于枪口。
var last_from := Vector3.ZERO
var last_to := Vector3.ZERO
var _audio: AudioStreamPlayer = null
var _rng := RandomNumberGenerator.new()

## 从内容读出来的那一组数。开局由 `setup()` 填。
var weapon_id := ""
var damage := 1
var reach := 100.0
var interval := 0.5
var mag_size := 1
var reload_time := 1.0
var spread := 0.0
var recoil_pitch := 0.0
var recoil_yaw := 0.0
var auto := false

var ammo := 0
## 记分：开了几枪、打中几发。命中率是这两个数除出来的，不另外存。
var shots := 0
var hits := 0

var _cool := 0.0
var _reloading := 0.0
var _trigger := false

## 复用的射线查询对象。开火是高频动作，每发 new 一份参数对象会把
## "每帧一次"的教训在射速上重演一遍（第 13 步会盯着每帧次数）。
var _ray := PhysicsRayQueryParameters3D.new()
var _exclude: Array[RID] = []


## 从内容读一把枪。返回 false = 内容损坏（没有 wieldable 段）。
##
## 读取点只有一个：`components.wieldable`。引擎不认 "rifle" 这个名字 ——
## 加一把新枪不需要改这里（铁律 2）。
func setup(player, camera: Camera3D, pack, id: String, vitals) -> bool:
	_player = player
	_camera = camera
	_pack = pack
	_vitals = vitals
	weapon_id = id
	_rng.randomize()

	var entity: Dictionary = pack.entity_of(id)
	if entity.is_empty():
		push_error("武器 `%s` 不存在" % id)
		return false
	var w: Dictionary = (entity.get("components", {}) as Dictionary).get("wieldable", {})
	if w.is_empty():
		push_error("武器 `%s` 没有 wieldable 组件（kind=weapon 必须有）" % id)
		return false

	damage = int(w.get("damage", 1))
	reach = float(w.get("reach", 100.0))
	var rate := maxf(0.05, float(w.get("rate", 2.0)))
	interval = 1.0 / rate
	mag_size = maxi(1, int(w.get("mag", 1)))
	reload_time = maxf(0.0, float(w.get("reload", 1.0)))
	spread = float(w.get("spread", 0.0))
	# 内容里的后坐是**度**（作者写的数），相机要的是弧度。
	# 第一版直接把 0.85 当弧度用 —— 一发就抬 48 度，第二枪打到天上去了，
	# 而"打中会疼"那条探针照样绿（它只开了第一枪）。
	recoil_pitch = deg_to_rad(float(w.get("recoil_pitch", 0.0)))
	recoil_yaw = deg_to_rad(float(w.get("recoil_yaw", 0.0)))
	auto = bool(w.get("auto", false))
	ammo = mag_size

	_make_audio(String(w.get("sound", "")))
	return true


## 把枪挂到相机上。由玩家在入树之后调用 —— 相机还没有父节点时挂不上去。
func setup_view(camera: Camera3D) -> void:
	if _view != null:
		return
	_view = GUN_VIEW.new()
	_view.name = "gun_view"
	# 入树之前把玩家交给视图模型：它要读速度和落地状态做晃动。
	# 入树之后再给也行，但第一帧的 `_ready` 已经在跑了 ——
	# 那会让枪在头一帧里没有晃动基准，看起来像"落地瞬间卡了一下"。
	if _view.has_method("bind"):
		_view.call("bind", _player)
	camera.add_child(_view)
	_setup_world_gun()


## 第三人称看到的枪。挂在外观下面，具体挂哪根骨头由 `gun_world.gd` 决定。
## 第一人称时外观整个隐藏，它自然也跟着不见（这里仍然显式开关一次，不靠巧合）。
func _setup_world_gun() -> void:
	if _player == null:
		return
	var host: Node3D = _player.get_node_or_null("visual")
	if host == null:
		host = _player
	_world_view = GUN_WORLD.new()
	_world_view.name = "gun_world"
	host.add_child(_world_view)


## 第三人称下把枪藏起来：它挂在相机上，不藏的话画面右下角会飘着一把
## 没有人的枪，而且比玩家本人还显眼。
func set_shown(shown: bool) -> void:
	_shown = shown
	if _view != null and _view.has_method("set_shown"):
		_view.call("set_shown", shown)
	if _world_view != null and _world_view.has_method("set_shown"):
		_world_view.call("set_shown", not shown)


## 鼠标转身。枪的惯性甩动由视图模型自己算，这里只转一道手 ——
## 玩家不该知道"枪的视图"长什么样，它只知道自己转过视角。
func look(relative: Vector2) -> void:
	if _view != null and _view.has_method("look"):
		_view.call("look", relative)


func _make_audio(sound_id: String) -> void:
	if sound_id.is_empty() or _player == null:
		return
	var path: String = ProjectSettings.globalize_path("res://") \
			.path_join("..").path_join(SFX_SUBDIR).path_join(sound_id + ".ogg")
	if not FileAccess.file_exists(path):
		# 静音是可接受的回退，静默失败不是：内容里写了 sound 却读不到，
		# 玩家只会觉得"这枪没声音"，而作者会以为音效生效了。
		push_error("音效 `%s` 读不到：%s（枪会没声音，但能开火）" % [sound_id, path])
		return
	var stream := AudioStreamOggVorbis.load_from_file(path)
	if stream == null:
		push_error("音效 `%s` 解析失败" % sound_id)
		return
	_audio = AudioStreamPlayer.new()
	_audio.name = "gun_audio"
	_audio.stream = stream
	# 连发时一声压一声：允许 4 个同时响，否则 9 发/秒会把前一声掐断，
	# 听起来像断续的电流声而不是枪声。
	_audio.max_polyphony = 4
	_player.add_child(_audio)


## 扳机。半自动在"按下"这一下就打出去，全自动靠 `tick()` 按射速续。
func trigger(down: bool) -> void:
	_trigger = down
	if not down:
		return
	if _reloading > 0.0 or _cool > 0.0:
		return
	if ammo <= 0:
		reload()
		return
	if not auto:
		_fire()


func reload() -> bool:
	if _reloading > 0.0 or ammo >= mag_size:
		return false
	if reload_time <= 0.0:
		ammo = mag_size
		return true
	_reloading = reload_time
	# 换弹的"进度"住在这里，动画住在视图模型里。把总时长传过去，
	# 动画自己按它变速 —— 否则内容里把 reload 从 1.7 改成 1.0 那天，
	# 弹匣已经满了，手还在慢悠悠地拉枪栓。
	if _view != null and _view.has_method("reload_started"):
		_view.call("reload_started", reload_time)
	return true


func tick(delta: float) -> void:
	if _cool > 0.0:
		_cool -= delta
	# 先摆枪口：这一帧还没开火时，枪管指向准心。开火时 `_fire()` 会用
	# 这一发的**实际落点**覆盖它 —— 于是枪管和曳光永远指向同一个点。
	# 顺序不能反：反了的话，"打偏一点"的那一枪，枪管仍然指着准心，
	# 玩家看到的是"枪口没动，子弹歪了"，正是这次要修的那种分裂。
	if _shown and _camera != null and _view != null and _view.has_method("aim_at_world"):
		_view.call("aim_at_world", _aim_point())
	if _reloading > 0.0:
		_reloading -= delta
		if _reloading <= 0.0:
			ammo = mag_size
			if _view != null and _view.has_method("reload_finished"):
				_view.call("reload_finished")
	elif _trigger and auto and _cool <= 0.0:
		if ammo <= 0:
			reload()
		else:
			_fire()
	if _view != null and _view.has_method("tick"):
		_view.call("tick", delta)
	_tick_tracers(delta)


## 一发。顺序有意义：先扣弹、再打射线、最后才给反馈 ——
## 反过来（先播放枪声）会出现"没子弹也能响一声"的空枪幻听。
##
## **子弹从枪口出去，不是从眼睛出去。** 眼睛只回答"准心落在哪"；
## 打中谁由枪口到那个点的那条线决定。玩家看到的曳光从枪口开始。
func _fire() -> void:
	if ammo <= 0 or _camera == null:
		return
	ammo -= 1
	shots += 1
	_cool = interval

	var xf := _camera.global_transform
	var forward := -xf.basis.z
	# 1) 准心落在哪：屏幕中心那条线，不带散布。
	var aim := _aim_point()
	# 2) 枪口在哪。第一人称用视图模型上量出来的那个点；没有视图时退回相机。
	var from := xf.origin
	if _shown and _view != null and _view.has_method("muzzle_world"):
		from = _view.call("muzzle_world")
	var dir := aim - from
	if dir.length() < 0.25:
		dir = forward
	dir = dir.normalized()
	# 3) 散布：绕相机轴抖 —— 抖的是"瞄偏了多少"，不是枪口的位置。
	var rad := deg_to_rad(spread)
	if rad > 0.0:
		dir = dir.rotated(xf.basis.x, _rng.randf_range(-rad, rad))
		dir = dir.rotated(xf.basis.y, _rng.randf_range(-rad, rad))

	# 4) 从枪口打出去。命中、曳光终点、伤害方向都以这一条为准。
	var hit := _cast(from, from + dir * reach)
	var end := from + dir * reach
	if not hit.is_empty():
		end = hit["position"]
	last_from = from
	last_to = end
	if _shown and _view != null and _view.has_method("aim_at_world"):
		# 让枪管对准这一发的实际落点（散布之后的那个点）。
		_view.call("aim_at_world", end)
	_spawn_tracer(from, end)
	if _world_view != null and _world_view.has_method("pulse"):
		_world_view.call("pulse")

	if not hit.is_empty() and _vitals != null:
		# 引擎不判断"打中的是不是怪"——它只问血量系统"这个东西会不会疼"。
		# **方向一起传过去**：枪口到落点的方向，就是击退的方向。
		var r: Dictionary = _vitals.damage(hit.get("collider"), damage, dir)
		if bool(r.get("ok", false)):
			hits += 1
			hit_confirmed.emit()

	# 后坐与声音属于"打出去了"这件事，不管有没有命中。
	if _player != null and (recoil_pitch != 0.0 or recoil_yaw != 0.0):
		_player.add_recoil(recoil_pitch, _rng.randf_range(-recoil_yaw, recoil_yaw))
	if _audio != null:
		# 每发随机音高 ±5%：同一个采样连放十次听起来像复印机，
		# 而这一点点偏差就足够让它像"枪在工作"。
		_audio.pitch_scale = _rng.randf_range(0.95, 1.05)
		_audio.play()
	if _view != null and _view.has_method("kick"):
		_view.call("kick")


## 屏幕中心那条线打到哪。没有命中就打满射程 —— 枪口仍然要有个方向。
func _aim_point() -> Vector3:
	var xf := _camera.global_transform
	var far := xf.origin - xf.basis.z * reach
	var hit := _cast(xf.origin, far)
	return far if hit.is_empty() else (hit["position"] as Vector3)


## 一条射线。排除玩家自己 —— 枪口就在玩家身前，不排除会先打中自己。
func _cast(from: Vector3, to: Vector3) -> Dictionary:
	_ray.from = from
	_ray.to = to
	_ray.collide_with_bodies = true
	_exclude.clear()
	if _player != null:
		_exclude.append(_player.get_rid())
	_ray.exclude = _exclude
	return _camera.get_world_3d().direct_space_state.intersect_ray(_ray)


## 一条从枪口到落点的曳光。不是"子弹模型"——是一道 0.06 秒的亮线，
## 让玩家看见"这一发真的从枪口出去了、打到了那里"。
##
## 挂在玩家的父节点上并 `top_level`：曳光是世界里的东西，
## 不该跟着角色转身/缩放，也不该被手里的枪带着走。
func _spawn_tracer(a: Vector3, b: Vector3) -> void:
	var length := a.distance_to(b)
	if length < 0.08 or _player == null:
		return
	var host: Node = _player.get_parent()
	if host == null:
		return
	var dir := (b - a) / length
	var up := Vector3.UP if absf(dir.dot(Vector3.UP)) < 0.98 else Vector3.RIGHT
	var t := Node3D.new()
	t.top_level = true
	host.add_child(t)
	t.global_transform = Transform3D(Basis.looking_at(dir, up), (a + b) * 0.5)
	var mi := MeshInstance3D.new()
	mi.mesh = _tracer_box()
	mi.material_override = _tracer_material()
	mi.scale = Vector3(1.0, 1.0, length)
	t.add_child(mi)
	_tracers.append({"node": t, "life": TRACER_TIME})


func _tracer_box() -> BoxMesh:
	if _tracer_mesh == null:
		_tracer_mesh = BoxMesh.new()
		_tracer_mesh.size = Vector3(0.012, 0.012, 1.0)
	return _tracer_mesh


func _tracer_material() -> StandardMaterial3D:
	if _tracer_mat != null:
		return _tracer_mat
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = Color(1.0, 0.88, 0.52, 1.0)
	m.emission_enabled = true
	m.emission = Color(1.0, 0.8, 0.4)
	m.emission_energy_multiplier = 2.0
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	# 不测深度：枪口就在画面右侧的枪身上，测深度会被自己的枪挡住。
	m.no_depth_test = true
	_tracer_mat = m
	return m


func _tick_tracers(delta: float) -> void:
	for i in range(_tracers.size() - 1, -1, -1):
		_tracers[i]["life"] = float(_tracers[i]["life"]) - delta
		if float(_tracers[i]["life"]) > 0.0:
			continue
		var n = _tracers[i]["node"]
		if is_instance_valid(n):
			n.queue_free()
		_tracers.remove_at(i)


## 探针用：当前还活着的曳光数量。
func tracer_count() -> int:
	return _tracers.size()


## HUD 与探针共用的一份快照。命中率在这里算，而不是各算各的。
func stats() -> Dictionary:
	return {
		"weapon": weapon_id,
		"ammo": ammo,
		"mag": mag_size,
		"reloading": _reloading > 0.0,
		"shots": shots,
		"hits": hits,
		"accuracy": float(hits) / float(shots) if shots > 0 else 0.0,
	}
