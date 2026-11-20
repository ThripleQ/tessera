# 角色资产来源

这个目录就是"能玩哪些角色"的全部真相：**文件名即 id**，丢一个 `.glb` 进来
（可选再配一个同名 `.json`），游戏里按 F8 就能换过去。

## knight.glb

- **来源**：KayKit — Character Pack: Adventurers 1.0
  <https://github.com/KayKit-Game-Assets/KayKit-Character-Pack-Adventures-1.0>
- **作者**：Kay Lousberg（<https://kaylousberg.com>）
- **许可**：CC0 1.0（可商用、免署名，见同目录 `KayKit-LICENSE.txt`）
- **取用方式**：`git clone --depth 1` 官方仓库，取
  `addons/kaykit_character_pack_adventures/Characters/gltf/Knight.glb` 原样拷贝，未做任何修改。
- **内容**：15 个网格、41 根骨骼、76 个动画片段、贴图内嵌（1024×1024 渐变图集）。

## mage.glb

- **来源**：同一个包（Adventurers 1.0），`.../Characters/gltf/Mage.glb` 原样拷贝。
- **内容**：12 个网格、41 根骨骼、76 个动画片段。与 knight 共用骨架，
  所以步态点的是同样三条片段。
- **加它的理由**：验证"多角色"不是一个角色的运气 —— 尤其是**帽子**。
  法师的尖顶帽比人头还高 0.8 m，把帽子算进身高会让整个法师缩到 0.56 倍。

## skeleton.glb

- **来源**：KayKit — Character Pack: Skeletons 1.0
  <https://github.com/KayKit-Game-Assets/KayKit-Character-Pack-Skeletons-1.0>
  取 `addons/kaykit_character_pack_skeletons/Characters/gltf/Skeleton_Minion.glb`
  原样拷贝，用 `md5sum` 比对过与上游逐字节一致（同一作者、同一 CC0 许可）。
- **内容**：9 个网格、41 根骨骼、**95 个动画片段**（比冒险者包多出起身、
  复活、受击、各种武器动作），材质含一张自发光（眼睛）。
- **加它的理由**：它是**另一份资产**，不是同一个包的另一个模型 ——
  动画集不同、身体部件不同、还带自发光材质。它证明通道吃的是资产结构，
  而不是"KayKit Adventurers 这四个"。

## man.glb

- **来源**：Quaternius — Ultimate Modular Characters（<https://quaternius.com>）
  glb 取自 Poly Pizza 的 CDN：<https://poly.pizza/m/nIItLV9nxS> 同作者同款，
  直接 `curl` 原文件，未做任何修改。
- **许可**：CC0 1.0（Poly Pizza 该模型页标注 CC0；作者自己也把整包放 CC0）。
- **内容**：1 个蒙皮网格（3967 顶点）、31 根骨骼、**11 条动画**、
  6 个纯色材质（Shirt / Skin / Pants / Eyes / Socks / Hair）、**零贴图**。
- **为什么选它**：这是全目录里唯一"一眼看得出是人、身上没有一件多余东西"的模型 ——
  没有盔甲、没有披风、没有武器插槽、没有渐变图集。剪影干净，
  配色就是六块平涂。要的正是这个。
- **已知缺陷（重要）**：**它的走路动画脚几乎不动。** 一个循环里脚的水平行程
  只有约 14 cm，而 1.35 m/s 的步速需要约 70 cm。所以按正常速度走，脚会明显打滑。
  这个包的动作是"原地踏步"式的，不是带动画位移的那种。
  它适合当"长得对的人"，不适合当"步速能对上的人"。
- **另外两处踩到的坑**：骨架挂在 **100 倍缩放**的节点下（自动测量会小一个数量级，
  而且数字看起来正常）；网格法线不规整，**反向外扩的描边会炸成一屏黑碎片**
  （所以 `man.json` 里 `"outline": false`）。

## `<id>.json`

不是上游文件，是本地写给资产加载器的选项（格式见
`docs/decisions/0014-character-assets.md` 第 4 节）。现在有四项：

- **`gait`**：哪几条片段算"走路 / 跑步"。只有资产自己知道 ——
  自动筛选会把"从地上爬起来"当成步态（骷髅包实测混进了
  `Skeletons_Awaken_Standing`，0.74 m/s，看着完全像在走）。

**不用写**的是 `hide_prefix`：手里的东西一律挂在 `handslot.l/r` 之下，
加载器按位置自动摘掉。这条规则第一版是"每个角色写一份前缀名单"，
加第二个角色时就发现写不动了 —— 名字每家都不同，位置才是共性。

另外两项：

- **`speeds`**：手工标定的"这条片段隐含多少米每秒"。只给**自动测不准**的资产用
  （`man.glb` 就是：骨架缩放在 100 倍节点上，测出来是 0.006）。
  标定与实测在输出里是分开的两档（`source` 写"标定"），不许混。
- **`outline`**：`false` 关掉描边。法线不规整的包会被反向外扩炸成黑碎片。
