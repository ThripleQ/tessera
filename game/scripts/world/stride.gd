extends RefCounted

## 步幅测量：从动画曲线本身算出**这套动作隐含的地面速度**（米/秒）。
##
## 解决的问题叫"脚底打滑"：角色实际移动 4 m/s，但动画是按 0.6 m/s 画的，
## 播放倍率还是 1.0 —— 于是腿在迈、人却在冰上滑。要修，就必须知道
## "这段动画一秒钟走多远"。这个数不该写死：换个角色、换套动画，它立刻变了。
##
## 怎么测（物理量，不是查表）：
##   人在走路时，**支撑的那只脚相对身体是匀速后退的**，后退速率就等于前进速度。
##   所以只要找到"脚在地面上"的那一段，量它相对身体的位移速率，就得到地面速度。
##   支撑相用脚的高度判：脚落在地面附近 = 支撑，抬起来 = 摆动。
##
## 为什么不用 AnimationPlayer 去驱动骨架再读：它要等节点 ready 之后的帧才
## 真正写 pose（在 `SceneTree._initialize` 里 seek / advance 全是空操作，实测过）。
## 那样测量要么变成异步，要么必须进游戏跑一遍才能拿到数。
## 这里改成**直接读曲线求值**：纯函数、任何时刻可调、不碰播放器状态，
## 于是探针能直接断言，加载流程也不用等帧。
##
## 它不是骨骼动画系统：没有 IK、没有根运动重定向、不处理缩放轨道。
## 只回答一个问题——这段循环动画，一秒走多少米。

## 支撑相阈值：脚高低于"最低点 + 行程 × 这个比例"就算踩在地上。
## 太小会把支撑相切碎，太大会把摆动也算进支撑（速度被拉低）。
const SUPPORT_BAND := 0.30
## 每个循环的采样数。48 对 0.8~1.1 秒的片段约 20ms 一点，够定位支撑相。
const SAMPLES := 48
## 支撑相少于这么多个采样点就不可信：直接判失败，不许给个错数。
const MIN_SUPPORT := 4
## 认脚的骨骼名关键词（小写比较）。
const FOOT_HINTS: Array[String] = ["foot", "toe", "ankle", "脚"]


## 一条片段的运动信息（**骨骼原始单位**/秒，未乘节点缩放）。
##
## 返回 {"ok", "speed", "forward", "lateral", "feet", "duty", "fit"}：
##   speed   —— 地面速度大小
##   forward —— 带符号的前向速度（正 = 向前走，负 = 倒退走）
##   lateral —— 横向分量（侧移动画在这项上会很大）
##   feet    —— 有几只脚量出了支撑相（走路应该是 2）
##   duty    —— 支撑相占整个循环的比例（走路 0.5~0.7，挥一刀约 0）
##   fit     —— 支撑段内速度的离散程度 / 速度本身（越大说明"不是匀速后退"）
##
## 为什么把这三个也吐出来：只靠"速度大于零"筛移动动画，会把挥刀、闪避、
## 爬起来的片段一起收进来 —— 它们也有一小段脚在原地蹭，速度不为零。
## 而 duty / fit 是**运动形态**的指纹：真正的走跑循环是"一只脚长时间匀速后撤"，
## 攻击是"脚蹭一下就抬起来"。这两项能分开它们，且与命名无关。
static func clip_motion(anim: Animation, sk: Skeleton3D) -> Dictionary:
	var empty := {
		"ok": false, "speed": 0.0, "forward": 0.0, "lateral": 0.0,
		"feet": 0, "duty": 0.0, "fit": 0.0,
	}
	var feet := foot_bones(sk)
	if feet.is_empty():
		return empty
	var ctx := prepare(anim, sk)
	var sum := Vector2.ZERO
	var counted := 0
	var duty_sum := 0.0
	var fit_sum := 0.0
	for bi in feet:
		var m := _foot_motion(ctx, bi)
		if not m["ok"]:
			continue
		sum += m["v"]
		duty_sum += float(m["duty"])
		fit_sum += float(m["fit"])
		counted += 1
	if counted == 0:
		return empty
	var v: Vector2 = sum / float(counted)
	# 角色本地 +Z 是前方，脚在支撑相里相对身体向后走（vz < 0），故取负。
	return {
		"ok": true,
		"speed": v.length(),
		"forward": -v.y,
		"lateral": absf(v.x),
		"feet": counted,
		"duty": duty_sum / float(counted),
		"fit": fit_sum / float(counted),
	}


