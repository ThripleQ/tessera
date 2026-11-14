extends RefCounted

## 交给 L4 mod 系统的唯一上下文对象。
##
## 它把「不透明 handle + 声明过的组件字段」包成动词：
##   entities() 问「哪些东西归我管」
##   read()     读一个字段（先读可变状态，再读内容的初始值）
##   write()    写一个字段（过白名单、类型、范围、枚举）
##
## mod 拿不到节点、Transform3D、组件对象，也拿不到 `pack` 本身。
## 越权调用不 push_error，而是返回 false / null 并把原因放进 `last_error` ——
## 一个写坏规则的 mod 不该把整局游戏的 ERROR 日志刷满。
##
## `api` 作为第二个参数照样传进来，spawn / impulse / tint 这些世界动词
## 仍走 L3 那份唯一 facade，不在这里复制第二套。

const VALIDATOR = preload("res://scripts/content/validator.gd")

## 与 api.MAX_QUERY 同量级：一次系统最多看这么多件，开放不等于无限遍历。
const MAX_ENTITIES := 64

var pack = null
var api = null
var state = null
var reads: Array[String] = []
var writes: Array[String] = []
var dt := 0.0
var frame := 0
var last_error := ""


func setup(spec: Dictionary, pk, a, st) -> void:
	pack = pk
	api = a
	state = st
	reads = []
	writes = []
	for c in spec.get("reads", []):
		reads.append(String(c))
	for c in spec.get("writes", []):
		writes.append(String(c))


## 归这个系统管的实体：带上全部 reads 组件的刚体。
## reads 为空时按 writes 找 —— 允许「只写状态」的系统存在，
## 但编译器已经拦掉了既不读也不写的空壳。
func entities() -> Array[int]:
	var wanted: Array[String] = reads
	if wanted.is_empty():
		wanted = writes
	var out: Array[int] = []
	for raw_h in api.handles():
		var h := int(raw_h)
		var comps: Dictionary = pack.components_of(api.content_id(h))
		var ok := true
		for c in wanted:
			if not comps.has(c):
				ok = false
				break
		if ok:
			out.append(h)
			if out.size() >= MAX_ENTITIES:
				break
	return out


func read(handle: int, component: String, field: String):
	last_error = ""
	if not reads.has(component):
		last_error = "系统没声明读组件 `%s`" % component
		return null
	if not api.exists(handle):
		return null
	var fd := _field_spec(component, field)
	if fd.is_empty():
		last_error = "组件 `%s` 没有字段 `%s`" % [component, field]
		return null
	var stored = state.value(handle, component, field)
	if stored != null:
		return stored
	var comps: Dictionary = pack.components_of(api.content_id(handle))
	var cval: Dictionary = comps.get(component, {})
	if cval.has(field):
		return cval.get(field)
	return fd.get("default", null)


func write(handle: int, component: String, field: String, v) -> bool:
	last_error = ""
	if not api.exists(handle):
		return false
	if not writes.has(component):
		last_error = "系统没声明写组件 `%s`" % component
		return false
	var fd := _field_spec(component, field)
	if fd.is_empty():
		last_error = "组件 `%s` 没有字段 `%s`" % [component, field]
		return false
	var err := VALIDATOR.check_value(fd, v)
	if not err.is_empty():
		last_error = err
		return false
	state.set_value(handle, component, field, v)
	return true


func _field_spec(component: String, field: String) -> Dictionary:
	var comps: Dictionary = pack.schema.get("components", {})
	var spec: Dictionary = comps.get(component, {})
	var fields: Dictionary = spec.get("fields", {})
	return fields.get(field, {})
