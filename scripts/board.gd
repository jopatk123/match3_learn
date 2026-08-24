extends Node2D
# =====================================================================
# M1 + M2 · 显示 8x8 棋盘 + 点击交换两块
# ---------------------------------------------------------------------
# 学习点 1：数据与显示分离
#   - board 是"数据层"：8x8 二维数组，每格存颜色索引 0~3
#   - _tiles 是"显示层"：8x8 的 ColorRect 节点，把数组画出来
#   将来交换 / 消除都只改数组，画面自动跟着变。
#
# 学习点 2：交互状态机（M2 新增）
#   - _selected 记录当前高亮的格子；Vector2i(-1,-1) 表示"空闲"（无选中）
#   - 每次用 GUI 信号回报"哪格被点"，走 _on_tile_clicked 的分支处理
# =====================================================================

const ROWS := 8
const COLS := 8
const CELL_SIZE := 64
const NONE := Vector2i(-1, -1)

# 四种颜色（纯色；将来可替换成图片）
const COLORS := [
	Color(0.92, 0.30, 0.28),  # 红
	Color(0.28, 0.56, 0.92),  # 蓝
	Color(0.96, 0.74, 0.14),  # 黄
	Color(0.34, 0.78, 0.46),  # 绿
]

# 高亮时把方块颜色调亮到这个倍率
const HIGHLIGHT := Color(1.2, 1.2, 1.2)
const NORMAL := Color.WHITE

# 数据层
var board: Array = []
# 显示层：board[r][c] 对应的 ColorRect 节点
var _tiles: Array = []
# 交互状态：当前高亮格子的行列，NONE 表示空闲
var _selected := NONE


func _ready() -> void:
	_build_data()
	_build_view()


# ---------- 数据层 ----------

func _build_data() -> void:
	board.clear()
	for r in ROWS:
		var row: Array = []
		for c in COLS:
			row.append(randi() % COLORS.size())
		board.append(row)


# ---------- 显示层 ----------

func _build_view() -> void:
	_tiles.clear()
	for r in ROWS:
		var row: Array = []
		for c in COLS:
			var tile := ColorRect.new()
			tile.color = COLORS[board[r][c]]
			tile.size = Vector2(CELL_SIZE, CELL_SIZE)
			tile.position = Vector2(c, r) * CELL_SIZE
			add_child(tile)

			# 每个格子自己报告被点击（行列用闭包固定，无需反算坐标）
			var rr := r
			var cc := c
			tile.gui_input.connect(func(event):
				if event is InputEventMouseButton \
					and event.pressed \
					and event.button_index == MOUSE_BUTTON_LEFT:
					_on_tile_clicked(rr, cc)
			)

			row.append(tile)
		_tiles.append(row)


# 点亮显示层里某个格子的颜色，使其和数据层一致
func _refresh_tile(r: int, c: int) -> void:
	_tiles[r][c].color = COLORS[board[r][c]]


# ---------- 交互状态机（M2） ----------

func _on_tile_clicked(r: int, c: int) -> void:
	var pos := Vector2i(c, r)

	if _selected == NONE:
		_set_selected(pos)
	elif _selected == pos:
		_clear_selection()          # 点同一格 → 取消选中
	elif _is_neighbor(_selected, pos):
		_swap(_selected, pos)       # 点相邻格 → 交换
		_clear_selection()
	else:
		_set_selected(pos)          # 点不相邻 → 改选这一格


func _set_selected(pos: Vector2i) -> void:
	_clear_selection()
	_selected = pos
	_tiles[pos.y][pos.x].modulate = HIGHLIGHT


func _clear_selection() -> void:
	if _selected == NONE:
		return
	_tiles[_selected.y][_selected.x].modulate = NORMAL
	_selected = NONE


# 判断两格是否上下左右相邻（不含对角）
func _is_neighbor(a: Vector2i, b: Vector2i) -> bool:
	return abs(a.x - b.x) + abs(a.y - b.y) == 1


# 交换数据层两格，并同步显示层颜色
func _swap(a: Vector2i, b: Vector2i) -> void:
	var tmp = board[a.y][a.x]
	board[a.y][a.x] = board[b.y][b.x]
	board[b.y][b.x] = tmp
	_refresh_tile(a.y, a.x)
	_refresh_tile(b.y, b.x)