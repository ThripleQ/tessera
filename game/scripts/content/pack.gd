extends RefCounted
class_name ContentPack

## 读 content.pack.json。
## 这里刻意不做任何"理解内容"的事：只把数据结构化，并回答两个问题——
## 有多少东西、它们用什么网格。判断"世界怎么跑"是 game/ 其他部分的事。

var api_version: int = 0
var counts: Dictionary = {}
var entities: Dictionary = {}


func load_from(path: String) -> bool:
	if not FileAccess.file_exists(path):
		push_error("找不到内容包：%s（先跑 ./check.sh 生成）" % path)
		return false

	var text := FileAccess.get_file_as_string(path)
	var parsed = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("内容包不是合法 JSON：%s" % path)
		return false

	api_version = int(parsed.get("api_version", 0))
	counts = parsed.get("counts", {})
	entities = parsed.get("entities", {})

	if api_version <= 0:
		push_error("内容包缺 api_version，拒绝加载")
		return false
	return true


## 能在世界里摆出来的原型：必须带 model 组件。
## 基类（只作为 extends 起点）通常也有 model，但它们的 tags 里带 "abstract"。
func spawnables() -> Array[String]:
	var out: Array[String] = []
	for id in entities:
		var e: Dictionary = entities[id]
		var comps: Dictionary = e.get("components", {})
		if not comps.has("model"):
			continue
		out.append(id)
	out.sort()
	return out


## 世界里实际会用到的网格种类。合批是按 (网格, 配色) 分组的，
## 所以这两个集合的大小直接决定 draw call 的量级。
func mesh_ids() -> PackedStringArray:
	var seen := {}
	for id in entities:
		var model: Dictionary = entities[id].get("components", {}).get("model", {})
		if model.has("mesh"):
			seen[String(model["mesh"])] = true
	return PackedStringArray(seen.keys())


func palette_ids() -> PackedStringArray:
	var seen := {}
	for id in entities:
		var model: Dictionary = entities[id].get("components", {}).get("model", {})
		if model.has("palette"):
			seen[String(model["palette"])] = true
	return PackedStringArray(seen.keys())


func summary() -> String:
	var lines: Array[String] = []
	lines.append("内容包 v%d：%d 条" % [api_version, entities.size()])
	var kinds := counts.keys()
	kinds.sort()
	for k in kinds:
		lines.append("  %-10s %d" % [k, int(counts[k])])
	lines.append("可摆放原型 %d，网格 %d 种，配色 %d 种"
		% [spawnables().size(), mesh_ids().size(), palette_ids().size()])
	lines.append("网格：%s" % ", ".join(mesh_ids()))
	return "\n".join(lines)
