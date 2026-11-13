extends RefCounted

## 加载行为 mod 的脚本。**只接受来自 mod 目录的脚本。**
##
## 参数是 mod 单元列表（每项 {id, dir, entities}），不是 pack ——
## 因为脚本路径必须相对 mod 自己的目录解析。mod 是可独立发布的单元，
## 它不知道仓库根在哪，也不该知道。
##
## 加载流程四步：读源码 → 编译 → 实例化 → 绑定事件。
## 这一步用掉 Godot 唯一一条真正开放的通道：GDScript 能在运行时从磁盘编译。
## 实测（docs/decisions/0003-open-channels.md）：
##   * 任意路径的 .gd 可以 reload() 成功并实例化调用
##   * 语法错的脚本返回 Parse error，不会带走进程
##   * 但也没有沙箱 —— OS.execute 在 mod 里照样能跑
##
## 所以"能不能进来"由 registry.gd 的授权闸门管，"进来了能干什么"引擎不管，
## 也管不了。见 ADR 0003 与 0008。

## mod 必须 extends RefCounted。不是洁癖：selftest 里不建场景，
## 一个 extends Node 的 mod 会在退出时变成 ObjectDB 泄漏警告，
## 而那些警告会淹掉真正的失败信息（这个坑踩过一次）。
const REQUIRED_METHOD := "handle"


## 返回 {loaded: Array[String], errors: Array[String], files: int, hooks: int}
static func load_all(units: Array, bus) -> Dictionary:
	var loaded: Array[String] = []
	var errors: Array[String] = []
	var files := 0
	var hooks := 0

	for unit in units:
		var mod_id := String(unit.get("id", "?"))
		var dir := String(unit.get("dir", "")).trim_suffix("/")
		var entities: Dictionary = unit.get("entities", {})

		for cid in entities:
			var body: Dictionary = entities[cid]
			if String(body.get("kind", "")) != "script":
				continue
			files += 1

			var source := String(body.get("source", ""))
			if not source.ends_with(".gd"):
				errors.append("%s/%s：`source` 必须是 .gd 文件路径" % [mod_id, cid])
				continue
			var path := source if source.begins_with("/") else dir + "/" + source
			if not FileAccess.file_exists(path):
				errors.append("%s/%s：找不到脚本 `%s`（找的是 %s）" % [mod_id, cid, source, path])
				continue

			var inst = _compile(path, "%s/%s" % [mod_id, cid], errors)
			if inst == null:
				continue

			var events: Array = body.get("events", [])
			var bound: Array[String] = []
			for e in events:
				if bus.bind(String(e), inst):
					bound.append(String(e))
			hooks += bound.size()
			loaded.append("%s：%s → %s" % [mod_id, source, ", ".join(bound)])

	return {"loaded": loaded, "errors": errors, "files": files, "hooks": hooks}


static func _compile(path: String, label: String, errors: Array[String]):
	var text := FileAccess.get_file_as_string(path)
	var script := GDScript.new()
	script.source_code = text
	if script.reload() != OK:
		# 语法错的 mod 不能带走进程，但必须留下一条能读懂的记录。
		errors.append("%s：`%s` 编译失败，见上面的 Parse error" % [label, path])
		return null

	var inst = script.new()
	if inst == null:
		errors.append("%s：实例化失败（是不是没有 extends RefCounted？）" % label)
		return null
	if inst is Node:
		errors.append("%s：mod 必须 extends RefCounted，不能是 Node（生命周期归引擎管）" % label)
		return null
	if not inst.has_method(REQUIRED_METHOD):
		errors.append("%s：缺少 func %s(event, ctx, api)" % [label, REQUIRED_METHOD])
		return null
	return inst


## 编辑器运行时 res:// 指向 game/，所以仓库根是它的上一级。
## 导出包里这层关系不存在 —— 所以允许 TESSERA_ROOT 覆盖，
## 也让"导出后这条路还通不通"变成一个必须显式回答的问题，而不是猜。
static func content_root() -> String:
	var env := OS.get_environment("TESSERA_ROOT")
	if not env.is_empty():
		return env.trim_suffix("/")
	var project := ProjectSettings.globalize_path("res://")
	return project.trim_suffix("/").get_base_dir()


## mod 的搜索路径。仓库自带的在前，玩家装的在后（后者覆盖同 id）。
##
## TESSERA_MODS 用 `:` 分隔，给 CI 和"我就要试这一个 mod"用。
static func search_paths() -> Array[String]:
	var out: Array[String] = []
	var env := OS.get_environment("TESSERA_MODS")
	if not env.is_empty():
		for p in env.split(":", false):
			var s := String(p).trim_suffix("/")
			if not s.is_empty():
				out.append(s)
		return out
	out.append(content_root() + "/mods")
	out.append(OS.get_user_data_dir() + "/mods")
	return out
