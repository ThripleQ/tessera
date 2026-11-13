extends RefCounted
class_name ContentPack

## 读 content.pack.json。
## 这里刻意不做任何"理解内容"的事：只把数据结构化，并回答两个问题——
## 有多少东西、它们用什么网格。判断"世界怎么跑"是 game/ 其他部分的事。

var api_version: int = 0
var counts: Dictionary = {}
var entities: Dictionary = {}
## 契约快照：由 contract/registry.py 生成，随包一起走。
## 引擎靠它知道"世界能有什么"，从而能算出"我现在能处理多少"。
var schema: Dictionary = {}


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
	schema = parsed.get("schema", {})

	if api_version <= 0:
		push_error("内容包缺 api_version，拒绝加载")
		return false
	# schema 是硬要求。没有它，引擎就无法知道自己漏实现了哪些组件，
	# 覆盖度会永远显示成一个好看的假数字。
	if schema.is_empty():
		push_error("内容包缺 schema 段（契约快照），拒绝加载。重新跑 tools/contentc.py")
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


## 世界里实际会用到的网格种类。合批是按网格分组的，
## 所以这个集合的大小直接决定提交次数的量级。
func mesh_ids() -> PackedStringArray:
	var seen := {}
	for id in entities:
		var model: Dictionary = entities[id].get("components", {}).get("model", {})
		if model.has("mesh"):
			seen[String(model["mesh"])] = true
	return PackedStringArray(seen.keys())


## 某个 kind 的全部实体 id，按 id 排序保证顺序确定（不依赖字典遍历顺序）。
func ids_of_kind(kind: String) -> PackedStringArray:
	var out: Array[String] = []
	for id in entities:
		if String(entities[id].get("kind", "")) == kind:
			out.append(id)
	out.sort()
	return PackedStringArray(out)


## 配色由契约提供，引擎不认识任何配色名。
## 未知配色返回刺眼的品红 —— 出问题时要看得见，不要悄悄变成灰色。
func palette_color(name: String) -> Color:
	var table: Dictionary = schema.get("palettes", {})
	var rgb = table.get(name, null)
	if rgb == null:
		push_warning("未知配色 `%s`（契约里没有），用品红代替" % name)
		return Color(1.0, 0.0, 1.0)
	return Color(float(rgb[0]), float(rgb[1]), float(rgb[2]))


func palette_ids() -> PackedStringArray:
	var seen := {}
	for id in entities:
		var model: Dictionary = entities[id].get("components", {}).get("model", {})
		if model.has("palette"):
			seen[String(model["palette"])] = true
	return PackedStringArray(seen.keys())


## 契约里声明过的全部组件（世界"能"有什么）。
func declared_components() -> PackedStringArray:
	var comps: Dictionary = schema.get("components", {})
	var out := PackedStringArray(comps.keys())
	out.sort()
	return out


## 这批内容实际用到的组件（世界"现在"有什么）。
## 引擎的实现覆盖度按这个集合算，不按契约全集算 ——
## 没被任何内容用到的组件，没实现也不影响这一版能跑。
func used_components() -> PackedStringArray:
	var seen := {}
	for id in entities:
		var comps: Dictionary = entities[id].get("components", {})
		for c in comps:
			seen[c] = true
	var out := PackedStringArray(seen.keys())
	out.sort()
	return out


## 合并前用同一份 schema 校验 mod 的内容。
##
## 编译期已经校验过一遍，但那是**作者的**编译器跑的，而 mod 产物是外部文件、
## 可以被手改。第三方产物不享有"编译期校验过"这个前提，所以这里必须再查一遍。
## 契约是唯一的信任根，而它在引擎这一侧。
func validate_entities(incoming: Dictionary) -> Array[String]:
	var problems: Array[String] = []
	var comps: Dictionary = schema.get("components", {})
	for cid in incoming:
		var body: Dictionary = incoming[cid]
		if typeof(body) != TYPE_DICTIONARY:
			problems.append("`%s` 不是字典" % cid)
			continue
		var used: Dictionary = body.get("components", {})
		for c in used:
			if not comps.has(c):
				problems.append("`%s` 用了契约里没有的组件 `%s`" % [cid, c])
	return problems


## 把一个 mod 的内容并进来。冲突按"后到者覆盖"处理，被覆盖的 id 返回给调用方 ——
## 两个 mod 改同一个原型时，玩家需要知道谁赢了，而不是看到一个混合结果。
func merge_entities(incoming: Dictionary) -> Dictionary:
	var overwritten: Array[String] = []
	for cid in incoming:
		if entities.has(cid):
			overwritten.append(String(cid))
		entities[cid] = incoming[cid]
	recompute_counts()
	return {"merged": incoming.size(), "overwritten": overwritten}


## counts 必须整体重算，不能累加：mod 的产物里可能包含被覆写的实体，
## 累加会把同一个 id 数两次，而 counts 是所有预算判断的分子。
func recompute_counts() -> void:
	counts = {}
	for cid in entities:
		var k := String(entities[cid].get("kind", ""))
		if k.is_empty():
			continue
		counts[k] = int(counts.get(k, 0)) + 1


## 把一个内容 id 变成"世界能摆的东西"。
##
## 房间填充、mod 的 spawn、存档还原都需要这件事，所以只能有一份实现 ——
## 三处各写一遍的话，它们会在原点、collider 默认值、is_dynamic 的判定上慢慢分叉，
## 而分叉的表现是"存档读出来的箱子和原来那个不太一样"，是最难查的一类 bug。
##
## 返回空字典 = 这个 id 摆不出来（没有 model，或者内容里根本没有它）。
## 这里**不检查网格是否实现** —— 那是渲染层的事，Pack 不认识渲染。
func item_for(content_id: String, xform: Transform3D) -> Dictionary:
	if not entities.has(content_id):
		return {}
	var comps: Dictionary = entities[content_id].get("components", {})
	var model: Dictionary = comps.get("model", {})
	if model.is_empty():
		return {}
	var collider: Dictionary = comps.get("collider", {})
	return {
		"id": content_id,
		"mesh": String(model.get("mesh", "")),
		"xform": xform,
		"color": palette_color(String(model.get("palette", "default"))),
		"collider": collider,
		# 引擎永远按数据判断"会不会动"，不按名字。铁律 2。
		"dynamic": not collider.is_empty() and bool(collider.get("dynamic", false)),
	}


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
	lines.append("契约组件 %d 个，内容用到 %d 个"
		% [declared_components().size(), used_components().size()])
	return "\n".join(lines)
