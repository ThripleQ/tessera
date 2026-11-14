extends RefCounted

## 运行时内容校验。编译期查过一遍，但 mod 产物是外部文件、可以被手改，
## 所以引擎这一侧必须拿 `pack.schema` 再独立查一遍（ADR 0002 / 0011）。
##
## 它不认识任何具体内容：只认 schema 里的字段名、类型、范围、枚举。
## 这就是「mod 能加新组件」和「mod 能往引擎里塞任意东西」的分界线。

const FIELD_TYPES = ["int", "float", "bool", "str", "list", "dict"]


static func check_value(fd: Dictionary, value) -> String:
	"""合法返回空字符串，不合法返回给人看的一句话。"""
	var t := String(fd.get("type", ""))
	var ok := false
	match t:
		"int":
			# Godot 的 JSON.parse_string 把所有数字都读成 float，
			# 于是编译产物里的 48 到运行时会变成 48.0。整数值仍然合法，
			# 但 1.5 这种「假装是整数」的小数必须拒绝。
			ok = typeof(value) == TYPE_INT or (typeof(value) == TYPE_FLOAT and _is_integral(value))
		"float":
			ok = typeof(value) == TYPE_FLOAT or typeof(value) == TYPE_INT
		"bool":
			ok = typeof(value) == TYPE_BOOL
		"str":
			ok = typeof(value) == TYPE_STRING
		"list":
			ok = typeof(value) == TYPE_ARRAY
		"dict":
			ok = typeof(value) == TYPE_DICTIONARY
		_:
			return "未知字段类型 `%s`" % t
	if not ok:
		return "期望 %s" % _type_word(t)

	if t == "str" and fd.get("enum") != null:
		var allowed = fd.get("enum")
		if allowed is Array and not (allowed as Array).has(value):
			return "`%s` 不在允许值 %s 中" % [String(value), str(allowed)]

	if (t == "int" or t == "float") and (typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT):
		var lo = fd.get("min", null)
		var hi = fd.get("max", null)
		if lo != null and float(value) < float(lo):
			return "不能小于 %s（当前 %s）" % [str(lo), str(value)]
		if hi != null and float(value) > float(hi):
			return "不能大于 %s（当前 %s）" % [str(hi), str(value)]
	return ""


static func _dict(value) -> Dictionary:
	"""外部 JSON 里的某一层可能不是表。返回空表，让调用方自己报一句人话。"""
	var out: Dictionary = {}
	if typeof(value) == TYPE_DICTIONARY:
		out = value
	return out


static func _is_integral(value) -> bool:
	"""Godot JSON 把 48 读成 48.0；48.0 是整数，48.5 不是。"""
	if typeof(value) != TYPE_FLOAT:
		return false
	var f := float(value)
	return is_equal_approx(f, float(int(f)))


static func _type_word(t: String) -> String:
	match t:
		"int": return "整数"
		"float": return "数字"
		"bool": return "true / false"
		"str": return "字符串"
		"list": return "数组"
		"dict": return "表"
	return t


## 合并 mod 之前：它带进来的组件值必须全部能在这份 schema 里找到解释。
## 缺字段不报错（编译器会补默认值），但拼错的字段名、类型错、越界一律拒绝。
static func validate_entities(schema_components: Dictionary, incoming: Dictionary) -> Array[String]:
	var problems: Array[String] = []
	for cid in incoming:
		var body = incoming.get(cid)
		if typeof(body) != TYPE_DICTIONARY:
			problems.append("`%s` 不是字典" % String(cid))
			continue
		var used_raw = (body as Dictionary).get("components", {})
		if typeof(used_raw) != TYPE_DICTIONARY:
			problems.append("`%s` 的 components 不是表" % String(cid))
			continue
		var used: Dictionary = used_raw
		for cname in used:
			var c := String(cname)
			if not schema_components.has(c):
				problems.append("`%s` 用了契约里没有的组件 `%s`" % [String(cid), c])
				continue
			var spec := _dict(schema_components.get(c, {}))
			var fields := _dict(spec.get("fields", {}))
			var cval = used.get(c)
			if typeof(cval) != TYPE_DICTIONARY:
				problems.append("`%s.%s` 必须是表" % [String(cid), c])
				continue
			for fname in cval:
				var f := String(fname)
				if not fields.has(f):
					problems.append("`%s.%s` 有未知字段 `%s`" % [String(cid), c, f])
					continue
				var field_dict: Dictionary = fields.get(f, {})
				var err := check_value(field_dict, (cval as Dictionary).get(f))
				if not err.is_empty():
					problems.append("`%s.%s.%s` %s" % [String(cid), c, f, err])
	return problems


