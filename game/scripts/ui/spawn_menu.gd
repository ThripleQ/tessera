extends CanvasLayer

## 生成菜单 —— 产品三件事里的第二件："一切来自数据的生成菜单"。
##
## 它刻意不硬编码任何可放置的东西：清单来自 `pack.spawnables()`，名字来自内容里的
## `name` 字段。所以往 `content/` 里加一个 TOML，菜单里就自动多一项，这里一行都不用改。
## 这一条同时也是验收标准：如果加内容要改这个文件，说明"内容即数据"在某处漏了。
##
## 和 mod 的关系：玩家手动放的东西走 `api.spawn`，和 mod 造物**同一个通道、同一个预算**。
## 分开两套的后果是"玩家的东西能无限放，mod 的不能"——那预算就成了只约束好人的规矩。
##
## 一个刻意的限制：菜单打开时鼠标交给 UI，视角冻结。所以"瞄准再放"是做不到的 ——
## 东西只会掉在你正前方固定距离处。这是这一版明确的取舍：先让"能放"成立，
## 把"瞄哪儿放哪儿"留给拾取/堆叠那一轮（那时会有真正的准星和目标点）。

const PANEL_W := 420.0
const PANEL_H := 470.0
const PANEL_MARGIN := 40.0

## 生成位置：站在面前两米多、齐胸高度。太近会卡进自己身体，
## 太远会让"点一下就出来"失去手感——它应该出现在你手能够到的地方。
const SPAWN_AHEAD := 2.4
const SPAWN_HEIGHT := 1.4

## 固定不动的东西在名字后面挂一个记号。玩家点之前就该知道它不会倒、也推不动 ——
## 放下去再发现"这个箱子是假的"是最差的体验。
const STATIC_MARK := "  ·固定"

var pack = null
var api = null
var player = null

var _panel: PanelContainer
var _list: ItemList
var _status: Label
var _hint: Label
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
	_hint.text = "Tab  生成菜单　　右键 拆除瞄着的东西　　F5 存档　　F9 读档"
	_hint.add_theme_font_size_override("font_size", 15)
	_hint.add_theme_color_override("font_color", Color(1, 1, 1, 0.9))
	_hint.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.65))
	_hint.add_theme_constant_override("shadow_offset_x", 1)
	_hint.add_theme_constant_override("shadow_offset_y", 1)
	_hint.position = Vector2(24.0, 20.0)
	add_child(_hint)


## 重新读清单。每次打开都读，不做缓存 ——
## 缓存意味着"改了内容要重启两次才生效"，而热改内容是这个项目的日常。
func refresh() -> void:
	if pack == null:
		return
	_ids = pack.spawnables()
	# 会动的排前面。排序只影响"第一眼看到什么"，而这恰恰很重要：
	# 菜单默认选中第一项，默认项应该是沙盒里最常用的那件（能推能扔的），
	# 而不是按 id 排出来的第一个"长得像怪其实不会动"的摆设。
	_ids.sort_custom(func(a: String, b: String) -> bool:
		# 显式写类型：`pack` 是 untyped 的，`:=` 推不出来 ——
		# 而 Parse Error 只会在真正加载这个文件的时侯炸（游戏或探针），
		# 编译期完全没有提示。
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
		_list.add_item(label)
		var idx := _list.item_count - 1
		# id 给人查，名字给人看。tooltip 里放 id，因为菜单里只有名字。
		_list.set_item_metadata(idx, id)
		_list.set_item_tooltip(idx, id)
	_status.text = "共 %d 项 · 双击或回车生成 · Tab 关闭 · 右键拆掉瞄着的东西" % _ids.size()


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

	var cam = player.camera()
	if cam == null:
		return false
	var fwd: Vector3 = -cam.global_transform.basis.z
	fwd.y = 0.0
	if fwd.length() < 0.01:
		fwd = Vector3.FORWARD
	fwd = fwd.normalized()
	var at: Vector3 = player.global_position + fwd * SPAWN_AHEAD + Vector3.UP * SPAWN_HEIGHT
	# 会动的东西从齐胸高度落下来（看得见它掉），钉住的东西必须直接落在脚下。
	# 静态物不会下落，摆在 1.4 米就是一根悬空的柱子 —— 而且它挡路，
	# 玩家会一边撞上去一边想"这里为什么有空气墙"。
	# 这条规则和 plan.gd 填房间时用的是同一条：能掉的东西才给离地高度。
	if not pack.places_as_rigid(id):
		at.y = player.global_position.y

	var r: Dictionary = api.spawn(id, at, atan2(fwd.x, fwd.z))
	if not bool(r.get("ok", false)):
		# 失败必须说话，而且要说**原因**。静默失败会让玩家以为"这个键没反应"，
		# 而真实原因可能是预算用完了 —— 那是他自己能解决的事。
		_status.text = "没放下：%s" % String(r.get("reason", "未知原因"))
		return false
	var what := "刚体" if bool(r["dynamic"]) else "固定物"
	_status.text = "已放下 %s（%s）· 剩余预算 %d" % [pack.label_of(id), what, api.budget_left()]
	return true
