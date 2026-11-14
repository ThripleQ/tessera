extends RefCounted

## mod 注册表 —— 发现、授权、合并。运行时的入口在这里，不在 loader。
##
## mod 是一个**目录**，里面必须有 `content.pack.json`（由 `tools/contentc.py --mod` 产出）。
## 引擎只读产物，不读 TOML：作者格式与运行时格式分开，中间只有一份编译器（Python）。
## 如果引擎也去解析 TOML，就等于有了两份编译器、两套行为，迟早不一致。
##
## 三件事按顺序发生：
##   1. discover  扫目录，读产物。**不加载**，只列出来
##   2. resolve   按授权记录决定谁进来。script 级没授权就挡住，但内容照常合并不了 ——
##                这里必须挡在"合并之前"，否则一个带脚本的 mod 即使脚本没跑，
##                也已经改了世界的数据，那道闸门就形同虚设
##   3. merge     按确定顺序把内容并进 pack
##
## 为什么顺序必须是确定的：同一个世界在不同机器上要长得一样。
## 目录遍历顺序、字典顺序在 Godot 里都不保证，所以这里全部显式 sort。

const PRODUCT := "content.pack.json"
const SETTINGS_PATH := "user://mods.json"

## 引擎支持的产物版本。与 contract/registry.py 的 SUPPORTED_API 是两回事：
## 那个管内容 schema，这个管 mod 产物的信封格式。两个都得对得上。
const SUPPORTED_PRODUCT := [1]


## 扫描一批根目录。返回 {candidates, errors}。
## 后出现的根目录覆盖先出现的（同 id）—— 玩家装的应该压过仓库自带的。
static func discover(dirs: Array) -> Dictionary:
	var found: Dictionary = {}      # id -> candidate
	var errors: Array[String] = []
	var warnings: Array[String] = []

	for raw_dir in dirs:
		var dir := String(raw_dir).trim_suffix("/")
		if dir.is_empty() or not DirAccess.dir_exists_absolute(dir):
			continue
		var d := DirAccess.open(dir)
		if d == null:
			errors.append("打不开 mod 目录 %s" % dir)
			continue
		var names := d.get_directories()
		names.sort()
		for name in names:
			var path := dir + "/" + name
			var cand := _read_product(path, name, errors, warnings)
			if cand.is_empty():
				continue
			if found.has(cand["id"]):
				warnings.append("mod `%s` 重复：%s 覆盖 %s" % [cand["id"], path, found[cand["id"]]["dir"]])
			found[cand["id"]] = cand

	var ids := found.keys()
	ids.sort()
	var out: Array[Dictionary] = []
	for id in ids:
		out.append(found[id])
	return {"candidates": out, "errors": errors, "warnings": warnings}


static func _read_product(path: String, dir_name: String, errors: Array[String], warnings: Array[String]) -> Dictionary:
	var product := path + "/" + PRODUCT
	if not FileAccess.file_exists(product):
		# 静默跳过等于"装了却什么都没发生"，这是最难查的一类问题：
		# 玩家会以为是游戏不认这个 mod，而实际上它只是没编译。
		errors.append("%s：缺少 %s（未编译？跑 `python3 tools/contentc.py --mod %s`）"
			% [path, PRODUCT, path])
		return {}

	var parsed = JSON.parse_string(FileAccess.get_file_as_string(product))
	if typeof(parsed) != TYPE_DICTIONARY:
		errors.append("%s：%s 不是合法 JSON" % [path, PRODUCT])
		return {}

	var meta: Dictionary = parsed.get("mod", {})
	var id := String(meta.get("id", ""))
	if id.is_empty():
		errors.append("%s：产物缺 mod.id" % path)
		return {}
	if id != dir_name:
		warnings.append("mod `%s` 装在目录 `%s` 下（允许，但不容易找）" % [id, dir_name])

	var ver := int(parsed.get("api_version", 0))
	if not (ver in SUPPORTED_PRODUCT):
		errors.append("mod `%s` 的产物版本 %d 不受支持（支持 %s）—— 它由更新/更旧的编译器产出"
			% [id, ver, str(SUPPORTED_PRODUCT)])
		return {}

	var entities: Dictionary = parsed.get("entities", {})
	# 真实级别只看内容里有没有可执行代码，不看作者在 mod.toml 里写的那一栏。
	# 作者完全可以把带脚本的 mod 标成 data 来跳过玩家授权；
	# 引擎一旦相信那份声明，闸门就是纸做的。
	var level := "script" if _has_scripts(entities) else "data"
	var declared := String(meta.get("level", "data"))
	if declared == "data" and level == "script":
		warnings.append("mod `%s` 声明 data 级但带脚本，按 script 级处理" % id)

	return {
		"id": id,
		"dir": path,
		"meta": meta,
		"entities": entities,
		"extensions": parsed.get("extensions", {}),
		"counts": parsed.get("counts", {}),
		"level": level,
		"declared_level": declared,
	}