## 校验一份 mod 的 L4 扩展声明。成功时返回归一化后的 components / systems，
## 调用方只在 problems 为空时才合并 —— 不许出现「半装进来」的状态。
static func validate_extension(schema: Dictionary, ext: Dictionary, mod_id: String) -> Dictionary:
	var problems: Array[String] = []
	var comps := _dict(schema.get("components", {}))
	var ext_section := _dict(schema.get("extensions", {}))
	var rules := _dict(ext_section.get("rules", {}))
	var systems := _dict(ext_section.get("systems", {}))
	if typeof(ext.get("components", {})) != TYPE_DICTIONARY:
		problems.append("mod 的 extensions.components 不是表")
	if typeof(ext.get("systems", {})) != TYPE_DICTIONARY:
		problems.append("mod 的 extensions.systems 不是表")
	var new_comps := _dict(ext.get("components", {}))
	var new_systems := _dict(ext.get("systems", {}))

	if systems.size() + new_systems.size() > int(rules.get("max_systems", 16)):
		problems.append("系统数超过上限 %d" % int(rules.get("max_systems", 16)))

	var clean_comps: Dictionary = {}
	for key in new_comps:
		var cname := String(key)
		if not _matches(String(rules.get("component_key", "^[a-z][a-z0-9_]*$")), cname):
			problems.append("组件 key `%s` 不合法" % cname)
			continue
		if comps.has(cname):
			problems.append("组件 `%s` 已存在；mod 只能加新名字，不许覆盖别人" % cname)
			continue
		var spec = new_comps.get(key)
		if typeof(spec) != TYPE_DICTIONARY:
			problems.append("组件 `%s` 的声明不是表" % cname)
			continue
		var spec_dict := _dict(spec)
		var fields := _dict(spec_dict.get("fields", {}))
		if fields.size() > int(rules.get("max_fields", 16)):
			problems.append("组件 `%s` 字段数超过上限" % cname)
			continue
		var clean_fields: Dictionary = {}
		for fname in fields:
			var f := String(fname)
			if not _matches(String(rules.get("field_name", "^[a-z][a-z0-9_]*$")), f):
				problems.append("组件 `%s` 的字段名 `%s` 不合法" % [cname, f])
				continue
			var fd = fields.get(fname)
			if typeof(fd) != TYPE_DICTIONARY:
				problems.append("组件 `%s.%s` 的字段定义不是表" % [cname, f])
				continue
			var fdict: Dictionary = _dict(fd).duplicate(true)
			var t := String(fdict.get("type", ""))
			if not FIELD_TYPES.has(t):
				problems.append("组件 `%s.%s` 的 type `%s` 不合法" % [cname, f, t])
				continue
			if not fdict.has("default"):
				problems.append("组件 `%s.%s` 缺 default" % [cname, f])
				continue
			var spec_err := _check_field_spec(cname, f, fdict)
			if not spec_err.is_empty():
				problems.append(spec_err)
				continue
			var default_err := check_value(fdict, fdict.get("default"))
			if not default_err.is_empty():
				problems.append("组件 `%s.%s` 的 default %s" % [cname, f, default_err])
				continue
			clean_fields[f] = fdict
		clean_comps[cname] = {
			"doc": String(spec_dict.get("doc", "")),
			"fields": clean_fields,
			"origin": mod_id,
		}

	var used_priorities: Dictionary = {}
	for sid in systems:
		var old_p = _dict(systems.get(sid, {})).get("priority", -1)
		if typeof(old_p) == TYPE_INT or (typeof(old_p) == TYPE_FLOAT and _is_integral(old_p)):
			used_priorities[int(old_p)] = String(sid)
	var clean_systems: Dictionary = {}
	for sid in new_systems:
		var name := String(sid)
		var spec = new_systems.get(sid)
		if typeof(spec) != TYPE_DICTIONARY:
			problems.append("系统 `%s` 的声明不是表" % name)
			continue
		var s: Dictionary = _dict(spec).duplicate(true)
		var p = s.get("priority", 0)
		if typeof(p) == TYPE_FLOAT and _is_integral(p):
			p = int(p)
			s["priority"] = p
		if typeof(p) != TYPE_INT:
			problems.append("系统 `%s` 的 priority 必须是整数" % name)
			continue
		var pmin := int(rules.get("system_priority_min", 100))
		var pmax := int(rules.get("system_priority_max", 999))
		if int(p) < pmin or int(p) > pmax:
			problems.append("系统 `%s` 的 priority=%d 越界" % [name, int(p)])
			continue
		if used_priorities.has(int(p)):
			problems.append("系统 `%s` 与 `%s` 的 priority 都是 %d"
				% [name, String(used_priorities[int(p)]), int(p)])
			continue
		used_priorities[int(p)] = name

		var period := float(s.get("period", rules.get("period_default", 0.25)))
		if period < float(rules.get("period_min", 0.05)) or period > float(rules.get("period_max", 5.0)):
			problems.append("系统 `%s` 的 period=%s 越界" % [name, str(period)])
			continue
		var reads = s.get("reads", [])
		var writes = s.get("writes", [])
		if typeof(reads) != TYPE_ARRAY or typeof(writes) != TYPE_ARRAY:
			problems.append("系统 `%s` 的 reads / writes 必须是数组" % name)
			continue
		var read_arr: Array = reads
		var write_arr: Array = writes
		if read_arr.is_empty() and write_arr.is_empty():
			problems.append("系统 `%s` 既不读也不写" % name)
			continue
		var refs: Array = []
		refs.append_array(read_arr)
		refs.append_array(write_arr)
		var bad_ref := false
		for c in refs:
			var cname := String(c)
			if not comps.has(cname) and not clean_comps.has(cname):
				problems.append("系统 `%s` 引用了未声明的组件 `%s`" % [name, cname])
				bad_ref = true
		if bad_ref:
			continue
		if not String(s.get("source", "")).ends_with(".gd"):
			problems.append("系统 `%s` 的 source 必须是 .gd" % name)
			continue
		s["id"] = name
		s["period"] = period
		clean_systems[name] = s

	return {
		"problems": problems,
		"components": clean_comps,
		"systems": clean_systems,
	}


