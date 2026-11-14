extends RefCounted

## 一个真实的 L4 物理规则：不识别内容 id，只识别「有没有 repulsor 组件」。
## 因此箱子、敌人、以及以后 agent 加的任何刚体都会自动成为作用目标。
## mod 只拿到 handle、组件字段和公开动词；引擎里没有这个玩法的特判。

func step(ctx, api) -> void:
	for h in ctx.entities():
		var remaining := maxf(0.0, float(ctx.read(h, "repulsor", "remaining")) - float(ctx.dt))
		if remaining > 0.0:
			ctx.write(h, "repulsor", "remaining", remaining)
			continue

		var origin: Vector3 = api.pos(h)
		var radius := float(ctx.read(h, "repulsor", "radius"))
		var strength := float(ctx.read(h, "repulsor", "strength"))
		for raw_other in api.handles():
			var other := int(raw_other)
			if other == int(h) or not api.exists(other):
				continue
			var offset: Vector3 = api.pos(other) - origin
			var distance := offset.length()
			if distance < 0.05 or distance > radius:
				continue
			# 水平远离 + 一点向上冲量，让目标先脱离地面接触。
			# 这是通用物理动词，不是把目标节点挪到一个新位置。
			var direction := offset / distance
			var impulse := direction * strength + Vector3.UP * strength * 0.25
			api.impulse(other, impulse)
		ctx.write(h, "repulsor", "remaining", float(ctx.read(h, "repulsor", "cooldown")))
