extends RefCounted

## 玩家身上那个"看得见的人"。装哪套资产、跑多快、按 F8 换成谁 —— 全在这里。
##
## 和 `view.gd` 一样是拆出来的：`player.gd` 原本 449 行，同时管"怎么动"、
## "怎么看"、"长什么样"。三者混在一起时最容易发生的退化是**拿外观的解法
## 去修物理的问题**（比如"人跑得慢"最后改成调动画倍率，而真正错的是速度）。
##
## 这一层不知道玩家的胶囊、速度和输入。它只回答一个问题：
## 这套骨架的腿一秒钟能走多远，于是身体就该走多远（ADR 0015）。

const CHARACTER_ASSETS = preload("res://scripts/world/character_assets.gd")
const RIG = preload("res://scripts/player/character_rig.gd")

var rig = null
## 由动画反推的走 / 冲刺速度。为 0 表示没量出来（资产缺失），调用方用兜底值。
var walk_speed := 0.0
var run_speed := 0.0
## 换角色时要原样传回去的两色。存下来是因为 `swap()` 要求它们每次都给，
## 而它们对"换谁"没有影响 —— 只是皮肤。
var _color := Color.WHITE
var _eye := Color.WHITE


## 建一棵带动画的树。失败返回 false —— 调用方要退回程序化几何，
## 而不是留一片空白：资产目录是可以整个删掉的，删掉之后游戏必须还能跑。
func build(parent: Node3D, id: String, color: Color, eye: Color) -> bool:
	rig = RIG.new()
	rig.name = "rig"
	parent.add_child(rig)
	if not rig.setup(id, color, eye):
		return false
	_measure()
	return true


## 量步速。换角色必须重量 —— 不同包腿不一样长，沿用上一个角色的速度就是让它滑。
func _measure() -> void:
	var w: float = rig.gait_walk()
	var r: float = rig.gait_run()
	if w <= 0.0 or r <= w:
		walk_speed = 0.0
		run_speed = 0.0
		return
	walk_speed = w
	run_speed = r


## 换下一个角色。返回换上的是谁，空串表示没换成。
##
## 这不是"换装系统"，是**通道的验收**：如果加一个角色需要改代码，
## 那么"丢个文件夹就能玩"这句话就是假的。所以名单只有一个来源 ——
## `assets/characters/` 目录里有什么文件，就能按什么顺序挨个试。
func cycle() -> String:
	var ids := CHARACTER_ASSETS.character_ids()
	if ids.size() < 2 or rig == null:
		return ""
	# `rig` 是 untyped 的，这一句必须显式写 String：`:=` 推不出来，
	# 而那个 Parse Error 只在真正加载这个文件的时候才炸（游戏或探针）。
	var cur: String = rig.character_id()
	var at: int = ids.find(cur)
	# 找不到当前角色（第一次跑、或者那个文件被删了）时从头开始。
	var next := String(ids[0] if at < 0 else ids[(at + 1) % ids.size()])
	if not rig.swap(next, _color, _eye):
		return ""
	_measure()
	return next


## 换角色时要原样传回去的两色。存下来是因为 `swap()` 要求它们每次都给，
## 而它们对"换谁"没有影响 —— 只是皮肤。
func remember_colors(color: Color, eye: Color) -> void:
	_color = color
	_eye = eye


func tier_count() -> int:
	return rig.tier_count() if rig != null else 0


func clip_count() -> int:
	return rig.clip_count() if rig != null else 0
