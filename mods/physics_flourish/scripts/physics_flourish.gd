extends RefCounted

## 行为 mod 示例：物理余韵。
##
## 契约只有一条：必须实现 handle(event, ctx, api) -> Dictionary。
## 返回字典的含义由事件的契约决定（见 contract/registry.py 里 hook(...) 的 returns）：
##   grab.request  可以返回 allow=false 否决，或 hold=距离
##   其它事件      返回值被引擎忽略，可以返回 {}
##
## 这里刻意不 import 任何项目内的脚本：mod 只能通过 api 与世界交互。
## 一旦某个 mod 开始 preload("res://scripts/...")，它就绑死在引擎内部结构上了，
## 那种 mod 一定会在下一次重构时坏掉 —— 所以这个示例一次都不这么做。

const HOT := Color(0.98, 0.44, 0.64)
const FLASH := Color(1.0, 0.74, 0.38)

## handle -> 还剩几拍恢复正常色。tick 是 0.25 秒一拍，所以 8 拍约 2 秒。
var _restore: Dictionary = {}


func handle(event: String, ctx: Dictionary, api) -> Dictionary:
	match event:
		"grab.request":
			# 抓得近一点。值必须在契约允许的范围内，否则抓取器会自己 clamp。
			return {"hold": 1.9}

		"grab.release":
			# 只有"扔"才发烫，"放下"（thrown=false）不发 —— 摆东西时不该闪。
			if bool(ctx.get("thrown", false)) and float(ctx.get("speed", 0.0)) > 4.0:
				_heat(int(ctx.get("handle", 0)), HOT, 8, api)
			return {}

		"impact":
			if float(ctx.get("speed", 0.0)) > 5.0:
				_heat(int(ctx.get("handle", 0)), FLASH, 1, api)
			return {}

		"tick":
			_decay(api)
			return {}

	return {}


func _heat(handle: int, color: Color, ticks: int, api) -> void:
	if handle == 0 or not api.exists(handle):
		return
	if api.tint(handle, color):
		# 取最大值：连续撞击不应该让已经发烫的东西提前冷却。
		_restore[handle] = max(int(_restore.get(handle, 0)), ticks)


func _decay(api) -> void:
	if _restore.is_empty():
		return
	var done: Array = []
	for h in _restore:
		_restore[h] = int(_restore[h]) - 1
		if int(_restore[h]) <= 0:
			done.append(h)
	for h in done:
		_restore.erase(h)
		# 物体可能在冷却期间被消费掉（现在是扔掉，将来会被拾取），
		# 所以 reset_tint 返回 false 也要当正常情况处理。
		api.reset_tint(h)
