# 角色资产来源

## knight.glb

- **来源**：KayKit — Character Pack: Adventurers 1.0
  <https://github.com/KayKit-Game-Assets/KayKit-Character-Pack-Adventures-1.0>
- **作者**：Kay Lousberg（<https://kaylousberg.com>）
- **许可**：CC0 1.0（可商用、免署名，见同目录 `KayKit-LICENSE.txt`）
- **取用方式**：`git clone --depth 1` 官方仓库，取
  `addons/kaykit_character_pack_adventures/Characters/gltf/Knight.glb` 原样拷贝，未做任何修改。
- **内容**：15 个网格、41 根骨骼、76 个动画片段、贴图内嵌（1024×1024 渐变图集）。
- **为什么只放一个**：另外三套（Barbarian / Mage / Rogue）留在原包里。
  换角色是拷一个文件进去、改 `player.gd` 里 `CHARACTER_ID` 一行的事 ——
  把四套都塞进仓库只会让 clone 变慢。

## knight.json

不是上游文件，是本地写给资产加载器的选项：KayKit 把**全部武器与盾牌**都绑在
同一个骨架上（一加载就是五把武器四张盾），这里按名字前缀把它们隐藏。
格式见 `docs/decisions/0014-character-assets.md` 第 4 节。
