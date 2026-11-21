"""扩展点注册表 —— 全工程唯一的"什么是合法的"来源。

为什么所有声明都挤在这一个文件里：

  * 校验器读它     -> 字段名写错、类型写错，编译期就报错，而不是玩到一半崩
  * 文档生成读它   -> build/components.md 永远和代码同步，不会过期
  * 运行时读它     -> 默认值填充、类型转换、枚举检查只有一套逻辑
  * 未来的编辑器读它 -> 自动补全和属性面板零成本

新增能力的正确姿势（只有这两处）：
  1. 在这里 register 一个组件 / 一种行为 / 一个网格 / 一个钩子
  2. 在 game/scripts/ 里实现消费它的那一层，并把「契约 vs 实测」写进自检

除此之外任何地方加"特例"，都是在关闭这个架构。
"""

from __future__ import annotations

from dataclasses import dataclass
import re
from typing import Any, Callable, Iterable

SUPPORTED_API = {1}

## L4 扩展的形状约束。随 schema 导出，编译器与引擎共用同一组数字，
## 不在两个地方各写一个「100」或「16」。改这里之前先看 ADR 0011。
FIELD_TYPES = ("int", "float", "bool", "str", "list", "dict")
EXTENSION_RULES: dict[str, Any] = {
    "component_key": r"^[a-z][a-z0-9_]*$",
    "field_name": r"^[a-z][a-z0-9_]*$",
    "max_fields": 16,
    "system_priority_min": 100,
    "system_priority_max": 999,
    "period_min": 0.05,
    "period_max": 5.0,
    "period_default": 0.25,
    "max_systems": 16,
}

## mod 的两个级别。引擎真的按它分流，不是文档里的一句话。
##
## 为什么必须分两级：Godot 没有 GDScript 沙箱（实测 mod 里 OS.execute 返回 0，
## 见 ADR 0003）。既然拦不住"能干什么"，就只能在"能不能进来"上做区分，
## 而那个区分必须让玩家看得见、并且由玩家按下开关。
MOD_LEVELS: dict[str, str] = {
    "data": "只改内容与外观，不执行代码。默认放行",
    "script": "带脚本，运行时编译，完全权限。必须玩家显式授权",
}

## 每条内容的**顶层字段**。它们不是组件 —— 组件描述"它有什么"，
## 这十来个字段描述"它是什么"，所以它们在契约里，不在内容里。
##
## 为什么要带类型：字段名拼错（`abstact = true`）必须当场报错。
## 允许任意字段的后果是拼错静默不生效，而"静默不生效"在这个项目里的典型表现
## 是"这个基类为什么被摆进世界了"——看起来完全正常，没人会去查。
TOP_FIELDS: dict[str, str] = {
    "api_version": "int",
    "id": "str",
    "kind": "str",
    "extends": "str",
    "name": "str",
    "doc": "str",
    "tags": "list",
    "abstract": "bool",
    "components": "dict",
    "target": "str",   # patch 用：覆写谁
    "source": "str",   # script 用：源码在哪
    "events": "list",  # script 用：挂哪些钩子
    "entries": "list",  # loot_table 用：一组 {id, chance}
    "key": "str",       # component_spec 用：新组件叫什么
    "fields": "list",   # component_spec 用：字段定义列表
    "priority": "int",  # system 用：越小越先跑
    "reads": "list",    # system 用：允许读哪些组件
    "writes": "list",   # system 用：允许写哪些组件
    "period": "float",  # system 用：固定节拍秒数
}

## `abstract = true` 的含义：**这条内容只能被 extends，不能单独存在。**
##
## 为什么值得一个正式字段，而不是往 tags 里塞一根 "abstract" 字符串：
## tags 是内容之间的约定（mod 可以往里面加任何东西），而"能不能出现在世界里"
## 是**引擎的行为**。把引擎行为挂在一根内容字符串上，写错一个字母的后果
## 是基类被当成实体摆出来，而那种错误看起来完全正常。
##
## 两条硬规则（contentc 会检查）：
##   * 抽象内容不能被房间的 spawner 指向 —— 否则世界里会出现一个"模板"
##   * 抽象内容不进生成菜单 —— 同理
## 还有一条容易搞反的：**abstract 不继承**。给它标上 abstract 只影响它自己，
## 否则所有子类会跟着变成模板，世界里一次性少掉一整类东西，而且没有任何报错。


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

