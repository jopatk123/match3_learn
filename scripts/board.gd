extends Node2D
# =====================================================================
# 开心消消乐 · 棋盘脚本
# 已实现：M1（显示 8x8 彩色棋盘）+ M2（点击交换两块）
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

# 四种颜色（现在是纯色占位，将来可替换成方块的图片）
const COLORS := [
	Color(0.92, 0.30, 0.28),  # 红
	Color(0.28, 0.56, 0.92),  # 蓝
	Color(0.96, 0.74, 0.14),  # 黄
	Color(0.34, 0.78, 0.46),  # 绿
]

# 被选中时，把方块颜色"调亮"到这个倍率（>1 更亮）
const HIGHLIGHT := Color(1.2, 1.2, 1.2)
# 没选中的正常色（白色=不改变原色）
const NORMAL := Color.WHITE


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


# ---------------------------------------------------------------
# 生命周期：节点一进入场景树就自动调用的入口函数（只跑一次）
# ---------------------------------------------------------------

func _ready() -> void:
	_build_data()   # 第一步：往 board 里随机填颜色编号
	_build_view()   # 第二步：按 board 生成 64 个 ColorRect 画出来


# ---------------------------------------------------------------
# 数据层：负责"算"，不负责"画"
# ---------------------------------------------------------------

# 生成 8x8 的随机数据。每个格子用 randi()%4 取 0~3 的随机数。
func _build_data() -> void:
	board.clear()               # 清空旧的
	for r in ROWS:              # 外层：走遍每一"行"
		var row: Array = []
		for c in COLS:          # 内层：在一行里走遍每一"列"
			row.append(randi() % COLORS.size())
		board.append(row)       # 把这一行装进 board


# ---------------------------------------------------------------
# 显示层：负责把数据"画"成屏幕上的方块
# ---------------------------------------------------------------

# 为 board 里的每个数字，创建一个对应的 ColorRect 节点放到场景里。
func _build_view() -> void:
	_tiles.clear()
	for r in ROWS:
		var row: Array = []
		for c in COLS:
			var tile := ColorRect.new()          # 新建一个矩形节点
			tile.color = COLORS[board[r][c]]     # 用数字查颜色，赋给它
			tile.size = Vector2(CELL_SIZE, CELL_SIZE)              # 宽高 64
			tile.position = Vector2(c, r) * CELL_SIZE              # 摆到 (列,行) 位置
			add_child(tile)                      # 挂到节点树里，"出现在屏幕上"

			# 实验：添加一个文本标签作为 tile 的孩子
			var label := Label.new()
			label.text = str(r) + "," + str(c)  # 显示坐标
			label.position = Vector2(10, 25)
			label.add_theme_font_size_override("font_size", 14)
			tile.add_child(label)  # ← 看！tile 也有孩子了！

			# 每个格子自己监听点击。
			# 用闭包把 r,c 记住（rr,cc 是副本），这样回调里直接知道"我在这格"。
			var rr := r
			var cc := c
			tile.gui_input.connect(func(event):
				# 只响应"鼠标左键刚按下"这个事件
				if event is InputEventMouseButton \
					and event.pressed \
					and event.button_index == MOUSE_BUTTON_LEFT:
					_on_tile_clicked(rr, cc)     # 转交给整个棋盘统一处理
			)

			row.append(tile)
		_tiles.append(row)


# 让显示层第 (r,c) 个格子的颜色，和数据层 board[r][c] 重新对齐。
#   这是唯一的"数据 → 画面"出口。以后所有改动都要经过它。
func _refresh_tile(r: int, c: int) -> void:
	_tiles[r][c].color = COLORS[board[r][c]]


# ---------------------------------------------------------------
# 交互状态机（M2 核心）：
#   用 _selected 记录"当前选没选、选的是哪格"，按点击情况分支处理。
# ---------------------------------------------------------------

# 任何格子被点击后，统一到这里来"决策"。
func _on_tile_clicked(r: int, c: int) -> void:
	var pos := Vector2i(c, r)     # 点击处：x=列, y=行

	if _selected == NONE:
		_set_selected(pos)          # ① 之前没选中 → 选中这一格
	elif _selected == pos:
		_clear_selection()          # ② 点的是同一格 → 取消选中
	elif _is_neighbor(_selected, pos):
		_swap(_selected, pos)       # ③ 点相邻格 → 交换
		_clear_selection()          #    换完取消高亮（准备下一轮）
	else:
		_set_selected(pos)          # ④ 点不相邻 → 改成选中这一格

# 把 _selected 改成某个格子，并把它的颜色调亮（高亮框）
func _set_selected(pos: Vector2i) -> void:
	_clear_selection()              # 先清旧的高亮，避免出现两格同时高亮
	_selected = pos
	_tiles[pos.y][pos.x].modulate = HIGHLIGHT

# 把当前高亮取消：颜色恢复正常，_selected 设回 NONE
func _clear_selection() -> void:
	if _selected == NONE:           # 本来就空闲，直接返回
		return
	_tiles[_selected.y][_selected.x].modulate = NORMAL
	_selected = NONE

# 判断 a、b 两格是否上下左右相邻（不含斜对角）。
#   用的是"曼哈顿距离"：行列差之和 == 1 就是相邻。
func _is_neighbor(a: Vector2i, b: Vector2i) -> bool:
	return abs(a.x - b.x) + abs(a.y - b.y) == 1

# 交换数据层两格的值，并同步显示层颜色（真正的"换位"动作）
func _swap(a: Vector2i, b: Vector2i) -> void:
	var tmp = board[a.y][a.x]          # 暂存格A的值
	board[a.y][a.x] = board[b.y][b.x]  # A 拿到 B 的值
	board[b.y][b.x] = tmp              # B 拿到原 A 的值
	_refresh_tile(a.y, a.x)            # 让两格的画面跟着改
	_refresh_tile(b.y, b.x)
