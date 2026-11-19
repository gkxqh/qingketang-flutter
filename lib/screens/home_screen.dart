import 'dart:io';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/ykt_lesson.dart';
import '../services/app_state.dart';
import '../services/ykt_api_client.dart';
import '../widgets/classroom_notice_panel.dart';
import 'classroom_screen.dart';
import 'homework_center_screen.dart';
import 'login_screen.dart';
import 'qr_lesson_scanner_screen.dart';
import 'settings_screen.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({required this.state, super.key});

  final AppState state;

  String get _noticeMessage =>
      '当前自动签到策略：${state.autoCheckinMode.label}。'
      '课堂接口由雨课堂官方控制，接口变化或动态二维码课堂可能需要重新适配。';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('晴课堂'),
        actions: [
          IconButton(
            tooltip: '扫码进入课堂',
            onPressed: () => _scanClassroom(context),
            icon: const Icon(Icons.qr_code_scanner_rounded),
          ),
          IconButton(
            tooltip: '刷新课堂状态',
            onPressed: state.loading ? null : state.refreshLessons,
            icon: state.loading
                ? const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh_rounded),
          ),
          IconButton(
            tooltip: '设置',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => SettingsScreen(state: state),
              ),
            ),
            icon: const Icon(Icons.tune_rounded),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: state.refreshLessons,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            if (!(state.hideHomeProfile && state.session != null)) ...[
              _AccountPanel(state: state),
              const SizedBox(height: 16),
            ],
            if (state.session != null) ...[
              _HomeworkEntryCard(state: state),
              const SizedBox(height: 22),
            ],
            _SectionTitle(
              title: '正在上课',
              trailing: state.lessons.isEmpty
                  ? null
                  : '${state.lessons.length} 节',
            ),
            const SizedBox(height: 10),
            if (state.loading && state.lessons.isEmpty)
              const _LoadingPanel()
            else if (state.error != null && state.lessons.isEmpty)
              _MessagePanel(
                icon: Icons.cloud_off_rounded,
                title: '暂时无法同步课堂',
                message: state.error!,
                actionLabel: '重新连接',
                onAction: state.refreshLessons,
              )
            else if (state.lessons.isEmpty)
              _MessagePanel(
                icon: Icons.school_outlined,
                title: '当前没有进行中的课堂',
                message: '老师开课后，课堂会自动出现在这里。',
                actionLabel: state.showLessonIdEntry ? '按课堂 ID 进入' : null,
                onAction: state.showLessonIdEntry ? () => _openByLessonId(context) : null,
              )
            else ...[
              ...state.lessons.map(
                (lesson) => Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: _LessonCard(
                    lesson: lesson,
                    onEnter: () => _enterClassroom(context, lesson),
                  ),
                ),
              ),
              if (state.showLessonIdEntry)
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    onPressed: () => _openByLessonId(context),
                    icon: const Icon(Icons.tag_rounded, size: 18),
                    label: const Text('按课堂 ID 进入'),
                  ),
                ),
            ],
            const SizedBox(height: 24),
            const _SectionTitle(title: '已实现能力'),
            const SizedBox(height: 10),
            const _CapabilityGrid(),
            if (state.homeNoticeEnabled) ...[
              const SizedBox(height: 24),
              ClassroomNoticePanel(
                message: _noticeMessage,
                onDismiss: () => state.dismissHomeNotice(),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _enterClassroom(BuildContext context, YktLesson lesson) async {
    if (state.session == null) {
      await _openLogin(context);
      return;
    }
    if (lesson.requiresDynamicQr && !lesson.isCheckedIn) {
      _showMessage(context, '该课堂启用了现场动态二维码。当前版本不会伪造签到码，请在教室扫码后再进入课堂。');
    }
    final result = await state.checkIn(lesson);
    if (!context.mounted) return;
    if (!result.success) {
      _showMessage(context, result.message);
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ClassroomScreen(
          state: state,
          lesson: lesson,
          initialCheckin: result,
        ),
      ),
    );
    await state.refreshLessons(runAutoCheckin: false);
  }

  Future<void> _openLogin(BuildContext context) {
    return Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => LoginScreen(state: state)));
  }

  Future<void> _openByLessonId(BuildContext context) async {
    final lessonId = await showDialog<String>(
      context: context,
      builder: (context) => const _LessonIdDialog(),
    );
    if (!context.mounted ||
        lessonId == null ||
        !RegExp(r'^\d{10,25}$').hasMatch(lessonId)) {
      return;
    }
    await _enterByLessonId(context, lessonId, label: '雨课堂课堂');
  }

  Future<void> _scanClassroom(BuildContext context) async {
    if (state.session == null) {
      await _openLogin(context);
      if (!context.mounted || state.session == null) return;
    }
    final lessonId = await Navigator.of(context).push<String>(
      MaterialPageRoute<String>(builder: (_) => const QrLessonScannerScreen()),
    );
    if (!context.mounted || lessonId == null) return;
    await _enterByLessonId(context, lessonId, label: '扫码进入的课堂');
  }

  Future<void> _enterByLessonId(
    BuildContext context,
    String lessonId, {
    required String label,
  }) async {
    final lesson = YktLesson.fromJson({'lessonId': lessonId, 'name': label});
    final result = await state.checkIn(lesson);
    if (!context.mounted) return;
    if (!result.success) {
      _showMessage(context, result.message);
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ClassroomScreen(
          state: state,
          lesson: lesson,
          initialCheckin: result,
        ),
      ),
    );
    await state.refreshLessons(runAutoCheckin: false);
  }

  void _showMessage(BuildContext context, String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }
}

