extends RefCounted

## 事件总线：mod 与引擎之间唯一的通道。
##
## 三条硬约束，每条都能在验收里被验证：
##   1. 只有契约声明过的钩子发得出去。发一个没声明的 = 引擎违约，直接报错，
##      而不是让某个 mod 静默地永远收不到东西。
##   2. 没写进 mod 的 events 列表的钩子不会转给它 —— **声明即权限**。
##      这样"这个 mod 能看见什么"是一份可审阅的清单，不是靠读源码推断。
##   3. 每帧事件数有上限。mod 写坏了最多让某个事件失效，不能把整局游戏拖到 5 帧。
##
## 不做的事：沙箱。Godot 没有 GDScript 沙箱（实测 mod 里 OS.execute 返回 0），
## 所以这里约束"能不能被调用"，不约束"调用了能干什么"。
## 那条边界写在 docs/decisions/0003-open-channels.md 与 0007-hooks.md。

## 一帧最多转发多少次事件。到了就丢弃并计数 —— 悄悄降级比崩溃更难查，
## 所以 dropped 必须能被打印出来。
const MAX_EVENTS_PER_FRAME := 256

## 引擎真正会发出的钩子。自检要求它与契约的 schema.hooks **完全相等**：
## 只声明不发是撒谎（mod 挂了钩子永远等不到），只发不声明是绕过契约。
const EMITTED: Array[String] = [
	"world.ready",
	"entity.spawn",
	"entity.remove",
	"grab.request",
	"grab.release",
	"impact",
	"tick",
]

var declared: Dictionary = {}
var api = null

var _handlers: Dictionary = {}
var _budget_frame := -1
var _budget := 0
var dropped := 0
var calls := 0
var bad_calls := 0


func _init(schema_hooks: Dictionary) -> void:
	declared = schema_hooks.duplicate(true)


## 给一个 mod 对象授予某个事件的接收权。返回 false = 契约里没有这个钩子。
func bind(hook_name: String, handler) -> bool:
	if not declared.has(hook_name):
		push_error("mod 想挂未声明的钩子 `%s`" % hook_name)
		return false
	if not _handlers.has(hook_name):
		_handlers[hook_name] = []
	var list: Array = _handlers[hook_name]
	if not list.has(handler):
		list.append(handler)
	return true


## 发一个事件。返回值是所有 handler 返回字典的合并结果。
## 对 blocking 事件，任何一个 handler 返回 allow=false 就立刻停止并返回 {allow=false}。
func emit(hook_name: String, ctx: Dictionary) -> Dictionary:
	if not declared.has(hook_name):
		push_error("引擎发了契约里没有的钩子 `%s` —— 它永远不会被任何人收到" % hook_name)
		return {}
	if not _handlers.has(hook_name):
		return {}  # 没人关心，零开销。这是"内容少时不付钱"的基本要求。
	if _over_budget():
		return {}

	var blocking := bool((declared[hook_name] as Dictionary).get("blocking", false))
	var out: Dictionary = {}
	var list: Array = _handlers[hook_name]
	for handler in list:
		var r = _invoke(handler, hook_name, ctx)
		if typeof(r) != TYPE_DICTIONARY:
			continue
		for k in r:
			if k == "allow" and blocking and not bool(r[k]):
				return {"allow": false}
			out[k] = r[k]
	return out


func _invoke(handler, hook_name: String, ctx: Dictionary):
	if not is_instance_valid(handler) or not handler.has_method("handle"):
		bad_calls += 1
		return null
	calls += 1
	# mod 里抛的运行时错误只会中断它自己的那次调用（Godot 打印错误、call 返回 null），
	# 不会把游戏带走。这是 GDScript 唯一能给的隔离，够用，但不能当成沙箱。
	return handler.call("handle", hook_name, ctx, api)


func _over_budget() -> bool:
	var f := Engine.get_process_frames()
	if f != _budget_frame:
		_budget_frame = f
		_budget = 0
	if _budget >= MAX_EVENTS_PER_FRAME:
		dropped += 1
		return true
	_budget += 1
	return false


func handler_count() -> int:
	var n := 0
	for h in _handlers:
		n += (_handlers[h] as Array).size()
	return n


func summary() -> String:
	var names := _handlers.keys()
	names.sort()
	var parts: Array[String] = []
	for n in names:
		parts.append("%s×%d" % [n, (_handlers[n] as Array).size()])
	var bound := ", ".join(parts) if not parts.is_empty() else "没有 mod 挂载"
	return "钩子：契约 %d 个事件，已绑定 %d 处（%s）" % [declared.size(), handler_count(), bound]
