import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../core/cookie_utils.dart';
import '../models/ykt_homework.dart';
import '../models/ykt_session.dart';
import '../services/app_state.dart';

enum _HomeworkTab {
  pending('待完成'),
  all('全部'),
  completed('已提交'),
  overdue('已逾期');

  const _HomeworkTab(this.label);
  final String label;
}

class HomeworkCenterScreen extends StatefulWidget {
  const HomeworkCenterScreen({required this.state, super.key});

  final AppState state;

  @override
  State<HomeworkCenterScreen> createState() => _HomeworkCenterScreenState();
}

class _HomeworkCenterScreenState extends State<HomeworkCenterScreen> {
  _HomeworkTab _tab = _HomeworkTab.pending;

  @override
  void initState() {
    super.initState();
    if (widget.state.homeworks.isEmpty && !widget.state.homeworksLoading) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        widget.state.refreshHomeworks();
      });
    }
  }

  List<YktHomeworkTask> _filtered(List<YktHomeworkTask> all) {
    final locallyDone = widget.state.locallyDoneHomeworkIds;
    return switch (_tab) {
      _HomeworkTab.pending => all
          .where(
            (t) =>
                t.status == HomeworkStatus.unsubmitted &&
                !locallyDone.contains(t.id),
          )
          .toList(),
      _HomeworkTab.all => all,
      _HomeworkTab.completed => all
          .where((t) => t.isCompleted || locallyDone.contains(t.id))
          .toList(),
      _HomeworkTab.overdue => all
          .where(
            (t) =>
                t.status == HomeworkStatus.overdue &&
                !locallyDone.contains(t.id),
          )
          .toList(),
    };
  }

  Future<void> _openWebTask(YktHomeworkTask task) async {
    final session = widget.state.session;
    final url = task.webUrl;
    if (session == null || url == null || url.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('暂未提供该任务的网页直达链接')),
      );
      return;
    }

    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _HomeworkWebViewPage(
          title: task.title,
          url: url,
          session: session,
        ),
      ),
    );
    // 返回后静默刷新最新提交状态
    if (mounted) {
      widget.state.refreshHomeworks();
    }
  }

  void _showTaskActions(YktHomeworkTask task, bool isLocalDone) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetCtx) => Padding(
        padding: EdgeInsets.fromLTRB(
          20,
          16,
          20,
          MediaQuery.viewInsetsOf(sheetCtx).bottom + 28,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 38,
                height: 4,
                decoration: BoxDecoration(
                  color: isDark ? const Color(0xFF38433E) : const Color(0xFFD1D5D2),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              task.courseName,
              style: TextStyle(
                color: Theme.of(context).colorScheme.primary,
                fontWeight: FontWeight.w700,
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              task.title,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF1E2522) : const Color(0xFFF3F6F4),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _InfoRow(
                    label: '截止时间',
                    value: task.deadline != null
                        ? DateFormat('yyyy-MM-dd HH:mm').format(task.deadline!)
                        : '无明确截止时间',
                  ),
                  const SizedBox(height: 6),
                  _InfoRow(
                    label: '当前状态',
                    value: '${task.status.label}${isLocalDone ? '（本地已标记完成）' : ''}',
                  ),
                  const SizedBox(height: 6),
                  _InfoRow(
                    label: '迟交规则',
                    value: task.overdueRuleText,
                  ),
                  if (task.score != null) ...[
                    const SizedBox(height: 6),
                    _InfoRow(
                      label: '当前得分',
                      value: task.totalScore != null
                          ? '${task.score} / ${task.totalScore}'
                          : '${task.score}',
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 18),
            if (task.webUrl != null && task.webUrl!.isNotEmpty)
              FilledButton.icon(
                onPressed: () {
                  Navigator.pop(sheetCtx);
                  _openWebTask(task);
                },
                icon: const Icon(Icons.open_in_browser_rounded),
                label: Text(task.isCompleted ? '查看提交与批改详情' : '前往作答'),
              ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: () async {
                await widget.state.toggleHomeworkLocalDone(task.id);
                if (sheetCtx.mounted) Navigator.pop(sheetCtx);
              },
              icon: Icon(
                isLocalDone
                    ? Icons.undo_rounded
                    : Icons.check_circle_outline_rounded,
              ),
              label: Text(isLocalDone ? '取消本地完成标记' : '标记为本地已处理'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.state,
      builder: (context, _) {
        final state = widget.state;
        final isDark = Theme.of(context).brightness == Brightness.dark;
        final filtered = _filtered(state.homeworks);
        final pendingCount = state.pendingHomeworkCount;

        return Scaffold(
          appBar: AppBar(
            title: const Text('作业与任务中心'),
            actions: [
              IconButton(
                tooltip: '刷新作业',
                onPressed: state.homeworksLoading ? null : state.refreshHomeworks,
                icon: state.homeworksLoading
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh_rounded),
              ),
            ],
          ),
          body: Column(
            children: [
              // 状态过滤栏
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: Row(
                  children: [
                    for (final tab in _HomeworkTab.values) ...[
                      ChoiceChip(
                        selected: _tab == tab,
                        label: Text(
                          tab == _HomeworkTab.pending && pendingCount > 0
                              ? '${tab.label} ($pendingCount)'
                              : tab.label,
                        ),
                        onSelected: (_) => setState(() => _tab = tab),
                      ),
                      const SizedBox(width: 8),
                    ],
                  ],
                ),
              ),
              if (state.homeworksError != null && state.homeworksError!.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: isDark ? const Color(0xFF331C1C) : const Color(0xFFFDF0EF),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '同步提示：${state.homeworksError}',
                      style: TextStyle(
                        fontSize: 12,
                        color: isDark ? const Color(0xFFFFA49E) : const Color(0xFFB33A32),
                      ),
                    ),
                  ),
                ),
              Expanded(
                child: RefreshIndicator(
                  onRefresh: state.refreshHomeworks,
                  child: filtered.isEmpty
                      ? ListView(
                          physics: const AlwaysScrollableScrollPhysics(),
                          padding: const EdgeInsets.all(40),
                          children: [
                            const SizedBox(height: 60),
                            Icon(
                              _tab == _HomeworkTab.pending
                                  ? Icons.task_alt_rounded
                                  : Icons.assignment_outlined,
                              size: 54,
                              color: isDark
                                  ? const Color(0xFF56635C)
                                  : const Color(0xFFA2ACA7),
                            ),
                            const SizedBox(height: 16),
                            Text(
                              _tab == _HomeworkTab.pending
                                  ? '太棒了！当前没有待完成的作业'
                                  : '该分类下暂无任务记录',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                                color: isDark
                                    ? const Color(0xFF9EABA4)
                                    : const Color(0xFF69716D),
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              '下拉可从雨课堂同步全部选修与必修课程的最新作业与测验',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 13,
                                color: isDark
                                    ? const Color(0xFF7D8A83)
                                    : const Color(0xFF8B948F),
                              ),
                            ),
                          ],
                        )
                      : ListView.separated(
                          padding: const EdgeInsets.fromLTRB(16, 4, 16, 28),
                          itemCount: filtered.length,
                          separatorBuilder: (_, _) => const SizedBox(height: 10),
                          itemBuilder: (context, index) {
                            final task = filtered[index];
                            final isLocalDone =
                                state.locallyDoneHomeworkIds.contains(task.id);
                            return _HomeworkCard(
                              task: task,
                              isLocalDone: isLocalDone,
                              onTap: () => _showTaskActions(task, isLocalDone),
                            );
                          },
                        ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _HomeworkCard extends StatelessWidget {
  const _HomeworkCard({
    required this.task,
    required this.isLocalDone,
    required this.onTap,
  });

  final YktHomeworkTask task;
  final bool isLocalDone;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isCritical = task.isCritical && !isLocalDone;
    final isUrgent = task.isUrgent && !isLocalDone;

    final badgeColor = isCritical
        ? const Color(0xFFD93F34)
        : isUrgent
            ? const Color(0xFFD97706)
            : (task.isCompleted || isLocalDone)
                ? const Color(0xFF216B42)
                : task.status == HomeworkStatus.overdue
                    ? const Color(0xFF6B7280)
                    : Theme.of(context).colorScheme.primary;

    final badgeBg = badgeColor.withValues(alpha: isDark ? 0.2 : 0.12);

    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                          decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.primary.withValues(
                              alpha: isDark ? 0.22 : 0.11,
                            ),
                            borderRadius: BorderRadius.circular(7),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.menu_book_rounded,
                                size: 14,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                              const SizedBox(width: 5),
                              Flexible(
                                child: Text(
                                  task.courseName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w800,
                                    color: Theme.of(context).colorScheme.primary,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (task.isExam) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                            decoration: BoxDecoration(
                              color: const Color(0xFF7C3AED).withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: const Text(
                              '考试',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFF8B5CF6),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: badgeBg,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      isLocalDone
                          ? '已标记处理'
                          : task.isCompleted
                              ? (task.score != null ? '已批改 ${task.score}分' : task.status.label)
                              : task.remainingText,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: badgeColor,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                task.title,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  decoration: isLocalDone ? TextDecoration.lineThrough : null,
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Icon(
                    Icons.schedule_rounded,
                    size: 14,
                    color: isDark ? const Color(0xFF9EABA4) : const Color(0xFF69716D),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    task.deadline != null
                        ? '截止：${DateFormat('MM-dd HH:mm').format(task.deadline!)}'
                        : '无截止时间',
                    style: TextStyle(
                      fontSize: 12,
                      color: isDark ? const Color(0xFF9EABA4) : const Color(0xFF69716D),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      task.overdueRuleText,
                      textAlign: TextAlign.right,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: task.allowOverdueSubmit
                            ? const Color(0xFF216B42)
                            : (isDark ? const Color(0xFF9EABA4) : const Color(0xFF69716D)),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Row(
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 13,
            color: isDark ? const Color(0xFF9EABA4) : const Color(0xFF69716D),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            value,
            textAlign: TextAlign.right,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
  }
}

class _HomeworkWebViewPage extends StatefulWidget {
  const _HomeworkWebViewPage({
    required this.title,
    required this.url,
    required this.session,
  });

  final String title;
  final String url;
  final YktSession session;

  @override
  State<_HomeworkWebViewPage> createState() => _HomeworkWebViewPageState();
}

class _HomeworkWebViewPageState extends State<_HomeworkWebViewPage> {
  late final WebViewController _controller;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) {
            if (mounted) setState(() => _loading = false);
          },
        ),
      );
    _injectCookiesAndLoad();
  }

  Future<void> _injectCookiesAndLoad() async {
    final cookieManager = WebViewCookieManager();
    final cookies = parseCookieString(widget.session.cookie);
    final domain = Uri.parse(widget.session.server.domain).host;
    for (final entry in cookies.entries) {
      await cookieManager.setCookie(
        WebViewCookie(
          name: entry.key,
          value: entry.value,
          domain: domain,
          path: '/',
        ),
      );
    }
    await _controller.loadRequest(Uri.parse(widget.url));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      body: Stack(
        children: [
          WebViewWidget(controller: _controller),
          if (_loading) const LinearProgressIndicator(),
        ],
      ),
    );
  }
}
