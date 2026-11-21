extends SceneTree

## 一次性工具（不入 check.sh）：把目录里每个角色的**所有**片段列出来，
## 附隐含地面速度。目的是看包里有没有起步 / 刹车 / 转向类片段可用。

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
		var binds := _bind_poses(root)
		print("DUMP ==== %s（scale %.4f，binds %d）====" % [id, s, binds.size()])
		for clip in ap.get_animation_list():
			var a := ap.get_animation(clip)
			var m := STRIDE.clip_motion(a, sk, binds)
			var spd: float = float(m["speed"]) * s if m["ok"] else -1.0
			var fwd: float = float(m["forward"]) * s if m["ok"] else 0.0
			var duty: float = float(m["duty"]) if m["ok"] else 0.0
			print("DUMP  %-34s len %.2f  spd %7.3f  fwd %7.3f  duty %.2f  loop %s"
				% [clip, a.length if a != null else 0.0, spd, fwd, duty,
				   "Y" if (a != null and a.loop_mode != Animation.LOOP_NONE) else "n"])
		root.free()
	quit(0)


func _bind_poses(root: Node) -> Dictionary:
	var binds := {}
	var sk: Skeleton3D = null
	for n in root.find_children("*", "Skeleton3D", true, false):
		sk = n as Skeleton3D
		break
	if sk == null:
		return binds
	for i in sk.get_bone_count():
		var rest := sk.get_bone_rest(i)
		binds[sk.get_bone_name(i)] = rest.inverse()
	return binds
