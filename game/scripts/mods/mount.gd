extends RefCounted

## mod 的发现 → 授权 → 合并。三步都"先看清楚，再动手"。
##
## 为什么从 `main.gd` 里搬出来：入口文件只该做**组装** —— 它把数据、世界、
## 玩家、系统接在一起。而"哪些 mod 能进来"是一整套判定（目录扫描、授权闸门、
## 扩展先并 schema 再校验内容），它有自己的顺序要求，混在装配顺序里最容易被
## 顺手改坏，而那类改动通常没有任何症状，只是某个 mod 悄悄不生效了。
##
## 合并放在这里而不是 registry 里，是因为它要动 pack 对象 ——
## registry 只回答"谁能进来"，不该拥有修改世界的权力。

const LOADER = preload("res://scripts/mods/loader.gd")
const REGISTRY = preload("res://scripts/mods/registry.gd")


## 返回 `{units, blocked}`：合并成功的 mod 单元（交给 loader 找脚本），
## 以及被授权闸门挡下的数量（自检要求它为 0 —— 否则"行为开放"这条通道
## 在这一轮里根本没被跑到，而验收照样是绿的）。
static func run(pack, args: PackedStringArray) -> Dictionary:
	var found := REGISTRY.discover(LOADER.search_paths())
	_apply_trust(args, found["candidates"])

	var resolved := REGISTRY.resolve(found, REGISTRY.load_settings())
	for e in resolved["errors"]:
		printerr("mod 扫描失败：%s" % e)
	for w in resolved["warnings"]:
		print("mod 提示：%s" % w)

	for cand in resolved["blocked"]:
		printerr("mod `%s` 未授权：它带可执行代码，而 Godot 没有 GDScript 沙箱（ADR 0003）。"
			% cand["id"])
		printerr("  信任它就跑一次： ./run.sh --trust=%s" % cand["id"])

	var units: Array[Dictionary] = []
	for cand in resolved["enabled"]:
		# 扩展声明必须先并进 schema，再校验内容 —— 否则 mod 自带的
		# `[components.<新组件>]` 会被当成「契约里没有的组件」。
		var ext: Dictionary = cand.get("extensions", {})
		var problems: Array[String] = pack.apply_extension(ext, String(cand["id"]))
		problems.append_array(pack.validate_entities(cand["entities"]))
		if not problems.is_empty():
			for p in problems:
				printerr("mod `%s` 被拒绝：%s" % [cand["id"], p])
			continue
		var merged: Dictionary = pack.merge_entities(cand["entities"])
		var overwritten: Array = merged["overwritten"]
		var note := "%s[%s] %d 条" % [cand["id"], cand["level"], merged["merged"]]
		var ext_comps: Dictionary = ext.get("components", {})
		var ext_systems: Dictionary = ext.get("systems", {})
		if not ext_comps.is_empty() or not ext_systems.is_empty():
			note += "，扩展 %d 组件 / %d 系统" % [ext_comps.size(), ext_systems.size()]
		if not overwritten.is_empty():
			note += "，覆写 %d 条（%s）" % [overwritten.size(), ", ".join(overwritten)]
		print("mod 合并：%s" % note)
		units.append(cand)

	print(REGISTRY.describe(resolved))
	return {"units": units, "blocked": resolved["blocked"].size()}


## 显式授权。没有 UI 之前，命令行就是那道开关 —— 而且它比 UI 更诚实：
## 玩家必须自己敲出这个 mod 的 id，不能靠一路点"下一步"过去。
static func _apply_trust(args: PackedStringArray, candidates: Array) -> void:
	var ids: Array[String] = []
	for a in args:
		var arg := String(a)
		if not arg.begins_with("--trust="):
			continue
		var id := arg.trim_prefix("--trust=")
		if id == "all":
			# 只在明说的情况下才全信任，而且照样逐个记进名单 ——
			# 下次不给这个参数时，授权依然有效，因为它们是具体的 id。
			for c in candidates:
				if c["level"] == "script":
					ids.append(String(c["id"]))
			continue
		var hit := false
		for c in candidates:
			if String(c["id"]) == id:
				hit = true
		if not hit:
			printerr("--trust=%s：没有这个 mod（现有：%s）"
				% [id, ", ".join(_mod_ids(candidates))])
			continue
		ids.append(id)

	if ids.is_empty():
		return
	if REGISTRY.trust(ids):
		print("已授权：%s（记在 %s，下次不用再给这个参数）"
			% [", ".join(ids), REGISTRY.SETTINGS_PATH])


static func _mod_ids(candidates: Array) -> Array[String]:
	var out: Array[String] = []
	for c in candidates:
		out.append(String(c["id"]))
	return out
