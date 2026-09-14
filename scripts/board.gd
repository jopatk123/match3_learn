extends Node2D
# =====================================================================
# 开心消消乐 · 棋盘脚本
# 已实现：M1–M6 核心规则 + M7.1 锁输入 + M7.2 交换滑动
# 【M7.1 一句话】棋盘在「结算 / 动画」时是忙碌的：忙碌期间点击全部丢掉。
# 【M7.2 一句话】交换不再瞬间换色，而是两块滑向对方；滑完再问「有没有三连」。
#   有 → 坐下（节点弹回自己的格子、颜色跟上数据），再走原来的消除结算。
#   没有 → 滑回去（回弹），数据不动。这一步才让「乱换」看起来像被拒绝。
#   滑动这段时间 _busy 一直为 true，M7.1 那把锁终于能被肉眼感觉到。
# ---------------------------------------------------------------------
# 【M3 新增一句话】消消乐的灵魂是一句大白话：
#   交换之后，只要"横着或竖着连续 3 个以上同色"，就一起消失（斜的不算）。
# 我们把"找连续同色"和"把它们清掉"分成了两件事：
#   _find_matches() 只负责"找"，_eliminate() 只负责"清"。
# 这样思路干净，M4 下落、M6 连锁都复用同一套扫描。
# 【M6 一句话】棋盘必须"结算到稳定"：消完下落如果又出现三连，就再消，
#   直到扫不到三连为止。只消一轮会把新三连留在棋盘上，那是规则没做完。
# ---------------------------------------------------------------------
# 【最重要的一张图】数据与显示分离
#
#    board（数据层）     _tiles（显示层）
#    ┌───────────┐       ┌───────────┐
#    │ 数字数组   │  ──→  │ ColorRect │
#    │ board[r][c]│ 同步   │ 节点矩阵   │
#    │ = 颜色编号 │  color │ 画在屏幕上│
#    └───────────┘       └───────────┘
#
#  以后做"交换 / 消除 / 下落"全部只改 board（数字），
#  再通过 _refresh_tile() 把颜色同步到一个格子上，画面就自动变。
#  这是整个项目的核心思想，先记住这句话：
#      「算的数写在 board，画的色由 _tiles 负责，中间用 _refresh_tile 连接。」
# =====================================================================


# ---------------------------------------------------------------
# 常量区：固定的"配置值"。用大写表示它们是常量，别在运行中改。
# ---------------------------------------------------------------

# 棋盘有几行、几列（8x8）
const ROWS := 8
const COLS := 8
# 每个方块在屏幕上占多少像素（边长 64px）
const CELL_SIZE := 64
# NONE 表示"当前没有任何格子被选中"。用 (-1,-1) 这个永远到不了的坐标当"空"。
const NONE := Vector2i(-1, -1)
# EMPTY 表示"这一格已经被消除，暂时空着"。用 -1 这个颜色编号里不存在的数当"空"。
const EMPTY := -1

# ⑥ M6：连锁的"保险丝"。正常玩法要一直消到棋盘稳定；
#   这个上限只防极端情况下随机补块形成几乎无穷的连锁，把游戏卡死。
#   8 太小——8x8 四色很容易连过 8 轮，轮次用尽就会把三连留在棋盘上。
const CHAIN_LIMIT := 64

# 四种颜色（现在是纯色占位，将来可替换成方块的图片）
const COLORS := [
	Color(0.92, 0.30, 0.28), # 红
	Color(0.28, 0.56, 0.92), # 蓝
	Color(0.96, 0.74, 0.14), # 黄
	Color(0.34, 0.78, 0.46), # 绿
]

# 空格的显示色（深灰半透明）——用来"标记一个洞"，让玩家看到哪里被消掉了。
const EMPTY_COLOR := Color(0.15, 0.15, 0.15, 0.6)

# 被选中时，把方块颜色"调亮"到这个倍率（>1 更亮）
const HIGHLIGHT := Color(1.2, 1.2, 1.2)
# 没选中的正常色（白色=不改变原色）
const NORMAL := Color.WHITE
# ⑧ M7.2：两块滑过去 / 滑回来各用这么多秒。数字越大动作越慢，方便看清楚。
const SWAP_DURATION := 0.18


