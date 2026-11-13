# 进度

> 每次会话结束前更新这一页。下一个 agent 靠它接续。
> 最后更新：2026-11-13（第二轮：架构加固）

## 现在在哪

**仓库：https://github.com/ThripleQ/tessera （public，main，CI 绿）**
**阶段 P0（底座）基本完成。架构纪律已经可执行，不再只靠自觉。**

已完成：

- 内容层与契约：`content/` `mods/` `contract/registry.py` `tools/contentc.py` 可用
- 契约校验：拼错组件名、枚举越界、继承环、数值越界都会编译失败
- 热重载：改 TOML 输出字段级差异（`tools/hotreload.py`）
- **P0-a**：`game/scripts/content/pack.gd` 读 pack，自检打印「8 条 / 可摆放 4 / 网格 3 / 配色 3」
- **架构守卫**：`tools/lint_arch.py` 六条规则接进 `check.sh` 第 2 步，违规即失败
- **契约到达引擎**：`pack.schema` 随包走，缺 schema 的包被拒绝加载（ADR 0002）
- **两个开放通道已实测**：运行时 GDScript 编译、目录资源 overlay 都可行（ADR 0003）
- CI：checkout → 拉 Godot → `./check.sh`，与本地同一脚本

未完成：

- `content/room/*.toml` 还没有代码消费
- 引擎侧组件实现 **0 / 12**（内容用到的 12 个组件一个都还没实现）
- 还没有任何画面

## 下一步（按顺序，不要跳）

1. **P0-b**：`game/scripts/world/` 按 chunk 生成 `MultiMeshInstance3D`，配对 `visibility_range`
2. **P0-c**：把 draw call / 可见数写进 `check.sh`，与 `legacy/cpp-renderer` 基线对照
   （注意：那组基线测的是静态实例，不是沙盒负载）
3. **P1**：走、跳、抓、扔 + 组件实现清单从 `0/12` 开始往上填

## 已知问题 / 必须记住的坑

- **无 GPU 直通**（无 `/dev/dri`），只能软件光栅，帧时没有参考价值；画面与数字仍可信
- **导出包未验证**：运行时 GDScript 编译只在编辑器二进制上验证过。P6 发布前必须用
  真实导出包重跑 ADR 0003 里的探针，否则可能"开发能跑、发出去 mod 全废"
- **mod 无沙箱**：`OS.execute` 实测可执行。mod 必须分级，`scripted` 需玩家显式授权
- `legacy/cpp-renderer` 构建目录已清理，需要时重新 `cmake -S game -B game/build`

## 待定（需要人拍板）

- 仓库名 `tessera` 是临时的，随时可改
- 是否要在 P5 之后引入 Lua 作为 mod 脚本语言（ADR 0003 已否，理由：GDScript 在训练数据里）
