extends SceneTree

## 第 12 步：一个 agent 新增的 mod，能不能只走公开通道做出真实物理玩法。
##
## 探针不认识 mod / 内容 id。它按「系统读写的组件具有脉冲语义字段」找到规则，
## 再分别找一件带该组件的机关与一件不带该组件的普通刚体。
## 四条断言：冲量真的发生、方向远离、冷却真的写回、冷却中不会连发。

const FIELDS: Array[String] = ["radius", "strength", "cooldown", "remaining"]

var _main
var _frames := 0
var _system_id := ""
var _component := ""
var _source_id := ""
var _target_id := ""
var _period := 0.25
var _source_handle := 0
var _target_handle := 0
var _source: RigidBody3D = null
var _target: RigidBody3D = null
var _ctx = null
var _before := Vector3.ZERO
var _after := Vector3.ZERO
var _remaining := 0.0
var _first_ok := false
var _direction_ok := false
var _state_ok := false
var _cooldown_ok := false


func _initialize() -> void:
	_main = load("res://main.tscn").instantiate()
	root.add_child(_main)
	physics_frame.connect(_on_physics_frame)


func _on_physics_frame() -> void:
	_frames += 1
	if _frames == 8:
		_setup()
	elif _frames == 12:
		_check_pulse()
	elif _frames == 16:
		_check_cooldown()


func _setup() -> void:
	var schema_components: Dictionary = _main.pack.schema.get("components", {})
	var systems: Dictionary = _main.pack.extension_systems()
	for raw_sid in systems:
		var spec: Dictionary = systems.get(raw_sid, {})
		for raw_component in spec.get("reads", []):
			var cname := String(raw_component)
			var fields: Dictionary = schema_components.get(cname, {}).get("fields", {})
			var matches := true
			for field in FIELDS:
				if not fields.has(field):
					matches = false
			if not matches:
				continue
			_system_id = String(raw_sid)
			_component = cname
			_period = float(spec.get("period", 0.25))
			break
		if not _system_id.is_empty():
			break

	for id in _main.pack.spawnables():
		if not _main.pack.places_as_rigid(id):
			continue
		var comps: Dictionary = _main.pack.components_of(id)
		if _source_id.is_empty() and comps.has(_component):
			_source_id = id
		elif _target_id.is_empty() and not comps.has(_component) \
			and not comps.has("move") and not comps.has("ai") and not comps.has("health"):
			_target_id = id
	for e in _main._systems._mod_systems:
		if String(e.get("id", "")) == _system_id:
			_ctx = e.get("ctx", null)
			break

	var discovered: bool = not _system_id.is_empty() and not _source_id.is_empty() \
		and not _target_id.is_empty() and _ctx != null
	print("RULE 发现：系统 %s / 组件 %s / 机关 %s / 普通目标 %s（%s）"
		% [_system_id, _component, _source_id, _target_id, discovered])
	if not discovered:
		_finish(false)
		return

	var at: Vector3 = _main._player.global_position + Vector3(0.0, 2.0, -2.0)
	var r_source: Dictionary = _main.api.spawn(_source_id, at, 0.0)
	var r_target: Dictionary = _main.api.spawn(_target_id, at + Vector3(1.0, 0.0, 0.0), 0.0)
	_source_handle = int(r_source.get("handle", 0))
	_target_handle = int(r_target.get("handle", 0))
	_source = _body_for(_source_handle)
	_target = _body_for(_target_handle)
	var spawned: bool = _source != null and _target != null
	print("RULE 生成：机关 handle %d / 目标 handle %d（%s）"
		% [_source_handle, _target_handle, spawned])
	if not spawned:
		_finish(false)
		return

	# 冲量要等物理步积分，不能在同一帧读。固定机关、去掉目标的重力与阻尼，
	# 再等 4 个物理帧读速度；目标不能 freeze，冻结刚体不会响应冲量。
	_source.freeze = true
	_target.freeze = false
	_target.gravity_scale = 0.0
	_target.linear_damp = 0.0
	_target.angular_damp = 0.0
	_target.linear_velocity = Vector3.ZERO
	_before = _target.linear_velocity
	_main._systems.step(_period)


func _check_pulse() -> void:
	_after = _target.linear_velocity
	var offset: Vector3 = _main.api.pos(_target_handle) - _main.api.pos(_source_handle)
	_first_ok = _before.length() < 0.001 and _after.length() > 0.1
	_direction_ok = _after.dot(offset) > 0.0 and _after.y > 0.0
	_remaining = float(_ctx.read(_source_handle, _component, "remaining"))
	_state_ok = _remaining > 0.0
	print("RULE 冲量：目标速度 %.3f → %.3f m/s（%s）"
		% [_before.length(), _after.length(), _first_ok])
	print("RULE 方向：速度点乘远离方向 %.3f / 向上 %.3f（%s）"
		% [_after.dot(offset), _after.y, _direction_ok])
	print("RULE 状态：冷却剩余 %.2f s（%s）" % [_remaining, _state_ok])
	if not _first_ok or not _direction_ok or not _state_ok:
		_finish(false)


func _check_cooldown() -> void:
	_target.linear_velocity = Vector3.ZERO
	_main._systems.step(_period * 0.5)
	var still_zero: bool = _target.linear_velocity.length() < 0.001
	var remaining_now := float(_ctx.read(_source_handle, _component, "remaining"))
	_cooldown_ok = still_zero and remaining_now < _remaining and remaining_now >= 0.0
	print("RULE 冷却：重复冲量 %s / 剩余 %.2f → %.2f s（%s）"
		% ["没有发生" if still_zero else "发生了", _remaining, remaining_now, _cooldown_ok])
	_finish(_first_ok and _direction_ok and _state_ok and _cooldown_ok)


func _body_for(handle: int) -> RigidBody3D:
	for body in _main._world.bodies:
		if int(body.get_meta("handle", 0)) == handle:
			return body
	return null


func _finish(ok: bool) -> void:
	print("RULE RESULT %s（冲量 %s / 方向 %s / 状态 %s / 冷却 %s）"
		% ["OK" if ok else "FAIL", "OK" if _first_ok else "FAIL",
			"OK" if _direction_ok else "FAIL", "OK" if _state_ok else "FAIL",
			"OK" if _cooldown_ok else "FAIL"])
	quit(0 if ok else 1)
