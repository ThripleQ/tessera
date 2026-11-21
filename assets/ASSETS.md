# 武器与音效来源

和角色一样：**文件即 id**，`assets/weapons/<id>.glb`、`assets/sfx/<id>.ogg`。
许可证必须可商用，这里每一项都记来源与改动。

## 武器

### akm_fps.glb

- **来源**：Poly Pizza — J-Toastie "Fps Rig AKM"
  <https://poly.pizza/m/U6l6wjxFhC>（文件直链
  <https://static.poly.pizza/c2ff5873-788f-42ac-b562-c6a530114671.glb>）
- **作者**：J-Toastie（<https://poly.pizza/u/J-Toastie>）
- **许可**：**CC-BY 3.0**（可商用，**必须署名**）。署名写在这里和 README 的
  「许可」一节；发布包改成本文件或 README 随附即可。
- **内容**：2 个蒙皮网格 `ArmModel` / `AKM_model`、12 个纯色材质、28 根骨、
  3 段动画 `Armature|Idle` / `Armature|Shoot` / `Armature|Reload`，
  6969 三角形，850 KB，**没有贴图**（颜色全在材质里）。
- **取用方式**：原样下载，未做任何修改。运行时用 `GLTFDocument` 直接读，
  不走 Godot 的导入管线（见 `gun_view.gd` 顶部的注释）。
- **为什么选它**：上一版是一把没有手、没有动画的低模枪，第一人称看起来像
  "漂浮的木头"。这个模型**自带绑骨手臂和 Idle / Shoot / Reload 三段动画** ——
  开火、换弹、待机的手部动作不用再手写，也省掉"再做一个角色手臂"这件
  不该手工建模的事。低模、纯色材质，和项目现有的卡通渲染是一路的。
- **没有采用枪口火焰贴图**：试过 OpenGameArt 的 CC0 火焰包，像素画风和
  低模场景冲突太大；现在的枪口火焰是程序生成的径向渐变（两片加法混合 quad
  加一盏点光），见 `gun_view.gd` 的 `_make_flash()`。

## 音效

### rifle_shot.ogg

- **来源**：OpenGameArt — "Gunshot Sounds"（原包含 CZ-52 / 莫辛纳甘 / SKS / 霰弹枪）
  <https://opengameart.org/content/gunshot-sounds>
- **作者**：Tabasco
- **许可**：CC0 1.0
- **改动**：从 `sounds/mosin.wav` 的 8.83 秒处裁 0.62 秒，转单声道 44.1 kHz，
  尾部 0.18 秒淡出。**这是唯一的改动，其余是原录音。**
- **为什么要裁**：原文件 14.7 秒，里面是一次完整的靶场录音（枪响 + 回声 + 环境音）。
  直接用会让每一发都带着上一发的回声尾巴。
