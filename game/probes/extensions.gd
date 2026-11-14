extends SceneTree

## L4 通道探针：mod 声明的新组件、新系统、新规则状态，是不是真的跑起来了。
##
## 这条探针守的不是某个 mod，而是「开放度」本身：
##   声明  —— 自定义组件进了 schema，系统声明进了调度表
##   装载  —— 系统脚本真的编译出实例，调度器真的接住了它
##   执行  —— 固定节拍跑过之后，系统写进了一个自定义字段
##   边界  —— 没声明的读写权限、错类型的值都被挡住，且不刷引擎 ERROR
##
## 和别的探针一样，这里**不认识任何内容 id**：自定义组件与带它的刚体
## 都从 pack 的数据里找。示例 mod 改名字、换内容都不会让这条探针假红。

var _main
var _f := 0
var _cid := ""
var _system_id := ""
var _component := ""
var _field := ""
var _ctx = null
var _fields: Array[String] = []
var _period := 0.25
var _handle := 0


func _initialize() -> void:
	_main = load("res://main.tscn").instantiate()
	root.add_child(_main)


func _process(_delta: float) -> bool:
	_f += 1
	if _f < 8:
		return false

	var ok := true
	var comps: Dictionary = _main.pack.schema.get("components", {})
	var systems: Dictionary = _main.pack.extension_systems()
	var custom: PackedStringArray = _main.pack.extension_component_names()
	var loaded: Array = _main.mods.get("systems", [])
	var runner = _main._systems

	# 以「系统」为起点找它自己的 writes、上下文和内容。不能再分别拿第一个组件、
	# 第一个系统、contexts[0] 拼在一起：第二个 mod 系统出现后，那三者可能不是一组。
	for entry in runner._mod_systems:
		var sid := String(entry.get("id", ""))
		var spec: Dictionary = systems.get(sid, {})
		for raw_cname in spec.get("writes", []):
			var cname := String(raw_cname)
			if not custom.has(cname):
				continue
			var fields: Dictionary = comps.get(cname, {}).get("fields", {})
			var numeric: Array[String] = []
			for fname in fields:
				var fd: Dictionary = fields.get(fname, {})
				var t := String(fd.get("type", ""))
				if t == "float" or t == "int":
					numeric.append(String(fname))
			if numeric.is_empty():
				continue
			for id in _main.pack.spawnables():
				if not _main.pack.components_of(id).has(cname):
					continue
				if not _main.pack.places_as_rigid(id):
					continue
				_cid = id
				_system_id = sid
				_component = cname
				_fields = numeric
				_field = String(numeric[0])
				_period = float(spec.get("period", 0.25))
				_ctx = entry.get("ctx", null)
				break
			if _ctx != null:
				break
		if _ctx != null:
			break

	var declared_ok: bool = not custom.is_empty() and not systems.is_empty() \
		and not _cid.is_empty() and _ctx != null
	var loaded_ok: bool = not loaded.is_empty() and runner != null \
		and runner.extension_systems_count() > 0 and not runner.contexts.is_empty()
	print("EXT 声明：自定义组件 %d 个 / 系统 %d 个 / 受验系统 %s / 刚体 %s（%s）"
		% [custom.size(), systems.size(), _system_id, _cid, declared_ok])
	print("EXT 装载：编译 %d 个 / 调度 %d 个（%s）"
		% [loaded.size(), runner.extension_systems_count() if runner != null else 0, loaded_ok])
	if not declared_ok or not loaded_ok:
		ok = false

	var spawn_ok := false
	var ran_ok := false
	var guard_ok := false
	if declared_ok and loaded_ok:
		var at: Vector3 = _main._player.global_position + Vector3(0.0, 0.0, -2.0)
		var r: Dictionary = _main.api.spawn(_cid, at, 0.0)
		_handle = int(r.get("handle", 0))
		spawn_ok = bool(r.get("ok", false)) and _handle > 0 and _main.api.exists(_handle)
		print("EXT 生成：handle %d，活着 %s，组件 `%s.%s`（%s）"
			% [_handle, _main.api.exists(_handle), _component, _field, spawn_ok])

		var ctx = _ctx
		var listed := false
		for h in ctx.entities():
			if int(h) == _handle:
				listed = true
				break
		# 先记下所有数值字段的初始值，再跑三个固定节拍。
		# 系统写的是哪个字段由 mod 自己决定，探针不能靠猜。
		var before_values: Dictionary = {}
		for fname in _fields:
			before_values[String(fname)] = ctx.read(_handle, _component, String(fname))
		for _i in 3:
			runner.step(_period)

		var changed := false
		var chosen_before := 0.0
		var stored = null
		var read_back = null
		for fname in _fields:
			var key := String(fname)
			var candidate = runner.extension_value(_handle, _component, key)
			var candidate_read = ctx.read(_handle, _component, key)
			if candidate == null or candidate_read == null:
				continue
			var raw_before = before_values.get(key, null)
			var value_before := 0.0
			if raw_before != null:
				value_before = float(raw_before)
			if is_equal_approx(float(candidate), value_before):
				continue
			_field = key
			chosen_before = value_before
			stored = candidate
			read_back = candidate_read
			changed = true
			break
		ran_ok = listed and changed and read_back != null \
			and is_equal_approx(float(stored), float(read_back)) \
			and float(ctx.dt) > 0.0 and int(ctx.frame) > 0
		print("EXT 执行：节拍 %.2f s，`%s` %.3f → %s，ctx 读到 %s（%s）"
			% [_period, _field, chosen_before, str(stored), str(read_back), ran_ok])

		# 权限清单必须有牙齿，但拒绝不能变成引擎 ERROR。
		var other := ""
		for cname in comps:
			var origin := String((comps[cname] as Dictionary).get("origin", "builtin"))
			if origin == "builtin" and not ctx.writes.has(String(cname)):
				other = String(cname)
				break
		var denied_write: bool = ctx.write(_handle, other, "no_such_field", 1)
		var deny_write_msg := String(ctx.last_error)
		var bad_type: bool = ctx.write(_handle, _component, _field, "不是数字")
		var bad_type_msg := String(ctx.last_error)
		var denied_read = ctx.read(_handle, other, "no_such_field")
		var deny_read_msg := String(ctx.last_error)
		guard_ok = not denied_write and not bad_type and denied_read == null \
			and not other.is_empty() \
			and deny_write_msg.contains("没声明写") \
			and bad_type_msg.contains("期望") \
			and deny_read_msg.contains("没声明读")
		print("EXT 边界：越权写 %s / 错类型 %s / 越权读 %s（%s）"
			% [deny_write_msg, bad_type_msg, deny_read_msg, guard_ok])

	ok = ok and spawn_ok and ran_ok and guard_ok
	print("EXT RESULT %s（声明 %s / 装载 %s / 执行 %s / 边界 %s）"
		% ["OK" if ok else "FAIL",
			"OK" if declared_ok else "FAIL", "OK" if loaded_ok else "FAIL",
			"OK" if ran_ok else "FAIL", "OK" if guard_ok else "FAIL"])
	quit(0 if ok else 1)
	return false
