extends RefCounted

## 角色资产：带动画的整棵节点树（骨架 / 贴图 / 片段）。
##
## 和 assets.gd 那层「换几何」是**两件不同的事**，混在一起是这一层最容易犯的错：
##   * mesh 覆盖改的是世界里的静态形状，产物是一份 ArrayMesh，没有骨骼；
##   * 角色资产是一整棵带动画的节点树 —— 骨架、贴图、76 个片段都在里面。
##
## 如果把后者硬塞进前者（烘成一份 ArrayMesh），动画会一起被烘掉，
## 人还是滑的，而且没有任何报错。所以角色走独立入口。
##
## 但它**仍然只有一个入口**：别的域只调 `CHARACTER_ASSETS.character()`，
## 不自己去 new GLTFDocument —— 那会让"资产从哪来"出现第二处真相。
##
## 问题统一记到 assets.gd 那本账上（`ASSETS.note_problem`），
## 否则"角色加载失败"会从自检里静默消失。

const MESH_LIB = preload("res://scripts/world/mesh_lib.gd")
const ASSETS = preload("res://scripts/world/assets.gd")
## 步态（速度表）在 gait.gd —— 那个文件只管"腿有多快"，这里只管"把人加载出来"。
const GAIT = preload("res://scripts/world/gait.gd")
## 角色资产目录（仓库根的 assets/characters/），和 mod 的 mesh 覆盖分开。
##
## 为什么不放进 game/ 里用 res://：那会让 Godot 的导入器在编辑器打开时
## 重新处理一遍 3.5 MB 的 glb，生成 .import 与 .godot/ 缓存；而运行时我们是
## 用 GLTFDocument 直接读磁盘。两条路各算一遍，包体里就多一份。
## 放在仓库根，它就是"投放物"，和 mod 目录一个性质。
const CHARACTER_SUBDIR := "assets/characters"
const CHARACTER_EXTS: Array[String] = ["glb", "gltf"]
## 角色脚底到头顶的目标高度，和玩家胶囊（BODY_HEIGHT）对齐。
## 现成资产一米八、一米五都有，不归一化就会出现"换个模型人就陷进地里"。
const CHARACTER_TARGET_HEIGHT := 1.68

const CHARACTER_CLIPS := {
	"idle": "Idle",
	"walk": "Walking_A",
	"run": "Running_A",
	"jump_up": "Jump_Start",
	"jump_air": "Jump_Idle",
	"land": "Jump_Land",
}

static var _char_dir := ""
static var _char_meta: Dictionary = {}   # id -> {animations, height, surfaces, source}
static var _char_mats: Dictionary = {}   # 贴图 + 颜色 -> ShaderMaterial


static func character_dir() -> String:
	if not _char_dir.is_empty():
		return _char_dir
	var env := OS.get_environment("TESSERA_ROOT")
	if not env.is_empty():
		_char_dir = env.path_join(CHARACTER_SUBDIR)
	else:
		# 没设环境变量时按 res:// 的上一级推 —— 仓库根。
		_char_dir = ProjectSettings.globalize_path("res://").path_join("..").path_join(CHARACTER_SUBDIR)
	return _char_dir


## 可用的角色 id（就是文件名去掉扩展名）。文件名即契约，没有清单文件：
## 换角色 = 往这个目录丢一个 glb，不用改任何配置。
static func character_ids() -> PackedStringArray:
	var out: Array[String] = []
	var root := character_dir()
	if not DirAccess.dir_exists_absolute(root):
		return PackedStringArray(out)
	var d := DirAccess.open(root)
	if d == null:
		return PackedStringArray(out)
	var files := d.get_files()
	files.sort()
	for f in files:
		var name := String(f)
		if CHARACTER_EXTS.has(name.get_extension().to_lower()):
			var id := name.get_basename()
			if not out.has(id):
				out.append(id)
	return PackedStringArray(out)


## 只有 id 是"文件名"时才放行。id 从玩家配置或探针来，一旦允许路径分隔符，
## `../` 就能读到仓库外面的文件 —— 和 mesh 覆盖同一个理由，先挡住。
static func character_path(char_id: String) -> String:
	if char_id.contains("/") or char_id.contains("\\") or char_id.contains(".."):
		return ""
	var root := character_dir()
	for ext in CHARACTER_EXTS:
		var p := root.path_join("%s.%s" % [char_id, ext])
		if FileAccess.file_exists(p):
			return p
	return ""


