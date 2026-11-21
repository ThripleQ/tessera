extends Node3D

## 第三人称里别人看见的那把枪。**和第一人称的视图模型是同一份 glb**，
## 只是这里只留枪身（资产自带的第一人称手臂藏掉）。
##
## 为什么必须有它：第一人称的枪是相机空间的模型，切到第三人称就藏起来了 ——
## 于是玩家看到一个空着手的法师，手里那把枪凭空消失。
## "什么就是什么"的第一条：**枪在两种视角里都得存在**，只是从不同的眼睛看。
##
## 它不参与开火：子弹的起点、伤害、后坐仍然归 `gun.gd`。
## 这里只管"别人看见的那把枪长什么样"。

const MODEL_SUBDIR := "assets/weapons/akm_fps.glb"
## 模型在**世界空间**里的缩放。0.10 时全长约 0.45 米 ——
## 法师只有 1.5 米高，照真枪 0.88 米摆会拖到地上。
const GUN_SCALE := 0.10
## 手骨位置之上的微调：枪的握把比手心高一点、靠前一点。
## 这两个数是看着截图量的，改完要重新截图 —— 否则枪会穿进手掌。
const HOLD_LIFT := 0.04
const HOLD_FWD := 0.06
## 枪口向下压的弧度（约 20°）。这不是为了好看：法师的帽子有一米宽，
## 水平端着的枪在第三人称背后会被帽檐和袍子完全挡住。低戒备角度
## 既像真的在"提着枪走路"，也让枪管从身体轮廓下方露出来。
const HOLD_PITCH := -0.35
## 枪口再往右偏一点（约 17°）。和压枪口是同一个理由：身体是圆的，
## 枪管沿着正中线指出去，从背后看就只剩一个枪托截面。偏出身体轮廓，
## 玩家才认得出"这是一把枪"，而不是"腰上挂了个黑东西"。
const HOLD_YAW := -0.30
## 找不到手骨时的退路：挂在身体右侧，按固定偏移摆。
## 位置不完美，但枪还在 —— 而不是凭空消失。
const FALLBACK_POS := Vector3(0.45, 0.86, -0.30)
const FALLBACK_YAW := 0.95
const FALLBACK_ROLL := -0.08

var _model: Node3D = null
var _anim: AnimationPlayer = null
var _shoot := ""
var _idle := ""
## 右手挂点。每帧读它的世界位置，于是待机、走路、转身时枪都跟着手走。
var _hand: Node3D = null


func _ready() -> void:
	var path: String = ProjectSettings.globalize_path("res://") \
			.path_join("..").path_join(MODEL_SUBDIR)
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	if doc.append_from_file(path, state) != OK:
		push_error("第三人称的枪读不出来：%s（角色会空着手）" % path)
		return
	_model = doc.generate_scene(state)
	if _model == null:
		push_error("第三人称的枪生不成场景：%s" % path)
		return
	_model.scale = Vector3.ONE * GUN_SCALE
	# 只留枪。这个资产自带第一人称的手臂，而角色已经有自己的手臂了 ——
	# 不藏的话，第三人称里会多出一双绿色的袖子。
	var arms := _find(_model, "ArmModel")
	if arms is MeshInstance3D:
		(arms as MeshInstance3D).visible = false
	_anim = _find(_model, "AnimationPlayer") as AnimationPlayer
	if _anim != null:
		_anim.playback_default_blend_time = 0.05
		for n in _anim.get_animation_list():
			var tail := String(n).to_lower()
			if tail.ends_with("shoot"):
				_shoot = n
			elif tail.ends_with("idle"):
				_idle = n
		# 播待机而不是停在绑定姿势：绑定姿势里枪和手臂的相对位置
		# 和"拿着"不是一回事，播了 Idle 才是模型作者调好的握枪角度。
		if not _idle.is_empty():
			_anim.play(_idle)
	add_child(_model)
	_attach()


## 找到右手骨，并决定这杆枪从哪儿长出来。
##
## 为什么不干脆把手骨当父节点：骨头自己的坐标轴长短不一（这个骨架的
## 手骨 Y 轴朝上），往里塞旋转等于在猜。这里只借它的**世界位置**，
## 朝向直接用玩家自己的前向 —— "枪口朝前"是一句人话，不是矩阵。
func _attach() -> void:
	var sk := _find_skeleton(get_parent())
	if sk != null:
		_hand = _bone_attachment(sk)
	if _hand == null:
		# 没有骨架：退回挂在身体旁边。位置不完美，但枪还在。
		position = FALLBACK_POS
		rotation = Vector3(0.0, FALLBACK_YAW, FALLBACK_ROLL)


func _process(_delta: float) -> void:
	# 按 F8 换角色时，整棵骨架被换掉，原来那个手骨就失效了。
	# 不重新找的话，从这里开始每帧都会对着一个已释放的对象取位置。
	if not is_instance_valid(_hand):
		_hand = null
		_attach()
	if _hand == null:
		return
	var body: Node3D = get_parent()
	var fwd := -body.global_transform.basis.z
	fwd.y = 0.0
	if fwd.length_squared() < 0.0001:
		return
	fwd = fwd.normalized()
	# 模型的长轴是 +X（枪口朝 +X），所以基的第一列放前向；
	# 第三列 = 前向 × 上，保证右手系。
	var b := Basis(fwd, Vector3.UP, fwd.cross(Vector3.UP)).orthonormalized()
	# 绕玩家的右轴压枪口。负角 = 枪口向下。
	b = Basis(Vector3.UP, HOLD_YAW) * b
	b = b.rotated(fwd.cross(Vector3.UP), HOLD_PITCH)
	var at: Vector3 = _hand.global_position + Vector3.UP * HOLD_LIFT - fwd * HOLD_FWD
	global_transform = Transform3D(b, at)


## KayKit 的约定是 `handslot.r`（专门放道具的空骨）；别的包可能只有
## `hand.r`。两个都试 —— 名字是资产的事实，不是我们这边能定的契约。
func _bone_attachment(sk: Skeleton3D) -> BoneAttachment3D:
	for n in ["handslot.r", "hand.r"]:
		var i := sk.find_bone(n)
		if i >= 0:
			var att := BoneAttachment3D.new()
			att.name = "gun_hand"
			att.bone_name = sk.get_bone_name(i)
			sk.add_child(att)
			return att
	return null


## 第一人称隐藏、第三人称显示。由 `gun.gd` 在切视角时调用。
func set_shown(shown: bool) -> void:
	visible = shown


## 模型真的读出来了吗。探针用：文件缺失时这个节点还在，
## 只是里面什么都没有 —— 那不算"第三人称有枪"。
func model_ok() -> bool:
	return _model != null


## 开火时动一下枪机。第一人称看不见它；但以后允许第三人称开火时，
## 别人看到的会是同一件事：枪在响。
func pulse() -> void:
	if _anim != null and not _shoot.is_empty():
		_anim.play(_shoot)


func _find_skeleton(n: Node) -> Skeleton3D:
	if n is Skeleton3D:
		return n as Skeleton3D
	for c in n.get_children():
		# 跳过自己：枪内部也有一副骨架（AKM 的手臂），
		# 那是给枪用的，不是给角色挂枪用的。
		if c == self:
			continue
		var r := _find_skeleton(c)
		if r != null:
			return r
	return null


func _find(n: Node, want: String) -> Node:
	if String(n.name) == want:
		return n
	for c in n.get_children():
		var r := _find(c, want)
		if r != null:
			return r
	return null