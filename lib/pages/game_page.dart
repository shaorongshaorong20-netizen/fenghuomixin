import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'dart:async';
import 'dart:math';

class GamePage extends StatefulWidget {
  const GamePage({super.key});

  @override
  State<GamePage> createState() => _GamePageState();
}

enum _GameStatus { idle, running, paused, gameOver }

enum _PieceType { i, o, t, s, z, j, l }

class _Piece {
  final _PieceType type;
  int rotation;
  int x;
  int y;

  _Piece({
    required this.type,
    required this.rotation,
    required this.x,
    required this.y,
  });
}

class _GamePageState extends State<GamePage> with WidgetsBindingObserver {
  static const int _cols = 10;
  static const int _rows = 20;

  final Random _rand = Random();
  Timer? _timer;
  Worker? _tabWorker;

  _GameStatus _status = _GameStatus.idle;
  List<List<int>> _board = List.generate(_rows, (_) => List.filled(_cols, 0));

  _Piece? _current;
  _PieceType? _nextType;

  int _score = 0;
  int _level = 1;

  Duration _tickDuration = const Duration(milliseconds: 800);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _nextType = _randomType();

    if (Get.isRegistered<RxInt>(tag: 'homeTabIndex')) {
      final RxInt tabIndex = Get.find<RxInt>(tag: 'homeTabIndex');
      _tabWorker = ever<int>(tabIndex, (index) {
        if (index != 2) {
          _pause();
        }
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _tabWorker?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive || state == AppLifecycleState.paused) {
      _pause();
    }
  }

  _PieceType _randomType() {
    return _PieceType.values[_rand.nextInt(_PieceType.values.length)];
  }

  Color _pieceColor(_PieceType type) {
    switch (type) {
      case _PieceType.i:
        return const Color(0xFF00BCD4);
      case _PieceType.o:
        return const Color(0xFFFFC107);
      case _PieceType.t:
        return const Color(0xFF9C27B0);
      case _PieceType.s:
        return const Color(0xFF4CAF50);
      case _PieceType.z:
        return const Color(0xFFC62828);
      case _PieceType.j:
        return const Color(0xFF1976D2);
      case _PieceType.l:
        return const Color(0xFFFF9800);
    }
  }

  int _typeIndex(_PieceType type) => _PieceType.values.indexOf(type) + 1;

  List<List<Point<int>>> _shape(_PieceType type) {
    switch (type) {
      case _PieceType.i:
        return [
          [const Point(0, 1), const Point(1, 1), const Point(2, 1), const Point(3, 1)],
          [const Point(2, 0), const Point(2, 1), const Point(2, 2), const Point(2, 3)],
          [const Point(0, 2), const Point(1, 2), const Point(2, 2), const Point(3, 2)],
          [const Point(1, 0), const Point(1, 1), const Point(1, 2), const Point(1, 3)],
        ];
      case _PieceType.o:
        return [
          [const Point(1, 0), const Point(2, 0), const Point(1, 1), const Point(2, 1)],
          [const Point(1, 0), const Point(2, 0), const Point(1, 1), const Point(2, 1)],
          [const Point(1, 0), const Point(2, 0), const Point(1, 1), const Point(2, 1)],
          [const Point(1, 0), const Point(2, 0), const Point(1, 1), const Point(2, 1)],
        ];
      case _PieceType.t:
        return [
          [const Point(1, 0), const Point(0, 1), const Point(1, 1), const Point(2, 1)],
          [const Point(1, 0), const Point(1, 1), const Point(2, 1), const Point(1, 2)],
          [const Point(0, 1), const Point(1, 1), const Point(2, 1), const Point(1, 2)],
          [const Point(1, 0), const Point(0, 1), const Point(1, 1), const Point(1, 2)],
        ];
      case _PieceType.s:
        return [
          [const Point(1, 0), const Point(2, 0), const Point(0, 1), const Point(1, 1)],
          [const Point(1, 0), const Point(1, 1), const Point(2, 1), const Point(2, 2)],
          [const Point(1, 1), const Point(2, 1), const Point(0, 2), const Point(1, 2)],
          [const Point(0, 0), const Point(0, 1), const Point(1, 1), const Point(1, 2)],
        ];
      case _PieceType.z:
        return [
          [const Point(0, 0), const Point(1, 0), const Point(1, 1), const Point(2, 1)],
          [const Point(2, 0), const Point(1, 1), const Point(2, 1), const Point(1, 2)],
          [const Point(0, 1), const Point(1, 1), const Point(1, 2), const Point(2, 2)],
          [const Point(1, 0), const Point(0, 1), const Point(1, 1), const Point(0, 2)],
        ];
      case _PieceType.j:
        return [
          [const Point(0, 0), const Point(0, 1), const Point(1, 1), const Point(2, 1)],
          [const Point(1, 0), const Point(2, 0), const Point(1, 1), const Point(1, 2)],
          [const Point(0, 1), const Point(1, 1), const Point(2, 1), const Point(2, 2)],
          [const Point(1, 0), const Point(1, 1), const Point(0, 2), const Point(1, 2)],
        ];
      case _PieceType.l:
        return [
          [const Point(2, 0), const Point(0, 1), const Point(1, 1), const Point(2, 1)],
          [const Point(1, 0), const Point(1, 1), const Point(1, 2), const Point(2, 2)],
          [const Point(0, 1), const Point(1, 1), const Point(2, 1), const Point(0, 2)],
          [const Point(0, 0), const Point(1, 0), const Point(1, 1), const Point(1, 2)],
        ];
    }
  }

  List<Point<int>> _blocks(_Piece piece, {int? rotation}) {
    final int rot = rotation ?? piece.rotation;
    final List<Point<int>> shape = _shape(piece.type)[rot % 4];
    return shape.map((p) => Point(piece.x + p.x, piece.y + p.y)).toList();
  }

  bool _collides(_Piece piece, {int? x, int? y, int? rotation}) {
    final _Piece test = _Piece(
      type: piece.type,
      rotation: rotation ?? piece.rotation,
      x: x ?? piece.x,
      y: y ?? piece.y,
    );
    for (final Point<int> b in _blocks(test)) {
      if (b.x < 0 || b.x >= _cols || b.y < 0 || b.y >= _rows) return true;
      if (_board[b.y][b.x] != 0) return true;
    }
    return false;
  }

  void _spawn() {
    final _PieceType type = _nextType ?? _randomType();
    _nextType = _randomType();

    final _Piece piece = _Piece(type: type, rotation: 0, x: 3, y: 0);
    if (type == _PieceType.o) piece.x = 3;
    if (type == _PieceType.i) piece.x = 3;

    _current = piece;

    if (_collides(piece)) {
      _status = _GameStatus.gameOver;
      _timer?.cancel();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _showGameOverDialog();
      });
    }
  }

  void _startNewGame() {
    _timer?.cancel();
    _board = List.generate(_rows, (_) => List.filled(_cols, 0));
    _score = 0;
    _level = 1;
    _tickDuration = const Duration(milliseconds: 800);
    _status = _GameStatus.running;
    _nextType = _randomType();
    _spawn();
    _restartTimer();
    setState(() {});
  }

  void _restartTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(_tickDuration, (_) => _tick());
  }

  void _pause() {
    if (_status != _GameStatus.running) return;
    _timer?.cancel();
    setState(() {
      _status = _GameStatus.paused;
    });
  }

  void _resume() {
    if (_status != _GameStatus.paused) return;
    setState(() {
      _status = _GameStatus.running;
    });
    _restartTimer();
  }

  void _togglePause() {
    if (_status == _GameStatus.idle || _status == _GameStatus.gameOver) {
      _startNewGame();
      return;
    }
    if (_status == _GameStatus.running) {
      _pause();
    } else if (_status == _GameStatus.paused) {
      _resume();
    }
  }

  void _tick() {
    if (!mounted) return;
    if (_status != _GameStatus.running) return;
    final _Piece? piece = _current;
    if (piece == null) return;

    if (!_collides(piece, y: piece.y + 1)) {
      setState(() {
        piece.y += 1;
      });
      return;
    }

    _lockPiece();
    _clearLines();
    _spawn();
    setState(() {});
  }

  void _lockPiece() {
    final _Piece? piece = _current;
    if (piece == null) return;

    final int value = _typeIndex(piece.type);
    for (final Point<int> b in _blocks(piece)) {
      if (b.y >= 0 && b.y < _rows && b.x >= 0 && b.x < _cols) {
        _board[b.y][b.x] = value;
      }
    }
  }

  void _clearLines() {
    int cleared = 0;
    final List<List<int>> nextBoard = [];

    for (int r = 0; r < _rows; r++) {
      final bool full = _board[r].every((v) => v != 0);
      if (full) {
        cleared += 1;
      } else {
        nextBoard.add(_board[r]);
      }
    }

    while (nextBoard.length < _rows) {
      nextBoard.insert(0, List.filled(_cols, 0));
    }

    _board = nextBoard;

    if (cleared > 0) {
      final int addScore = switch (cleared) {
        1 => 100,
        2 => 300,
        3 => 600,
        _ => 1000,
      };
      _score += addScore;
      final int nextLevel = (_score ~/ 1000) + 1;
      if (nextLevel != _level) {
        _level = nextLevel;
        final int ms = max(120, 800 - (_level - 1) * 60);
        _tickDuration = Duration(milliseconds: ms);
        if (_status == _GameStatus.running) {
          _restartTimer();
        }
      }
    }
  }

  void _move(int dx) {
    if (_status != _GameStatus.running) return;
    final _Piece? piece = _current;
    if (piece == null) return;

    if (!_collides(piece, x: piece.x + dx)) {
      setState(() {
        piece.x += dx;
      });
    }
  }

  void _rotate() {
    if (_status != _GameStatus.running) return;
    final _Piece? piece = _current;
    if (piece == null) return;

    final int nextRot = (piece.rotation + 1) % 4;
    if (!_collides(piece, rotation: nextRot)) {
      setState(() {
        piece.rotation = nextRot;
      });
      return;
    }

    for (final int kick in const [-1, 1, -2, 2]) {
      if (!_collides(piece, x: piece.x + kick, rotation: nextRot)) {
        setState(() {
          piece.x += kick;
          piece.rotation = nextRot;
        });
        return;
      }
    }
  }

  void _drop() {
    if (_status != _GameStatus.running) return;
    final _Piece? piece = _current;
    if (piece == null) return;

    int y = piece.y;
    while (!_collides(piece, y: y + 1)) {
      y += 1;
    }
    setState(() {
      piece.y = y;
    });
    _tick();
  }

  void _showGameOverDialog() {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return AlertDialog(
          title: const Text('游戏结束'),
          content: Text('得分：$_score'),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
                _startNewGame();
              },
              child: const Text('重新开始'),
            ),
          ],
        );
      },
    );
  }

  int _cellValueAt(int x, int y) {
    int v = _board[y][x];
    final _Piece? piece = _current;
    if (piece != null) {
      for (final Point<int> b in _blocks(piece)) {
        if (b.x == x && b.y == y) {
          v = _typeIndex(piece.type);
          break;
        }
      }
    }
    return v;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('游戏'),
      ),
      backgroundColor: const Color(0xFF080C14),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final double maxW = constraints.maxWidth;
          final double maxH = constraints.maxHeight;

          final double sideWidth = min(200, maxW * 0.32);
          const double gap = 12;
          final double boardAreaW = maxW - sideWidth - 24 - gap;
          final double boardAreaH = maxH - 140;
          final double cell = max(
            10,
            min(boardAreaW / _cols, boardAreaH / _rows),
          );

          final double boardW = cell * _cols;
          final double boardH = cell * _rows;

          return Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: [
                Expanded(
                  child: Center(
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        SizedBox(
                          width: boardW,
                          height: boardH,
                          child: Stack(
                            children: [
                              Container(
                                decoration: BoxDecoration(
                                  color: const Color(0xFF0F131E),
                                  borderRadius: const BorderRadius.all(Radius.circular(14)),
                                  border: Border.all(color: const Color(0xFF1A1F2E)),
                                ),
                                child: ClipRRect(
                                  borderRadius: const BorderRadius.all(Radius.circular(14)),
                                  child: GridView.builder(
                                    physics: const NeverScrollableScrollPhysics(),
                                    padding: EdgeInsets.zero,
                                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                                      crossAxisCount: _cols,
                                    ),
                                    itemCount: _cols * _rows,
                                    itemBuilder: (context, index) {
                                      final int x = index % _cols;
                                      final int y = index ~/ _cols;
                                      final int v = _cellValueAt(x, y);
                                      final Color? color = v == 0
                                          ? null
                                          : _pieceColor(_PieceType.values[v - 1]);
                                      return Container(
                                        margin: const EdgeInsets.all(0.5),
                                        decoration: BoxDecoration(
                                          color: color ?? Colors.transparent,
                                          borderRadius: const BorderRadius.all(Radius.circular(2)),
                                          border: Border.all(
                                            color: const Color(0xFF1A1F2E),
                                            width: 0.5,
                                          ),
                                        ),
                                      );
                                    },
                                  ),
                                ),
                              ),
                              if (_status == _GameStatus.idle)
                                Positioned.fill(
                                  child: Material(
                                    color: Colors.black.withValues(alpha: 0.35),
                                    child: InkWell(
                                      onTap: _togglePause,
                                      child: const Center(
                                        child: Text(
                                          '点击开始游戏',
                                          style: TextStyle(
                                            color: Colors.white,
                                            fontSize: 20,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              if (_status == _GameStatus.paused)
                                Positioned.fill(
                                  child: Material(
                                    color: Colors.black.withValues(alpha: 0.35),
                                    child: InkWell(
                                      onTap: _togglePause,
                                      child: const Center(
                                        child: Text(
                                          '已暂停',
                                          style: TextStyle(
                                            color: Colors.white,
                                            fontSize: 20,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        SizedBox(
                          width: sideWidth,
                          child: _buildSidePanel(cell),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                _buildControls(),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildSidePanel(double cell) {
    final _PieceType? next = _nextType;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF0F131E),
        borderRadius: const BorderRadius.all(Radius.circular(16)),
        border: Border.all(color: const Color(0xFF1A1F2E)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            '下一个',
            style: TextStyle(color: Color(0xFFE8E8E8), fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 10),
          AspectRatio(
            aspectRatio: 1,
            child: Container(
              decoration: BoxDecoration(
                color: const Color(0xFF080C14),
                borderRadius: const BorderRadius.all(Radius.circular(12)),
                border: Border.all(color: const Color(0xFF1A1F2E)),
              ),
              child: next == null
                  ? const SizedBox.shrink()
                  : _NextPreview(type: next, color: _pieceColor(next)),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            '分数：$_score',
            style: const TextStyle(
              color: Color(0xFFB8960C),
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '等级：$_level',
            style: const TextStyle(
              color: Color(0xFFB8960C),
              fontWeight: FontWeight.w600,
            ),
          ),
          const Spacer(),
          if (_status == _GameStatus.gameOver)
            Text(
              '游戏结束',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.9),
                fontWeight: FontWeight.w700,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildControls() {
    final bool canControl = _status == _GameStatus.running;
    final String toggleText = switch (_status) {
      _GameStatus.idle => '开始',
      _GameStatus.running => '暂停',
      _GameStatus.paused => '继续',
      _GameStatus.gameOver => '重新开始',
    };
    final Color toggleBg = (_status == _GameStatus.idle || _status == _GameStatus.gameOver)
        ? const Color(0xFFB8960C)
        : const Color(0xFF1A1F2E);

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 560),
      child: Wrap(
        alignment: WrapAlignment.center,
        spacing: 10,
        runSpacing: 10,
        children: [
          _ControlButton(
            icon: Icons.chevron_left,
            label: '左移',
            onPressed: canControl ? () => _move(-1) : null,
          ),
          _ControlButton(
            icon: Icons.chevron_right,
            label: '右移',
            onPressed: canControl ? () => _move(1) : null,
          ),
          _ControlButton(
            icon: Icons.rotate_right,
            label: '旋转',
            onPressed: canControl ? _rotate : null,
          ),
          _ControlButton(
            icon: Icons.arrow_downward,
            label: '下落',
            onPressed: canControl ? _drop : null,
          ),
          _ControlButton(
            icon: _status == _GameStatus.running ? Icons.pause : Icons.play_arrow,
            label: toggleText,
            onPressed: _togglePause,
            primary: true,
            backgroundColor: toggleBg,
          ),
        ],
      ),
    );
  }
}

class _ControlButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool primary;
  final Color? backgroundColor;

  const _ControlButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.primary = false,
    this.backgroundColor,
  });

  @override
  Widget build(BuildContext context) {
    final Color bg = backgroundColor ?? const Color(0xFF1A1F2E);
    return SizedBox(
      height: 44,
      child: ElevatedButton.icon(
        onPressed: onPressed,
        icon: Icon(icon, size: 20),
        label: Text(label),
        style: ElevatedButton.styleFrom(
          backgroundColor: bg,
          foregroundColor: Colors.white,
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(10)),
          ),
          overlayColor: Colors.white.withValues(alpha: 0.08),
        ),
      ),
    );
  }
}

class _NextPreview extends StatelessWidget {
  final _PieceType type;
  final Color color;

  const _NextPreview({required this.type, required this.color});

  List<Point<int>> _shape() {
    switch (type) {
      case _PieceType.i:
        return [const Point(0, 1), const Point(1, 1), const Point(2, 1), const Point(3, 1)];
      case _PieceType.o:
        return [const Point(1, 1), const Point(2, 1), const Point(1, 2), const Point(2, 2)];
      case _PieceType.t:
        return [const Point(1, 1), const Point(0, 2), const Point(1, 2), const Point(2, 2)];
      case _PieceType.s:
        return [const Point(1, 1), const Point(2, 1), const Point(0, 2), const Point(1, 2)];
      case _PieceType.z:
        return [const Point(0, 1), const Point(1, 1), const Point(1, 2), const Point(2, 2)];
      case _PieceType.j:
        return [const Point(0, 1), const Point(0, 2), const Point(1, 2), const Point(2, 2)];
      case _PieceType.l:
        return [const Point(2, 1), const Point(0, 2), const Point(1, 2), const Point(2, 2)];
    }
  }

  @override
  Widget build(BuildContext context) {
    final Set<Point<int>> blocks = _shape().toSet();
    return GridView.builder(
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.all(8),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 4),
      itemCount: 16,
      itemBuilder: (context, index) {
        final int x = index % 4;
        final int y = index ~/ 4;
        final bool on = blocks.contains(Point(x, y));
        return Container(
          margin: const EdgeInsets.all(1),
          decoration: BoxDecoration(
            color: on ? color : Colors.transparent,
            borderRadius: const BorderRadius.all(Radius.circular(4)),
            border: Border.all(color: const Color(0xFF1A1F2E)),
          ),
        );
      },
    );
  }
}