# ---------------------------------------------------------------
# 变量区：程序运行过程中会变化的数据
# ---------------------------------------------------------------

# 数据层：board[r][c] = 0~3 的数字（索引 COLORS 用）
#   注意方向！r 是"行"（上下），c 是"列"（左右）
var board: Array = []

# 显示层：和 board 对应的一张"网表"，
#   _tiles[r][c] 就是画在（行r, 列c）的那个 ColorRect 节点
var _tiles: Array = []

# 交互状态：当前被高亮的格子坐标（也是"行列"），NONE 表示空闲
#   用下划线前缀 _ 表示"内部私有变量"，提醒自己别在别处乱碰
var _selected := NONE

# ⑦ M7.1：棋盘忙不忙。true = 正在滑动 / 回弹 / 结算，这时不接受新点击。
#   它是交互状态机的第三种状态：空闲未选 / 已选中某格 / 忙碌。
var _busy := false

# ⑤ M5 计分：当前累积的总分
var score: int = 0
# 显示分数的文字标签（显示层的一部分，和 _tiles 是一家人）
var _score_label: Label = null


# ---------------------------------------------------------------
# 生命周期：节点一进入场景树就自动调用的入口函数（只跑一次）
# ---------------------------------------------------------------

func _ready() -> void:
	randomize() # 每次打开游戏用不同随机种子，棋盘才不会千篇一律
	_build_data() # 第一步：往 board 里填颜色编号（逐格避开三连）
	_build_view() # 第二步：按 board 生成 64 个 ColorRect 画出来
	# 开局再结算一次：生成兜底万一还有三连，瞬间消干净。分数清零，不算开局分。
	# 和游戏中同一套锁：结算时点不动。开局其实还点不到（画面刚出来），但规则要统一。
	_busy = true
	_resolve_matches()
	_busy = false
	score = 0
	_score_label.text = "0"


# ---------------------------------------------------------------
# 数据层：负责"算"，不负责"画"
# ---------------------------------------------------------------

# 生成 8x8 开局。从左到右、从上到下逐格放，
# 放之前先问"这个颜色会不会跟已经放好的格子构成横/竖三连"。
func _build_data() -> void:
	board.clear()
	# 先铺一层 EMPTY，这样放第 (r,c) 格时，board[r][c] 已经能按下标访问。
	for r in ROWS:
		var row: Array = []
		for c in COLS:
			row.append(EMPTY)
		board.append(row)

	for r in ROWS:
		for c in COLS:
			board[r][c] = _pick_color_without_match(r, c)


# 格子 (r,c) 是否在棋盘里面。后面生成、扫描都会用到，抽出来避免重复写四个不等式。
func _in_bounds(r: int, c: int) -> bool:
	return r >= 0 and r < ROWS and c >= 0 and c < COLS


# 在 (r,c) 放入 color 之后，会不会立刻跟"已经填好的格子"构成横/竖三连。
# 按行优先从左上往右下填，只需往已经填过的方向看两格：左（横）、上（竖）。
func _would_match_at(r: int, c: int, color: int) -> bool:
	var backs := [
		Vector2i(-1, 0), # 左（横）
		Vector2i(0, -1), # 上（竖）
	]
	for d in backs:
		var r1: int = r + d.y
		var c1: int = c + d.x
		var r2: int = r + d.y * 2
		var c2: int = c + d.x * 2
		if _in_bounds(r1, c1) and _in_bounds(r2, c2):
			if board[r1][c1] == color and board[r2][c2] == color:
				return true
	return false


# 从 4 种颜色里随机挑一个"放下去不会成横/竖三连"的。
# 极少数格子横竖都禁同一种色时，只好随便放一个，开局的 _resolve_matches 会把漏网的消掉。
func _pick_color_without_match(r: int, c: int) -> int:
	var choices: Array = []
	for color in COLORS.size():
		if not _would_match_at(r, c, color):
			choices.append(color)
	if choices.is_empty():
		return randi() % COLORS.size()
	return choices[randi() % choices.size()]


# ---------------------------------------------------------------
# 显示层：负责把数据"画"成屏幕上的方块
# ---------------------------------------------------------------