static func _check_field_spec(cname: String, fname: String, fd: Dictionary) -> String:
	var t := String(fd.get("type", ""))
	var numeric := t == "int" or t == "float"
	var lo = fd.get("min", null)
	var hi = fd.get("max", null)
	if lo != null and (typeof(lo) == TYPE_BOOL or (typeof(lo) != TYPE_INT and typeof(lo) != TYPE_FLOAT) or not numeric):
		return "组件 `%s.%s` 的 min 只能是数字，且只给数值字段用" % [cname, fname]
	if hi != null and (typeof(hi) == TYPE_BOOL or (typeof(hi) != TYPE_INT and typeof(hi) != TYPE_FLOAT) or not numeric):
		return "组件 `%s.%s` 的 max 只能是数字，且只给数值字段用" % [cname, fname]
	if lo != null and hi != null and float(lo) > float(hi):
		return "组件 `%s.%s` 的 min 比 max 还大" % [cname, fname]
	var en = fd.get("enum", null)
	if en != null:
		if t != "str" or typeof(en) != TYPE_ARRAY or (en as Array).is_empty():
			return "组件 `%s.%s` 的 enum 只能给非空的字符串数组用" % [cname, fname]
		for v in (en as Array):
			if typeof(v) != TYPE_STRING:
				return "组件 `%s.%s` 的 enum 里有非字符串" % [cname, fname]
	return ""


static func _matches(pattern: String, text: String) -> bool:
	var re := RegEx.new()
	if re.compile(pattern) != OK:
		return false
	return re.search(text) != null
