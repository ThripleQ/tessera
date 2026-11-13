extends RefCounted

## 无头自检：**装配完成之后，回头问一遍"这台机器真的成立吗"**。
##
## 它从 main.gd 拆出来，理由不是"文件太长"，而是职责不同：main 负责把东西拼起来，
## 这一份负责怀疑拼起来的结果。两者混在一个文件里时，最典型的退化是
## "自检开始迁就实现" —— 某条检查过不去了，就在 main 里顺手改一行让它过去。
## 分成两个文件至少让那次修改需要一次显式的跳转。
##
## 每一条检查都对应一种**静默失败**：不报错、不崩、只是世界变得不对。
## 这个项目最贵的 bug 都是这一类，所以检查写的不是"代码跑了"，而是"数据自洽"。

const MESH_LIB = preload("res://scripts/world/mesh_lib.gd")
const BUS_SCRIPT = preload("res://scripts/hooks/bus.gd")


## app 就是 main 自己。这里读它的装配结果，不碰它的生命周期。
static func run(app) -> bool:
	var ok := true
	var pack = app.pack
	var plan = app.plan

	# 钩子：契约声明的 == 引擎真发的。
	# 只声明不发是撒谎（mod 挂了钩子永远等不到），只发不声明是绕过契约。
	# 这条检查的价值不在于今天，而在于以后有人加了钩子却忘了接线的那一刻。
	var declared := PackedStringArray(pack.schema.get("hooks", {}).keys())
	declared.sort()
	var emitted := PackedStringArray(BUS_SCRIPT.EMITTED)
	emitted.sort()
	if declared != emitted:
		printerr("自检失败：钩子声明与引擎发出不一致\n  契约：%s\n  引擎：%s"
			% [", ".join(declared), ", ".join(emitted)])
		ok = false

	# mod 编译失败必须在 CI 就暴露。玩家装了个坏 mod 当然会炸，
	# 但我们自己仓库里的 mod 挂了却一路绿灯，那才是灾难。
	for e in app.mods.get("errors", []):
		printerr("自检失败：mod 加载错误 —— %s" % e)
		ok = false

	# 带脚本的 mod 一个都没跑起来，说明验收没测到行为开放。
	# 这种"绿得毫无意义"的通过比红的更危险，所以必须当成失败。
	if app.mod_blocked > 0:
		printerr("自检失败：%d 个带脚本的 mod 未被授权，脚本通道没被验证到"
			% app.mod_blocked)
		printerr("  验收里应该显式授权：./check.sh 会给 --trust。见 docs/decisions/0008")
		ok = false

	# 基础内容不许带脚本：基础内容永远被信任（它在仓库里、随引擎发布），
	# 一旦它能带脚本，就存在一条绕过授权闸门的通道 —— 而且是最好用的那条。
	if app.base_scripts > 0:
		printerr("自检失败：基础内容里有 %d 条 kind=\"script\"。脚本必须来自 mod 目录"
			% app.base_scripts)
		ok = false

	# 边界校验：内容用到的每个组件，契约里必须声明过。
	# 编译期已经查过一遍，这里再查是防"旧 pack 配新引擎"这类错配 ——
	# 那种情况下编译期检查根本没跑过。
	var declared_comps := {}
	for c in pack.declared_components():
		declared_comps[c] = true
	for c in pack.used_components():
		if not declared_comps.has(c):
			printerr("自检失败：内容引用了契约里不存在的组件 `%s`" % c)
			ok = false

	# 契约里有这个网格，引擎就必须画得出来。缺一个都算失败 ——
	# 否则那个东西会静默地从世界里消失，没有任何人会发现。
	var declared_meshes: Dictionary = pack.schema.get("meshes", {})
	var missing := MESH_LIB.missing(PackedStringArray(declared_meshes.keys()))
	if not missing.is_empty():
		printerr("自检失败：契约里有这些网格但引擎没实现几何：%s" % ", ".join(missing))
		ok = false

	# 三角形数必须与实测一致。改了几何却忘了改契约，预算就会在无人察觉的情况下失真，
	# 而"预算失真"是这个项目最不能接受的一种错误 —— 它让人以为世界还装得下。
	for mesh_id in declared_meshes:
		var want := int(declared_meshes[mesh_id])
		var got: int = MESH_LIB.triangles_of(String(mesh_id))
		if want != got:
			printerr("自检失败：网格 `%s` 契约写 %d 三角形，引擎实测 %d" % [mesh_id, want, got])
			ok = false

	if plan.instance_count() <= 0:
		printerr("自检失败：世界是空的（房间填不出东西，检查 spawner 指向的原型）")
		ok = false

	# 生成菜单的全部内容来自数据，所以"菜单里有什么"必须在 CI 里就能看见。
	# 三条各是一次独立的失败，因为它们的后果完全不同：
	#   * 抽象基类混进菜单 —— 点下去必然失败，玩家会以为菜单坏了
	#   * 一件刚体都没有 —— 沙盒里放不下会动的东西，物理手感无从谈起
	#   * 一件固定物都没有 —— 静态摆放那条路（world.props + 存档）永远走不到
	var rigid_placeable := 0
	var static_placeable := 0
	for id in pack.spawnables():
		if pack.is_abstract(id):
			printerr("自检失败：抽象基类 `%s` 出现在可摆放清单里（它只能被 extends）" % id)
			ok = false
			continue
		if pack.places_as_rigid(id):
			rigid_placeable += 1
		else:
			static_placeable += 1
	if rigid_placeable == 0:
		printerr("自检失败：没有任何可生成的**刚体**，沙盒里放不下会动的东西")
		ok = false
	if static_placeable == 0:
		printerr("自检失败：没有任何可生成的**固定物**，摆放静态物的那条路没被验证到")
		ok = false

	# 每个房间都必须有地板，否则玩家走进去会直接掉进虚空。
	for room_id in plan.rooms:
		var fs: Vector2 = plan.rooms[room_id]["floor_size"]
		if fs.x <= 0.0 or fs.y <= 0.0:
			printerr("自检失败：房间 `%s` 没有地板尺寸，玩家会掉下去" % room_id)
			ok = false

	print("网格实现 %d / 契约 %d 种" % [MESH_LIB.implemented().size(), declared_meshes.size()])
	print("物理：刚体 %d / 障碍 %d / 地板 %d 块"
		% [plan.dynamic_count(), plan.solid_static_count(), plan.rooms.size()])
	print("可生成：刚体 %d 种 / 固定 %d 种（清单来自内容，菜单里没有一行硬编码）"
		% [rigid_placeable, static_placeable])
	print("行为：mod %d 个 / 脚本 %d 个 / 挂载 %d 处 / 契约钩子 %d 个"
		% [app.mod_units.size(), app.mods.get("files", 0), app.bus.handler_count(), declared.size()])
	if ok:
		print("自检通过")
	return ok
