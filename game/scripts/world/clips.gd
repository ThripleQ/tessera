extends RefCounted

## 片段表：这个角色的「待机 / 走 / 跑 / 跳 / 落地」各是哪条动画。
##
## 从 character_assets 里分出来，因为它回答的是另一个问题：
## 那边管"把 glb 变成一棵能穿的树"，这里管"树上的哪根枝叫什么名字"。
## 加一个角色包就会动这个文件，而加载流程不该跟着变。
##
## 为什么需要它：换一个包，同一个动作叫法完全不同 ——
## KayKit 叫 `Walking_A`，Quaternius 叫 `HumanArmature|Man_Walk`。
## 名字是各家的自由，**词尾**才是共性。所以先按后缀认，认不到才退回精确名。

## 兜底名（KayKit 的叫法）。后缀全认不出来时才用它。
const ROLES := {
	"idle": "Idle",
	"walk": "Walking_A",
	"run": "Running_A",
	"jump_up": "Jump_Start",
	"jump_air": "Jump_Idle",
	"land": "Jump_Land",
}

## 后缀表：顺序即优先级，更具体的放前面（`Walking_A` 比 `Walk` 更具体）。
##
## 只认词尾、不认词头，是为了避开 `Idle_Gun` 这类"前面沾了同一个词"的片段 ——
## 按词头认的话，枪的待机会被当成普通待机。
const SUFFIX := {
	"idle": ["Idle", "Idle_Neutral"],
	"walk": ["Walking_A", "Walk", "Walking"],
	"run": ["Running_A", "Run"],
	"jump_up": ["Jump_Start", "Jump"],
	"jump_air": ["Jump_Idle", "Jump"],
	"land": ["Jump_Land", "Land"],
}


## 返回 {角色: 片段名}。`declared` 来自资产的 `<id>.json`（`clips` 字段），
## 写了就完全听它的 —— 名字完全不合套路的包只有这一条路。
static func resolve(anims: PackedStringArray, declared: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for role in ROLES.keys():
		if declared.has(role):
			out[role] = String(declared[role])
			continue
		var found := ""
		for suffix in SUFFIX.get(role, []):
			for a in anims:
				var s := String(a)
				if s == suffix or s.ends_with(String(suffix)):
					found = s
					break
			if found != "":
				break
		out[role] = found if found != "" else String(ROLES[role])
	return out
