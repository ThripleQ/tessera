extends RefCounted

## L4 系统示例：一条 mod 自带的规则，引擎里没有一行认识它。
##
## 契约只有一条：func step(ctx, api) -> void。
## ctx 只给不透明 handle 和声明过的组件字段；想要改变世界，
## 走的还是 L3 那个 api（这里用 tint）。没有节点、没有路径、没有组件对象。
##
## 这个 mod 故意不 preload 任何引擎脚本：一旦开始 preload("res://scripts/...")，
## 它就绑死在引擎内部结构上，下一次重构会把它一起带走。

func step(ctx, api) -> void:
	for h in ctx.entities():
		var rate := float(ctx.read(h, "pulse", "rate"))
		var charge := float(ctx.read(h, "pulse", "charge"))
		charge = fmod(charge + rate * float(ctx.dt), 1.0)
		ctx.write(h, "pulse", "charge", charge)
		if api.exists(h):
			api.tint(h, Color(charge, 0.40, 1.0 - charge))
