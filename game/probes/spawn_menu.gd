extends SceneTree

## 生成菜单探针：开菜单 → 放刚体 → 放固定物 → 收进背包 → 从背包放回 → 再收 →
## 堆叠上限与价值 → 用 api 拆刚体 → 拆房间（必须被拒绝）。
##
## 为什么要真跑：菜单是纯运行时 UI，无头自检一个节点都不建，
## 而 UI 的错法通常是"能打开但点了没反应"或"打开之后操作卡住"——
## 两者都不报错，只有真的走一遍才知道。
##
## 为什么要在"收"和"放"之间来回一趟：这两件事共用一份预算、一份库存。
## 只测单向的话，"收进去的东西放不出来"和"放出来没扣库存"都会漏掉，
## 而它们的表现是玩家丢东西 —— 最难被玩家说清楚、最容易被我们当成偶发。
##
## 四条路径各错各的：
##   玩家右键收    → `world.remove_thing` → 背包
##   菜单从背包放  → 背包 → `api.spawn`
##   mod 拿 handle 拆 → `api.remove`（这一条**不进背包**：mod 的动词是"让它消失"）
##   房间的障碍    → 必须被拒绝（内容的形状 vs 玩家的动作）

var _main
var _f := 0
var _bodies0 := 0
var _props0 := 0
var _crate_handle := 0
var _props_after_spawn := 0
var _before_remove := 0
var _called_rigid := false
var _called_static := false
var _placed_ok := false
var _reticle_ok := false
var _scraped_ok := false
var _replaced_ok := false
var _removed_ok := false
var _refused_ok := false
var _stack_pick_ok := false
var _stack_full_ok := false
var _stack_ok := false
var _aim_pos := Vector3.ZERO
var _static_id := ""
var _stack_id := ""
var _charm2: RigidBody3D = null


func _initialize() -> void:
	_main = load("res://main.tscn").instantiate()
	root.add_child(_main)


func _menu():
	return _main.get_node("spawn_menu")


func _bag():
	return _main._player.bag()


