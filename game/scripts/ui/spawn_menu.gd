extends CanvasLayer

## 生成菜单 —— 产品三件事里的第二件："一切来自数据的生成菜单"。
##
## 它刻意不硬编码任何可放置的东西：清单来自 `pack.spawnables()`，名字来自内容里的
## `name` 字段。所以往 `content/` 里加一个 TOML，菜单里就自动多一项，这里一行都不用改。
## 这一条同时也是验收标准：如果加内容要改这个文件，说明"内容即数据"在某处漏了。
##
## **背包里的东西也在同一份清单里。** 玩家不需要理解"凭空生成"和"从背包拿出来"
## 的区别 —— 对他来说都是"我要放这个"。区别只在内部：有库存就先扣库存，
## 没库存就凭空造。分成两栏会让玩家每次都要想"我刚才捡的那个在哪儿"。
##
## 和 mod 的关系：玩家手动放的东西走 `api.spawn`，和 mod 造物**同一个通道、同一个预算**。
## 分开两套的后果是"玩家的东西能无限放，mod 的不能"——那预算就成了只约束好人的规矩。
##
## 上一版的取舍是"菜单打开时视角冻结，东西只能掉在正前方固定距离处"。
## 这一版补上了准星：手那条射线打到哪儿就放在哪儿，打不到才退回正前方。

const PANEL_W := 420.0
const PANEL_H := 470.0
const PANEL_MARGIN := 40.0

## 打不到东西时的兜底位置：站在面前两米多、齐胸高度。太近会卡进自己身体，
## 太远会让"点一下就出来"失去手感——它应该出现在你手能够到的地方。
const SPAWN_AHEAD := 2.4
const SPAWN_HEIGHT := 1.4

## 固定不动的东西在名字后面挂一个记号。玩家点之前就该知道它不会倒、也推不动 ——
## 放下去再发现"这个箱子是假的"是最差的体验。
const STATIC_MARK := "  ·固定"

## 会动的东西从落点上方多少米掉下来。直接放在落点上会和地面穿插，
## 物理引擎会用一次弹跳把它顶出来 —— 看起来像"东西被我放炸了"。
const DROP_LIFT := 0.45
## 钉住的东西贴到侧壁上时往外推多远。它的原点在底面中心，
## 直接放在墙面命中点上等于把箱子埋进墙里一半。
const WALL_CLEARANCE := 0.28
## 法线的 Y 分量大于这个值就当它是"地面"，不做侧壁外推。
const FLOOR_NORMAL_Y := 0.7

## 收集反馈的停留时间。太短看不见，太长会挡住画面。
const TOAST_TIME := 1.6

var pack = null
var api = null
var player = null
var bag = null

var _panel: PanelContainer
var _list: ItemList
var _status: Label
var _hint: Label
var _toast: Label
var _toast_left := 0.0
var _open := false
var _ids: Array[String] = []


func _ready() -> void:
	layer = 20
	# 菜单要在暂停时也能用。将来真加了暂停，这条会救一次。
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build()
	_panel.visible = false


func _build() -> void:
	_panel = PanelContainer.new()
	_panel.name = "panel"
	# 贴左边、垂直居中，**不居中**。东西是从玩家正前方掉下来的，
	# 面板压在那儿就等于"放完看不见自己放了什么" —— 而看见才是这个菜单的意义。
	_panel.anchor_left = 0.0
	_panel.anchor_right = 0.0
	_panel.anchor_top = 0.5
	_panel.anchor_bottom = 0.5
	_panel.offset_left = PANEL_MARGIN
	_panel.offset_right = PANEL_MARGIN + PANEL_W
	_panel.offset_top = -PANEL_H * 0.5
	_panel.offset_bottom = PANEL_H * 0.5

	var box := StyleBoxFlat.new()
	box.bg_color = Color(0.08, 0.09, 0.13, 0.94)
	box.border_color = Color(0.38, 0.66, 0.96)
	box.set_border_width_all(2)
	box.set_corner_radius_all(12)
	box.content_margin_left = 18
	box.content_margin_right = 18
	box.content_margin_top = 14
	box.content_margin_bottom = 14
	_panel.add_theme_stylebox_override("panel", box)
	add_child(_panel)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 10)
	_panel.add_child(col)

	var title := Label.new()
	title.name = "title"
	title.text = "生成"
	title.add_theme_font_size_override("font_size", 22)
	title.add_theme_color_override("font_color", Color(0.85, 0.93, 1.0))
	col.add_child(title)

	_list = ItemList.new()
	_list.name = "list"
	_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_list.add_theme_font_size_override("font_size", 16)
	_list.item_activated.connect(_on_activated)
	col.add_child(_list)

	_status = Label.new()
	_status.name = "status"
	_status.add_theme_font_size_override("font_size", 13)
	_status.add_theme_color_override("font_color", Color(0.62, 0.70, 0.82))
	_status.text = "选中后双击或回车生成 · Tab 关闭"
	col.add_child(_status)

	# 常驻提示。藏起来的话，玩家永远不知道有这个功能 ——
	# 而"能放东西"是这个产品目前唯一还没兑现的承诺。
	_hint = Label.new()
	_hint.name = "hint"
	_hint.text = "Tab  生成菜单　　右键 收进背包　　F5 存档　　F9 读档"
	_hint.add_theme_font_size_override("font_size", 15)
	_hint.add_theme_color_override("font_color", Color(1, 1, 1, 0.9))
	_hint.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.65))
	_hint.add_theme_constant_override("shadow_offset_x", 1)
	_hint.add_theme_constant_override("shadow_offset_y", 1)
	_hint.position = Vector2(24.0, 20.0)
	add_child(_hint)

	# 收东西的即时反馈。没有它，右键的表现和"这个键没绑"完全一样 ——
	# 而一个不说话的键，玩家试两次就会放弃。
	_toast = Label.new()
	_toast.name = "toast"
	_toast.add_theme_font_size_override("font_size", 17)
	_toast.add_theme_color_override("font_color", Color(0.72, 1.0, 0.86))
	_toast.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.7))
	_toast.add_theme_constant_override("shadow_offset_x", 1)
	_toast.add_theme_constant_override("shadow_offset_y", 1)
	_toast.position = Vector2(24.0, 48.0)
	_toast.visible = false
	add_child(_toast)