static func _has_scripts(entities: Dictionary) -> bool:
	# L3 的事件脚本与 L4 的系统脚本都是可执行代码。少算一种，
	# 就等于给「标成 data 的 mod 偷偷跑规则」留了一道门（ADR 0011）。
	for cid in entities:
		var kind := String((entities[cid] as Dictionary).get("kind", ""))
		if kind == "script" or kind == "system":
			return true
	return false


# ---------------------------------------------------------------- 授权

## 授权记录。文件不存在 = 从没授权过任何东西，这是正确的默认值：
## 默认拒绝，而不是默认信任。
static func load_settings() -> Dictionary:
	var s := {"trusted": [], "disabled": []}
	if not FileAccess.file_exists(SETTINGS_PATH):
		return s
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(SETTINGS_PATH))
	if typeof(parsed) != TYPE_DICTIONARY:
		return s
	s["trusted"] = parsed.get("trusted", [])
	s["disabled"] = parsed.get("disabled", [])
	return s


static func save_settings(s: Dictionary) -> bool:
	var f := FileAccess.open(SETTINGS_PATH, FileAccess.WRITE)
	if f == null:
		push_error("写不了授权记录 %s" % SETTINGS_PATH)
		return false
	f.store_string(JSON.stringify({
		"trusted": s.get("trusted", []),
		"disabled": s.get("disabled", []),
	}, "  "))
	f.close()
	return true


## 把一批 id 加进信任名单。返回是否真的改变了记录 ——
## 没变就不用写盘，写盘是最容易在只读环境里崩的一步。
static func trust(ids: Array) -> bool:
	var s := load_settings()
	var changed := false
	for id in ids:
		var sid := String(id)
		if sid.is_empty() or sid == "all":
			continue
		if not (sid in s["trusted"]):
			s["trusted"].append(sid)
			changed = true
	if changed:
		save_settings(s)
	return changed


## 按授权决定谁进来。返回 {enabled, blocked, errors, warnings}。
##
## blocked 是"内容是安全的，但它带代码而且没被授权"——
## 这种情况整包挡住，不放一半。理由：只合并数据不跑代码，玩家看到的是一个
## 「装了却没生效」的 mod，比直接拒绝更让人困惑，而且下次授权后世界状态会突变。
static func resolve(found: Dictionary, settings: Dictionary) -> Dictionary:
	var trusted: Array = settings.get("trusted", [])
	var disabled: Array = settings.get("disabled", [])
	var enabled: Array[Dictionary] = []
	var blocked: Array[Dictionary] = []
	var warnings: Array[String] = found.get("warnings", []).duplicate()

	for cand in found.get("candidates", []):
		var id: String = cand["id"]
		if id in disabled:
			warnings.append("mod `%s` 已被停用（%s 里的 disabled）" % [id, SETTINGS_PATH])
			continue
		if cand["level"] == "script" and not (id in trusted):
			blocked.append(cand)
			continue
		enabled.append(cand)

	return {
		"enabled": enabled,
		"blocked": blocked,
		"errors": found.get("errors", []),
		"warnings": warnings,
	}


## 给人看的一句话总结，`check.sh` 与运行日志都用它。
static func describe(resolved: Dictionary) -> String:
	var parts: Array[String] = []
	for c in resolved["enabled"]:
		parts.append("%s[%s]" % [c["id"], c["level"]])
	var line := "mod：载入 %d 个" % resolved["enabled"].size()
	if not parts.is_empty():
		line += "（%s）" % ", ".join(parts)
	if not resolved["blocked"].is_empty():
		var names: Array[String] = []
		for c in resolved["blocked"]:
			names.append(String(c["id"]))
		line += "；**未授权 %d 个**（%s）—— 它们带脚本，需要 --trust" % [names.size(), ", ".join(names)]
	return line
