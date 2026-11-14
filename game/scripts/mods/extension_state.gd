extends RefCounted

## L4 自定义组件的可变状态。按不透明 handle 存，不碰节点、不进存档。
##
## 为什么不进存档：存档的边界是「只存玩家的动作」（ADR 0008）。mod 的临时规则
## 状态一旦写进 slot0.json，卸载 mod 之后那些键就没有任何人能解释，
## 也没法做版本迁移。重开一局让规则从内容的默认值重新长出来，是刻意选择。

var _values: Dictionary = {}   # handle -> component -> field -> value


func value(handle: int, component: String, field: String):
	var by_handle: Dictionary = _values.get(handle, {})
	var by_component: Dictionary = by_handle.get(component, {})
	return by_component.get(field, null)


func set_value(handle: int, component: String, field: String, v) -> void:
	var by_handle: Dictionary = _values.get(handle, {})
	var by_component: Dictionary = by_handle.get(component, {})
	by_component[field] = v
	by_handle[component] = by_component
	_values[handle] = by_handle


## 刚体被拆掉 / 读档重建之后，旧 handle 不能继续占内存。
## 没有这一步，长时间游玩后状态表会一直涨，而且看起来完全正常。
func prune(api) -> void:
	var dead: Array[int] = []
	for h in _values:
		if not api.exists(int(h)):
			dead.append(int(h))
	for h in dead:
		_values.erase(h)