## 只要速度大小；测不出来返回 -1.0（调用方必须能看见失败，不许当成 0）。
static func clip_speed(anim: Animation, sk: Skeleton3D) -> float:
	var m := clip_motion(anim, sk)
	if not m["ok"]:
		return -1.0
	return float(m["speed"])


## 所有"脚"的骨骼索引。按名字匹配；一根都没有就返回空，
## 由调用方决定退让（不猜、不硬凑）。
static func foot_bones(sk: Skeleton3D) -> Array[int]:
	var out: Array[int] = []
	for i in sk.get_bone_count():
		var low := sk.get_bone_name(i).to_lower()
		for hint in FOOT_HINTS:
			if low.contains(hint):
				out.append(i)
				break
	return out


## 预解析：轨道路径是 NodePath，每次采样都解一遍会白烧几十毫秒。
## 一条片段只解析一次，之后采样只查字典。
##
## 公开而非下划线开头：探针要拿它和播放器真实驱动**对拍** ——
## 测量逻辑如果不能被独立验证，它给出来的数就只是"看起来对"。
static func prepare(anim: Animation, sk: Skeleton3D) -> Dictionary:
	var pos: Dictionary = {}
	var rot: Dictionary = {}
	for ti in anim.get_track_count():
		var path := anim.track_get_path(ti)
		var bname := String(path.get_concatenated_subnames())
		if bname.is_empty():
			continue
		var bi := sk.find_bone(bname)
		if bi < 0:
			continue
		var ty := anim.track_get_type(ti)
		if ty == Animation.TYPE_POSITION_3D:
			pos[bi] = ti
		elif ty == Animation.TYPE_ROTATION_3D:
			rot[bi] = ti
	var rest: Array[Transform3D] = []
	var parent: Array[int] = []
	for i in sk.get_bone_count():
		rest.append(sk.get_bone_rest(i))
		parent.append(sk.get_bone_parent(i))
	return {
		"anim": anim, "count": sk.get_bone_count(),
		"pos": pos, "rot": rot, "rest": rest, "parent": parent,
	}