# 网格注册表：数据里只能引用这里出现过的 mesh。
# 三角形数是**实测值**，不是估算：引擎自检会拿这里的数字和自己数出来的比，
# 不一致就失败。这样"预算"才不会在改几何的过程中悄悄失真。
MESHES: dict[str, int] = {
    "humanoid_lowpoly": 96,   # 8 个盒子：躯干/头/四肢/胸甲/护肩
    "shade_lowpoly": 48,      # 六棱台袍子 + 头盒（实测 48）
    "prop_crate": 12,
    "prop_pillar": 24,
    "prop_gem": 40,           # 两个四棱锥（cylinder 4 段，实测 40）
    "prop_blade": 36,         # 3 个盒子：剑身/护手/剑柄
    "player_lowpoly": 692,    # 球头 + 7 盒 + 12 段柱体。主角只有一个，贵得起
}

# 音效注册表：内容里只能引用这里出现过的音效 id，**不许写文件路径**。
#
# 和 MESHES 一样是手写清单而不是扫目录：路径由 id 拼出来（`assets/sfx/<id>.ogg`），
# 于是内容作者拿不到"读任意文件"的能力。加一个音效 = 放文件 + 在这里登记一行，
# 漏登记会被编译期挡下（枚举校验），不会静默变成静音。
SFX: tuple[str, ...] = (
    "rifle_shot",   # 一声真枪响，0.62 秒，见 assets/ASSETS.md
)

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
    elif t == "dict":
        if not isinstance(value, dict):
            return "期望表（[xxx] 段）"
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


def component_from_spec(body: dict, origin: str = "mod") -> tuple[dict | None, list[str]]:
    """把 `kind="component_spec"` 的内容变成 schema 里的一段组件声明。

    L4 的组件不是「随便往字典里塞任意键」：类型、默认值、范围、枚举都要在这里
    过一遍。否则一个拼错的字段名或字符串型的数字会静默生效，和内置组件当年
    踩过的坑一模一样（ADR 0011）。
    """
    errors: list[str] = []
    key = body.get("key")
    if not isinstance(key, str) or not re.match(EXTENSION_RULES["component_key"], key):
        errors.append(f"组件 key `{key!r}` 不合法（小写字母开头，只允许 a-z 0-9 _）")
        return None, errors
    if key in COMPONENTS:
        errors.append(f"组件 `{key}` 与契约内置组件重名；mod 只能加新名字，不能改内置语义")

    raw_fields = body.get("fields")
    if not isinstance(raw_fields, list) or not raw_fields:
        errors.append(f"组件 `{key}` 的 fields 必须是非空数组")
        return None, errors
    if len(raw_fields) > int(EXTENSION_RULES["max_fields"]):
        errors.append(f"组件 `{key}` 有 {len(raw_fields)} 个字段，超过上限 {EXTENSION_RULES['max_fields']}")
        return None, errors

    fields: dict[str, dict] = {}
    for i, item in enumerate(raw_fields):
        where = f"组件 `{key}` 的第 {i + 1} 个字段"
        if not isinstance(item, dict):
            errors.append(f"{where} 必须是一张表")
            continue
        fname = item.get("name")
        if not isinstance(fname, str) or not re.match(EXTENSION_RULES["field_name"], fname):
            errors.append(f"{where} 的 name `{fname!r}` 不合法")
            continue
        if fname in fields:
            errors.append(f"组件 `{key}` 的字段 `{fname}` 重复")
            continue
        ftype = item.get("type")
        if ftype not in FIELD_TYPES:
            errors.append(f"{where} 的 type `{ftype!r}` 不合法（可用：{', '.join(FIELD_TYPES)}）")
            continue
        if "default" not in item:
            errors.append(f"{where} 缺 default；运行时不该猜它从几开始")
            continue
        default = item["default"]
        lo = item.get("min")
        hi = item.get("max")
        enum = item.get("enum")
        if lo is not None and (not isinstance(lo, (int, float)) or isinstance(lo, bool) or ftype not in ("int", "float")):
            errors.append(f"{where} 的 min 只能是数字，且只给数值字段用")
            continue
        if hi is not None and (not isinstance(hi, (int, float)) or isinstance(hi, bool) or ftype not in ("int", "float")):
            errors.append(f"{where} 的 max 只能是数字，且只给数值字段用")
            continue
        if lo is not None and hi is not None and lo > hi:
            errors.append(f"{where} 的 min 比 max 还大")
            continue
        if enum is not None:
            if ftype != "str" or not isinstance(enum, list) or not enum or not all(isinstance(x, str) for x in enum):
                errors.append(f"{where} 的 enum 只能是非空的字符串数组，且只给 str 字段用")
                continue
            enum = tuple(enum)
        fspec = Field(ftype, default, lo, hi, enum, str(item.get("doc", "")))
        problem = check_value(fspec, default)
        if problem:
            errors.append(f"{where} 的 default {problem}")
            continue
        fields[fname] = {
            "type": ftype,
            "default": default,
            "min": lo,
            "max": hi,
            "enum": list(enum) if enum else None,
            "doc": fspec.doc,
        }

    if errors:
        return None, errors
    return {
        "doc": str(body.get("doc", "")),
        "fields": fields,
        "origin": origin,
    }, []


