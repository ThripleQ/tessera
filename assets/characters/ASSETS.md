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

## `<id>.json`

不是上游文件，是本地写给资产加载器的选项（格式见
`docs/decisions/0014-character-assets.md` 第 4 节）。现在只剩一项真正必写：

- **`gait`**：哪几条片段算"走路 / 跑步"。只有资产自己知道 ——
  自动筛选会把"从地上爬起来"当成步态（骷髅包实测混进了
  `Skeletons_Awaken_Standing`，0.74 m/s，看着完全像在走）。

**不用写**的是 `hide_prefix`：手里的东西一律挂在 `handslot.l/r` 之下，
加载器按位置自动摘掉。这条规则第一版是"每个角色写一份前缀名单"，
加第二个角色时就发现写不动了 —— 名字每家都不同，位置才是共性。
