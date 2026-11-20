extends RefCounted

## 步态：这个角色**应该跑多快**，以及某个速度该用哪一档动画。
##
## 和 character_assets.gd 分开，是因为这是两件事：
##   * character_assets 管"把 glb 变成一棵能穿的树"（骨架、贴图、身高、材质）；
##   * 这里只管"腿有多快"，输入是动画曲线，输出是一张速度表。
## 混在一起的后果是那个文件既加载资产又做工效测量，谁都不敢改。
##
## 为什么速度不能写死：写死的速度配现成的动画，两者比值就是滑动的量。
## 4.6 m/s 配画到 0.55 m/s 的走路 = 滑 4 倍。而且这比值随资产变 ——
## 换一个角色包，写死的数立刻作废，只能靠试。
##
## 所以反过来：**先量腿，再定速度。**

const STRIDE = preload("res://scripts/world/stride.gd")
const ASSETS = preload("res://scripts/world/assets.gd")

## 步频倍率：1.0 = 资产自带的自然节奏。
##
## 它**不是用来补滑动的**。倍率的职责只有一个：在同一条片段内部做小幅微调，
## 让速度在档位之间连续过渡。升速必须靠换片段（走→慢跑→跑），
## 就像动作游戏那样一档一档升，而不是把同一条走路播成 8 倍（那是蜂鸟）。
const WALK_RATE := 1.35
const RUN_RATE := 1.35
## 没点名步态时的兜底门槛：前进速度低于「身高 × 这个比例」的片段不算移动动画。
## 0.25 × 1.68 m ≈ 0.42 m/s。用身高折算而不是写死米数，换个高个子角色门槛跟着长。
const MIN_GAIT_RATIO := 0.25


## 测出这个角色每条移动动画隐含多大前进速度，按速度升序排成档位。
##
## 哪几条算移动动画，优先**由资产点名**（`<id>.json` 的 `gait`）。
## 为什么不纯靠物理量自动挑：包里 76 条动画，挥刀、闪避、死亡、爬起来的片段
## 也有一段"脚在地上匀速后撤"。实测闪避的拟合残差（0.053）比走路（0.066）还规整，
## 支撑占比也更像走路 —— 形态上分不开。再往下堆启发式，
## 就是造一套只有作者看得懂的规则。
##
## 资产没点名时才退回物理筛选，门槛按身高折算：宁可漏掉一条慢走动画、
## 退回默认速度，也不要把挥刀当成步态。
##
## 返回 {"moving": [{"clip", "speed"}, ...], "walk", "run", "source"}。
## 一条都测不出来时返回 {} —— 调用方必须退回兜底路径，不许假装成功。
static func measure(root: Node, ap: AnimationPlayer, scale: float,
		declared: Array, body_height: float) -> Dictionary:
	if ap == null:
		return {}
	var sk: Skeleton3D = null
	for n in root.find_children("*", "Skeleton3D", true, false):
		sk = n as Skeleton3D
		break
	if sk == null:
		return {}
	var moving: Array = []
	var source := "声明"
	if declared.is_empty():
		source = "自动筛选"
	var binds := _bind_poses(root)
	for clip in _candidates(ap, declared):
		var a := ap.get_animation(clip)
		if a == null:
			if not declared.is_empty():
				ASSETS.note_problem("角色 `%s` 声明的步态片段 `%s` 不存在" % [root.name, clip])
			continue
		var m := STRIDE.clip_motion(a, sk, binds)
		if not m["ok"]:
			continue
		var spd: float = m["speed"] * scale
		var fwd: float = m["forward"] * scale
		# 原地动作（Idle / 待机循环）：没有水平位移，不是移动片段。
		if spd < 0.05:
			continue
		# 能当"直行"用吗：必须向前，且横向分量不占主导（侧移动画会在这里落选）。
		if fwd <= 0.0 or fwd < spd * 0.8:
			continue
		# 没点名时的兜底门槛：比这更慢的"前进"，多半是挥一下手带出来的抖动。
		if declared.is_empty() and spd < body_height * MIN_GAIT_RATIO:
			continue
		moving.append({"clip": String(clip), "speed": spd})
	if moving.is_empty():
		return {}
	moving.sort_custom(func(a, b): return float(a["speed"]) < float(b["speed"]))
	# 走 / 冲刺速度由**最低档和最高档**反推，中间档留给加速过程自然过渡。
	var walk: float = float(moving[0]["speed"]) * WALK_RATE
	var run: float = float(moving[moving.size() - 1]["speed"]) * RUN_RATE
	return {"moving": moving, "walk": walk, "run": run, "source": source}


