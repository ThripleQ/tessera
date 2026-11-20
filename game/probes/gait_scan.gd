extends SceneTree

## 步态扫描（**不是**验收步骤，是加角色时用的一次性工具）。
##
## 加一个角色要写 `<id>.json` 的 `gait`：哪几条片段算走 / 跑。可包里几十上百条动画
## （骑士包 76 条、骷髅包 95 条），名字也未必自解释 —— 挑之前得先看见每条多快。
##
## 它把目录里**每个**角色的**所有**片段按隐含地面速度列出来（口径与第 15 步一致，
## 都走 `stride.gd`），人肉挑两三档写进 json。不必进 `check.sh`：
## 这里没有断言，只有一个"该挑哪几条"的判断，判断不能自动化。
##
##   tools-bin/Godot_v4.6-stable_linux.x86_64 --headless --path game \
##       --script res://probes/gait_scan.gd

const CHARACTERS = preload("res://scripts/world/character_assets.gd")
const STRIDE = preload("res://scripts/world/stride.gd")


func _initialize() -> void:
	for id in CHARACTERS.character_ids():
		var c := CHARACTERS.character(String(id))
		if not c["ok"]:
			print("DUMP %s 加载失败：%s" % [id, c["error"]])
			continue
		var root: Node = c["root"]
		var ap: AnimationPlayer = null
		for n in root.find_children("*", "AnimationPlayer", true, false):
			ap = n as AnimationPlayer
			break
		var sk: Skeleton3D = null
		for n in root.find_children("*", "Skeleton3D", true, false):
			sk = n as Skeleton3D
			break
		var s: float = float(c["scale"])
		print("DUMP %s：%d 片段 / %.2f m / scale %.4f"
			% [id, (c["animations"] as PackedStringArray).size(), float(c["height"]), s])
		var rows: Array = []
		for clip in ap.get_animation_list():
			var m := STRIDE.clip_motion(ap.get_animation(clip), sk)
			if not m["ok"]:
				continue
			var spd: float = float(m["speed"]) * s
			var fwd: float = float(m["forward"]) * s
			# 只留"真的往正前方走"的：侧移、后退、原地动作都不要。
			if spd < 0.05 or fwd <= 0.0 or fwd < spd * 0.8:
				continue
			rows.append({"clip": String(clip), "speed": spd})
		rows.sort_custom(func(a, b): return float(a["speed"]) < float(b["speed"]))
		for r in rows:
			print("DUMP   %-28s %.3f m/s" % [r["clip"], r["speed"]])
		root.free()
	quit(0)
