extends RefCounted

## 移动里两块不认识"玩家"的活儿：求"想往哪走"、把挡路的箱子推开。
##
## 它们只吃身体状态（方向基、速度、碰撞结果），吐一个方向或一串冲量，
## 完全不碰视角、枪、背包、骨架。放在这里是让 player.gd 只留装配：
## 每帧该叫谁、按什么顺序，而不是又解一次几何。

## 推刚体的力度。CharacterBody3D 默认只是被挡住，不会推动 RigidBody——
## 不给冲量的话，"物理世界"会变成"一堵会掉的墙"。
const PUSH_STRENGTH := 2.2


## 相机朝向决定"前"在哪。所以输入不是世界方向，要过一遍身体的 basis。
static func wish_direction(basis: Basis) -> Vector3:
	var ix := 0.0
	var iz := 0.0
	if Input.is_physical_key_pressed(KEY_W):
		iz -= 1.0
	if Input.is_physical_key_pressed(KEY_S):
		iz += 1.0
	if Input.is_physical_key_pressed(KEY_D):
		ix += 1.0
	if Input.is_physical_key_pressed(KEY_A):
		ix -= 1.0
	if ix == 0.0 and iz == 0.0:
		return Vector3.ZERO
	var dir := basis * Vector3(ix, 0.0, iz)
	dir.y = 0.0
	return dir.normalized()


## 推开挡路的刚体。撞上 RigidBody3D 时默认只会被挡住 —— 箱子一动不动，
## 玩家会以为"这游戏没有物理"。所以要主动给冲量，并且按玩家当时的速度给，
## 慢走轻推、冲刺撞飞。
static func push_bodies(body: CharacterBody3D, delta: float) -> void:
	var speed := Vector2(body.velocity.x, body.velocity.z).length()
	if speed < 0.4:
		return
	for i in body.get_slide_collision_count():
		var hit := body.get_slide_collision(i)
		var other = hit.get_collider()
		if other is RigidBody3D:
			var push := -hit.get_normal() * speed * PUSH_STRENGTH * delta * 60.0
			# 作用在接触点上，箱子才会转，而不是整体平移。
			other.apply_impulse(push, hit.get_position() - other.global_position)
