extends SceneTree

## 生成菜单探针：打开菜单 → 放一件刚体 → 放一件固定物 → 关菜单。
##
## 为什么要真跑：菜单是纯运行时 UI，无头自检一个节点都不建，
## 而 UI 的错法通常是"能打开但点了没反应"或"打开之后操作卡住"——
## 两者都不报错，只有真的走一遍才知道。
##
## 为什么要放两种：动态走 world.add_dynamic（登记 handle、发 entity.spawn），
## 静态走 world.add_static（进 world.props，进存档）。两条路的错法完全不同，
## 只测一条会让另一条一直"看起来能用"。

var _main
var _f := 0
var _bodies0 := 0
var _props0 := 0
var _called_rigid := false
var _called_static := false


func _initialize() -> void:
	_main = load("res://main.tscn").instantiate()
	root.add_child(_main)


func _menu():
	return _main.get_node("spawn_menu")


func _process(_delta: float) -> bool:
	_f += 1

	if _f == 20:
		# 常驻提示藏着的话，玩家永远不知道 Tab 是干什么的。
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
			print("MENU 放刚体：%s → %s（刚体 %d）"
				% [_menu()._ids[idx], ok, _main._world.bodies.size()])

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

	if _f == 80:
		var menu = _menu()
		print("MENU 状态栏：%s" % menu._status.text)
		# 截图只在真有显示的时候做。CI 是无头的，拿不到视口纹理 ——
		# 而"因为拿不到截图所以整条验收失败"会让这条检查在 CI 里被删掉。
		if DisplayServer.get_name() != "headless":
			var img := root.get_viewport().get_texture().get_image()
			if img != null:
				img.save_png("res://spawn_menu.png")
				print("MENU 截图：res://spawn_menu.png")

	if _f == 95:
		var menu = _menu()
		menu.set_open(false)
		var released: bool = not _main._player.input_blocked
		var bodies: int = _main._world.bodies.size()
		var props: int = _main._world.props.size()
		print("MENU 关闭后输入恢复：%s" % released)
		var ok: bool = released and bodies == _bodies0 + 1 and props == _props0 + 1
		print("MENU RESULT %s（刚体 %d→%d，静态物 %d→%d）"
			% ["OK" if ok else "FAIL", _bodies0, bodies, _props0, props])
		quit(0 if ok else 1)

	return false


## 菜单里第一个"会动 / 不会动"的项。按数据判断，不按名字猜。
func _index_of(rigid: bool) -> int:
	var menu = _menu()
	for i in menu._ids.size():
		if _main.pack.places_as_rigid(menu._ids[i]) == rigid:
			return i
	return -1