## 骨骼 → 绑定矩阵。取第一份带蒙皮网格的 skin：
## 一个角色的所有网格共用同一副骨架，谁先谁后都一样。
##
## 没有蒙皮网格（比如纯几何兜底）时返回空字典，测量退回"只读骨骼"的老路。
static func _bind_poses(root: Node) -> Dictionary:
	var out: Dictionary = {}
	for n in root.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi.skin == null:
			continue
		for i in mi.skin.get_bind_count():
			var bone := mi.skin.get_bind_bone(i)
			if bone >= 0:
				out[bone] = mi.skin.get_bind_pose(i)
		if not out.is_empty():
			return out
	return out


## 把"片段 → 它隐含的地面速度"整理成和实测一样形状的档位表。
##
## 走 / 冲刺速度取最低档和最高档（和 measure 同一条规则），中间档留给加速过程——
## 于是上层完全不用知道这张表是测出来的还是人标的。
##
## 手工标定存在的理由：有些包把骨架挂在缩放节点下、把长度藏在绑定矩阵里，
## 自动测出来的数会小一个数量级，而且**看起来像个正常数**。
## 那种资产就由人标一次写进 json，代码不再猜。`source` 必须写"标定"，
## 不许冒充"实测"—— 两件事的可信度不一样。
static func from_speeds(speeds: Dictionary) -> Dictionary:
	var moving: Array = []
	for clip in speeds.keys():
		moving.append({"clip": String(clip), "speed": float(speeds[clip])})
	if moving.is_empty():
		return {}
	moving.sort_custom(func(a, b): return float(a["speed"]) < float(b["speed"]))
	return {
		"moving": moving,
		"walk": float(moving[0]["speed"]) * WALK_RATE,
		"run": float(moving[moving.size() - 1]["speed"]) * RUN_RATE,
		"source": "标定",
	}


## 待测的片段名。点名了就只测点名的；没点名就把全部片段过一遍交给物理筛。
static func _candidates(ap: AnimationPlayer, declared: Array) -> Array[String]:
	var out: Array[String] = []
	if not declared.is_empty():
		for c in declared:
			out.append(String(c))
		return out
	for clip in ap.get_animation_list():
		out.append(String(clip))
	return out


## 把测量结果整理成"该跑多快"。纯函数，不读任何状态 ——
## 存到哪、缓存多久，是 character_assets 的事。
##
## 返回 {ok, walk, run, tiers}。测不出来时 ok=false：
## 调用方必须退回默认速度，不许拿 0 当速度用（0 会让角色永远站着）。
static func from_table(loco: Dictionary) -> Dictionary:
	if loco.is_empty() or not loco.has("walk"):
		return {"ok": false, "walk": 0.0, "run": 0.0, "tiers": []}
	return {
		"ok": true,
		"walk": float(loco["walk"]),
		"run": float(loco["run"]),
		"tiers": loco["moving"],
	}


## 档位的文字摘要，给启动日志和探针用 —— 不打开游戏也能看出"这套资产跑多快"。
static func summary(loco: Dictionary) -> String:
	if loco.is_empty():
		return "无步速档位（没有可用的移动动画）"
	var parts: Array[String] = []
	for e in loco["moving"]:
		parts.append("%s %.2f" % [e["clip"], float(e["speed"])])
	var tail := ""
	if loco.has("walk"):
		tail = "｜反推：走 %.2f / 冲刺 %.2f m/s" % [float(loco["walk"]), float(loco["run"])]
	return "步速档位：" + " / ".join(parts) + " m/s" + tail