## 重新读清单。每次打开都读，不做缓存 ——
## 缓存意味着"改了内容要重启两次才生效"，而热改内容是这个项目的日常。
func refresh() -> void:
	if pack == null:
		return
	var ids: Array[String] = pack.spawnables()
	# 背包里可能有内容已经不在了的 id（mod 被卸载、原型改名）。
	# 它们**不进菜单**：菜单是"能放什么"，放不出来的东西列在这里
	# 会让玩家每点一次就失败一次，而他并不知道为什么。
	if bag != null:
		for id in bag.ids():
			if not ids.has(id) and pack.entities.has(id):
				ids.append(id)
	# 排序 = 三把尺子，按顺序比较：
	#   1) 背包里有的排前面 —— 那是我刚捡的东西，最可能想放回去
	#   2) 会动的排前面 —— 能推能扔的那件才是沙盒的主角
	#   3) 剩下的按 id 字典序，保证同样的世界每次打开顺序一致
	_ids = ids
	_ids.sort_custom(func(a: String, b: String) -> bool:
		# 显式写类型：`pack` 是 untyped 的，`:=` 推不出来 ——
		# 而 Parse Error 只会在真正加载这个文件的时侯炸（游戏或探针），
		# 编译期完全没有提示。
		var ha: int = 0 if (bag != null and bag.has(a)) else 1
		var hb: int = 0 if (bag != null and bag.has(b)) else 1
		if ha != hb:
			return ha < hb
		var ra: bool = pack.places_as_rigid(a)
		var rb: bool = pack.places_as_rigid(b)
		if ra != rb:
			return ra
		return a < b)
	_list.clear()
	for id in _ids:
		var label: String = pack.label_of(id)
		if not pack.places_as_rigid(id):
			label += STATIC_MARK
		# 有库存就标件数。这一行是背包存在的全部可见证据 ——
		# 少了它，"我捡的东西去哪儿了"没有任何答案。
		# 有堆叠上限的连上限一起标（×3/20）：玩家要知道"还能再捡几个"，
		# 而不是等右键没反应了才开始猜。
		if bag != null and bag.has(id):
			var n: int = bag.count(id)
			var lim: int = bag.stack_limit(id)
			if lim > 0:
				label += "  ×%d/%d" % [n, lim]
			else:
				label += "  ×%d" % n
		_list.add_item(label)
		var idx := _list.item_count - 1
		# id 给人查，名字给人看。tooltip 里放 id，因为菜单里只有名字。
		_list.set_item_metadata(idx, id)
		_list.set_item_tooltip(idx, id)
	var carried: int = 0 if bag == null else bag.total()
	var worth: int = 0 if bag == null else bag.total_value()
	_status.text = "共 %d 项 · 背包 %d 件（价值 %d）· 双击或回车放下 · Tab 关闭" \
		% [_ids.size(), carried, worth]


func set_open(v: bool) -> void:
	_open = v
	_panel.visible = v
	_hint.visible = not v
	if player != null:
		player.set_input_blocked(v)
	if v:
		refresh()
		if _list.item_count > 0:
			_list.select(0)
			_list.grab_focus()


func is_open() -> bool:
	return _open


func _input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	var key := (event as InputEventKey).physical_keycode
	if key == KEY_TAB:
		set_open(not _open)
		get_viewport().set_input_as_handled()
	elif _open and key == KEY_ESCAPE:
		# 菜单打开时 Esc 先关菜单，不要顺手把鼠标也放出来 ——
		# 那会让玩家以为"关掉菜单之后视角还卡着"。
		set_open(false)
		get_viewport().set_input_as_handled()


func _on_activated(index: int) -> void:
	_list.select(index)
	spawn_selected()