# 为 board 里的每个数字，创建一个对应的 ColorRect 节点放到场景里。
func _build_view() -> void:
	_tiles.clear()
	for r in ROWS:
		var row: Array = []
		for c in COLS:
			var tile := ColorRect.new() # 新建一个矩形节点
			tile.color = COLORS[board[r][c]] # 用数字查颜色，赋给它
			tile.size = Vector2(CELL_SIZE, CELL_SIZE) # 宽高 64
			tile.position = Vector2(c, r) * CELL_SIZE # 摆到 (列,行) 位置
			add_child(tile) # 挂到节点树里，"出现在屏幕上"

			# 每个格子自己监听点击。
			# 用闭包把 r,c 记住（rr,cc 是副本），这样回调里直接知道"我在这格"。
			var rr := r
			var cc := c
			tile.gui_input.connect(func(event):
				# 只响应"鼠标左键刚按下"这个事件
				if event is InputEventMouseButton \
					and event.pressed \
					and event.button_index == MOUSE_BUTTON_LEFT:
					_on_tile_clicked(rr, cc) # 转交给整个棋盘统一处理
			)

			row.append(tile)
		_tiles.append(row)

	# ⑤ M5：在棋盘上方画一个"分数"标签。
	#   Label 是"文字控件"，横跨整个棋盘宽度、水平居中，让文字显示在正中间。
	_score_label = Label.new()
	_score_label.text = str(score) # 初始分数 0
	_score_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER # 文字水平居中
	_score_label.size = Vector2(COLS * CELL_SIZE, 60) # 宽=棋盘宽（列数 × 格子边长），高 60
	_score_label.position = Vector2(0, -62) # 放在棋盘上方一点
	_score_label.add_theme_font_size_override("font_size", 40) # 字号加大
	add_child(_score_label) # 挂到节点树上


# 让显示层第 (r,c) 个格子的颜色，和数据层 board[r][c] 重新对齐。
#   这是唯一的"数据 → 画面"出口。以后所有改动都要经过它。
#   M3 起多了一个情况：如果这一格是 EMPTY（被消掉了），就画成"洞"的颜色。
func _refresh_tile(r: int, c: int) -> void:
	if board[r][c] == EMPTY:
		_tiles[r][c].color = EMPTY_COLOR
	else:
		_tiles[r][c].color = COLORS[board[r][c]]


# ---------------------------------------------------------------
# 交互状态机（M2 核心）：
#   用 _selected 记录"当前选没选、选的是哪格"，按点击情况分支处理。
# ---------------------------------------------------------------

# 任何格子被点击后，统一到这里来"决策"。
func _on_tile_clicked(r: int, c: int) -> void:
	# ⑦ M7.1：忙碌时直接丢掉这次点击。
	#   不要清选中、不要交换——玩家的手还在，棋盘只是暂时不听。
	if _busy:
		return

	var pos := Vector2i(c, r) # 点击处：x=列, y=行

	if _selected == NONE:
		_set_selected(pos) # ① 之前没选中 → 选中这一格
	elif _selected == pos:
		_clear_selection() # ② 点的是同一格 → 取消选中
	elif _is_neighbor(_selected, pos):
		# ③ 点相邻格 → 先滑过去，再决定「留下」还是「弹回」。
		#    整段动画 + 后面的结算都算忙碌，所以 M7.1 的锁会一直握住。
		_busy = true
		var from := _selected
		_clear_selection() # 先取消高亮，别让「发光」跟着滑
		await _try_swap(from, pos)
		_busy = false
	else:
		_set_selected(pos) # ④ 点不相邻 → 改成选中这一格

# 把 _selected 改成某个格子，并把它的颜色调亮（高亮框）
func _set_selected(pos: Vector2i) -> void:
	_clear_selection() # 先清旧的高亮，避免出现两格同时高亮
	_selected = pos
	_tiles[pos.y][pos.x].modulate = HIGHLIGHT

# 把当前高亮取消：颜色恢复正常，_selected 设回 NONE
func _clear_selection() -> void:
	if _selected == NONE: # 本来就空闲，直接返回
		return
	_tiles[_selected.y][_selected.x].modulate = NORMAL
	_selected = NONE

# 判断 a、b 两格是否上下左右相邻（不含斜对角）。
#   用的是"曼哈顿距离"：行列差之和 == 1 就是相邻。
func _is_neighbor(a: Vector2i, b: Vector2i) -> bool:
	return abs(a.x - b.x) + abs(a.y - b.y) == 1

