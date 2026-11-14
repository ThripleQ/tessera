# asset_demo 的资源来源与投放方式

## 这个目录里的文件从哪来

`assets/meshes/prop_crate.gltf` 由本目录的 `make_sample.py` 生成（纯 Python，
无第三方依赖）：一个 8 三角形的钻石，用来盖掉引擎内置的 12 三角形木箱。

- **作者 / 来源**：tessera 项目自造，仅用于验证通道
- **许可**：CC0 1.0（公有领域贡献），可商用、免署名
- **几何**：24 个顶点、8 个三角形，POSITION / NORMAL / TEXCOORD_0，
  buffer 以 base64 内嵌，纯文本 JSON

为什么仓库里不直接放网上下载的模型：**CI 必须离线可验**。
资源站会改文件、会挂、会换许可，让验收依赖它等于埋一颗定时炸弹。
自造的最小 glTF 是"通道样品"，真实资源包由玩家自己投放 —— 这本来就是
资源包该有的样子：文件夹放进去就生效，不进版本库。

## 真实资源包怎么放

放一个文件夹进 `mods/`，里面只要有 `mod.toml` 和 `assets/meshes/`：

```
mods/my_skin/
  mod.toml
  assets/meshes/
    player_lowpoly.glb        # 换主角
    humanoid_lowpoly.glb      # 换骨行者
    prop_crate.gltf           # 换木箱
```

**文件名 = 契约里的网格 id**（见 `contract/registry.py` 的 `MESHES`）。
扩展名 `.gltf` / `.glb` 都认。没放文件的网格回退到引擎的程序化几何。
多个 mod 都放同一个 id 时，**后加载的压过先加载的**（按 mod id 排序，
玩家装的目录在仓库自带之后，见 `scripts/mods/loader.gd` 的 `search_paths()`）。

装完跑一次 `python3 tools/contentc.py --mod mods/my_skin --base content`
生成产物，再启动游戏。不需要改任何代码、不需要重新编译引擎、不需要 `--trust`。

### 优先用现成资源（用户 2026-11-14 拍板）

优先找 CC0 / 可商用、最好免署名的现成资源，不要自己造美术资产：

| 站点 | 内容 | 许可 |
|---|---|---|
| Kenney (kenney.nl) | 低模道具、UI、贴图 | CC0 |
| KayKit (kaylousberg.com) | 风格化角色 / 地牢包 | CC0 |
| Quaternius (quaternius.com) | 低模角色、动物、道具 | CC0 |
| Poly Haven (polyhaven.com) | 贴图 / HDRI | CC0 |
| Mixamo (adobe) | 骨骼动画 | 免费可商用，需 Adobe 账号 |

**入库前必须记下：来源 URL、作者、许可、下载日期，写进本文件。**
许可要求署名的，发布包里要带上署名文件。

### 目前还做不到的事（别误以为已支持）

- **骨骼动画 / 蒙皮**：这轮只把静态 glTF 网格取出来，骨骼与动画剪辑不读。
  接现成动画要单独设计（动画状态机、播放 API、与固定节拍系统的关系）。
- **贴图覆盖**：`assets/textures/` 还没接。它和 MultiMesh 的合批单位绑在一起
  （贴图按网格走，配色按内容走），是另一个独立决定，见 `docs/status.md` 下一步。
- **加一种全新的网格 id**：资源包只能**覆盖**契约里已有的槽位，和 MC 资源包一样。
  加新形状要动契约 / 编译器，是 L4 那样的扩展容器，不是资源包的事。
- **导出包未验证**：glTF 运行时加载只在编辑器二进制上验过（无头 + 窗口）。
  P6 公开发布前必须在 Linux / Windows 导出包里重测。
