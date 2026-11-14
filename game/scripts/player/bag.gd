extends RefCounted

## 背包：世界里第一个**非物理状态**。
##
## 里面装着的内容 id 不对应任何节点 —— 不参与物理、不占生成预算、
## 不会被合批也不会被剔除。它只是一份"我有什么"的账。
##
## 为什么需要它（不是为了像 MC）：**收**这个动作必须有个去处。
## 右键如果只是把东西删掉，玩家就不敢动自己刚摆好的东西 ——
## 摆一件是花力气想清楚的，删掉是不可逆的损失，于是沙盒变成一个
## 只能加不能减的静态陈列柜。收进背包，东西还在，玩家才敢动手。
##
## 这里**只记 id 和件数**，不记位置、朝向、速度。背包里的东西没有位置：
## 「放出来」是重新造一件，不是把某个具体的物体搬回去。
## 这条区别是硬边界 —— 一旦要记住位置，就得在背包里模拟一个静止的世界，
## 那是另一个项目（而且和"存档只存玩家的动作"这条分界直接打架）。
##
## 容量上限是必要的：没有上限的容器等于"世界里的东西永不消失"，
## 而"收"的成本为零时，玩家会把整个世界捡干净，再也没东西可推。

## 128 件：比生成预算（96）大，所以"收完整个世界的造物"装得下。
## 背包小于预算的话，会出现"我拆了但装不下，东西凭空消失" —— 最坏的失败方式。
const CAPACITY := 128

## 内容包。**只用来问两个问题**：这东西能叠多少、值多少。
## 背包依然不认识节点、位置、物理 —— 那些是世界的事。
## 堆叠上限和价值是内容定义的（pickup 组件），引擎不写死数值，所以只能问内容。
var pack = null

## 内容 id -> 件数。
var _items: Dictionary = {}
## 第一次拿到的顺序。字典序会把"刚捡的那件"排到最后，
## 而玩家打开菜单时第一眼想看的恰恰是刚捡的东西。
var _order: Array[String] = []


func total() -> int:
	var n := 0
	for id in _items:
		n += int(_items[id])
	return n


func count(content_id: String) -> int:
	return int(_items.get(content_id, 0))


func is_full() -> bool:
	return total() >= CAPACITY


## 这一叠还能不能再加一件。判断顺序和 `add()` 一模一样 ——
## 调用方（准星、收物）先问这里再动手，"先拿走再发现装不下"就不可能发生。
func can_add(content_id: String) -> bool:
	if content_id.is_empty() or is_full():
		return false
	var lim := stack_limit(content_id)
	if lim > 0 and count(content_id) >= lim:
		return false
	return true


## 堆叠上限。0 = 不限（没有 pickup 组件的东西）。
func stack_limit(content_id: String) -> int:
	if pack == null:
		return 0
	return pack.stack_limit(content_id)


## 背包里全部东西的价值合计。没有 pickup 的东西价值 0 ——
## 木箱是拿来推的，不是拿来卖的，给它编一个价格才是撒谎。
func total_value() -> int:
	var v := 0
	if pack == null:
		return v
	for id in _order:
		if has(id):
			v += count(id) * pack.value_of(id)
	return v


## 这件东西背包里有没有（数量 > 0）。菜单用它决定要不要标 `×n`。
func has(content_id: String) -> bool:
	return count(content_id) > 0


## 收一件进来。返回 false = 背包满了，或者这一叠到了内容规定的堆叠上限。
##
## 满了**必须返回失败**而不是静默丢弃：调用方要靠这个返回值决定
## 要不要把世界里的那一件拿走。静默丢弃的表现是"东西收进来了但不见了"。
func add(content_id: String) -> bool:
	if not can_add(content_id):
		return false
	if not _items.has(content_id):
		_items[content_id] = 0
		_order.append(content_id)
	_items[content_id] = int(_items[content_id]) + 1
	return true


## 拿一件出来（放回世界时调用）。返回 false = 本来就没有。
func take(content_id: String) -> bool:
	var n := count(content_id)
	if n <= 0:
		return false
	n -= 1
	if n == 0:
		_items.erase(content_id)
		_order.erase(content_id)
	else:
		_items[content_id] = n
	return true


## 有库存的内容 id，按拿到的先后。菜单要按这个顺序排。
func ids() -> Array[String]:
	var out: Array[String] = []
	for id in _order:
		if has(id):
			out.append(id)
	return out


func clear() -> void:
	_items.clear()
	_order.clear()


# ---------------------------------------------------------------- 存档

## 存成 [{id, n}]。"n" 而不是 "count"：存档是要被人手看、手改的，
## 短键在几百行 JSON 里读起来差别很大。
func to_save() -> Array:
	var out: Array = []
	for id in _order:
		if has(id):
			out.append({"id": id, "n": count(id)})
	return out


## 读回。返回恢复了几种。
##
## **不假设内容还在**：mod 被卸载后它的东西会留在存档里。
## 这里照样收下，让菜单去跳过（菜单认识 pack，背包也认识 —— 但只问
## 堆叠上限和价值，不会因为内容没了就把玩家的东西丢掉）。
## 在背包这一层就丢掉，等于玩家卸载 mod 再装回来时"我的东西没了"。
func from_save(rows) -> int:
	clear()
	if not (rows is Array):
		return 0
	for row in rows:
		if not (row is Dictionary):
			continue
		var id := String((row as Dictionary).get("id", ""))
		var n := int((row as Dictionary).get("n", 1))
		if id.is_empty() or n <= 0:
			continue
		# 旧存档可能手改过，件数超过容量就压回去 —— 但要说出来，
		# 悄悄截断会让"我明明存了 200 个"永远得不到解释。
		var room := CAPACITY - total()
		# 堆叠上限同样压回去：内容把骨符定成 20 一叠，读档不该绕过它，
		# 否则"手改存档"就成了唯一的堆叠方式。
		var lim := stack_limit(id)
		if lim > 0:
			room = min(room, lim - count(id))
		if n > room:
			push_warning("背包存档超过容量 %d，%s 从 %d 压到 %d" % [CAPACITY, id, n, room])
			n = max(0, room)
		if n <= 0:
			continue
		if not _items.has(id):
			_order.append(id)
			_items[id] = 0
		_items[id] = int(_items[id]) + n
	return _items.size()


## 状态栏/自检用的一行摘要。
func describe() -> String:
	if _items.is_empty():
		return "空"
	var parts: Array[String] = []
	for id in ids():
		parts.append("%s×%d" % [id, count(id)])
	return "、".join(parts)