class _LessonIdDialog extends StatefulWidget {
  const _LessonIdDialog();

  @override
  State<_LessonIdDialog> createState() => _LessonIdDialogState();
}

class _LessonIdDialogState extends State<_LessonIdDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('按课堂 ID 进入'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        keyboardType: TextInputType.number,
        decoration: const InputDecoration(
          labelText: 'lessonId',
          hintText: '例如 1817290075055332992',
        ),
        onSubmitted: (value) => Navigator.pop(context, value.trim()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _controller.text.trim()),
          child: const Text('进入'),
        ),
      ],
    );
  }
}

class _AccountPanel extends StatelessWidget {
  const _AccountPanel({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final session = state.session;
    if (session == null) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primary
                      .withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  Icons.person_add_alt_1_rounded,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      state.sessionExpired ? '雨课堂登录已过期' : '连接雨课堂',
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 17,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      state.sessionExpired
                          ? '请在雨课堂重新扫码登录'
                          : '支持扫码、短信验证码和账号密码登录',
                      style: const TextStyle(color: Color(0xFF69716D)),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              FilledButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => LoginScreen(state: state),
                  ),
                ),
                child: Text(state.sessionExpired ? '重新登录' : '登录'),
              ),
            ],
          ),
        ),
      );
    }
    final statusLabel = state.sessionStatus == SessionValidation.valid
        ? '已连接'
        : state.sessionStatus == SessionValidation.invalid
        ? '已过期'
        : '验证中';
    final statusColor = state.sessionStatus == SessionValidation.valid
        ? const Color(0xFF216B42)
        : state.sessionStatus == SessionValidation.invalid
        ? const Color(0xFFB33A32)
        : const Color(0xFF9A641E);
    final customAvatar = state.homeAvatarPath;
    final ImageProvider<Object>? avatarImage = customAvatar.isNotEmpty
        ? customAvatar.startsWith('http')
              ? NetworkImage(customAvatar)
              : FileImage(File(customAvatar))
        : session.avatar.isNotEmpty
        ? NetworkImage(session.avatar)
        : null;
    final displayName = state.homeDisplayName;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Row(
          children: [
            CircleAvatar(
              radius: 25,
              backgroundColor: const Color(0xFFE6F0ED),
              backgroundImage: avatarImage,
              onBackgroundImageError: avatarImage != null ? (_, _) {} : null,
              child: avatarImage == null
                  ? Text(
                      displayName.isEmpty ? '雨' : displayName.characters.first,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.primary,
                        fontWeight: FontWeight.w800,
                      ),
                    )
                  : null,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    displayName,
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 18,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    state.sessionStatus == SessionValidation.valid
                        ? '${session.school.isEmpty ? '雨课堂' : session.school} · ${session.server.label}'
                        : state.sessionStatus == SessionValidation.unknown
                        ? '正在核验雨课堂会话…'
                        : '会话已失效，请重新登录',
                    style: const TextStyle(color: Color(0xFF69716D)),
                  ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: statusColor.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                statusLabel,
                style: TextStyle(
                  color: statusColor,
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LessonCard extends StatelessWidget {
  const _LessonCard({required this.lesson, required this.onEnter});

  final YktLesson lesson;
  final VoidCallback onEnter;

  @override
  Widget build(BuildContext context) {
    final start = lesson.startTime > 0
        ? DateFormat('HH:mm')
              .format(DateTime.fromMillisecondsSinceEpoch(lesson.startTime))
        : '刚刚';
    final statusColor = lesson.isCheckedIn
        ? const Color(0xFF216B42)
        : lesson.requiresDynamicQr
        ? const Color(0xFFB85C1E)
        : Theme.of(context).colorScheme.primary;
    final status = lesson.isCheckedIn
        ? '已签到'
        : lesson.requiresDynamicQr
        ? '需现场扫码'
        : '可签到';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(17),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 4,
                  height: 38,
                  decoration: BoxDecoration(
                    color: statusColor,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        lesson.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        [
                          if (lesson.teacher.isNotEmpty) lesson.teacher,
                          if (lesson.classroom.isNotEmpty) lesson.classroom,
                          '$start 开始',
                        ].join(' · '),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Color(0xFF69716D)),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 9,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: statusColor.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(7),
                  ),
                  child: Text(
                    status,
                    style: TextStyle(
                      color: statusColor,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                const Icon(
                  Icons.bolt_rounded,
                  size: 18,
                  color: Color(0xFFC76A2A),
                ),
                const SizedBox(width: 5),
                const Expanded(
                  child: Text(
                    '进入后可查看课件、随堂习题和实时互动',
                    style: TextStyle(fontSize: 13, color: Color(0xFF69716D)),
                  ),
                ),
                TextButton.icon(
                  onPressed: onEnter,
                  icon: const Icon(Icons.arrow_forward_rounded, size: 18),
                  label: Text(
                    lesson.requiresDynamicQr && !lesson.isCheckedIn
                        ? '查看提示'
                        : '进入课堂',
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _CapabilityGrid extends StatelessWidget {
  const _CapabilityGrid();

  @override
  Widget build(BuildContext context) {
    const capabilities = [
      (Icons.qr_code_scanner_rounded, '快捷进课堂', '一定要扫码吗...'),
      (Icons.present_to_all_rounded, '课件放映同步', '同步翻页，亦可预览后续的页面'),
      (Icons.quiz_outlined, '纵览习题', '获取所有习题并预约提交，亦可尝试补交'),
      (Icons.file_download_outlined, '课件多格式导出', '一键导出 PDF、离线网页和原图包'),
    ];
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 660 ? 4 : 2;
        return GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: capabilities.length,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            crossAxisSpacing: 10,
            mainAxisSpacing: 10,
            mainAxisExtent: 176,
          ),
          itemBuilder: (context, index) {
            final capability = capabilities[index];
            return Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF1E2421) : Colors.white,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: isDark ? const Color(0xFF2C3530) : const Color(0xFFE6E3DA),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    capability.$1,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    capability.$2,
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 4),
                  Expanded(
                    child: Text(
                      capability.$3,
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFF69716D),
                        height: 1.4,
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.title, this.trailing});

  final String title;
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(
          title,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
        ),
        const Spacer(),
        if (trailing != null)
          Text(trailing!, style: const TextStyle(color: Color(0xFF69716D))),
      ],
    );
  }
}

class _LoadingPanel extends StatelessWidget {
  const _LoadingPanel();

  @override
  Widget build(BuildContext context) {
    return const Card(
      child: Padding(
        padding: EdgeInsets.all(22),
        child: Row(
          children: [
            SizedBox.square(
              dimension: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: 12),
            Text('正在同步雨课堂课堂状态…'),
          ],
        ),
      ),
    );
  }
}

class _MessagePanel extends StatelessWidget {
  const _MessagePanel({
    required this.icon,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          children: [
            Icon(icon, size: 34, color: const Color(0xFF7B837F)),
            const SizedBox(height: 12),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 6),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Color(0xFF69716D), height: 1.5),
            ),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 14),
              OutlinedButton(onPressed: onAction, child: Text(actionLabel!)),
            ],
          ],
        ),
      ),
    );
  }
}

