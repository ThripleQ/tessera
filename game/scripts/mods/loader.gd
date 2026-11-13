extends RefCounted

## 运行时加载行为 mod。
##
## mod 是什么：`kind="script"` 的一条内容，指向一个 .gd 文件，声明它要挂哪些事件。
## 加载流程就是四步 —— 读源码 → 编译 → 实例化 → 绑定事件。
##
## 这一步用掉了 Godot 唯一一条真正开放的通道：GDScript 能在运行时从磁盘编译。
## 实测（docs/decisions/0003-open-channels.md）：
##   * 任意路径的 .gd 可以 reload() 成功并实例化调用
##   * 语法错的脚本返回 Parse error，不会带走进程
##   * 但也没有沙箱 —— OS.execute 在 mod 里照样能跑
##
## 所以 mod 分两级：这个 load_all 只处理 data+script 同级，权限靠"玩家装不装"来管，
## 不靠引擎假装能拦。见 ADR 0007。

## mod 必须 extends RefCounted。不是洁癖：selftest 里不建场景，
## 一个 extends Node 的 mod 会在退出时变成 ObjectDB 泄漏警告，
## 而那些警告会淹掉真正的失败信息（这个坑踩过一次）。
const REQUIRED_METHOD := "handle"


## 返回 {loaded: Array[String], errors: Array[String], files: int}
static func load_all(pack, root: String, bus) -> Dictionary:
	var loaded: Array[String] = []
	var errors: Array[String] = []
	var ids: PackedStringArray = pack.ids_of_kind("script")

	for id in ids:
		var body: Dictionary = pack.entities[id]
		var source := String(body.get("source", ""))
		var path := _resolve(root, source)
		if path.is_empty() or not FileAccess.file_exists(path):
			errors.append("%s: 找不到脚本 `%s`（找的是 %s）" % [id, source, path])
			continue

		var text := FileAccess.get_file_as_string(path)
		var script := GDScript.new()
		script.source_code = text
		if script.reload() != OK:
			errors.append("%s: `%s` 编译失败，见上面的 Parse error" % [id, source])
			continue

		var inst = script.new()
		if inst == null:
			errors.append("%s: `%s` 实例化失败（是不是没有 extends RefCounted？）" % [id, source])
			continue
		if inst is Node:
			errors.append("%s: mod 必须 extends RefCounted，不能是 Node（生命周期归引擎管）" % id)
			continue
		if not inst.has_method(REQUIRED_METHOD):
			errors.append("%s: `%s` 缺少 func %s(event, ctx, api)" % [id, source, REQUIRED_METHOD])
			continue

		var events: Array = body.get("events", [])
		var bound: Array[String] = []
		for e in events:
			if bus.bind(String(e), inst):
				bound.append(String(e))
		loaded.append("%s [%s] → %s" % [id, source, ", ".join(bound)])

	return {"loaded": loaded, "errors": errors, "files": ids.size()}


## 内容根目录：内容包里的路径都是相对仓库根的（例如 mods/scripts/x.gd）。
##
## 编辑器运行时 res:// 指向 game/，所以根是它的上一级；
## 导出包里这层关系不存在 —— 所以允许 TESSERA_ROOT 覆盖，
## 也让"导出后这条路还通不通"变成一个必须显式回答的问题，而不是猜。
static func content_root() -> String:
	var env := OS.get_environment("TESSERA_ROOT")
	if not env.is_empty():
		return env.trim_suffix("/")
	var project := ProjectSettings.globalize_path("res://")
	return project.trim_suffix("/").get_base_dir()


static func _resolve(root: String, source: String) -> String:
	if source.is_empty():
		return ""
	if source.begins_with("/"):
		return source
	return root + "/" + source
