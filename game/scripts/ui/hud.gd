extends CanvasLayer

## 屏幕上的四个数：命中、击杀、命中率、用时 —— 外加弹药。
##
## 为什么是这四个而不是血条、雷达、任务列表：训练场里唯一要回答的问题是
## "我打得准不准"。命中率是这句话唯一的量化形式，而它必须**当场**看得见 ——
## 打完一轮再去翻日志的人不会改自己的打法。
##
## 它只读，不拥有任何状态。射击的账在 `gun.gd`，死亡的账在 `vitals.gd`，
## 这里做的是除法。合并成"UI 自己记账"之后，最常见的事故是
## "屏幕说 5 中 5，日志说 7 发"——而两个数都对，只是算的不是同一件事。

## 左上角，但往下让一截 —— 第一行是生成菜单的按键提示，两组字叠在一起
## 谁都读不清（第一版就是这样撞上的）。
const MARGIN := Vector2(24, 96)
const FONT_SIZE := 17

var gun = null
var vitals = null

var _label: Label
var _elapsed := 0.0


func _ready() -> void:
	layer = 10
	_label = Label.new()
	_label.name = "stats"
	_label.position = MARGIN
	# 描边而不是背景板：亮场地里白字看不见，暗场地里黑字看不见，
	# 而一块半透明底板会把 6 平方米的视野挡掉一块。
	_label.add_theme_font_size_override("font_size", FONT_SIZE)
	_label.add_theme_color_override("font_color", Color(0.96, 0.98, 1.0))
	_label.add_theme_color_override("font_shadow_color", Color(0.0, 0.0, 0.0, 0.85))
	_label.add_theme_constant_override("shadow_offset_x", 2)
	_label.add_theme_constant_override("shadow_offset_y", 2)
	add_child(_label)


func _process(delta: float) -> void:
	_elapsed += delta
	if _label == null or gun == null:
		return
	var s: Dictionary = gun.stats()
	var killed := 0
	if vitals != null:
		killed = int(vitals.kills)
	var acc := float(s.get("accuracy", 0.0)) * 100.0
	var lines: Array[String] = []
	lines.append("命中 %d 发　击杀 %d" % [int(s.get("hits", 0)), killed])
	lines.append("命中率 %d%%　用时 %s" % [int(round(acc)), _clock(_elapsed)])
	if bool(s.get("reloading", false)):
		lines.append("换弹中…")
	else:
		lines.append("弹药 %d / %d" % [int(s.get("ammo", 0)), int(s.get("mag", 0))])
	_label.text = "\n".join(lines)


## 秒 → 1:23。超过一小时也只显示分秒：一局训练场不会那么久，
## 而多一段 "1:02:03" 的格式会让每一帧多一次判断。
static func _clock(seconds: float) -> String:
	var t := int(seconds)
	return "%d:%02d" % [t / 60, t % 60]
