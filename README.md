# Tessera

[![check](https://github.com/ThripleQ/tessera/actions/workflows/ci.yml/badge.svg)](https://github.com/ThripleQ/tessera/actions/workflows/ci.yml)

**一个可以被第三方扩展的 3D 沙盒** —— 形态接近 GMod，而不是某个题材的游戏。

三件事构成产品本身：

1. **抓、放、堆、扔的物理手感**
2. **一切来自数据的生成菜单**
3. **放一个文件夹进去就能加载 mod**（内容 + 脚本 + 资源覆盖）

题材故意不定。框架先成立，内容后边长。

> 状态：能玩、能装 mod、能从菜单放东西、能收进背包、关掉再开东西还在。
> 有可操控角色、重力、碰撞、抓 / 扔 / 收（背包）、准星、卡通渲染、事件钩子、
> 会走会死会掉的系统层、逐实例剔除、存档；**mod 还能自带新组件与新规则**（L4），
> **放一个文件夹里的模型就能换掉画面**（外观开放），
> **agent 只走公开扩展通道就能加上真实物理玩法**。
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
| `content/` | 官方 TOML 内容：原型、道具、房间 | 可用 |
| `mods/` | 可独立投放的 mod，一个目录一个（内容 / 脚本 / 规则 / 资源覆盖） | 可用 |
| `assets/characters/` | 带动画的角色资产（`.glb`，文件名即 id），加角色 = 丢一个文件进去，游戏里按 `F8` 换 | 可用 |
| `contract/` | 扩展点契约：组件、字段、枚举、事件钩子、组件规格 / 系统读写集 | 可用 |
| `tools/` | 内容编译器、架构纪律检查 | 可用 |
| `game/` | Godot 4.6 工程 | 能玩：带骨骼动画的角色 + 物理 + 抓取 + 生成菜单 + 系统层 + mod 自定义系统 + 存档 |
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

开局默认**第一人称**（手里有枪），按 `V` 切到第三人称才是沙盒那套抓放玩法。

| 操作 | 键 |
|---|---|
| 转视角 | 鼠标（左键捕获） |
| 走 / 跳 / 冲刺 | `WASD` / `空格` / `Shift` |
| **开火 / 换弹** | **左键 / `R`**（第一人称） |
| **切第一 / 第三人称** | **`V`** |
| **生成菜单** | **`Tab`**（双击或回车放下选中项，第三人称） |
| **抓起 / 扔出** | **左键按住 / 松开**（第三人称） |
| **轻轻放下** | **`R`**（第三人称） |
| **收进背包** | **右键**（拿走瞄着的东西，不销毁） |
| **换角色** | **`F8`**（骑士 / 法师 / 骷髅，`assets/characters/` 里有几个就轮换几个） |
| **存档 / 读档** | **`F5` / `F9`** |
| 释放鼠标 | `Esc` |

你会站在**训练场**：一块 30×30 的空地，四只骷髅从对面走过来，
手里有一把 AKM（带绑骨手臂和三段动画，来自 J-Toastie，CC-BY 3.0），
屏幕中心有准心，左上角是命中 / 击杀 / 命中率 / 用时。
默认**第一人称**：左键开火、`R` 换弹、`V` 切第三人称看自己。
枪有呼吸、走路晃动、鼠标甩枪的惯性；开火会喷火、换弹会演完那只手。
**子弹真的从枪口出来**：曳光从枪管末端飞向准心落点，枪管也跟着抬过去；
切到第三人称也是同一把 AKM —— 握在法师的右手骨上，走路时跟着手摆
（第一人称看的是相机上的模型，第三人称看的是世界里的模型，两边各有一把，ADR 0019）。
**每次打开都是干净一局**（不读存档），想接着上次摆的东西玩用 `./run.sh --resume`。
打中骷髅会扣血、死了会计数、尸身离场；武器数值全在 `content/weapon/rifle.toml`，
改完重开就能感觉到（ADR 0016）。旁边仍留着旧房间，走过去就是原来的沙盒。

打中还有**看得见摸得着的反馈**：准心会闪一个 X，骷髅会**被推着退**一下、
并愣住半秒（不退不愣的话你会以为打偏了，第二枪就更用力）。
退多少、愣多久写在内容里（`content/enemy/base_undead.toml` 的 `hit_react`），
改数值不用改代码（ADR 0018）。

主角是**法师**（按 `F8` 换骑士 / 骷髅）。走路和跑步之间那一下是**对齐过的**：
切片段前记下步态相位，切完 seek 回同一个相位，脚不会在那一帧跳一下
（关掉对齐会从 5 厘米变成 74 厘米，见 ADR 0017）。

下面这些是**第三人称**（按 `V`）的沙盒玩法：手那条射线打到哪儿，地上就有个**准星环**
（亮青 = 这件东西能收，灰白 = 那是墙或地板）。
它画在射线的落点上而不是屏幕中心 —— 第三人称有视差，屏幕准星会骗人。

按 `Tab` 打开生成菜单：清单是从内容里读出来的，**这里没有一行硬编码**。
会动的东西排在前面，钉住不动的标着 `·固定`，背包里有的标着 `×n/上限`。
木箱、骨符、锈刃都能放 —— 往世界里加一条 TOML，菜单里就多一项。

右键把瞄着的东西**收进背包**，**生成额度会还回来**——能放不能收就不叫沙盒。
收起来的东西没消失，菜单里带着 `×n` 等你放回原处；关窗口也还在。
能叠几个由内容说了算（骨符 20 个一叠，锈刃不叠），满了右键会拒绝——
东西留在原地，不会凭空消失。房间自带的障碍收不走：它们是内容的形状，不是你的作品。

抓取用的是力，不是把物体挂到手上：手上的东西仍然参与碰撞、仍然会撞翻别的东西。
重的东西提起来更慢、扔出去更近——这个差别不是脚本写的，是质量与加速度上限算出来的。

画面是卡通渲染：两级色阶 + 边缘光 + 反向外扩描边。内置几何是程序化低模，
但**形状不再由引擎钉死**：往 mod 的 `assets/meshes/` 里放一份 glTF，
游戏里那个网格就换成文件里的模型（见下方「外观开放」）。
优先用现成 CC0 / 可商用资源，来源与许可记在 [`mods/asset_demo/ASSETS.md`](mods/asset_demo/ASSETS.md)。
贴图覆盖、骨骼动画还没做，见 [`docs/status.md`](docs/status.md) 下一步。

**训练场每次打开都是干净的一局**：默认不读存档，计数、弹药、靶子全部重置。
存档仍然在写（关窗口或 `F5`），想接着上次摆的东西玩用 `./run.sh --resume`；
`F9` 随时手动读档。`--fresh` 保留兼容，等价于默认行为。

## 验收

```bash
./check.sh
```

十九步：编译器自测 + 编译官方内容 → 逐个编译 mod → 架构纪律（含检查器自测）→
同步到 Godot → 无头自检 → 系统层（怪会动会死会掉）→ 存档往返（含背包）→
生成菜单与准星 → 剔除与性能成本 → L4 扩展（mod 自带组件 / 系统 / 权限边界）→
外观开放（文件夹里的模型盖掉内置几何）→ 真实玩法扩展（agent 新增 mod 能改变物理世界）→
性能结构（材质共用、染色隔离、视锥每帧一次、剔除对拍、无孤儿节点）→
角色资产（带动画的人、脚贴地、卡通材质、能回退、**骨骼真的在动**、**目录里每个角色都验**）→
步态匹配（档位由资产声明、速度带无缝、**支撑脚不打滑**）→
世界里的人（丢一个 glb 就多一个人、同一份资产能要两次、**别人真的在走**）→
手里的枪（数值来自内容、打中会疼、打死会记、会打空并自己装填、后坐会回、
**子弹从枪口出发且枪管对着落点**、视图模型与三段动画、**两个视角各有一把枪**）→
步态连续性（起步有初速、起步与停车不滑、**换档那一帧脚不跳**、关掉对齐必须跳得更远）→
受击反馈（**打中准心闪 X**、挨打会退、挨打会愣、把击退调 0 必须就退不动了）。
失败返回非零。CI 跑的是同一个脚本。

还有一条贯穿第 5–19 步的守卫：**引擎自己的报错一律算失败**。
功能对、但引擎在骂人的实现不属于「可以留着」的范畴（见 `docs/status.md` 坑列表）。

第 1 步和第 3 步各带一步"检查器自测"：故意造一批违规，确认检查真的会失败。
**一个从来没拒绝过东西的校验器，和不存在没有区别，而且更危险，因为它看起来是绿的。**

第 7 步真的会推一个箱子、放下一个柱子、存、再推走、读档，然后要求箱子回到存档位置
（误差 < 0.15 米）、柱子也回来。这类代码的错法是"看起来存了，读回来差一点"——
只有对比数字能发现。第 8 步真的会开菜单、放一件刚体和一件固定物。
菜单坏起来很安静："能打开但点了没反应"、"关掉之后操作还卡着"，两种都不报错。

第 10 步真的会跑一个 mod 声明的系统：自带一个新组件、一段固定节拍规则。
探针要求组件进 schema、脚本被编译进调度器、规则真的写了运行时状态，
并且**没声明的读写和错类型的值会被挡住**。开放不等于把引擎内部对象交出去。

第 11 步真的会加载一份外部 glTF：要求覆盖被扫到、三角形数与内置不同、
世界里刚体的视觉网格**就是**资源层给出的那个对象（漏改一个调用点就会红），
并且拼错文件名被记、后加载的 mod 优先、未覆盖网格照旧回退，都有断言。

第 12 步真的会跑一份 agent 新增的物理玩法：`mods/kinetics/` 不改引擎，
只用自定义组件、固定节拍规则和公开的 `impulse` 动词，把附近的任意刚体推开。
探针不认识内容 id，只按组件语义找机关与普通目标，并验证冲量、方向、冷却写回
和冷却中不连发。

## 性能

这台开发机没有 GPU，无头主循环自己就有 ~6.8 ms 的地板（空场景同样 6.90 ms），
**所以这里不拿毫秒当结论**，只守三种和机器无关的东西：

- **共享**：材质按配色共用，一个配色一份，不是一件物体一份。
  23 件东西 32 次引用只用 10 份材质 —— 真机上这就是提交次数。
- **每帧次数**：视锥一帧建一次（以前每件物品建一次）、射线查询对象复用
  （以前每帧新建两份）、剔除原地改记账而不是每帧造新字典。
- **同机对拍**：新旧写法各跑 120×5 遍取最小值。剔除 26 件 0.248 → 0.132 ms；
  预算上限（119 个刚体）时 1.45 → 0.83 ms。

想自己看这些数字：

```bash
./check.sh                                   # 第 9 步打印常态负载的成本
tools-bin/Godot_* --headless --path game --script res://probes/perf.gd -- --fresh --trust=all
tools-bin/Godot_* --headless --path game --script res://probes/perf.gd -- --fresh --trust=all --stress
```

`--stress` 会把世界填到预算上限（96 件）再测，所以"最坏情况"是能直接量出来的。
**帧率的真实数字只能在有 GPU 的机器或导出包上拿**，不要在无头日志里读它。

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

想做"只给子类继承、自己不出现在世界里"的模板，就在那份内容里写
`abstract = true`。它会自动从生成菜单里消失，也不能被房间的 `spawner` 指向，
而它的子类照旧是具体内容（`abstract` 不继承）。

## 写一个 mod

一个 mod 就是一个目录。`mods/hello_glove/`：

```
mod.toml                 元数据
content/*.toml           内容 / 组件规格 / 系统声明（可省略，纯脚本 mod 也行）
scripts/*.gd             脚本（可选）：事件脚本 handle() 与系统脚本 step()
```

`mod.toml`：

```toml
[mod]
id = "hello_glove"
name = "磁力手套"
version = "1.0.0"
api_version = 1
level = "script"          # data = 只有内容，script = 带代码
```

`content/behavior.toml` —— 声明它要挂哪些事件（这一步同时是**权限清单**）：

```toml
api_version = 1
kind = "script"
source = "scripts/hello_glove.gd"     # 相对本 mod 目录
events = ["grab.request", "grab.release"]
```

`scripts/hello_glove.gd` —— 只有一个入口：

```gdscript
extends RefCounted

func handle(event: String, ctx: Dictionary, api) -> Dictionary:
	if event == "grab.request":
		return {"hold": 1.2}                      # 抓得更近
	if event == "grab.release":
		api.impulse(int(ctx["handle"]), Vector3.UP * 40.0)
	return {}
```

编译并启动：

```bash
python3 tools/contentc.py --mod mods/hello_glove --base content
./run.sh --trust=hello_glove
```

`--trust` 只需给一次，之后记录在 `user://mods.json`。

### 为什么需要 `--trust`

**Godot 没有 GDScript 沙箱**：mod 脚本里 `OS.execute` 是可执行的（实测）。所以
mod 只有两级——`data`（只有内容，默认放行）和 `script`（带代码，**默认拒绝**）。
级别由"有没有可执行代码"判定，不由 `mod.toml` 里写的那一栏判定：
把带脚本的 mod 标成 `data` 会被按 `script` 处理并挡下来。

理由和边界见 [ADR 0003](docs/decisions/0003-open-channels.md) 与
[ADR 0008](docs/decisions/0008-mods-and-saves.md)。

### `api` 只提供动词

`spawn` / `remove` / `impulse` / `tint` / `reset_tint` / `pos` / `speed` / `nearest`。

拿不到节点、拿不到 `Transform3D`——这是故意的（[ADR 0007](docs/decisions/0007-hooks.md)）：
暴露意图，不暴露结构。一旦 mod 能 `get_node("../../chunk_0/MultiMesh")`，
引擎内部结构当天就被生态钉死，之后你再也不敢重构。

钩子清单在 `contract/registry.py`，当前 7 个：`world.ready`、`entity.spawn`、`entity.remove`、
`grab.request`（可否决）、`grab.release`、`impact`、`tick`。
契约声明与引擎实际发出的事件必须完全相等，不符合 `check.sh` 就红。

### L4：mod 自带新组件与新规则

挂事件只能"在事情发生时改一下"。要让一条**持续的规则**参与世界循环，mod 还得能声明
自己的数据形状和自己的系统。这两样都不用改引擎（`mods/l4_demo/` 是完整可跑的例子）。

`content/pulse_spec.toml` —— 声明一个新组件，字段带类型 / 默认值 / 范围 / 枚举：

```toml
api_version = 1
kind = "component_spec"
id = "l4_demo/pulse"
name = "脉动"
key = "pulse"
fields = [
  { name = "rate", type = "float", default = 0.5, min = 0.0, max = 10.0 },
  { name = "charge", type = "float", default = 0.0, min = 0.0, max = 1.0 },
]
```

之后内容里就可以写 `[components.pulse]`，和内置组件同等校验。
`content/pulse_system.toml` 声明规则：

```toml
api_version = 1
kind = "system"
id = "l4_demo/pulse_system"
source = "scripts/pulse_system.gd"
priority = 120        # 从 100 起，两个系统不许撞同一个值
period = 0.25         # 固定节拍，不是每渲染帧
reads = ["pulse"]     # 权限清单，没声明的组件读不到
writes = ["pulse"]    # 写值还要过类型 / 范围 / 枚举
```

`scripts/pulse_system.gd` 只有一个入口：

```gdscript
extends RefCounted

func step(ctx, api) -> void:
    for h in ctx.entities():                       # 不透明 handle，不是节点
        var rate := float(ctx.read(h, "pulse", "rate"))
        var charge := float(ctx.read(h, "pulse", "charge"))
        charge = fmod(charge + rate * float(ctx.dt), 1.0)
        ctx.write(h, "pulse", "charge", charge)
        if api.exists(h):
            api.tint(h, Color(charge, 0.40, 1.0 - charge))
```

`ctx` 只给 `entities()` / `read()` / `write()` / `dt` / `frame`，
拿不到节点、`Transform3D`、组件对象；改变世界仍然走上面那个 `api` 的动词。
自定义组件的运行时值**只在内存里、不进存档**，物体消失就清理。

带 `system` 的 mod 和带 `script` 的 mod 一样是**可执行代码**：默认拒绝，
必须 `--trust=<id>`，编译器和引擎各自独立按"有没有可执行代码"算真实级别。
理由与推翻条件见 [ADR 0011](docs/decisions/0011-l4-extension-container.md)。

### 外观开放：放个文件夹就换模型

资源包不写内容、不带脚本，是 `data` 级，**默认放行、不需要 `--trust`** ——
换外貌不该要求玩家运行任意代码。目录长这样：

```
mods/my_skin/
  mod.toml
  assets/meshes/
    player_lowpoly.glb        # 换主角
    prop_crate.gltf           # 换木箱
```

**文件名就是契约里的网格 id**（`contract/registry.py` 的 `MESHES`），
`.gltf` / `.glb` 都认。没放文件的网格回退到引擎的程序化几何。
多个 mod 都放同一个 id 时，后加载的压过先加载的。

编一次产物、启动即可，不改代码、不重编译引擎：

```bash
python3 tools/contentc.py --mod mods/my_skin --base content
./run.sh
```

几条边界，都是刻意设计的：

- **内容里不写资源路径**。路径由目录枚举出来，文件名里没有 `/`，
  于是默认放行的 `data` mod 也读不到 mod 目录之外的东西。
- **拼错文件名会报错**，不会静默失效 ——「装了却什么都没发生」最难查。
- **覆盖只能换已有槽位**，和 MC 资源包一样；加一种全新网格要动契约，是另一件事。
- **三角形数按运行时实测算**，不用手写的规划值：文件在 mod 目录里，
  编译期看不到它有没有被换掉。
- 解析坏掉的文件不静默回退内置几何，自检和第 11 步探针会判红。

`mods/asset_demo/` 是完整可跑的例子（含自造的 8 三角形钻石与来源 / 许可说明）。
现成资源优先找 KayKit / Quaternius / Kenney 等 CC0 包，**来源、作者、许可、下载日期
必须记进 mod 自己的说明里**；要求署名的，发布包要带署名文件。
理由与推翻条件见 [ADR 0012](docs/decisions/0012-asset-override.md)。

贴图覆盖、骨骼动画、按配色换贴图**还没做**（贴图与 MultiMesh 的合批单位绑在一起，
是另一个独立决定），见 `docs/status.md` 下一步。

## 给 agent 的话

开工前读 [`AGENTS.md`](AGENTS.md)。那不是给人看的介绍，是合同。
目录纪律在 [`docs/structure.md`](docs/structure.md)，阶段划分在 [`docs/roadmap.md`](docs/roadmap.md)，
每个不可逆决定的理由在 [`docs/decisions/`](docs/decisions/)。

## 许可

MIT。见 [`LICENSE`](LICENSE)。

内置模型、音效里的第三方素材（含 CC-BY 的署名要求）单独列在
[`assets/ASSETS.md`](assets/ASSETS.md)。
