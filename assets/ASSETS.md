# 武器与音效来源

和角色一样：**文件即 id**，`assets/weapons/<id>.glb`、`assets/sfx/<id>.ogg`。
许可证必须可商用，这里每一项都记来源与改动。

## 武器

### rifle.glb

- **来源**：Quaternius — 低模枪械集，经 Poly Pizza 的 CDN
  <https://static.poly.pizza/da83f4f9-7a4e-4739-9033-79d688aa3b5e.glb>
- **作者**：Quaternius（<https://quaternius.com>）
- **许可**：CC0 1.0（可商用、免署名）
- **内容**：1 个网格 `Weapon_Rifle`、1 个材质 `Atlas`、1 张内嵌贴图、
  **没有动画、没有骨骼**，63 KB。
- **取用方式**：原样下载，未做任何修改。
- **为什么选它**：低模、单网格、无动画 —— 后坐力用代码做（位移 + 旋转的弹簧回位），
  比绑一套骨骼动画便宜，而且每个数字都能在 TOML 里调。

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