func _process(_delta: float) -> bool:
	_f += 1

	if _f == 10:
		# 这一整套（抓 / 放 / 收 / 世界里的落点圈）都是**第三人称**的玩法。
		# 第一人称下左键是扳机、屏中是另一个准心、落点圈故意藏着 ——
		# 探针要验的是抓放那条链，所以先显式切回第三人称。
		# 不能放在 `_initialize` 里：那一刻 main 的 `_ready` 还没跑，玩家还不存在。
		_main._player.toggle_view()

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
		print("MENU 起始：刚体 %d / 静态物 %d / 背包 %d" % [_bodies0, _props0, _bag().total()])

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
			_static_id = String(_menu()._ids[idx])
			var ok: bool = _menu().spawn_selected()
			print("MENU 放固定物：%s → %s（静态物 %d）"
				% [_static_id, ok, _main._world.props.size()])

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
		print("MENU 放完后：刚体 %d / 静态物 %d / 预算已用 %d / 背包 %d"
			% [_main._world.bodies.size(), _main._world.props.size(),
				_main.api.budget_used(), _bag().total()])

	if _f == 88:
		# ---- 拾取与堆叠：pickup 组件的 stack / value 必须是真规则 ----
		# 只调视角。**落点必须等下一帧再算**：set_pose 改的是 arm 的旋转，
		# 相机方向要到下一帧才生效 —— 同帧算出来的落点还是旧朝向的，
		# 东西会放在"我以为在的地方"的旁边，而射线却指向真正的地方。
		_main._player.set_pose({
			"pos": _main._player.global_position,
			"yaw": float(_main._player.pose()["yaw"]),
			"pitch": -0.62,
		})

	if _f == 92:
		# 堆叠上限和价值都必须来自内容，而不是引擎里的常数。
		# 两份都读：pack 的查询是引擎路径，直接读 entities 是内容真相 ——
		# 两边对不上，说明引擎把数值写死过。
		_stack_id = _stackable_id()
		if _stack_id.is_empty():
			_print_stack_fail("内容里没有任何可堆叠的东西（pickup.stack），堆叠规则无从验证")
		else:
			var raw: Dictionary = _main.pack.entities[_stack_id].get("components", {}).get("pickup", {})
			var lim: int = _main.pack.stack_limit(_stack_id)
			var lim_ok: bool = lim > 0 and lim == int(raw.get("stack", -1))
			var fill_ok := true
			for i in lim - 1:
				if not _bag().add(_stack_id):
					fill_ok = false
					break
			print("STACK 堆叠上限 %s：%d（内容写 %d，一致：%s），先填到 %d：%s"
				% [_stack_id, lim, int(raw.get("stack", -1)), lim_ok, lim - 1, fill_ok])
			# 真实路径的"拾取"：东西在世界里，右键收，必须进背包。
			# 放和收**同一帧**完成：物理帧和探针帧不同步，隔几帧它可能被
			# 推开或者滚走，而那不是拾取的问题，是时序的噪声。
			var at: Vector3 = _aim_spot()
			var r: Dictionary = _main.api.spawn(_stack_id, at, 0.0)
			var charm: RigidBody3D = _main._world.bodies[-1] if bool(r.get("ok", false)) else null
			if charm != null:
				charm.global_position = at + Vector3(0.0, 0.17, 0.0)
				charm.linear_velocity = Vector3.ZERO
			var got: String = _main._player.hands().collect()
			_stack_pick_ok = not got.is_empty() and got == _stack_id \
				and _bag().count(_stack_id) == lim
			print("STACK 拾取：%s → %s（背包 %s）"
				% [_stack_id, got if not got.is_empty() else "（什么都没收到）", _bag().describe()])

	if _f == 96:
		# 堆叠上限必须在"收"的那一刻生效：满叠再收 = 什么都不做，
		# 而且是**先拒绝再保留世界里的那一件** —— 顺序反了东西就凭空消失。
		# 断言里必须有"瞄着的确实是自己的东西"：否则射线打空时也会"拒绝"，
		# 那是另一回事，绿了等于没测。
		var lim: int = _main.pack.stack_limit(_stack_id) if not _stack_id.is_empty() else 0
		var at: Vector3 = _aim_spot()
		var r: Dictionary = _main.api.spawn(_stack_id, at, 0.0) if not _stack_id.is_empty() else {}
		var n_world: int = _main._world.bodies.size()
		_charm2 = _main._world.bodies[-1] if bool(r.get("ok", false)) else null
		if _charm2 != null:
			_charm2.global_position = at + Vector3(0.0, 0.17, 0.0)
			_charm2.linear_velocity = Vector3.ZERO
		var hands = _main._player.hands()
		var can: bool = hands.can_collect()
		var aimed = hands.aim_node()
		var aimed_mine: bool = aimed != null and _main._world.is_made(aimed)
		var got: String = hands.collect()
		_stack_full_ok = not _stack_id.is_empty() and got.is_empty() and not can \
			and aimed_mine and _main._world.bodies.size() == n_world \
			and _bag().count(_stack_id) == lim
		print("STACK 满叠拒收：%s（瞄着自己的东西 %s，准星可收 %s，世界仍有 %d 件，背包 %s）"
			% ["拒绝" if got.is_empty() else ("收走了 " + got), aimed_mine, can,
				_main._world.bodies.size(), _bag().describe()])

	if _f == 100:
		# value 必须也是真规则：背包合计 = Σ 件数 × 内容里的 value。
		# 期望值直接读内容原文，不经过 pack.value_of —— 否则两个都错时断言照样绿。
		var want_v := 0
		for bid in _bag().ids():
			var raw: Dictionary = _main.pack.entities[bid].get("components", {}).get("pickup", {})
			want_v += _bag().count(bid) * int(raw.get("value", 0))
		var got_v: int = _bag().total_value()
		var value_ok: bool = got_v == want_v and want_v > 0
		# 菜单标签要把堆叠上限亮出来（×20/20），玩家要看得见"还能不能捡"。
		_menu().set_open(true)
		var idx := _index_of_id(_stack_id)
		var label: String = _menu()._list.get_item_text(idx) if idx >= 0 else "（没进菜单）"
		var label_ok: bool = idx >= 0 and label.contains("×%d/%d" % [
			_main.pack.stack_limit(_stack_id), _main.pack.stack_limit(_stack_id)])
		_menu().set_open(false)
		# 手改存档也不能绕过堆叠上限。from_save 要把它压回去。
		var lim: int = _main.pack.stack_limit(_stack_id) if not _stack_id.is_empty() else 0
		if not _stack_id.is_empty():
			_bag().from_save([{"id": _stack_id, "n": lim + 5}])
		var clamp_ok: bool = not _stack_id.is_empty() and _bag().count(_stack_id) == lim
		_stack_ok = value_ok and label_ok and clamp_ok
		print("STACK 价值 %d（内容合计 %d）/ 标签「%s」/ 存档超限压回 %d → %d：%s"
			% [got_v, want_v, label, lim + 5, _bag().count(_stack_id), _stack_ok])
		# 收尾：把堆叠测试的世界和背包都清干净，不让它影响后面的结算。
		_bag().clear()
		if _charm2 != null and is_instance_valid(_charm2):
			_main._world.remove_thing(_charm2)
		_charm2 = null

	if _f == 112:
		# 柱子立在**准星的落点上**，不是算出来的某个偏移。
		# 上一版用的是 `玩家位置 + (0,0,-1.2)`，而那和射线实际打到的地方
		# 差了几十厘米 —— 于是射线从柱子旁边掠过打到地板，收的动作照样成功，
		# 但准星指着的地方和柱子不是一处。这种"碰巧对上"的测试最会骗人。
		var p: Dictionary = _main._player.hands().place_point()
		_aim_pos = p["pos"] if bool(p.get("ok", false)) \
			else _main._player.global_position + Vector3(0.0, 0.0, -1.2)
		var r: Dictionary = _main.api.spawn(_static_id, _aim_pos, 0.0)
		_props_after_spawn = _main._world.props.size()
		print("MENU 立在准星落点 %s：%s（静态物 %d）"
			% [_static_id, r.get("ok", false), _props_after_spawn])

	if _f == 118:
		# 准星。它必须和"能不能收"给出**同一个答案** —— 玩家看到的那个圈，
		# 就是他按下右键会发生的事。所以这几行放在一起验：
		#   圈可见 / 圈说可收 / hands 也说可收 / 瞄着的确实是自己的东西
		var reticle = _main.get_node("reticle")
		var hands = _main._player.hands()
		var can: bool = hands.can_collect()
		var aimed = hands.aim_node()
		var made: bool = _main._world.is_made(aimed)
		print("SCRAPE 准星：可见 %s，可收 %s，位置 %s（玩家 %s）"
			% [reticle.visible, can, reticle.global_position, _main._player.global_position])
		print("SCRAPE 瞄着：%s（是我的东西：%s）"
			% ["（空气）" if aimed == null else aimed.name, made])
		_reticle_ok = reticle.visible and can and made
		if DisplayServer.get_name() != "headless":
			var img := root.get_viewport().get_texture().get_image()
			if img != null:
				img.save_png("res://reticle.png")
				print("SCRAPE 截图：res://reticle.png")

	if _f == 126:
		var got: String = _main._player.hands().collect()
		_scraped_ok = not got.is_empty() \
			and _main._world.props.size() == _props_after_spawn - 1 \
			and _bag().count(_static_id) == 1
		print("SCRAPE 右键收：%s（静态物 %d → %d，背包 %s）"
			% [got if not got.is_empty() else "（什么都没收到）",
				_props_after_spawn, _main._world.props.size(), _bag().describe()])

	if _f == 132:
		# 从背包放回。菜单里那一项现在应该带 ×1，放下之后背包清空、世界多一件。
		_menu().set_open(true)
		var idx := _index_of_id(_static_id)
		if idx < 0:
			print("SCRAPE 背包里的东西没进菜单 —— 收了就再也放不出来")
		else:
			var label: String = _menu()._list.get_item_text(idx)
			_menu()._list.select(idx)
			var ok: bool = _menu().spawn_selected()
			_replaced_ok = ok and _bag().count(_static_id) == 0 \
				and _main._world.props.size() == _props_after_spawn
			print("SCRAPE 从背包放回：%s → %s（标签「%s」，背包 %s，静态物 %d）"
				% [_static_id, ok, label, _bag().describe(), _main._world.props.size()])
		_menu().set_open(false)

	if _f == 140:
		# mod 那条路：拿 handle 拆刚体。**不进背包** —— mod 的动词是"让它消失"。
		_before_remove = _main._world.bodies.size()
		var used_before: int = _main.api.budget_used()
		var ok: bool = _main.api.remove(_crate_handle)
		_removed_ok = ok and _main._world.bodies.size() == _before_remove - 1 \
			and _main.api.budget_used() == used_before - 1 \
			and _bag().total() == 0
		print("SCRAPE api.remove(%d)：%s，刚体 %d → %d，预算 %d → %d，背包 %s"
			% [_crate_handle, ok, _before_remove, _main._world.bodies.size(),
				used_before, _main.api.budget_used(), _bag().describe()])

	if _f == 148:
		# **房间自带的障碍不许被收走。** 它和玩家摆的柱子在物理上一模一样，
		# 区别只在"归属"：房间的是内容的形状，不在 world.props 里。
		# 没有这条守卫，玩家能把房间一块一块搬进背包，而世界会留下一个
		# 既不属于内容、也不属于存档的洞。
		var room_body := _room_obstacle()
		if room_body == null:
			print("SCRAPE 找不到房间自带障碍 —— 这条守卫没法验证")
			_refused_ok = false
		else:
			var before: int = _bag().total()
			var got: String = String(_main._world.remove_thing(room_body))
			_refused_ok = got.is_empty() and _bag().total() == before
			print("SCRAPE 收房间的 %s：%s（必须被拒绝：%s）"
				% [room_body.name, got if not got.is_empty() else "（拒绝）", _refused_ok])

	if _f == 156:
		var bodies: int = _main._world.bodies.size()
		var props: int = _main._world.props.size()
		var used: int = _main.api.budget_used()
		var released: bool = not _main._player.input_blocked
		# 结算：菜单放的固定物 + 收回又放回的那根柱子 = p0 + 2；
		# 背包空（收的那件已经放回去了，堆叠测试已清场）；
		# 预算 2（两个静态物，刚体已经被 api 拆掉，骨符收完已归还）。
		var final_ok: bool = bodies == _bodies0 and props == _props0 + 2 and used == 2 \
			and _bag().total() == 0 and released
		var ok: bool = _placed_ok and _reticle_ok and _scraped_ok and _replaced_ok \
			and _removed_ok and _refused_ok and _stack_pick_ok and _stack_full_ok \
			and _stack_ok and final_ok
		print("MENU RESULT %s（放 %s / 准星 %s / 收 %s / 拾取 %s / 堆叠 %s / 背包放回 %s / api 拆 %s / 房间不可收 %s / 收尾 %s）"
			% ["OK" if ok else "FAIL",
				"OK" if _placed_ok else "FAIL",
				"OK" if _reticle_ok else "FAIL",
				"OK" if _scraped_ok else "FAIL",
				"OK" if _stack_pick_ok else "FAIL",
				"OK" if (_stack_full_ok and _stack_ok) else "FAIL",
				"OK" if _replaced_ok else "FAIL",
				"OK" if _removed_ok else "FAIL",
				"OK" if _refused_ok else "FAIL",
				"OK" if final_ok else "FAIL"])
		print("MENU 收尾：刚体 %d→%d，静态物 %d→%d，预算已用 %d，背包 %d"
			% [_bodies0, bodies, _props0, props, used, _bag().total()])
		quit(0 if ok else 1)

	return false


