# Tessera

[![check](https://github.com/ThripleQ/tessera/actions/workflows/ci.yml/badge.svg)](https://github.com/ThripleQ/tessera/actions/workflows/ci.yml)

**一个可以被第三方扩展的 3D 沙盒** —— 形态接近 GMod，而不是某个题材的游戏。

三件事构成产品本身：

1. **抓、放、堆、扔的物理手感**
2. **一切来自数据的生成菜单**
3. **放一个文件夹进去就能加载 mod**（内容 + 脚本 + 资源覆盖）

题材故意不定。框架先成立，内容后边长。

> 状态：极早期。阶段 P0（底座）基本完成，还没有可玩的画面。
> 详细进度见 [`docs/status.md`](docs/status.md)。

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
| `content/` `mods/` | TOML 内容：原型、道具、房间、覆写层 | 可用 |
| `contract/` | 扩展点契约：合法的组件、字段、枚举 | 可用 |
| `tools/` | 内容编译器、热重载、架构纪律检查 | 可用 |
| `game/` | Godot 4.6 工程 | 能出画面：分块 + 合批 + 自由相机 |
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

左键捕获鼠标转视角，`WASD` 平移，`空格/Ctrl` 升降，`Shift` 加速，`Esc` 释放鼠标。

现在能看到的东西：两个房间的地面、6 个骨行者、3 个墓影，全部由 TOML 驱动。
**还不能玩** —— 没有角色、没有碰撞、没有物理。相机是观察工具，会穿墙。

## 验收

```bash
./check.sh
```

四步：编译内容 → 架构纪律检查 → 同步到 Godot → 无头自检。失败返回非零。CI 跑的是同一个脚本。

## 加一件东西

新建 `content/archetype/frost_wight.toml`：

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

## 给 agent 的话

开工前读 [`AGENTS.md`](AGENTS.md)。那不是给人看的介绍，是合同。
目录纪律在 [`docs/structure.md`](docs/structure.md)，阶段划分在 [`docs/roadmap.md`](docs/roadmap.md)，
每个不可逆决定的理由在 [`docs/decisions/`](docs/decisions/)。

## 许可

MIT。见 [`LICENSE`](LICENSE)。