def check_system_spec(cid: str, body: dict, component_names: set[str]) -> list[str]:
    """检查一条 `kind="system"` 声明。返回空列表 = 合法。"""
    errors: list[str] = []
    rules = EXTENSION_RULES
    source = body.get("source")
    if not isinstance(source, str) or not source.endswith(".gd"):
        errors.append(f"系统 `{cid}` 的 source 必须是 .gd 文件路径")
    priority = body.get("priority")
    if isinstance(priority, bool) or not isinstance(priority, int):
        errors.append(f"系统 `{cid}` 的 priority 必须是整数")
    elif not (int(rules["system_priority_min"]) <= priority <= int(rules["system_priority_max"])):
        errors.append(
            f"系统 `{cid}` 的 priority={priority} 越界"
            f"（mod 系统只允许 {rules['system_priority_min']}~{rules['system_priority_max']}，"
            "100 以前留给引擎自带系统）"
        )
    period = body.get("period", rules["period_default"])
    if isinstance(period, bool) or not isinstance(period, (int, float)):
        errors.append(f"系统 `{cid}` 的 period 必须是秒数")
    elif not (float(rules["period_min"]) <= float(period) <= float(rules["period_max"])):
        errors.append(
            f"系统 `{cid}` 的 period={period} 越界"
            f"（允许 {rules['period_min']}~{rules['period_max']} 秒）"
        )

    reads = body.get("reads")
    writes = body.get("writes")
    for label, names in (("reads", reads), ("writes", writes)):
        if not isinstance(names, list):
            errors.append(f"系统 `{cid}` 的 {label} 必须是数组")
            continue
        for c in names:
            if not isinstance(c, str):
                errors.append(f"系统 `{cid}` 的 {label} 里出现非字符串 {c!r}")
            elif c not in component_names:
                errors.append(f"系统 `{cid}` 的 {label} 引用了未声明的组件 `{c}`")
    if isinstance(reads, list) and isinstance(writes, list) and not (reads or writes):
        errors.append(f"系统 `{cid}` 既不读也不写，引擎不知道该把哪些实体交给它")
    return errors


def check_extension_order(systems: dict[str, dict]) -> list[str]:
    """多个 mod 系统之间的冲突。优先级必须唯一，否则顺序靠字典遍历决定。"""
    errors: list[str] = []
    if len(systems) > int(EXTENSION_RULES["max_systems"]):
        errors.append(f"系统数 {len(systems)} 超过上限 {EXTENSION_RULES['max_systems']}")
    seen: dict[int, str] = {}
    for cid, body in systems.items():
        p = body.get("priority")
        if not isinstance(p, int) or isinstance(p, bool):
            continue
        if p in seen:
            errors.append(f"系统 `{cid}` 与 `{seen[p]}` 的 priority 都是 {p}；顺序不能靠猜")
        else:
            seen[p] = cid
    return errors


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
    "掉落。`table` 是一个 **loot_table 内容的 id**，不是写死的表名 ——\n"
    "    表本身是内容，所以 mod 能加自己的表，也能覆写已有的。\n"
    "    编译期会查它指的那条真的存在且真是 loot_table（悬空引用当场报错）。",
    table=Field("str", "", doc="掉落表的内容 id（kind = loot_table）。空 = 不掉东西"),
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
    start=Field("bool", False, doc="开局房间。多个都标了时按房间 id 取第一个"),
)

