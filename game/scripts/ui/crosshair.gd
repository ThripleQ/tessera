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

## 命中标记（hitmarker）：打中时在准心周围闪一个 X。
##
## 为什么必须有它：准心告诉玩家"子弹往哪飞"，但**打中之后没有任何东西变**——
## 血量在左上角，击杀数也在左上角，都要用眼睛去"读"。
## 而打中是整局里最需要立刻确认的一件事（我打中了吗？）。
## 一个闪一下的 X 就在眼睛盯着的地方，是唯一不用挪视线的确认方式。
##
## 显示多久。0.18 秒：短到不挡视线（下一枪之间就淡完了），
## 长到在 60 帧下能被看见（不到 11 帧的东西会被一帧跳过）。
const HIT_TIME := 0.18
## 命中标记的 X 比准心大多少（像素）。大一点才看得出"多了一个东西"，
## 太小就变成准心自己变粗，看不出是命中了。
const HIT_GAP := 9.0
const HIT_LENGTH := 7.0
const COLOR_HIT := Color(1.0, 0.94, 0.62, 0.95)

var player = null
## 命中标记还剩多少秒显示。由枪的信号点亮（装配层接线，见 main.gd）。
var _hit := 0.0


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
func _process(delta: float) -> void:
	visible = player != null and bool(player.is_first_person())
	if _hit > 0.0:
		_hit = maxf(0.0, _hit - delta)
		# 命中标记画在另一个 Control 上，所以准心本身要重画一次。
		# 不重画的话标记会停在第一帧的样子（永远满亮），那不叫"闪"。
		var c := get_child(0) as Control
		if c != null:
			c.queue_redraw()


## 枪打中了会疼的东西。装配层把这个信号接过来（见 main.gd）——
## **准心不认识枪**，它只知道"该闪一下"。
func on_hit() -> void:
	_hit = HIT_TIME
	var c := get_child(0) as Control
	if c != null:
		c.queue_redraw()


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
	_draw_hitmarker(c, mid)


## 命中标记：四个角上的斜线，画成一个 X 的四臂。
##
## 用**斜线**而不是正交短线：正交的短线和准心的四条线平行，
## 混在一起分不清哪个是哪个。斜的不会。
func _draw_hitmarker(c: Control, mid: Vector2) -> void:
	if _hit <= 0.0:
		return
	# 越接近消失越淡。"啪"地一下消失不如慢慢淡掉 ——
	# 后者能让人看清"刚才打中了"，前者只留下"好像闪了一下"。
	var a := clampf(_hit / HIT_TIME, 0.0, 1.0)
	var col := Color(COLOR_HIT.r, COLOR_HIT.g, COLOR_HIT.b, COLOR_HIT.a * a)
	# 四条斜线：从内角指向外角。
	var arms: Array[Array] = [
		[Vector2(-HIT_GAP, -HIT_GAP), Vector2(-HIT_GAP - HIT_LENGTH, -HIT_GAP - HIT_LENGTH)],
		[Vector2(HIT_GAP, -HIT_GAP), Vector2(HIT_GAP + HIT_LENGTH, -HIT_GAP - HIT_LENGTH)],
		[Vector2(-HIT_GAP, HIT_GAP), Vector2(-HIT_GAP - HIT_LENGTH, HIT_GAP + HIT_LENGTH)],
		[Vector2(HIT_GAP, HIT_GAP), Vector2(HIT_GAP + HIT_LENGTH, HIT_GAP + HIT_LENGTH)],
	]
	for arm in arms:
		var p0: Vector2 = arm[0]
		var p1: Vector2 = arm[1]
		c.draw_line(mid + p0, mid + p1, col, THICKNESS)