## 菜单里第一个"会动 / 不会动"的项。按数据判断，不按名字猜。
func _index_of(rigid: bool) -> int:
	var menu = _menu()
	for i in menu._ids.size():
		if _main.pack.places_as_rigid(menu._ids[i]) == rigid:
			return i
	return -1


func _index_of_id(content_id: String) -> int:
	var menu = _menu()
	for i in menu._ids.size():
		if String(menu._ids[i]) == content_id:
			return i
	return -1


## 内容里第一件能堆叠的东西（pickup.stack > 0）。**按数据找，不写死 id** ——
## 探针写死 `item/bone_charm` 的那天起，改个内容名就要改探针。
func _stackable_id() -> String:
	for id in _main.pack.spawnables():
		if _main.pack.stack_limit(id) > 0:
			return id
	return ""


## 准星落点。打不到就退回玩家正前方 —— 和菜单的 _place_spot 同一条规则。
func _aim_spot() -> Vector3:
	var p: Dictionary = _main._player.hands().place_point()
	if bool(p.get("ok", false)):
		return p["pos"]
	return _main._player.global_position + Vector3(0.0, 0.0, -1.2)


func _print_stack_fail(msg: String) -> void:
	_stack_pick_ok = false
	_stack_full_ok = false
	_stack_ok = false
	print("STACK FAIL：%s" % msg)


## 房间里的一块静态碰撞体（障碍或地板）。用来验证"房间不可收"。
## 从 chunks 里取，而不是从 world.props 里 —— 后者全是玩家摆的。
func _room_obstacle() -> Node:
	for room_id in _main._world.chunks:
		for child in _main._world.chunks[room_id].get_children():
			if child is StaticBody3D:
				return child
	return null