# 格子 (r,c) 在屏幕上应处的左上角。滑动的起点 / 终点都用它，避免手写两遍乘法。
func _grid_pos(pos: Vector2i) -> Vector2:
	return Vector2(pos.x, pos.y) * CELL_SIZE


# 只改数据层：对调 board 里两个格子的颜色编号，不动画面。
#   滑动过程中画面由节点自己「走过去」负责；这里只给「扫三连」用。
func _swap_board(a: Vector2i, b: Vector2i) -> void:
	var tmp = board[a.y][a.x]
	board[a.y][a.x] = board[b.y][b.x]
	board[b.y][b.x] = tmp


# 把一格的 ColorRect 立刻放回它自己的格子位置（不播动画）。
#   成功交换后会用到：颜色已经换过了，节点「瞬移回家」眼睛看不出来。
func _snap_tile(pos: Vector2i) -> void:
	_tiles[pos.y][pos.x].position = _grid_pos(pos)


# ⑧ M7.2：让 a 格的方块滑到 dest_a 那个格子，b 格的方块滑到 dest_b。
#   Tween = 「在一段时间里，把某个属性从现在的值缓到目标值」。
#   await tween.finished = 「滑完之前，后面的代码先别跑」——没有这句就会边滑边结算。
func _slide_pair(a: Vector2i, dest_a: Vector2i, b: Vector2i, dest_b: Vector2i) -> void:
	var tween := create_tween()
	tween.set_parallel(true) # 两块同时动，不要一个走完另一个才走
	tween.tween_property(_tiles[a.y][a.x], "position", _grid_pos(dest_a), SWAP_DURATION)
	tween.tween_property(_tiles[b.y][b.x], "position", _grid_pos(dest_b), SWAP_DURATION)
	await tween.finished


# ⑧ M7.2 核心：先看滑动，再改规则结果。
#   顺序必须是：滑 → 试着换数据 → 问有没有三连 → 有就坐下并结算 / 没有就换回去再滑回来。
#   为什么滑的时候先不换颜色？因为 ColorRect 还是「A 槽的那块」在往 B 走，
#   它身上带着 A 的颜色；如果中途 _refresh_tile，就会出现「人还在走、衣服先换了」。
func _try_swap(a: Vector2i, b: Vector2i) -> void:
	await _slide_pair(a, b, b, a) # 两块走向对方的格子
	_swap_board(a, b) # 数据层现在按「已经换过」来算
	if _find_matches().is_empty():
		_swap_board(a, b) # 不成三连：数据改回去，棋盘规则上等于没换
		await _slide_pair(a, a, b, b) # 两块从对方格子走回家
		_snap_tile(a) # 防浮点误差，保证正好压在格子上
		_snap_tile(b)
		return
	# 成三连：节点还停在对方格子上，但 _tiles[A] 永远表示「A 这个槽」。
	#   把节点瞬移回自己的槽，再按新数据刷新颜色——屏幕上的色块位置不变，换的是「谁负责画」。
	_snap_tile(a)
	_snap_tile(b)
	_refresh_tile(a.y, a.x)
	_refresh_tile(b.y, b.x)
	_resolve_matches() # 有三连才结算；消除 / 下落这一步仍是瞬时的（M7.3 / M7.4）


# ---------------------------------------------------------------
# 消除逻辑（M3 核心）：
#   分成两层——先用 _find_matches 找出"所有要消的格子"，
#   再用 _eliminate 把这一批格子同时清空。
# ---------------------------------------------------------------

# 入口：把棋盘结算到"稳定"——扫不到三连才停。
# ⑥ M6：交换后、下落后、顶部补出的新方块，都可能再构成三连。
#   只消一轮就会把新三连留在棋盘上（测试时看到的那种），所以必须循环。
#   for + CHAIN_LIMIT 是保险丝；正常情况会在远小于上限时因 matched 为空而结束。
func _resolve_matches() -> void:
	for _round in CHAIN_LIMIT:
		var matched := _find_matches() # 每次循环都重新扫一遍棋盘
		if matched.is_empty():
			return # 稳定了：没有三连，可以交给玩家继续玩
		_eliminate(matched)
		_apply_gravity() # 下落 + 顶部补新块 → 可能又有三连 → 下一轮再扫
	# 走到这里说明保险丝烧了。棋盘上可能还留着三连，打一行警告方便以后发现。
	push_warning("连锁超过 CHAIN_LIMIT，棋盘可能仍有三连")


