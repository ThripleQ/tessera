extends RefCounted

## 天光：环境 + 主光。世界里"光从哪来"只有这一处。
##
## 从 main.gd 搬出来，理由不是"main 太长"，而是这四十行是**画面参数**：
## 每次调卡通色调、雾、阴影硬度，打开的就是这里，而不是入口文件。
## 入口文件应该只有一句"先装天光、再装世界"。


## 卡通渲染要的是"天光充足、阴影明确"，不是写实的那种暗调氛围。
## 背景用天空蓝而不是黑，是因为大片暗背景会把角色的暗部染色吃掉，
## 人物的剪影就糊在背景里了。
static func environment() -> WorldEnvironment:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.52, 0.72, 0.92)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.66, 0.78, 0.98)
	# 环境光必须压低：卡通渲染的暗部是由色阶的 shade_tint 决定的，
	# 环境光一大就把暗部冲淡，色阶就没了，画面回到"平淡的写实"。
	env.ambient_light_energy = 0.26
	env.fog_enabled = true
	env.fog_light_color = Color(0.60, 0.74, 0.90)
	env.fog_density = 0.0022

	var node := WorldEnvironment.new()
	node.name = "environment"
	node.environment = env
	return node


## 主光开阴影：卡通渲染里阴影是"硬边"的另一半，没有它，所有东西都像贴纸。
## Compatibility 下阴影只有一张深度图，比 Forward+ 便宜得多，这是选它的理由之一。
static func sun() -> DirectionalLight3D:
	var node := DirectionalLight3D.new()
	node.name = "sun"
	node.rotation_degrees = Vector3(-48.0, -36.0, 0.0)
	# 3.0 看起来很高，但 light() 里除以了 PI，净系数约 0.95 ——
	# 卡通渲染要让亮面直接显示 albedo 原色，所以这个值不是"过亮"。
	node.light_energy = 3.0
	node.light_color = Color(1.0, 0.97, 0.90)
	node.shadow_enabled = true
	node.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
	node.directional_shadow_max_distance = 60.0
	return node
