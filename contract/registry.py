"""扩展点注册表 —— 全工程唯一的"什么是合法的"来源。

为什么所有声明都挤在这一个文件里：

  * 校验器读它     -> 字段名写错、类型写错，编译期就报错，而不是玩到一半崩
  * 文档生成读它   -> build/components.md 永远和代码同步，不会过期
  * 运行时读它     -> 默认值填充、类型转换、枚举检查只有一套逻辑
  * 未来的编辑器读它 -> 自动补全和属性面板零成本

新增能力的正确姿势（只有这两处）：
  1. 在这里 register 一个组件 / 一种行为 / 一个网格
  2. 在 runtime/systems.py 里注册一个消费它的系统

除此之外任何地方加"特例"，都是在关闭这个架构。
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Callable, Iterable

SUPPORTED_API = {1}


@dataclass(frozen=True)
class Field:
    """一个组件字段的完整契约。"""

    type: str  # "int" | "float" | "bool" | "str" | "list"
    default: Any = None
    min: float | None = None
    max: float | None = None
    enum: tuple[str, ...] | None = None
    doc: str = ""


@dataclass(frozen=True)
class ComponentSpec:
    name: str
    doc: str
    fields: dict[str, Field]


@dataclass(frozen=True)
class KindSpec:
    name: str
    doc: str
    require: tuple[str, ...] = ()


@dataclass(frozen=True)
class SystemSpec:
    name: str
    priority: int
    reads: tuple[str, ...]
    writes: tuple[str, ...]
    fn: Callable | None = None


@dataclass(frozen=True)
class HookSpec:
    """一个事件钩子的完整契约。

    params  承诺给 mod 的上下文字段。少一个 = 引擎违约，mod 会读到 null。
    returns 引擎会读的返回值。空 = 这个事件只能"看"，不能改变什么。
    blocking  True 表示这个事件可以被否决（返回 allow=false 就到此为止）。
    """

    name: str
    doc: str
    params: tuple[str, ...] = ()
    returns: tuple[str, ...] = ()
    blocking: bool = False


COMPONENTS: dict[str, ComponentSpec] = {}
KINDS: dict[str, KindSpec] = {}
SYSTEMS: list[SystemSpec] = []
HOOKS: dict[str, HookSpec] = {}

# 行为注册表：数据里只能引用已注册的 brain，不能凭空写字符串
BRAINS: tuple[str, ...] = ("idle", "patrol", "charger", "ambusher")
LOOT_TABLES: tuple[str, ...] = ("none", "common", "rare")

# 网格注册表：数据里只能引用这里出现过的 mesh。
# 三角形数是**实测值**，不是估算：引擎自检会拿这里的数字和自己数出来的比，
# 不一致就失败。这样"预算"才不会在改几何的过程中悄悄失真。
MESHES: dict[str, int] = {
    "humanoid_lowpoly": 96,   # 8 个盒子：躯干/头/四肢/胸甲/护肩
    "shade_lowpoly": 48,      # 六棱台袍子 36 + 头盒 12
    "prop_crate": 12,
    "prop_pillar": 24,
    "player_lowpoly": 692,    # 球头 + 7 盒 + 12 段柱体。主角只有一个，贵得起
}

# 配色注册表：(r, g, b)，0..1 的 sRGB。
# 颜色放在契约里而不是引擎里，是为了让引擎**不认识任何配色名**——
# 加一个新配色只改这一处，引擎从内容包读到的就是新颜色。
PALETTES: dict[str, tuple[float, float, float]] = {
    "default": (0.78, 0.78, 0.76),
    "bone": (0.90, 0.88, 0.80),
    "violet": (0.55, 0.43, 0.76),
    "wood": (0.60, 0.42, 0.26),
    # 卡通着色会把暗部压成色块，所以配色整体比写实路线亮一档、饱和一档。
    # 这不是审美偏好，是渲染管线的补偿：同一份颜色在两个渲染器下观感差很远。
    "azure": (0.42, 0.66, 0.94),
    "blossom": (0.96, 0.66, 0.76),
    "jade": (0.44, 0.80, 0.64),
}


def component(name: str, doc: str = "", **fields: Field) -> None:
    if name in COMPONENTS:
        raise RuntimeError(f"组件 `{name}` 重复注册")
    COMPONENTS[name] = ComponentSpec(name, doc, dict(fields))


def kind(name: str, doc: str = "", require: Iterable[str] = ()) -> None:
    if name in KINDS:
        raise RuntimeError(f"内容类型 `{name}` 重复注册")
    KINDS[name] = KindSpec(name, doc, tuple(require))


def hook(name: str, doc: str, params: Iterable[str] = (), returns: Iterable[str] = (),
         blocking: bool = False) -> None:
    """注册一个事件钩子。名字用 `域.动作` 形式，全小写。

    钩子是**行为开放的唯一入口**：mod 能看见什么、能改什么，全部由这张表决定。
    表里没有的事件，引擎不会发；表里没声明的返回值，引擎不会读。
    这条约束让"引擎能提供哪些介入点"变成一个可审阅的清单，而不是散在代码里的字符串。
    """
    if name in HOOKS:
        raise RuntimeError(f"钩子 `{name}` 重复注册")
    HOOKS[name] = HookSpec(name, doc, tuple(params), tuple(returns), blocking)


def system(name: str, priority: int, reads: Iterable[str] = (), writes: Iterable[str] = ()):
    """注册一个系统。priority 越小越先跑。

    两条硬规则（check_system_order 会检查）：
      * 同一个组件如果有两个系统写，它们的 priority 必须不同
      * 系统只能通过组件交流，不许直接引用另一个系统
    """

    def deco(fn: Callable) -> Callable:
        SYSTEMS.append(SystemSpec(name, priority, tuple(reads), tuple(writes), fn))
        return fn

    return deco


def check_system_order() -> list[str]:
    """返回系统写入冲突。空列表 = 顺序是确定的。"""
    problems: list[str] = []
    writers: dict[str, list[SystemSpec]] = {}
    for s in SYSTEMS:
        for c in s.writes:
            writers.setdefault(c, []).append(s)

    for cname, owners in writers.items():
        prios = [s.priority for s in owners]
        if len(set(prios)) != len(prios):
            detail = "、".join(f"{s.name}(p={s.priority})" for s in owners)
            problems.append(f"组件 `{cname}` 被多个同优先级系统写入：{detail}")

    for s in SYSTEMS:
        for c in s.writes:
            if c not in COMPONENTS:
                problems.append(f"系统 `{s.name}` 写入了未注册的组件 `{c}`")
        for c in s.reads:
            if c not in COMPONENTS:
                problems.append(f"系统 `{s.name}` 读取了未注册的组件 `{c}`")
    return problems


def check_value(spec: Field, value: Any) -> str | None:
    """返回错误说明，合法时返回 None。"""
    t = spec.type
    if t == "int":
        if isinstance(value, bool) or not isinstance(value, int):
            return "期望整数"
    elif t == "float":
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            return "期望数字"
    elif t == "bool":
        if not isinstance(value, bool):
            return "期望 true / false"
    elif t == "str":
        if not isinstance(value, str):
            return "期望字符串"
    elif t == "list":
        if not isinstance(value, list):
            return "期望数组"
    else:
        return f"未知字段类型 `{t}`"

    if spec.enum is not None and isinstance(value, str) and value not in spec.enum:
        return f"`{value}` 不在允许值 {list(spec.enum)} 中"

    if isinstance(value, (int, float)) and not isinstance(value, bool):
        if spec.min is not None and value < spec.min:
            return f"不能小于 {spec.min}（当前 {value}）"
        if spec.max is not None and value > spec.max:
            return f"不能大于 {spec.max}（当前 {value}）"
    return None


# --------------------------------------------------------------------------
# 游戏组件声明。加一个组件 = 在这里加一段。
# --------------------------------------------------------------------------

component(
    "transform",
    "摆放信息。位置由实体自身持有，这里只放缩放和朝向。",
    scale=Field("float", 1.0, 0.05, 20.0, doc="统一缩放"),
    yaw=Field("float", 0.0, -360.0, 360.0, doc="初始朝向，度"),
)

component(
    "model",
    "外观。mesh 决定三角形数，palette 决定配色（同一 mesh 换色不增加 draw call）。",
    mesh=Field("str", "prop_crate", enum=tuple(MESHES), doc="网格 id"),
    palette=Field("str", "default", enum=tuple(PALETTES), doc="配色方案 id"),
    cast_shadow=Field("bool", False, doc="是否投射实时阴影（很贵，默认关）"),
)

component(
    "health",
    "生命。hp 为 0 时按 max 填满，表示开局满血。",
    max=Field("int", 10, 1, 1_000_000, doc="生命上限"),
    hp=Field("int", 0, 0, 1_000_000, doc="当前生命，0 = 满血"),
    regen=Field("float", 0.0, 0.0, 1000.0, doc="每秒回复"),
)

component(
    "move",
    "移动能力。speed 为 0 表示这是个静态物体。",
    speed=Field("float", 0.0, 0.0, 60.0, doc="移动速度 m/s"),
    wander=Field("float", 0.0, 0.0, 50.0, doc="游荡幅度"),
)

component(
    "ai",
    "行为。brain 只能取注册表里的行为 id。",
    brain=Field("str", "idle", enum=BRAINS, doc="行为模板"),
    aggro_radius=Field("float", 8.0, 0.0, 200.0, doc="仇恨半径"),
    leash=Field("float", 30.0, 0.0, 400.0, doc="脱离半径"),
)

component(
    "loot",
    "掉落。",
    table=Field("str", "none", enum=LOOT_TABLES, doc="掉落表"),
    chance=Field("float", 0.0, 0.0, 1.0, doc="掉落概率"),
)

component(
    "light",
    "光源。实时点光源是帧预算的大敌，全局同时存在的数量会被运行时限制。",
    radius=Field("float", 6.0, 0.0, 60.0, doc="影响半径"),
    intensity=Field("float", 1.0, 0.0, 8.0, doc="强度"),
    flicker=Field("bool", False, doc="是否闪烁（每帧要算）"),
)

component(
    "collider",
    "碰撞体。只支持简单图元，不做网格碰撞。dynamic 决定它是不是刚体——"
    "这条由数据声明，引擎绝不按内容 id 判断（铁律 2）。",
    shape=Field("str", "capsule", enum=("capsule", "box", "sphere"), doc="形状"),
    size=Field("float", 0.5, 0.05, 20.0, doc="特征尺寸：box 的边长，capsule/sphere 的直径"),
    height=Field("float", 0.0, 0.0, 30.0, doc="总高。0 = 按形状推导（胶囊按人形比例）"),
    mass=Field("float", 5.0, 0.1, 2000.0, doc="质量 kg，只有 dynamic 时有意义"),
    dynamic=Field("bool", False, doc="true = 受重力与冲量的刚体；false = 钉住的障碍物"),
)

component(
    "spawner",
    "生成器。房间用它把怪填进去。",
    archetype=Field("str", "", doc="要生成的原型 id"),
    count=Field("int", 1, 0, 500, doc="数量"),
    radius=Field("float", 10.0, 0.0, 200.0, doc="散布半径"),
    height=Field("float", 0.0, 0.0, 50.0, doc="散布时的离地高度（有重力的东西会自己落下）"),
    respawn=Field("float", 0.0, 0.0, 600.0, doc="重生间隔秒，0 = 不重生"),
)

component(
    "room",
    "空间定义。分块流式加载以它为单位。",
    size_x=Field("float", 24.0, 2.0, 500.0, doc="宽度"),
    size_z=Field("float", 24.0, 2.0, 500.0, doc="进深"),
    lit=Field("bool", False, doc="是否有烘焙光照"),
)

component(
    "wieldable",
    "可持握武器的数值。",
    damage=Field("int", 1, 0, 100_000, doc="伤害"),
    reach=Field("float", 1.5, 0.0, 20.0, doc="攻击距离"),
    cooldown=Field("float", 0.6, 0.0, 60.0, doc="冷却秒"),
)

component(
    "pickup",
    "可拾取物。",
    value=Field("int", 1, 0, 1_000_000, doc="价值"),
    stack=Field("int", 1, 1, 999, doc="堆叠上限"),
)

component(
    "interaction",
    "可交互。verb 是动作，prompt 是给玩家看的提示。",
    verb=Field("str", "use", doc="动作 id"),
    prompt=Field("str", "", doc="提示文案"),
)

# --------------------------------------------------------------------------
# 事件钩子声明。加一个钩子 = 在这里加一段，同时引擎必须真的会发它。
#
# 自检要求两边**完全相等**（契约声明 == 引擎发出）。只声明不发是撒谎，
# 只发不声明是绕过契约 —— 两种都算失败。
# --------------------------------------------------------------------------

hook(
    "world.ready",
    "世界装配完成、玩家已就位。mod 做一次性初始化的地方。",
    params=("rooms", "entities", "player_pos"),
)

hook(
    "entity.spawn",
    "一个刚体进入世界。静态合批的实例不发这个事件——它们没有独立身份。",
    params=("id", "handle", "pos"),
)

hook(
    "grab.request",
    "玩家试图抓起某个物体。可以否决，也可以改变持握距离。",
    params=("id", "handle", "mass", "pos"),
    returns=("allow", "hold"),
    blocking=True,
)

hook(
    "grab.release",
    "松手或抛出。thrown=false 表示是放下，不是扔。",
    params=("id", "handle", "speed", "thrown"),
)

hook(
    "impact",
    "刚体撞到东西。speed 是撞击前一帧的速度，不是撞完的残余速度。",
    params=("id", "handle", "speed", "pos"),
)

hook(
    "tick",
    "固定节拍（每 0.25 秒一次），不是每帧。给 mod 一个便宜的『我还活着』的机会。",
    params=("dt", "frame"),
)


kind("archetype", "世界里被摆放的东西：怪、道具、装饰", require=("name",))
kind("item", "背包里的东西", require=("name",))
kind("room", "一个空间单元", require=("name",))
kind("patch", "覆写别人的内容（mod 专用）", require=("target",))
kind(
    "script",
    "行为 mod。声明源码位置和它要挂的事件，引擎运行时编译并绑定。"
    "events 是**权限清单**：没写进这里的事件，引擎不会转给它。",
    require=("name", "source", "events"),
)
