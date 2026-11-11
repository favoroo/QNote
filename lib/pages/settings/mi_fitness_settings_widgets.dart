part of 'mi_fitness_settings_page.dart';
// 本文件从 mi_fitness_settings_page.dart 机械拆出，仅承载页面 State 之外的对话框与底部弹层。

/// 扫码授权对话框
class _MiQrLoginDialog extends ConsumerStatefulWidget {
  const _MiQrLoginDialog();

  @override
  ConsumerState<_MiQrLoginDialog> createState() => _MiQrLoginDialogState();
}

class _MiQrLoginDialogState extends ConsumerState<_MiQrLoginDialog> {
  MiQrLoginSession? _session;
  bool _isLoading = true;
  String _statusText = '正在生成二维码…';
  Timer? _pollTimer;
  bool _isDisposed = false;

  @override
  void initState() {
    super.initState();
    _startQrFlow();
  }

  @override
  void dispose() {
    _isDisposed = true;
    _pollTimer?.cancel();
    super.dispose();
  }

  Future<void> _startQrFlow() async {
    final authService = ref.read(miFitnessAuthServiceProvider);
    try {
      final session = await authService.createQrSession();
      if (_isDisposed) return;

      setState(() {
        _session = session;
        _isLoading = false;
        _statusText = '用小米运动健康 App 或小米手机扫码授权';
      });

      _startPolling(session.lp);
    } catch (e) {
      if (_isDisposed) return;
      setState(() {
        _isLoading = false;
        _statusText = '生成二维码失败：$e';
      });
    }
  }

  void _startPolling(String lp) {
    _pollTimer = Timer.periodic(const Duration(seconds: 3), (timer) async {
      if (_isDisposed) {
        timer.cancel();
        return;
      }

      final authService = ref.read(miFitnessAuthServiceProvider);
      final res = await authService.pollQrStatus(lp);

      if (_isDisposed) return;

      if (res.status == MiQrPollStatus.success) {
        timer.cancel();
        setState(() => _statusText = '授权成功，正在同步…');
        if (mounted) Toast.success(context, '授权绑定成功');
        final syncService = ref.read(healthSyncServiceProvider);
        syncService.syncDays(daysBack: 7);

        if (mounted) {
          Future.delayed(const Duration(milliseconds: 800), () {
            if (mounted) Navigator.of(context).pop();
          });
        }
      } else if (res.status == MiQrPollStatus.expired) {
        timer.cancel();
        setState(() => _statusText = '二维码已失效，请重试');
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return AlertDialog(
      title: const Text('绑定小米运动健康'),
      content: SizedBox(
        width: 280,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_isLoading)
              const Padding(padding: EdgeInsets.symmetric(vertical: 36), child: CircularProgressIndicator())
            else if (_session != null) ...[
              Container(
                width: 200,
                height: 200,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: [
                    BoxShadow(color: Colors.black.withValues(alpha: 0.08), blurRadius: 10, offset: const Offset(0, 4)),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.network(
                    _session!.qrCodeUrl,
                    fit: BoxFit.contain,
                    errorBuilder: (context, error, stackTrace) =>
                        const Center(child: Icon(Icons.broken_image, size: 40, color: Colors.grey)),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Text(
                _statusText,
                style: theme.textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                icon: const Icon(Icons.open_in_browser, size: 16),
                label: const Text('在浏览器中登录'),
                onPressed: () async {
                  final uri = Uri.parse(_session!.loginUrl);
                  if (await canLaunchUrl(uri)) {
                    await launchUrl(uri, mode: LaunchMode.externalApplication);
                  }
                },
              ),
            ] else ...[
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 20),
                child: Text(_statusText, style: TextStyle(color: colorScheme.error)),
              ),
              FilledButton(
                onPressed: () {
                  setState(() => _isLoading = true);
                  _startQrFlow();
                },
                child: const Text('重试'),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            _pollTimer?.cancel();
            Navigator.of(context).pop();
          },
          child: const Text('关闭'),
        ),
      ],
    );
  }
}

/// 批量同步进度弹窗
class _SyncProgressDialog extends StatelessWidget {
  final ValueNotifier<({int current, int total, String message})> notifier;

  const _SyncProgressDialog({required this.notifier});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.sync_rounded, size: 20),
          SizedBox(width: 8),
          Text('批量同步中', style: TextStyle(fontSize: 16)),
        ],
      ),
      content: ValueListenableBuilder<({int current, int total, String message})>(
        valueListenable: notifier,
        builder: (ctx, state, _) {
          final progress = state.total > 0 ? (state.current / state.total).clamp(0.0, 1.0) : 0.0;
          final percent = (progress * 100).toInt();

          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: LinearProgressIndicator(value: progress, minHeight: 8),
              ),
              const SizedBox(height: 12),
              Text(
                state.message,
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 4),
              Text('$percent%', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
            ],
          );
        },
      ),
    );
  }
}

/// 每日目标步数选择底部弹窗
class _StepTargetSheet extends StatefulWidget {
  final int initial;

  const _StepTargetSheet({required this.initial});

  @override
  State<_StepTargetSheet> createState() => _StepTargetSheetState();
}

class _StepTargetSheetState extends State<_StepTargetSheet> {
  late final TextEditingController _controller;
  int? _selectedPreset;

  static const _presets = [5000, 6000, 7000, 8000, 9000, 10000, 12000];

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initial.toString());
    _selectedPreset = _presets.contains(widget.initial) ? widget.initial : null;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final viewInsets = MediaQuery.viewInsetsOf(context);

    return Padding(
      padding: EdgeInsets.only(bottom: viewInsets.bottom),
      child: Container(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
        decoration: BoxDecoration(
          color: colorScheme.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(color: colorScheme.outlineVariant, borderRadius: BorderRadius.circular(2)),
              ),
            ),
            Row(
              children: [
                const Icon(Icons.flag_rounded, size: 20),
                const SizedBox(width: 8),
                Text('每日目标步数', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
              ],
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _presets.map((v) {
                final isSelected = v == _selectedPreset;
                return ChoiceChip(
                  label: Text('${NumberFormat('#,###').format(v)} 步'),
                  selected: isSelected,
                  onSelected: (_) {
                    setState(() {
                      _selectedPreset = v;
                      _controller.text = v.toString();
                    });
                  },
                );
              }).toList(),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _controller,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: '自定义步数', suffixText: '步', border: OutlineInputBorder()),
              onChanged: (val) {
                final parsed = int.tryParse(val);
                if (parsed != null && _presets.contains(parsed)) {
                  setState(() => _selectedPreset = parsed);
                } else {
                  setState(() => _selectedPreset = null);
                }
              },
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () {
                  final parsed = int.tryParse(_controller.text.trim());
                  if (parsed != null && parsed > 0) {
                    Navigator.of(context).pop(parsed);
                  }
                },
                child: const Text('确定'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
