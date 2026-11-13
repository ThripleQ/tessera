# 0007 事件钩子：mod 怎么介入世界

> 状态：已实现（L3）。日期：2026-11-14。
> 前置：[ADR 0003 开放通道实测](0003-open-channels.md)、[ADR 0005 开放度边界](0005-openness-boundary.md)。

## 问题

ADR 0005 记下了当时的缺口：**"通道验证过"不等于"能力有了"**。
L3 的定义是"能执行 mod 代码"，但 `SYSTEMS` 是空列表，一个 mod 脚本写出来能调用的钩子是零个。

而抓取、投掷这类玩法马上要动手。如果先写抓取、事后再补钩子，抓取就会长成引擎硬编码，
mod 只能看不能改——那时候要补钩子，等于把已经跑通的逻辑全部返工。
**这是整个项目里唯一一个"顺序错了就必须重做"的地方**，所以钩子先于玩法。

## 决定

### 一、钩子是契约里的数据，不是代码里的字符串

`contract/registry.py` 里用 `hook(...)` 声明，编译期导出成 `pack.schema.hooks`：

```python
hook("grab.request", "玩家试图抓起某个物体。可以否决，也可以改变持握距离。",
     params=("id", "handle", "mass", "pos"),
     returns=("allow", "hold"),
     blocking=True)
```

三条信息一起声明：**承诺给 mod 的上下文字段**（params）、**引擎会读的返回值**（returns）、
**能不能否决**（blocking）。

自检要求 `契约声明 == 引擎的 EMITTED 列表`，**完全相等**。
只声明不发是撒谎（mod 挂了钩子永远等不到），只发不声明是绕过契约。
这条检查已经实测会拦人：把 `"tick"` 从 `EMITTED` 里删掉，验收立刻红，并打印两份清单的差异。

### 二、mod 只有一个入口，`events` 是权限清单

```gdscript
extends RefCounted

func handle(event: String, ctx: Dictionary, api) -> Dictionary:
	match event:
		"grab.request": return {"hold": 1.9}   # 改引擎行为
		"grab.release": ...
	return {}
```

没有 `on_grab_request`/`on_impact` 之类的方法名约定。理由不是省事：

- **方法名约定会让"未授权"变成不可能**。引擎要调 `on_x` 得先知道它存在，而 `has_method`
  一查就能调——权限清单就成了装饰。
- 单入口 + `events` 列表，让 **`bus.bind()` 成为唯一闸门**：没写进 `events` 的事件，
  引擎不会转给它，`bind()` 直接返回 false。

`events` 里的拼写错误在编译期就被抓（`check_scripts` 对着 `HOOKS` 校验），
而不是"这个 mod 装了但从来不触发"，那种问题没人查得出来。

### 三、mod 拿到的是动词，不是节点

`api.gd` 提供的方法全部是动作：

```
spawn(id, pos) / impulse(handle, v) / tint(handle, color) / reset_tint(handle)
pos(handle) / speed(handle) / mass(handle) / content_id(handle) / nearest(pos, r) / exists(handle)
```

**没有 `get_node`，没有 `Transform3D`，没有组件对象。** mod 手里只有整数 handle。

这条比"扩展点够不够多"重要得多。一旦 mod 能拿到节点树，第一天就会有人写
`get_node("../../chunk_0/MultiMesh")`，引擎内部结构当天被生态钉死，
之后任何重构都会破坏所有 mod——于是你再也不敢改引擎。GMod 能给 `hook.Add`、
却从不交出 Source 的内部对象，就是这个道理。

顺带一条分界，很容易搞反：**引擎必须对内容无知，mod 不必**。
引擎只知道"有个刚体的 handle 是 7"，mod 知道"7 号是 `prop/crate`"——后者是正当的，
因为 mod 本来就是内容的一部分。

### 四、预算由系统强制

- `MAX_EVENTS_PER_FRAME = 256`：超了直接丢弃并计数。**悄悄降级比崩溃更难查**，
  所以 `dropped` 必须能被打印。
- `tick` 是固定 0.25 秒一拍，不是每帧。绝大多数 mod 想做的事（计时、巡视、状态更新）
  这个节拍完全够，而每帧钩子是帧率的敌人。
- `api.MAX_SPAWNED = 96`：mod 造物有硬上限。开放不等于无限——一个没人拦的 spawn 循环
  能瞬间把帧率打到零。

## 代价与未做的事

- **没有沙箱**，而且做不出来（ADR 0003 实测 `OS.execute` 返回 0）。
  钩子约束的是"能不能被调用"，不是"调用了能干什么"。这条边界必须对玩家可见。
- **没有系统容器**：mod 不能注册自己的组件与系统。L3 → L4 的分水岭在这里，
  它需要"运行时新增组件类型"，比钩子难一个量级，属于 P5。
- **只有刚体有 handle**。合批的静态实例没有独立身份（它们连节点都没有），
  mod 看不见也改不了。这是合批的固有代价，不是疏漏。
- **导出包仍未验证**：运行时编译只在编辑器二进制上跑过，P6 前必须重测。

## 什么情况下应该推翻

1. **mod 生态开始互相破坏**（A 的 spawn 循环把 B 的钩子饿死）→ 需要按 mod 配额，
   而不是全局配额。
2. **需要真正的第三方沙箱**（商店、陌生人下 mod）→ 必须换进程隔离或 WASM，
   钩子表的形状会跟着变。
3. **mod 需要每帧介入**（自己写角色的移动积分）→ `tick` 的 0.25 秒不够，
   得引入"系统"级扩展点（L4），而不是把 tick 频率调高。
4. **钩子数量涨到 20 个以上** → 说明缺的是"组件的写入权"（系统），不是更多事件点。
