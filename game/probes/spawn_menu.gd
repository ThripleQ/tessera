extends SceneTree

## 生成菜单探针：开菜单 → 放一件刚体 → 放一件固定物 → 关菜单 → 把放下的东西拆掉。
##
## 为什么要真跑：菜单是纯运行时 UI，无头自检一个节点都不建，
## 而 UI 的错法通常是"能打开但点了没反应"或"打开之后操作卡住"——
## 两者都不报错，只有真的走一遍才知道。
##
## 为什么要放两种、还要拆：动态走 `world.add_dynamic`（登记 handle、发 entity.spawn），
## 静态走 `world.add_static`（进 world.props、进存档、**没有 handle**）。
## 拆也分两条路：玩家右键走 `world.remove_thing`，mod 走 `api.remove(handle)`。
## 四条路各错各的，只测一条会让另外三条一直"看起来能用"。
##
## 预算也要能还回去：放满 96 件之后沙盒就死了，而"拆了却不归还预算"
## 表现成"我明明拆了，还是放不下"——这种事只会被玩家发现，不会被代码发现。

var _main
var _f := 0
var _bodies0 := 0
var _props0 := 0
var _crate_handle := 0
var _props_at_aim := 0
var _before_remove := 0
var _called_rigid := false
var _called_static := false
var _placed_ok := false
var _scraped_ok := false
var _removed_ok := false
var _refused_ok := false
var _aim_pos := Vector3.ZERO


func _initialize() -> void:
	_main = load("res://main.tscn").instantiate()
	root.add_child(_main)


func _menu():
	return _main.get_node("spawn_menu")