## 放下选中的那一件。**返回是否成功**，因为探针和将来的自动化都要它能被断言 ——
## 一个只能靠看状态栏文字判断成败的函数，测不了。
func spawn_selected() -> bool:
	if pack == null or api == null or player == null:
		return false
	var sel := _list.get_selected_items()
	if sel.is_empty():
		return false
	var id: String = String(_list.get_item_metadata(sel[0]))

	# 有库存就先用库存。这样"捡起来再放回去"是一个闭环，
	# 而不是"捡了个假的，放出来的是新造的"。
	var from_bag: bool = bag != null and bag.take(id)

	var spot := _place_spot(id)
	var r: Dictionary = api.spawn(id, spot["pos"], spot["yaw"])
	if not bool(r.get("ok", false)):
		# 失败要把库存还回去。不然玩家点一次失败的放下，背包里就少一件东西 ——
		# 而这种"操作失败还扣东西"的 bug，玩家只会理解成游戏在偷他的东西。
		if from_bag:
			bag.add(id)
		# 失败必须说话，而且要说**原因**。静默失败会让玩家以为"这个键没反应"，
		# 而真实原因可能是预算用完了 —— 那是他自己能解决的事。
		_status.text = "没放下：%s" % String(r.get("reason", "未知原因"))
		return false
	var what := "刚体" if bool(r["dynamic"]) else "固定物"
	var src := "（来自背包）" if from_bag else ""
	# 放下之后库存变了，先把清单重读一遍（它会重写状态栏），
	# 再把"我刚做了什么"写回状态栏 —— 顺序反了的话状态栏会停在
	# "共 N 项 · 背包 M 件"上，而玩家刚问的问题是"我放下了没有"。
	refresh()
	var keep := _ids.find(id)
	if keep >= 0:
		_list.select(keep)
	_status.text = "已放下 %s%s（%s）· 剩余预算 %d" % [
		pack.label_of(id), src, what, api.budget_left()]
	return true


## 这一件该放在哪、朝哪。
##
## 优先用手的射线落点（准星指的地方）—— 这就是"瞄哪儿放哪儿"。
## 打不到东西时退回正前方固定距离，因为玩家可能正对着天花板或者远处空地，
## 而"点了一下什么都没发生"比"放在一个还行的地方"差得多。
func _place_spot(id: String) -> Dictionary:
	var rigid: bool = pack.places_as_rigid(id)
	var hands = player.hands() if player != null else null
	if hands != null:
		var p: Dictionary = hands.place_point()
		if bool(p.get("ok", false)):
			var at: Vector3 = p["pos"]
			var n: Vector3 = p["normal"]
			if rigid:
				# 会动的从落点上方落下来：直接摆在落点上它会和地面穿插，
				# 物理引擎会用一次弹跳把它顶出来 —— 看起来像"放炸了"。
				at.y += DROP_LIFT
			elif n.y < FLOOR_NORMAL_Y:
				# 钉住的东西贴在侧壁上时往外让一点，否则一半埋在墙里。
				at += n * WALL_CLEARANCE
			return {"pos": at, "yaw": _face_yaw(at)}

	var cam = player.camera()
	if cam == null:
		return {"pos": player.global_position + Vector3(0, 1.0, 0), "yaw": 0.0}
	var fwd: Vector3 = -cam.global_transform.basis.z
	fwd.y = 0.0
	if fwd.length() < 0.01:
		fwd = Vector3.FORWARD
	fwd = fwd.normalized()
	var fallback: Vector3 = player.global_position + fwd * SPAWN_AHEAD + Vector3.UP * SPAWN_HEIGHT
	# 会动的东西从齐胸高度落下来（看得见它掉），钉住的东西必须直接落在脚下。
	# 静态物不会下落，摆在 1.4 米就是一根悬空的柱子 —— 而且它挡路，
	# 玩家会一边撞上去一边想"这里为什么有空气墙"。
	# 这条规则和 plan.gd 填房间时用的是同一条：能掉的东西才给离地高度。
	if not rigid:
		fallback.y = player.global_position.y
	return {"pos": fallback, "yaw": atan2(fwd.x, fwd.z)}


## 放下的东西朝向玩家，而不是和玩家同向。
## 摆一排柱子时这个差别很明显：同向会让每一件都背对镜头。
func _face_yaw(at: Vector3) -> float:
	var to_player: Vector3 = player.global_position - at
	if to_player.length() < 0.01:
		return 0.0
	return atan2(to_player.x, to_player.z)


## 收到了一件东西。UI 只负责说出来 —— 内容名字在这里翻译，
## 因为玩家只认识名字，不认识 id。
func on_collected(content_id: String) -> void:
	var what := content_id
	if pack != null and pack.entities.has(content_id):
		what = pack.label_of(content_id)
	var n: int = 0 if bag == null else bag.count(content_id)
	_toast.text = "收进背包：%s  ×%d" % [what, n]
	_toast.visible = true
	_toast_left = TOAST_TIME
	if _open:
		# 菜单开着的时候提示挂在面板外面会看不到，直接更新状态栏。
		refresh()


func _process(delta: float) -> void:
	if _toast_left <= 0.0:
		return
	_toast_left -= delta
	if _toast_left <= 0.0:
		_toast.visible = false