# 扫描整张棋盘，返回"所有同色连续 >=3 的格子"。
#   返回值是个 Dictionary（字典）：键是 "行,列" 这样的字符串，值无所谓 true。
#   用它当"集合"用，因为同一个格子可能同时属于一条横三连和一条竖三连，字典能自动去重。
func _find_matches() -> Dictionary:
	var matched := {}

	# 只扫两个方向：右（横）、下（竖）。斜向不算三连。
	# 每个格子都会当起点，所以朝一个走向扫就覆盖整行/整列。
	var dirs := [Vector2i(1, 0), Vector2i(0, 1)]
	for dir in dirs:
		_scan_dir(matched, dir)
	return matched


# 从每个格子出发，沿 dir 方向数"连续同色有几个"，>=3 就把它们全记进 matched。
func _scan_dir(matched: Dictionary, dir: Vector2i) -> void:
	# 起点可以是棋盘上任意一格（格子本身的坐标先算进去）
	for r in ROWS:
		for c in COLS:
			var color: int = board[r][c] # board 是未定型的数组，取出的是 Variant，要显式声明
			if color == EMPTY: # 空空格没有颜色，跳过，别拿它当起点
				continue

			var run: Array = [Vector2i(c, r)] # run = 这一串"连续同色"的坐标列表，先有自己
			var cr := r
			var cc := c
			# 顺着 dir 一步、一步往前挪（cr, cc）
			while true:
				cr += dir.y # 行方向（上下）
				cc += dir.x # 列方向（左右）
				if not _in_bounds(cr, cc):
					break # 出界了，这是这一串的尽头
				if board[cr][cc] != color:
					break # 颜色不一样了，也是尽头
				run.append(Vector2i(cc, cr)) # 同色 → 加进当前这一串

			# 这一串 >=3 才够成"三连"，把它们全部记下来
			if run.size() >= 3:
				for pos in run:
					matched["%d,%d" % [pos.y, pos.x]] = true


# 把 matched 里记录的所有格子，统一设成 EMPTY（清空），并同步画面。
func _eliminate(matched: Dictionary) -> void:
	# ⑤ M5：先计分。matched.size() = 这次一共消掉几格（字典已自动去重）。
	#   每消一格 +10 分，然后把新分数立刻显示到标签上。
	score += matched.size() * 10
	_score_label.text = str(score)

	# 字典的每个键都是我们存的 "行,列" 字符串，拆回数字就能定位格子
	for key in matched.keys():
		var parts: PackedStringArray = key.split(",")
		var r := int(parts[0])
		var c := int(parts[1])
		board[r][c] = EMPTY # 数据层：这一格变成"空"
		_refresh_tile(r, c) # 画面层：同步成"洞"的颜色


# M4 核心：下落补位。一列一列处理——
#   ① 从下往上，把这列里"还有颜色"的格子数出来（去掉空位）
#   ② 从最底行开始，把这些方块原样码回去（等于整体砸到底）
#   ③ 顶部空出来的位置，用随机新颜色填上
func _apply_gravity() -> void:
	for c in COLS: # 列与列互不干扰，逐列扫
		var col: Array = [] # 临时存"这一列里还活着的方块"
		for r in range(ROWS - 1, -1, -1): # 注意：从最底行往上走
			if board[r][c] != EMPTY: # 不是洞才收进来，"压实"把洞挤掉
				col.append(board[r][c])

		# 从最底行往上，把收好的方块一本一本码回去
		#   col 的顺序是 [最底…最顶]，从底开始放正好保持上下关系不变
		var write_r := ROWS - 1
		for value in col:
			board[write_r][c] = value
			write_r -= 1

		# 现在 write_r 及以上的格子都是空的，补上随机新方块
		while write_r >= 0:
			board[write_r][c] = randi() % COLORS.size()
			write_r -= 1

	# 数据层全部改完，统一刷新画面（只用 _refresh_tile 这一个出口）
	for r in ROWS:
		for c in COLS:
			_refresh_tile(r, c)