class _HomeworkEntryCard extends StatelessWidget {
  const _HomeworkEntryCard({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final pending = state.pendingHomeworkCount;
    final urgent = state.urgentHomeworkCount;

    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => HomeworkCenterScreen(state: state),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: (urgent > 0
                          ? const Color(0xFFD97706)
                          : Theme.of(context).colorScheme.primary)
                      .withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  Icons.assignment_turned_in_outlined,
                  color: urgent > 0
                      ? const Color(0xFFD97706)
                      : Theme.of(context).colorScheme.primary,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Text(
                          '作业与任务中心',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        if (urgent > 0) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 7,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xFFD97706).withValues(
                                alpha: isDark ? 0.25 : 0.14,
                              ),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              '$urgent 项即将截止',
                              style: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFFD97706),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      state.homeworksLoading && state.homeworks.isEmpty
                          ? '正在同步各门课程作业与测验…'
                          : pending > 0
                              ? '当前有 $pending 项待完成'
                              : '所有任务均已处理完毕，点击查看全部记录',
                      style: TextStyle(
                        fontSize: 12,
                        color: isDark
                            ? const Color(0xFF9EABA4)
                            : const Color(0xFF69716D),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              const Icon(Icons.chevron_right_rounded),
            ],
          ),
        ),
      ),
    );
  }
}