## 唯一的「问角色」入口。返回 {ok, id, root, animations, height, surfaces, source, error}。
##
## root 是一棵**未挂进场景树**的节点树，调用方负责 add_child 并最终 free ——
## 和 `mesh()` 不同，这里不能缓存同一个 root 复用到两处（一个节点只能有一个父）。
## 缓存的只有元数据，所以第二次调用仍然要重新解析文件。
static func character(char_id: String) -> Dictionary:
	var out: Dictionary = {
		"ok": false, "id": char_id, "root": null,
		"animations": PackedStringArray(), "height": 0.0,
		"surfaces": 0, "hidden": 0, "source": "", "error": "",
	}
	var path := character_path(char_id)
	if path.is_empty():
		out["error"] = "找不到角色 `%s`（在 %s 下找 .glb/.gltf）" % [char_id, character_dir()]
		return out

	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	var err: int = doc.append_from_file(path, state)
	if err != OK:
		out["error"] = "角色 `%s` 解析失败（%s，err=%d）" % [char_id, path, err]
		ASSETS.note_problem(String(out["error"]))
		return out

	var root := doc.generate_scene(state)
	if root == null:
		out["error"] = "角色 `%s` 生成不出场景（%s）" % [char_id, path]
		ASSETS.note_problem(String(out["error"]))
		return out

	var ap: AnimationPlayer = null
	if root is AnimationPlayer:
		ap = root as AnimationPlayer
	else:
		ap = root.find_child("AnimationPlayer", true, false) as AnimationPlayer
	var anims := PackedStringArray()
	if ap != null:
		anims = ap.get_animation_list()

	# 可选装备要先摘掉再算包围盒，否则"身高"会把两米长的巨剑也算进去。
	var opts := _load_options(char_id)
	var hidden := _hide_optional(root, opts.get("hide_prefix", []))

	# 归一化身高：现成资产高矮不一，不缩放就会出现"换个模型人就陷进地里"。
	# 只在**绑定姿势**下量一次 —— 动画一播，手臂和披风会把包围盒改了，
	# 那之后再量就是"这个人这一刻多高"，不是"这个人多高"。
	#
	# 量的时候不算帽子（见 `_skip_for_height`）。法师的尖顶帽比人头还高
	# 0.8 m（原生 3.00 m vs 2.20 m），算进去就会把整个法师缩到 0.56 倍 ——
	# 帽子高度一致了，人矮了一头半。而"换个模型人忽大忽小"正是这一层要消灭的东西。
	var skip := _skip_for_height(root)
	var box := _tree_aabb(root, Transform3D(), skip)
	var h := box.size.y
	var s := 1.0
	if h > 0.01:
		s = CHARACTER_TARGET_HEIGHT / h
		root.scale = Vector3(s, s, s)

	var sw := _retint(root)

	# 步速档位：自动测，不查表。第一次加载某个角色时算一遍并缓存，
	# 之后同一个 id 直接复用（character() 每次都重建节点，但测量结果与节点无关）。
	# 哪几条算步态由资产声明（opts.gait）；没声明才退回物理筛选。
	var loco: Dictionary = {}
	var prev: Dictionary = _char_meta.get(char_id, {})
	if prev.has("locomotion"):
		loco = prev["locomotion"]
	else:
		loco = GAIT.measure(root, ap, s, opts.get("gait", []), CHARACTER_TARGET_HEIGHT)

	out["ok"] = true
	out["root"] = root
	out["animations"] = anims
	out["height"] = h
	out["scale"] = s
	out["scaled_height"] = h * s
	out["foot"] = box.position.y * s
	out["surfaces"] = sw
	out["hidden"] = hidden
	out["locomotion"] = loco
	out["source"] = path.get_file()
	_char_meta[char_id] = {
		"animations": anims, "height": h, "scale": s,
		"scaled_height": h * s, "foot": box.position.y * s, "surfaces": sw,
		"hidden": hidden, "locomotion": loco, "source": path.get_file(),
	}
	return out



