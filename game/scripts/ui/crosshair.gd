extends CanvasLayer

## 屏幕正中的准心。**它和 `reticle.gd` 不是一件事，别合并。**
##
##   reticle   —— 画在世界里的落点圈，告诉玩家"右键能收哪个"。第三人称用。
##   这个      —— 画在屏幕上，告诉玩家"子弹会往哪飞"。第一人称用。
##
## 第一版没有它，截图里立刻穿帮：画面正中空空如也，而世界里的青色落点圈
## 因为射线打到近处而糊在眼前。两个都对，只是属于两个视角。
##
## 形状按"能不能看见"设计，不按好看：中心一个点（精确指向）+ 四条短线（不挡视野）。
## 线用两色描边（深底浅心），因为训练场的地板是亮的、墙是白的，单色准心总有一半看不见。

const LAYER := 9
## 中心点到每根线外端的距离，以及间隙。太大会挡住目标，太小在 1080p 下看不见。
const GAP := 4.0
const LENGTH := 9.0
const THICKNESS := 2.0
const COLOR_OUTLINE := Color(0.03, 0.04, 0.06, 0.85)
const COLOR_CORE := Color(0.97, 0.99, 1.0, 0.95)

var player = null


func _ready() -> void:
	layer = LAYER
	var c := Control.new()
	c.name = "cross"
	c.set_anchors_preset(Control.PRESET_FULL_RECT)
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	c.draw.connect(_draw_cross.bind(c))
	add_child(c)


## 只在第一人称显示。第三人称的"瞄哪儿"由世界里的落点圈回答，
## 屏中再加一个准心会变成两套指向（而且它们指的常常不是同一个点）。
func _process(_delta: float) -> void:
	visible = player != null and bool(player.is_first_person())


func _draw_cross(c: Control) -> void:
	if not visible:
		return
	var mid: Vector2 = c.size * 0.5
	# 先描边再画芯：两遍同样的线，粗的那遍是底。
	for layer_i in 2:
		var col := COLOR_OUTLINE if layer_i == 0 else COLOR_CORE
		var w := THICKNESS + 2.0 if layer_i == 0 else THICKNESS
		var segs: Array[Array] = [
			[Vector2(-GAP - LENGTH, 0), Vector2(-GAP, 0)],
			[Vector2(GAP, 0), Vector2(GAP + LENGTH, 0)],
			[Vector2(0, -GAP - LENGTH), Vector2(0, -GAP)],
			[Vector2(0, GAP), Vector2(0, GAP + LENGTH)],
		]
		for s in segs:
			var a: Vector2 = s[0]
			var b: Vector2 = s[1]
			c.draw_line(mid + a, mid + b, col, w)
	# 中心点。准心没有点时，"两条线中间那格"到底对着哪儿要靠猜。
	c.draw_circle(mid, THICKNESS * 0.5 + 0.6, COLOR_CORE)