func _process(_delta: float) -> bool:
	_f += 1

	if _f == 20:
		# 常驻提示藏着的话，玩家永远不知道 Tab 和右键是干什么的。
		print("MENU 常驻提示可见：%s" % _menu().get_node("hint").visible)

	if _f == 30:
		_menu().set_open(true)
		var ids: Array = _menu()._ids
		print("MENU 打开：%d 项，第一项 %s" % [ids.size(), ids[0] if not ids.is_empty() else "-"])
		print("MENU 名称来自内容：%s" % _menu()._list.get_item_text(0))
		print("MENU 玩家输入被接管：%s" % _main._player.input_blocked)
		_bodies0 = _main._world.bodies.size()
		_props0 = _main._world.props.size()
		print("MENU 起始：刚体 %d / 静态物 %d" % [_bodies0, _props0])

	if _f == 45 and not _called_rigid:
		_called_rigid = true
		var idx := _index_of(true)
		if idx < 0:
			print("MENU 找不到可生成的刚体 —— 生成菜单形同虚设")
		else:
			_menu()._list.select(idx)
			var ok: bool = _menu().spawn_selected()
			# 菜单不放回 handle，从世界里认一下刚放进来的那个：
			# 它一定是 bodies 里最后一个，而这是引擎的登记顺序，不是猜的。
			if ok and _main._world.bodies.size() > _bodies0:
				_crate_handle = int(_main._world.bodies[-1].get_meta("handle", 0))
			print("MENU 放刚体：%s → %s（刚体 %d，handle %d）"
				% [_menu()._ids[idx], ok, _main._world.bodies.size(), _crate_handle])

	if _f == 60 and not _called_static:
		_called_static = true
		var idx := _index_of(false)
		if idx < 0:
			print("MENU 找不到可生成的固定物 —— 静态摆放那条路没被测到")
		else:
			_menu()._list.select(idx)
			var ok: bool = _menu().spawn_selected()
			print("MENU 放固定物：%s → %s（静态物 %d）"
				% [_menu()._ids[idx], ok, _main._world.props.size()])

	if _f == 75:
		var menu = _menu()
		print("MENU 状态栏：%s" % menu._status.text)
		# 截图只在真有显示的时候做。CI 是无头的，拿不到视口纹理 ——
		# 而"因为拿不到截图所以整条验收失败"会让这条检查在 CI 里被删掉。
		if DisplayServer.get_name() != "headless":
			var img := root.get_viewport().get_texture().get_image()
			if img != null:
				img.save_png("res://spawn_menu.png")
				print("MENU 截图：res://spawn_menu.png")

	if _f == 85:
		var menu = _menu()
		menu.set_open(false)
		_placed_ok = _main._world.bodies.size() == _bodies0 + 1 \
			and _main._world.props.size() == _props0 + 1
		print("MENU 关闭后输入恢复：%s" % (not _main._player.input_blocked))
		print("MENU 放完后：刚体 %d / 静态物 %d / 预算已用 %d"
			% [_main._world.bodies.size(), _main._world.props.size(),
				_main.api.budget_used()])

	if _f == 92:
		# 在脚下正前方立一根柱子，然后把视角压下去看它 —— 这样"右键拆"
		# 走的是玩家真正的路径（射线 → world.remove_thing），而不是内部函数。
		_aim_pos = _main._player.global_position + Vector3(0.0, 0.0, -1.2)
		var sid := _pick_static()
		var r: Dictionary = _main.api.spawn(sid, _aim_pos, 0.0)
		_props_at_aim = _main._world.props.size()
		print("SCRAPE 立柱子 %s：%s（静态物 %d）"
			% [sid, r.get("ok", false), _props_at_aim])
		_main._player.set_pose({
			"pos": _main._player.global_position,
			"yaw": float(_main._player.pose()["yaw"]),
			"pitch": -0.62,
		})

	if _f == 100:
		# 让相机真的转过去：set_pose 改的是 arm 的旋转，方向要等下一帧才生效。
		var ok: bool = _main._player.hands().scrape()
		_scraped_ok = ok and _main._world.props.size() == _props_at_aim - 1
		print("SCRAPE 右键拆：%s，静态物 %d → %d（拆一件只少一件：%s）"
			% [ok, _props_at_aim, _main._world.props.size(), _scraped_ok])

	if _f == 108:
		# mod 那条路：拿 handle 拆刚体。
		_before_remove = _main._world.bodies.size()
		var ok: bool = _main.api.remove(_crate_handle)
		_removed_ok = ok and _main._world.bodies.size() == _before_remove - 1 \
			and _main.api.budget_used() == 1
		print("SCRAPE api.remove(%d)：%s，刚体 %d → %d，预算剩 %d"
			% [_crate_handle, ok, _before_remove, _main._world.bodies.size(),
				_main.api.budget_used()])

	if _f == 112:
		# **房间自带的障碍不许被拆。** 它和玩家摆的柱子在物理上一模一样，
		# 区别只在"归属"：房间的是内容的形状，不在 world.props 里。
		# 没有这条守卫，玩家能把房间一块一块拆掉，而世界会留下一个
		# 既不属于内容、也不属于存档的洞。
		var room_body := _room_obstacle()
		if room_body == null:
			print("SCRAPE 找不到房间自带障碍 —— 这条守卫没法验证")
			_refused_ok = false
		else:
			_refused_ok = not _main._world.remove_thing(room_body)
			print("SCRAPE 拆房间的 %s：%s（必须被拒绝：%s）"
				% [room_body.name, not _refused_ok, _refused_ok])

	if _f == 118:
		var bodies: int = _main._world.bodies.size()
		var props: int = _main._world.props.size()
		var used: int = _main.api.budget_used()
		var released: bool = not _main._player.input_blocked
		# 菜单放的那件固定物还在（拆的是另外两件），所以这里期望 p0 + 1。
		var final_ok := bodies == _bodies0 and props == _props0 + 1 and used == 1
		var ok: bool = released and _placed_ok and _scraped_ok and _removed_ok \
			and _refused_ok and final_ok
		print("MENU RESULT %s（放 %s / 右键拆 %s / api 拆 %s / 房间不可拆 %s / 收尾 %s）"
			% ["OK" if ok else "FAIL",
				"OK" if _placed_ok else "FAIL",
				"OK" if _scraped_ok else "FAIL",
				"OK" if _removed_ok else "FAIL",
				"OK" if _refused_ok else "FAIL",
				"OK" if (final_ok and released) else "FAIL"])
		print("MENU 收尾：刚体 %d→%d，静态物 %d→%d，预算已用 %d"
			% [_bodies0, bodies, _props0, props, used])
		quit(0 if ok else 1)

	return false


## 菜单里第一个"会动 / 不会动"的项。按数据判断，不按名字猜。
func _index_of(rigid: bool) -> int:
	var menu = _menu()
	for i in menu._ids.size():
		if _main.pack.places_as_rigid(menu._ids[i]) == rigid:
			return i
	return -1


## 挑一件静态内容来立柱子。探针不许认识内容 id（铁律 2 对探针一样有效）。
func _pick_static() -> String:
	for id in _main.pack.spawnables():
		if not _main.pack.places_as_rigid(id):
			return id
	return ""


## 房间里的一块静态碰撞体（障碍或地板）。用来验证"房间不可拆"。
## 从 chunks 里取，而不是从 world.props 里 —— 后者全是玩家摆的。
func _room_obstacle() -> Node:
	for room_id in _main._world.chunks:
		for child in _main._world.chunks[room_id].get_children():
			if child is StaticBody3D:
				return child
	return null