## 资产自带的选项文件 `<id>.json`，可选，两项：`gait` / `hide_prefix`。
##
## 为什么需要它：现成角色包惯例是把**全部可选装备**都绑在同一个骨架上，
## 一加载就是"左手三面盾、右手两把剑"。资源没坏 —— 是资源本来就等引擎
## 决定穿哪一件。而"穿哪一件"不该写死在代码里：换个角色包，前缀就变了。
## 所以由资产自己说明，代码只认前缀，不认具体名字。
##
## 手里的东西现在由位置规则自动摘（见 `_hide_optional`），所以这个文件的
## 主力用途变成了 `gait`：哪几条片段算「走路 / 跑步」只有资产自己知道。
## 不写它也能跑（退回自动筛选），但筛选会把"从地上爬起来"算成一档步态 ——
## 实测骷髅包里 `Skeletons_Awaken_Standing` 就混进了档位表。
static func _load_options(char_id: String) -> Dictionary:
	var p := character_dir().path_join(char_id + ".json")
	if not FileAccess.file_exists(p):
		return {}
	var f := FileAccess.open(p, FileAccess.READ)
	if f == null:
		return {}
	var parsed = JSON.parse_string(f.get_as_text())
	f.close()
	if parsed is Dictionary:
		return parsed
	ASSETS.note_problem("角色 `%s` 的选项文件不是合法 JSON（%s）" % [char_id, p])
	return {}


## 摘掉这个角色身上"默认不该穿"的东西。返回摘掉的件数。
##
## 两条规则，一前一后：
##
## 1. **手里的东西（结构规则，不需要任何配置）**。
##    可选手持物一律挂在 `handslot.l` / `handslot.r` 之下 —— 这是 KayKit 系
##    （以及绝大多数 Mixamo 绑定）的结构惯例，四个冒险者包和骷髅包全都如此。
##    按**位置**判而不是按名字判，于是新角色只要丢文件进来就自动正确：
##    名字每家都不一样（1H_Sword / Mug / Spellbook / Knife），位置才是共性。
##
##    这条不是锦上添花：法师包没写选项文件时，法杖把包围盒撑到 3.00 m，
##    归一化于是把整个法师缩到 0.56 倍 —— 人变矮了，而"看着看着觉得怪"
##    是最难查到根因的那一类问题。
##
## 2. **选项文件里的 `hide_prefix`（手工补充）**。
##    结构规则盖不住的东西才需要它，比如某个包把披风也做成了可选件。
##    它现在是补充而不是主力：加角色不需要写它。
static func _hide_optional(root: Node, prefixes: Array) -> int:
	var n := 0
	for slot in root.find_children("handslot*", "", true, false):
		for node in slot.find_children("*", "MeshInstance3D", true, false):
			var mi := node as MeshInstance3D
			if mi.visible:
				mi.visible = false
				n += 1
	for node in root.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if not mi.visible:
			continue
		for pre in prefixes:
			if String(mi.name).begins_with(String(pre)):
				mi.visible = false
				n += 1
				break
	return n


## 元数据（不进树、不创建节点）。探针用它断言"这个角色有没有 Idle"，
## 不必为了读一串名字就造一棵完整场景。
static func character_meta(char_id: String) -> Dictionary:
	if _char_meta.has(char_id):
		return _char_meta[char_id]
	var c := character(char_id)
	if c["ok"] and c["root"] != null:
		(c["root"] as Node).free()
	return _char_meta.get(char_id, {})


## 角色在当前缩放下的包围盒。探针用它断言"脚底贴地、身高对得上" ——
## 这两条错了症状很一致：人陷进地里，或者浮在半空。
static func character_box(root: Node) -> AABB:
	return _tree_aabb(root, Transform3D())


static func character_summary() -> String:
	var ids := character_ids()
	if ids.is_empty():
		return "角色资产：无（用引擎内置几何兜底）"
	var parts: Array[String] = []
	for id in ids:
		var m: Dictionary = _char_meta.get(id, {})
		if m.is_empty():
			parts.append(String(id))
		else:
			parts.append("%s（%d 动画 / %.2f m）"
				% [id, (m["animations"] as PackedStringArray).size(), float(m["height"])])
	return "角色资产 %d 个：%s" % [ids.size(), ", ".join(parts)]


