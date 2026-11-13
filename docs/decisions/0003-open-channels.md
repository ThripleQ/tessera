# 0003 两个开放通道怎么实现

## 背景

产品定义里有三层开放（见 `docs/roadmap.md` 一）。第一层"内容开放"已经成立，
第二层"行为开放"和第三层"外观开放"决定这个项目是平台还是单机游戏。
在 P1 之前必须先钉死这两条路的技术选型，否则 P3/P4/P5 会返工。

## 决定

**行为开放走 Godot 的运行时 GDScript 编译；外观开放走目录 overlay。两者都不引入新依赖。**

### 行为开放：运行时编译外部 `.gd`

```gdscript
var gd := GDScript.new()
gd.source_code = FileAccess.get_file_as_string(mod_dir + "/entry.gd")
if gd.reload() != OK:      # 语法错在这里返回 Parse error，不是崩溃
    return                  # 该 mod 标记为坏，其余 mod 继续加载
var inst = gd.new()
inst.call("on_spawn", {"x": 1})
```

### 外观开放：磁盘目录优先于 `res://`

解析一个资源路径时按顺序查：

1. 已启用 mod 的目录（后加载的优先）
2. `res://assets/`

第一个命中即生效。图片用 `Image.load_from_file(绝对路径)` → `ImageTexture`，
目录用 `DirAccess` 枚举。**不需要 `.pck` 打包工具链，因为资源包的本质就是文件夹。**

### mod 分两级，权限差异必须在 UI 上说清楚

| 级别 | 内容 | 能力 | 默认 |
|---|---|---|---|
| `data-only` | TOML + 资源文件 | 只能改数据和外貌 | 默认，无需授权 |
| `scripted` | 额外带 `.gd` | **完全权限：能读写文件、能执行系统命令** | 需玩家显式授权 |

第二条不是保守，是实测结论：mod 脚本里 `OS.execute("echo", [...])` 的返回码是 0，
输出是 `untrusted-mod-code-ran`。**Godot 没有 GDScript 沙箱，也做不出来。**

## 证据（2026-11-13，Godot 4.6.stable，`--headless`）

探针脚本已删除，结论在此留档，可照上面代码片断在 10 行内复现：

| 验证项 | 结果 |
|---|---|
| 从任意绝对路径读 `.gd` 源码（非 `res://`） | 成功，389 字节 |
| `GDScript.new()` + `source_code` + `reload()` | 返回 OK |
| 实例化并 `call("on_spawn", {...})` | 返回 `{"kind": "probe", "double": 42}` |
| 语法错误的脚本 | `reload()` 返回 `Parse error`，进程存活，可捕获 |
| 纯字符串源码（无文件） | 可编译并调用 |
| mod 脚本执行系统命令 | `exit=0 out=untrusted-mod-code-ran` ← **无沙箱** |
| 绝对路径 PNG → `Image` → `ImageTexture` | 成功，1100×620 |
| `DirAccess.open(磁盘目录)` + `get_files()` | 成功枚举 |

**未验证的一条，必须记住**：以上全部在**编辑器二进制**上跑的。导出后的
`export_template` 是否同样支持运行时编译，**没有验证**（需要下载 1GB 模板）。
P6 公开发布前必须用真实导出包重跑这个探针，否则可能"开发能跑、发出去 mod 全废"。

## 被否掉的选项，以及为什么

| 选项 | 为什么否 |
|---|---|
| 引入 Lua（godot-lua 等） | 第三方依赖，违反 AGENTS.md 六；且 GDScript 在训练数据里，Lua 绑定不在 |
| 只做数据化行为（组合已有 brain） | 表达不了"这个箱子被扔出去就爆炸"。**没有脚本就没有 GMod** |
| 只用 `.pck` + `load_resource_pack()` | 需要导出工具链才能产出 pck；且 MC 式资源包本来就是文件夹，玩家能直接看能改 |
| 自己写 GDScript 沙箱 | 做不到。反射和 `OS` 通道绕得过去，做出来的是**虚假安全感**，比明确告知更危险 |
| 不区分 mod 级别 | 让玩家在不知情的情况下运行任意代码。用 warning 标出来，而不是偷偷放行 |

## 什么情况下应该推翻这个决定

- **导出包不支持运行时编译** → 行为开放改成"预编译 mod 为 `.pck` + 启动时 `load_resource_pack()`"，
  代价是 mod 作者需要装导出工具，必须写清楚。
- **mod 恶意代码成为真实事件** → 不再是信任问题而是安全问题，改成进程隔离：
  mod 跑在子进程，只通过 IPC 传事件。那时本 ADR 的"无沙箱"前提作废。
- **Godot 移除运行时脚本编译**（上游决策）→ 整条路要重选，届时 Lua 或 WASM 重新进入候选。
- **性能上 mod 脚本拖垮主循环** → 引入每帧脚本指令预算，超预算的 mod 被降频或停用
  （这是"预算由系统强制"在脚本层的版本，不是禁止脚本）。