component(
    "wieldable",
    "可持握武器的数值。\n"
    "    **一把枪是一条 `kind = \"weapon\"` 的内容**，数值全在这里；\n"
    "    摆在世界里的同款（kind = archetype）就只是件道具，不会开火。\n"
    "    为什么把弹道相关的数放在契约而不是代码里：射速、弹匣、散布、后坐\n"
    "    是手感的第一现场，改它们不该需要动引擎（铁律 1）。",
    damage=Field("int", 1, 0, 100_000, doc="每发伤害"),
    reach=Field("float", 1.5, 0.0, 400.0, doc="射程，米"),
    cooldown=Field("float", 0.6, 0.0, 60.0, doc="近战冷却秒（枪用 rate，不用它）"),
    rate=Field("float", 2.0, 0.05, 60.0, doc="每秒发数"),
    mag=Field("int", 1, 1, 999, doc="弹匣容量"),
    reload=Field("float", 1.0, 0.0, 20.0, doc="换弹秒数"),
    spread=Field("float", 0.0, 0.0, 30.0, doc="散布半角，度。0 = 绝对精准"),
    recoil_pitch=Field("float", 0.0, 0.0, 30.0, doc="每发抬枪，度"),
    recoil_yaw=Field("float", 0.0, 0.0, 30.0, doc="每发横向抖动幅度，度"),
    auto=Field("bool", False, doc="按住不放是否连发"),
    sound=Field("str", "", enum=SFX, doc="开火音效 id。空 = 静音"),
)

component(
    "hit_react",
    "被打中时的反应。**它管的是「挨打之后会怎样」，不是「挨了多少打」。**\n"
    "    伤害是 health 的事（掉了多少血），反应是这一份（会不会被推倒、会不会愣住）。\n"
    "    为什么要分开：被打一下就死掉的靶子和被打一下会退两步的怪，血量可以一样，\n"
    "    手感完全不同。后者是「有没有反馈」的关键 —— 一枪打上去纹丝不动，\n"
    "    玩家会以为打偏了，于是第二枪更用力，第三枪更慌。\n"
    "    knockback 0 = 打了跟没打一样（默认）；stun 0 = 不会愣住。",
    knockback=Field("float", 0.0, 0.0, 50.0, doc="被打中时向后退多少 m/s"),
    stun=Field("float", 0.0, 0.0, 5.0, doc="被打中后愣住多少秒（期间不走）"),
)

component(
    "pickup",
    "可拾取物。stack 是**背包里的堆叠上限**（同一个 id 最多几件），"
    "value 是价值。两个数都被引擎读：堆叠上限由背包强制，价值进背包合计。",
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
    "entity.remove",
    "一个刚体离开世界。与 entity.spawn 严格对称：有 handle 的才会发，"
    "所以 mod 拿到的 handle 迟早会在这里被收回。",
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
kind(
    "weapon",
    "玩家手里的枪。一条 weapon 内容 = 一把枪，数值全在 wieldable 组件里。\n"
    "    它不是一个能被摆放的实体（那需要 kind = archetype）—— 这条分界\n"
    "    让『世界里捡到一把枪』和『玩家拿着哪把枪』变成两件事，\n"
    "    而不是靠引擎猜某个 archetype 是不是武器。",
    require=("name",),
)
kind("patch", "覆写别人的内容（mod 专用）", require=("target",))
kind(
    "loot_table",
    "掉落表。entries 是一组 `{id, chance}`，id 指向一条 item。\n"
    "    为什么表是内容而不是代码：'这个怪掉什么'是内容作者的决定，\n"
    "    而 mod 要能加自己的表、也能用 patch 覆写别人的表 ——\n"
    "    两条路都要求表本身是可寻址的内容，而不是引擎里的一张字典。",
    require=("entries",),
)
kind(
    "script",
    "行为 mod。声明源码位置和它要挂的事件，引擎运行时编译并绑定。"
    "events 是**权限清单**：没写进这里的事件，引擎不会转给它。",
    require=("name", "source", "events"),
)
kind(
    "component_spec",
    "L4 扩展：声明一个新组件。fields 是带类型 / 默认值 / 范围的字段定义；"
    "key 就是之后 `[components.<key>]` 里用的名字。",
    require=("name", "key", "fields"),
)
kind(
    "system",
    "L4 扩展：声明一条固定节拍规则。source 指向自己的 .gd，"
    "reads / writes 是权限清单，priority 决定系统之间的顺序。",
    require=("name", "source", "reads", "writes", "priority"),
)
