# Tessera

[![check](https://github.com/ThripleQ/tessera/actions/workflows/ci.yml/badge.svg)](https://github.com/ThripleQ/tessera/actions/workflows/ci.yml)

**一个可以被第三方扩展的 3D 沙盒** —— 形态接近 GMod，而不是某个题材的游戏。

三件事构成产品本身：

1. **抓、放、堆、扔的物理手感**
2. **一切来自数据的生成菜单**
3. **放一个文件夹进去就能加载 mod**（内容 + 脚本 + 资源覆盖）

题材故意不定。框架先成立，内容后边长。

> 状态：P1（手感）基本完成。有可操控角色、重力、碰撞、抓取与投掷，卡通渲染已接上，
> 行为 mod（事件钩子）已跑通。详细进度见 [`docs/status.md`](docs/status.md)。

**这个仓库的纪律是可执行的**：`./check.sh` 会检查目录命名、文件长度、域大小，
以及最重要的一条——引擎层有没有硬编码具体内容的 id。写在文档里的架构，agent 会忘；
写在 CI 里的架构，agent 绕不过。

---

## 为什么是这样

一句话：**内容描述"世界有什么"，代码永远不该知道"有什么"。**

所以内容全部是 TOML，编译器在构建时把它们合成一个数据包，引擎启动时读这个包。
新增一件东西不需要动一行引擎代码，也不需要重新编译。

这套东西的直接后果是：**mod 不是外挂的功能，而是这套机制的常态。** 玩家能加的内容，
和"官方内容"走的是同一条路径。这是 GMod 和 Minecraft 真正共同的地方——它们开放的是
*作者身份*，不是 API 列表。

## 现在有什么

| 目录 | 内容 | 状态 |
|---|---|---|
| `content/` `mods/` | TOML 内容：原型、道具、房间、覆写层、行为 mod | 可用 |
| `contract/` | 扩展点契约：组件、字段、枚举、事件钩子 | 可用 |
| `tools/` | 内容编译器、热重载、架构纪律检查 | 可用 |
| `game/` | Godot 4.6 工程 | 能玩：角色 + 物理 + 抓取 + 卡通渲染 |
| `legacy/` | 早期的自研 C++ 渲染器与 Python 参考实现 | 归档，不参与构建 |

`legacy/cpp-renderer` 是一个真实跑通过的 OpenGL 渲染器（3 万条内容 / 3 次 draw call /
llvmpipe 上出图）。它被归档的原因是需求变了：**沙盒的瓶颈是物理和网络，不是 draw call。**
保留它是因为它产出的那组数字，仍然可以当作性能基线。

## 准备引擎

需要 Python 3.11+ 和 Godot 4.6（单文件，约 65MB，不需要安装）：

```bash
mkdir -p tools-bin && cd tools-bin
curl -LO https://github.com/godotengine/godot/releases/download/4.6-stable/Godot_v4.6-stable_linux.x86_64.zip
unzip -o Godot_v4.6-stable_linux.x86_64.zip
cd ..
```

不想放在 `tools-bin/` 也行：`GODOT=/path/to/godot ./check.sh`。

## 跑起来看看

```bash
./run.sh
```

| 操作 | 键 |
|---|---|
| 转视角 | 鼠标（左键捕获） |
| 走 | `WASD` |
| 跳 | `空格` |
| 冲刺 | `Shift` |
| **抓起 / 扔出** | **左键按住 / 松开** |
| **轻轻放下** | **`R`** |
| 释放鼠标 | `Esc` |

你会站在一个堆着木箱的院子里：14 个箱子是**真的刚体**，会掉、会滚、能被推、能被抓起来扔。
旁边还有两个房间——墓厅里有 6 个骨行者，葬园里有 3 个墓影。

抓取用的是力，不是把物体挂到手上：手上的东西仍然参与碰撞、仍然会撞翻别的东西。
重的东西提起来更慢、扔出去更近——这个差别不是脚本写的，是质量与加速度上限算出来的。

画面是卡通渲染：两级色阶 + 边缘光 + 反向外扩描边。原神那种脸做不到——
那需要贴图与 blend shape，属于资产管线。现在能做到的是"色块卡通风"。

## 验收

```bash
./check.sh
```

四步：编译内容 → 架构纪律检查 → 同步到 Godot → 无头自检。失败返回非零。CI 跑的是同一个脚本。

## 加一件东西

新建 `content/enemy/frost_wight.toml`：

```toml
api_version = 1
kind = "archetype"
extends = "enemy/base_undead"
name = "霜尸"
tags = ["frost"]

[components.health]
max = 60

[components.ai]
brain = "ambusher"
```

然后 `./check.sh`。**不用改任何代码，不用重新编译引擎。**

## 写一个行为 mod

两步。先声明它要挂哪些事件（这一步同时是**权限清单**）：

```toml
# mods/my_glove.toml
api_version = 1
kind = "script"
name = "磁力手套"
source = "mods/scripts/my_glove.gd"
events = ["grab.request", "grab.release"]
```

再写脚本，只有一个入口：

```gdscript
extends RefCounted

func handle(event: String, ctx: Dictionary, api) -> Dictionary:
	if event == "grab.request":
		return {"hold": 1.2}                      # 抓得更近
	if event == "grab.release":
		api.impulse(int(ctx["handle"]), Vector3.UP * 40.0)
	return {}
```

`./check.sh` 会编译它、校验 `events` 里的钩子都在契约里注册过，
并在无头自检里真的加载一次。**写错了不会等到玩游戏才发现。**

`api` 只提供动词：`spawn` / `impulse` / `tint` / `reset_tint` / `pos` / `speed` / `nearest`。
拿不到节点、拿不到 `Transform3D`——这是故意的，理由见
[ADR 0007](docs/decisions/0007-hooks.md)：暴露意图，不暴露结构。

钩子清单在 `contract/registry.py`，当前 6 个：`world.ready`、`entity.spawn`、
`grab.request`（可否决）、`grab.release`、`impact`、`tick`。
契约声明与引擎实际发出的事件必须完全相等，不符合 `check.sh` 就红。

## 给 agent 的话

开工前读 [`AGENTS.md`](AGENTS.md)。那不是给人看的介绍，是合同。
目录纪律在 [`docs/structure.md`](docs/structure.md)，阶段划分在 [`docs/roadmap.md`](docs/roadmap.md)，
每个不可逆决定的理由在 [`docs/decisions/`](docs/decisions/)。

## 许可

MIT。见 [`LICENSE`](LICENSE)。
