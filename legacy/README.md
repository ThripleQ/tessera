# 归档：不参与构建

这里的代码**不再维护**，也不被 `check.sh` 检查。保留它们只有一个理由：它们是证据。

## `cpp-renderer/`

早期自研的 C++17 + OpenGL 3.3 渲染器。真的跑通过：3 万条内容、3 次 `glDrawArraysInstanced`、
8 盏光源上限、EGL 离屏出图、X11 窗口 + WASD。`docs/media/` 里的图和录像就是它出的。

被归档的原因见 `docs/decisions/0001-engine-godot.md`：沙盒的瓶颈是物理和网络，不是 draw call。

**它产出的数字仍然有用**，是 Godot 侧的对照基线：

| 场景 | 可见 | draw call | 三角形 |
|---|---|---|---|
| 3 万条内容，正常密度 | 174 | **3** | 10212 |
| 3 万条，挤在 200×200 | 5220 | **3** | 313668 |
| 关掉合批（同密度） | 174 | **174** | 10212 |

需要重新编译时：

```bash
cd legacy/cpp-renderer
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build build
```

## `python-reference/`

同一套 ECS / 漏斗逻辑的 Python 参考实现。保留它是为了验证"用第二种语言重写一遍"
能不能得出同样的数字——这是检验架构描述有没有歧义的最快方法。

**不要往这两个目录里加新代码。** 需要复活某个想法，就把它重写进 `game/`，而不是改这里。