## 把整棵树换成卡通材质。返回换过的 surface 数（探针拿它判"真的换了"）。
##
## 现成资产带的是 PBR 材质，直接用会和卡通世界割裂得很明显；
## 换成 toon 之后**贴图仍然保留**（toon.gdshader 的 use_albedo_tex），
## 于是角色既有渐变图的细节，又和箱子吃同一套两级色阶。
static func _retint(root: Node) -> int:
	var sw := 0
	for node in root.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi.mesh == null or not mi.visible:
			continue
		for i in mi.mesh.get_surface_count():
			var src: Material = mi.get_surface_override_material(i)
			if src == null:
				src = mi.mesh.surface_get_material(i)
			var tex: Texture2D = null
			var col := Color(1.0, 1.0, 1.0)
			if src is BaseMaterial3D:
				tex = (src as BaseMaterial3D).albedo_texture
				col = (src as BaseMaterial3D).albedo_color
			mi.set_surface_override_material(i, _char_material(tex, col))
			sw += 1
	return sw


## 角色材质也按（贴图, 颜色）共用。一个角色 15 个网格，一份材质足够 ——
## 和第 13 步那条"材质数不该跟着物体数走"是同一条红线。
static func _char_material(tex: Texture2D, col: Color) -> ShaderMaterial:
	var key := "none" if tex == null else str(tex.get_instance_id())
	key += "|" + col.to_html()
	if _char_mats.has(key):
		return _char_mats[key]
	var m := ShaderMaterial.new()
	m.shader = MESH_LIB.TOON_SHADER
	m.set_shader_parameter("base_color", col)
	m.set_shader_parameter("use_albedo_tex", tex != null)
	if tex != null:
		m.set_shader_parameter("albedo_tex", tex)
	# 角色比箱子小得多，描边要细一点，否则远看是一团黑边。
	var ol := ShaderMaterial.new()
	ol.shader = MESH_LIB.OUTLINE_SHADER
	ol.set_shader_parameter("width", 0.009)
	m.next_pass = ol
	_char_mats[key] = m
	return m


## 量身高时不算进去的东西：手上已经摘掉了（不可见，本来就跳过），
## 剩下的只有**头上的配件** —— 帽子、头盔、兜帽。
##
## 为什么要单独说一句：`head` 在绑定里是一个 BoneAttachment3D，挂在上面的
## 网格就是"戴在头上的东西"。它们的高度差别极大（骑士头盔比人头高 0.15 m，
## 法师尖顶帽高 0.8 m），算进总高会让戴高帽的角色被整体缩小 ——
## 结果就是"三个角色并排站，戴帽子的那个矮一头"。
##
## 人有多高由头决定，帽子有多高是造型。所以这里按**位置**排除，
## 和 handslot 是同一条思路。
static func _skip_for_height(root: Node) -> Array:
	var skip: Array = []
	for head in root.find_children("head", "BoneAttachment3D", true, false):
		skip.append(head)
	return skip


## 整棵树的包围盒（rest pose）。骨骼动画在运行时会跑出这个盒子，
## 但归一化身高用的是建模姿势 —— 那才是"这个人多高"的稳定答案。
##
## `skip` 里的节点（连同它们的子树）完全不计入 —— 只给身高归一化用；
## 探针要的"真实包围盒"走默认空数组，两者不要混。
static func _tree_aabb(node: Node, parent_xform: Transform3D, skip: Array = []) -> AABB:
	if skip.has(node):
		return AABB()
	var xf := parent_xform
	if node is Node3D:
		xf = parent_xform * (node as Node3D).transform
	var box := AABB()
	var has := false
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		if mi.visible and mi.mesh != null:
			var a: AABB = xf * mi.mesh.get_aabb()
			box = a
			has = true
	for child in node.get_children():
		var sub := _tree_aabb(child, xf, skip)
		if sub.size == Vector3.ZERO:
			continue
		box = sub if not has else box.merge(sub)
		has = true
	return box
