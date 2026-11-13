extends Node3D

## 入口。只做组装，不写业务逻辑（见 AGENTS.md 铁律 3）。
## 无头自检：godot --headless --path game -- --selftest
##
## 用 preload 而不是 class_name：全局类需要编辑器导入一遍才注册，
## 而 CI 里的无头模式没跑过编辑器。preload 不依赖任何缓存。

const PACK_SCRIPT = preload("res://scripts/content/pack.gd")

const PACK_PATH := "res://content.pack.json"

var pack


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var selftest := "--selftest" in args

	pack = PACK_SCRIPT.new()
	if not pack.load_from(PACK_PATH):
		get_tree().quit(1)
		return

	print(pack.summary())

	if selftest:
		var ok: bool = pack.entities.size() > 0 and pack.mesh_ids().size() > 0
		if not ok:
			printerr("自检失败：内容包为空或没有可用网格")
			get_tree().quit(1)
			return
		print("自检通过")
		get_tree().quit(0)
