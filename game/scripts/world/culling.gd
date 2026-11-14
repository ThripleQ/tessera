extends RefCounted

## 剔除：决定"这一帧谁要画"。
##
## **只管画，不动物理。** 隐藏起来的箱子照样挡路、照样能被抓、照样进存档 ——
## 把"看不见"和"不存在"混在一起的实现，最后都会变成"看不见但撞得到"的幽灵，
## 而那是玩家最没法治的一类 bug。
##
## 为什么判定要单独一个文件：它是最容易被改坏的一类代码。剔除的错法只有两种 ——
## 把看得见的剔掉了（玩家看到世界在闪），或者该剔的没剔（帧率慢慢掉）。
## 两种都不会报错。所以判定必须只有一处，而且要能被单独验。
##
## 判定用**包围盒对视锥平面**的精确测试，不是"中心点在不在视锥里"。
## 点测试在小东西上碰巧对，在大东西上必错：一个房间的中心在屏幕外，
## 而它有半个身子在屏幕里。宁可多画，不可少画。

## 超过这个距离一律不画。只看水平距离，不看高度差 ——
## 楼下/坑里的东西本来就该不画，而高度差会让距离虚高。
const VISIBLE_RANGE := 120.0

## 这个距离内的东西不剔。相机就在玩家脑后，视野边缘的东西有一半会被裁到，
## 而"刚好在视野边上的箱子一闪一闪"是玩家立刻会注意到的错。
const NEAR_GUARD := 6.0


## 一件东西这一帧要不要画。box 是**世界坐标**的包围盒。
static func should_draw(cam: Camera3D, box: AABB) -> bool:
	if cam == null:
		return true
	var c := box.get_center()
	var cam_pos: Vector3 = cam.global_position
	var d := Vector2(c.x - cam_pos.x, c.z - cam_pos.z).length()
	if d > VISIBLE_RANGE:
		return false
	if d <= NEAR_GUARD:
		return true
	return _in_frustum(cam.get_frustum(), box)


## 包围盒是否在视锥内。
##
## **这里踩过两次坑，两次都不报错**，所以约定必须写下来：
## Godot 的 `Camera3D.get_frustum()` 返回的平面，法线朝**外** ——
## 一个视野正中的点，到六个平面的有符号距离**全是负数**（实测，不是推断）。
## 所以"在内"= 距离 < 0，"整个盒子在外" = 某个平面的**最近顶点**都在外侧。
##
## 两次写错分别是：
##   顶点取对了、比较号写反（`< 0` 当出局）→ 世界被剔得只剩免剔区里的两件
##   改成"最可能在内"的顶点 → 仍然错，因为那个顶点在外不代表整盒在外
## 两种的共同症状是"站在房间里看着空荡荡的世界"，而验收全绿 ——
## 所以探针里有一条**和 Godot 自己的 `is_position_in_frustum` 对拍**的断言。
static func _in_frustum(planes: Array, box: AABB) -> bool:
	for p in planes:
		var n: Vector3 = p.normal
		var near := Vector3(
			box.position.x + (box.size.x if n.x < 0.0 else 0.0),
			box.position.y + (box.size.y if n.y < 0.0 else 0.0),
			box.position.z + (box.size.z if n.z < 0.0 else 0.0))
		if p.distance_to(near) > 0.0:
			return false
	return true


## 零散单件的包围盒：一个中心点 + 半径。
## 刚体和玩家摆的静态物都用这个 —— 它们没有现成的 AABB 可取，
## 而去遍历子网格算精确包围盒，比多画几个还贵。
static func ball(center: Vector3, radius: float) -> AABB:
	var r := maxf(radius, 0.5)
	return AABB(center - Vector3.ONE * r, Vector3.ONE * r * 2.0)