## 一只脚在支撑相里的运动：相对身体的速度 + 支撑占比 + 直线拟合残差。
## 失败返回 {ok:false}。
static func _foot_motion(ctx: Dictionary, bone: int) -> Dictionary:
	var anim: Animation = ctx["anim"]
	var length := anim.length
	if length <= 0.001:
		return {"ok": false}
	var step := length / float(SAMPLES)

	# 采一整个循环：y 判支撑，x/z 是水平位移。
	var ys: Array[float] = []
	var xs: Array[float] = []
	var zs: Array[float] = []
	for k in SAMPLES:
		var g := bone_at(ctx, bone, float(k) * step)
		ys.append(g.y)
		xs.append(g.x)
		zs.append(g.z)

	var ymin := ys[0]
	var ymax := ys[0]
	for y in ys:
		ymin = minf(ymin, y)
		ymax = maxf(ymax, y)
	var travel := ymax - ymin
	# 脚几乎不动（Idle 之类）：没有可测的位移，按 0 处理，不算失败。
	if travel < 0.001:
		return {"ok": true, "v": Vector2.ZERO, "duty": 1.0, "fit": 0.0}
	var thr := ymin + travel * SUPPORT_BAND

	# 找最长的连续支撑段。采样是环形的，所以允许它跨循环边界。
	var best_len := 0
	var best_start := 0
	for start in SAMPLES:
		if ys[start] > thr:
			continue
		var run := 0
		while run < SAMPLES and ys[(start + run) % SAMPLES] <= thr:
			run += 1
		if run > best_len:
			best_len = run
			best_start = start
	if best_len < MIN_SUPPORT:
		return {"ok": false}

	# 段内对 (采样序号, 坐标) 各做一次最小二乘。用斜率而不是首尾差：
	# 支撑相本来就有轻微抖动，首尾两点一有噪声就差很远。
	var n := float(best_len)
	var mx := (n - 1.0) * 0.5
	var mxsum := 0.0
	var mzsum := 0.0
	for k in best_len:
		var i := (best_start + k) % SAMPLES
		mxsum += xs[i]
		mzsum += zs[i]
	mxsum /= n
	mzsum /= n
	var num_x := 0.0
	var num_z := 0.0
	var den := 0.0
	for k in best_len:
		var i := (best_start + k) % SAMPLES
		var dx := float(k) - mx
		num_x += dx * (xs[i] - mxsum)
		num_z += dx * (zs[i] - mzsum)
		den += dx * dx
	if den <= 0.0:
		return {"ok": false}
	var sx := num_x / den
	var sz := num_z / den

	# 残差：偏离"匀速直线后撤"的程度。挥刀那类动作脚是"蹭一下又抬起来"，
	# 拟合出来斜率不为零、但残差和位移同量级 —— 这一项就是用来抓它的。
	var res := 0.0
	for k in best_len:
		var i := (best_start + k) % SAMPLES
		var dx := float(k) - mx
		var ex := xs[i] - (mxsum + sx * dx)
		var ez := zs[i] - (mzsum + sz * dx)
		res += ex * ex + ez * ez
	var rms := sqrt(res / n)
	var span := sqrt(sx * sx + sz * sz) * n
	var fit := 1.0 if span < 0.000001 else rms / span

	# 斜率单位是「原始单位 / 采样间隔」，除以间隔即「原始单位 / 秒」。
	return {
		"ok": true,
		"v": Vector2(sx, sz) / step,
		"duty": n / float(SAMPLES),
		"fit": fit,
	}


## t 时刻某根骨骼相对骨架根的位置。
##
## 这就是 Skeleton3D 自己会算的东西，只是不经过播放器：
## 每根骨骼的局部姿态 = 绑定姿势，再被位置 / 旋转轨道覆盖，然后沿父链累乘。
## 轨道里没有的骨骼保持绑定姿势 —— 这正是 Godot 的行为。
static func bone_at(ctx: Dictionary, bone: int, t: float) -> Vector3:
	var chain: Array[int] = []
	var cur := bone
	var parent: Array[int] = ctx["parent"]
	while cur >= 0:
		chain.push_front(cur)
		cur = parent[cur]
	var xf := Transform3D()
	for bi in chain:
		xf = xf * _local_pose(ctx, bi, t)
	return xf.origin


## 单根骨骼在 t 时刻的局部姿态：绑定姿势，再被位置 / 旋转轨道覆盖。
##
## 注意别用 `value_track_interpolate()` —— 那个只对**变体轨道**（TYPE_VALUE）有效，
## 喂给它一条位置 / 旋转轨道会安静地返回 null，既不报错也不生效，
## 症状是"测出来的速度永远是 0"。3D 变换轨道要用 position/rotation 专用方法。
static func _local_pose(ctx: Dictionary, bone: int, t: float) -> Transform3D:
	var anim: Animation = ctx["anim"]
	var local: Transform3D = ctx["rest"][bone]
	var pos: Dictionary = ctx["pos"]
	var rot: Dictionary = ctx["rot"]
	if pos.has(bone):
		local.origin = anim.position_track_interpolate(pos[bone], t)
	if rot.has(bone):
		local.basis = Basis(anim.rotation_track_interpolate(rot[bone], t))
	return local
