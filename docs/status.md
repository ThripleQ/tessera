# 进度

> 每次会话结束前更新这一页。下一个 agent 靠它接续。
> 最后更新：2026-11-13

## 现在在哪

**阶段 P0（底座）刚开工。**

已完成：
- 内容层与契约：`content/` `mods/` `contract/registry.py` `tools/contentc.py` 可用
- 契约校验：拼错组件名、枚举越界、继承环、数值越界都会编译失败
- 热重载：改 TOML 输出字段级差异（`tools/hotreload.py`）
- Godot 4.6 stable 在本机验证可运行（`--version` 正常）
- 仓库骨架、目录纪律、验收入口已建立

未完成：
- Godot 侧还没读 `content.pack.json`，也还没有任何画面
- `content/room/*.toml` 里的房间定义还没有任何代码消费它

## 下一步（按顺序，不要跳）

1. **P0-a**：`game/scripts/content/` 读 pack，无头模式下打印条数与网格数，与 `pack.json` 对齐
2. **P0-b**：`game/scripts/world/` 按 chunk 生成 `MultiMeshInstance3D`，配对 `visibility_range`
3. **P0-c**：把 draw call / 可见数 / 帧时写进 `check.sh` 的输出，与 `legacy/cpp-renderer` 的基线对照

## 已知问题

- 无 GPU 直通（无 `/dev/dri`），本机 Godot 只能走软件光栅，帧时没有参考价值；画面与数字仍可信
- `legacy/cpp-renderer` 的构建目录已清理，需要时重新 `cmake -S game -B game/build`

## 待定（需要人拍板）

- 仓库名 `tessera` 是临时的，随时可改
- 是否要在 P3 之后引入 Lua 作为 mod 脚本语言（现在 Godot 的 GDScript 够用，但对 mod 作者门槛高）
