import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../models/ykt_session.dart';
import '../services/app_state.dart';
import '../services/background_auto_submit_service.dart';
import '../services/file_platform_helper.dart';
import '../services/ykt_session_store.dart';
import '../widgets/classroom_notice_panel.dart';
import 'login_screen.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({required this.state, super.key});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: state,
      builder: (context, _) {
        return Scaffold(
          appBar: AppBar(title: const Text('晴课堂设置')),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              const _SettingsLabel('账号'),
              Card(
                child: Column(
                  children: [
                    ListTile(
                      leading: const Icon(Icons.person_outline_rounded),
                      title: Text(state.session?.name ?? '未登录雨课堂'),
                      subtitle: Text(
                        state.session == null
                            ? '登录后可同步正在上课的课堂'
                            : '${state.session!.school} · ${state.session!.server.label}',
                      ),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () {
                        if (state.session == null) {
                          Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => LoginScreen(state: state),
                            ),
                          );
                        }
                      },
                    ),
                    if (state.session != null) ...[
                      const Divider(),
                      ListTile(
                        leading: const Icon(Icons.logout_rounded),
                        title: const Text('退出雨课堂'),
                        onTap: () async {
                          final confirmed = await showDialog<bool>(
                            context: context,
                            builder: (context) => AlertDialog(
                              title: const Text('退出账号'),
                              content: const Text('已保存的课堂 token 会一并清除。'),
                              actions: [
                                TextButton(
                                  onPressed: () =>
                                      Navigator.pop(context, false),
                                  child: const Text('取消'),
                                ),
                                FilledButton(
                                  onPressed: () => Navigator.pop(context, true),
                                  child: const Text('退出'),
                                ),
                              ],
                            ),
                          );
                          if (confirmed == true) {
                            await state.logout();
                            if (context.mounted) Navigator.pop(context);
                          }
                        },
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 22),
              const _SettingsLabel('首页个人信息'),
              Card(
                child: Column(
                  children: [
                    SwitchListTile(
                      value: state.hideHomeProfile,
                      onChanged: state.updateHideHomeProfile,
                      secondary: const Icon(Icons.visibility_off_outlined),
                      title: const Text('隐藏首页个人信息'),
                      subtitle: const Text('隐藏头像、昵称和连接状态卡片'),
                    ),
                    const Divider(),
                    ListTile(
                      enabled: !state.hideHomeProfile,
                      leading: const Icon(Icons.badge_outlined),
                      title: Text(
                        state.homeNickname.isEmpty
                            ? '使用雨课堂昵称'
                            : state.homeNickname,
                      ),
                      subtitle: const Text('自定义首页昵称，仅保存在本机'),
                      trailing: const Icon(Icons.edit_outlined),
                      onTap: state.hideHomeProfile
                          ? null
                          : () => _editHomeNickname(context),
                    ),
                    const Divider(),
                    ListTile(
                      enabled: !state.hideHomeProfile,
                      leading: Opacity(
                        opacity: state.hideHomeProfile ? 0.38 : 1,
                        child: _HomeAvatarPreview(path: state.homeAvatarPath),
                      ),
                      title: const Text('自定义首页头像'),
                      subtitle: const Text('从相册选择，仅保存在本机'),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: state.hideHomeProfile
                          ? null
                          : () => _pickHomeAvatar(context),
                    ),
                    if (state.hasCustomHomeProfile) ...[
                      const Divider(),
                      ListTile(
                        enabled: !state.hideHomeProfile,
                        leading: const Icon(Icons.restart_alt_rounded),
                        title: const Text('恢复雨课堂资料'),
                        onTap: state.hideHomeProfile
                            ? null
                            : () async {
                                final oldPath = state.homeAvatarPath;
                                await state.resetHomeProfile();
                                await _deleteManagedAvatar(oldPath);
                              },
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 22),
              const _SettingsLabel('外观与主题'),
              Card(
                child: RadioGroup<ThemeMode>(
                  groupValue: state.themeMode,
                  onChanged: (mode) {
                    if (mode != null) state.updateThemeMode(mode);
                  },
                  child: const Column(
                    children: [
                      RadioListTile<ThemeMode>(
                        value: ThemeMode.system,
                        secondary: Icon(Icons.brightness_auto_outlined),
                        title: Text('跟随系统'),
                        subtitle: Text('根据设备系统设置自动切换深浅外观'),
                      ),
                      Divider(),
                      RadioListTile<ThemeMode>(
                        value: ThemeMode.light,
                        secondary: Icon(Icons.light_mode_outlined),
                        title: Text('浅色模式'),
                        subtitle: Text('保持明亮清爽的界面风格'),
                      ),
                      Divider(),
                      RadioListTile<ThemeMode>(
                        value: ThemeMode.dark,
                        secondary: Icon(Icons.dark_mode_outlined),
                        title: Text('深色模式'),
                        subtitle: Text('沉浸暗黑低眩光，适合夜间上课'),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 22),
              const _SettingsLabel('课件导出'),
              Card(
                child: Column(
                  children: [
                    FutureBuilder<String>(
                      future: state.getEffectiveExportDirectory(),
                      builder: (context, snapshot) {
                        final currentPath = snapshot.data ?? '加载中…';
                        final isCustom = state.exportDirectory != null &&
                            state.exportDirectory!.isNotEmpty;
                        return ListTile(
                          leading: const Icon(Icons.folder_outlined),
                          title: const Text('导出保存目录'),
                          subtitle: Text(
                            currentPath,
                            style: const TextStyle(fontSize: 12),
                          ),
                          trailing: Chip(
                            label: Text(
                              isCustom ? '自定义' : '系统下载',
                              style: const TextStyle(fontSize: 11),
                            ),
                            visualDensity: VisualDensity.compact,
                          ),
                          onTap: () => _editExportDirectory(
                            context,
                            currentPath,
                            isCustom,
                          ),
                        );
                      },
                    ),
                    const Divider(),
                    const ListTile(
                      leading: Icon(Icons.info_outline_rounded),
                      title: Text('导出说明'),
                      subtitle: Text('导出的 PDF、图片包及离线网页课件默认保存在系统的【下载】(Download) 文件夹中，支持导出后直接打开与分享给好友。'),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 22),
              const _SettingsLabel('雨课堂节点'),
              Card(
                child: RadioGroup<YktServer>(
                  groupValue: state.selectedServer,
                  onChanged: (value) async {
                    if (value == null || value == state.selectedServer) return;
                    if (state.session != null &&
                        state.session!.server != value) {
                      final confirmed = await showDialog<bool>(
                        context: context,
                        builder: (context) => AlertDialog(
                          title: const Text('切换雨课堂节点'),
                          content: Text(
                            '当前已登录「${state.session!.server.label}」，各节点的登录凭据互相独立。\n\n'
                            '切换至「${value.label}」需要重新登录，是否退出当前账号并切换？',
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(context, false),
                              child: const Text('取消'),
                            ),
                            FilledButton(
                              onPressed: () => Navigator.pop(context, true),
                              child: const Text('切换并重新登录'),
                            ),
                          ],
                        ),
                      );
                      if (confirmed != true) return;
                      await state.logout();
                    }
                    await state.updateServer(value);
                  },
                  child: Column(
                    children: [
                      for (final server in YktServer.values)
                        RadioListTile<YktServer>(
                          value: server,
                          title: Text(server.label),
                          subtitle: Text(server.domain),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 22),
              const _SettingsLabel('自动签到'),
              Card(
                child: RadioGroup<AutoCheckinMode>(
                  groupValue: state.autoCheckinMode,
                  onChanged: (value) {
                    if (value != null) state.updateAutoCheckinMode(value);
                  },
                  child: Column(
                    children: [
                      for (final mode in AutoCheckinMode.values)
                        RadioListTile<AutoCheckinMode>(
                          value: mode,
                          title: Text(mode.label),
                          subtitle: Text(_modeDescription(mode)),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 22),
              const _SettingsLabel('答题'),
              Card(
                child: Column(
                  children: [
                    SwitchListTile(
                      value: state.allowOvertime,
                      onChanged: state.updateAllowOvertime,
                      secondary: const Icon(Icons.timer_outlined),
                      title: const Text('超时/收题后尝试补交'),
                      subtitle: const Text(
                        '调用雨课堂官方 problem/retry 接口；是否能补交由服务端决定。',
                      ),
                    ),
                    const Divider(),
                    SwitchListTile(
                      value: state.autoSubmitEnabled,
                      onChanged: (value) async {
                        if (value &&
                            !kIsWeb &&
                            defaultTargetPlatform == TargetPlatform.android) {
                          final granted =
                              await BackgroundAutoSubmitService.requestNotificationPermission();
                          if (!granted) {
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('需要通知权限才能运行后台课堂服务'),
                                ),
                              );
                            }
                            return;
                          }
                        }
                        await state.updateAutoSubmitEnabled(value);
                        if (!value) {
                          await BackgroundAutoSubmitService.stopAndWait();
                        }
                      },
                      secondary: const Icon(Icons.auto_awesome_outlined),
                      title: const Text('预选答案自动提交'),
                      subtitle: const Text('只自动提交你已预选并保存答案的题；老师发布后等待设定延迟再提交。'),
                    ),
                    ListTile(
                      leading: const Icon(Icons.more_time_rounded),
                      title: const Text('自动提交延迟'),
                      subtitle: Text('${state.autoSubmitDelaySeconds} 秒'),
                      trailing: DropdownButton<int>(
                        value: state.autoSubmitDelaySeconds,
                        underline: const SizedBox.shrink(),
                        items: const [
                          DropdownMenuItem(value: 0, child: Text('立即')),
                          DropdownMenuItem(value: 1, child: Text('1 秒')),
                          DropdownMenuItem(value: 3, child: Text('3 秒')),
                          DropdownMenuItem(value: 5, child: Text('5 秒')),
                          DropdownMenuItem(value: 10, child: Text('10 秒')),
                          DropdownMenuItem(value: 15, child: Text('15 秒')),
                          DropdownMenuItem(value: 30, child: Text('30 秒')),
                        ],
                        onChanged: (value) {
                          if (value != null) {
                            state.updateAutoSubmitDelay(value);
                          }
                        },
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 22),
              const _SettingsLabel('其他'),
              Card(
                child: Column(
                  children: [
                    SwitchListTile(
                      secondary: const Icon(Icons.developer_mode_rounded),
                      title: const Text('开发者模式'),
                      value: state.developerModeEnabled,
                      onChanged: (value) => state.updateDeveloperMode(value),
                    ),
                    if (state.developerModeEnabled) ...[
                      const Divider(),
                      SwitchListTile(
                        secondary: const Icon(Icons.tag_rounded),
                        title: const Text('首页显示「按课堂 ID 进入」'),
                        subtitle: const Text('在首页“正在上课”区域显示手动输入课堂 ID 入口'),
                        value: state.showLessonIdEntry,
                        onChanged: (value) => state.updateShowLessonIdEntry(value),
                      ),
                      const Divider(),
                      ListTile(
                        leading: const Icon(Icons.receipt_long_outlined),
                        title: const Text('自动提交日志'),
                        subtitle: const Text('查看后台匹配和提交结果'),
                        trailing: const Icon(Icons.chevron_right_rounded),
                        onTap: () => _showAutoSubmitLogs(context),
                      ),
                    ],
                    const Divider(),
                    ListTile(
                      leading: const Icon(Icons.cleaning_services_outlined),
                      title: const Text('清除 WebView 缓存'),
                      subtitle: const Text('清理内置网页缓存，不影响登录状态'),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () => _clearWebViewCache(context),
                    ),
                    const Divider(),
                    ListTile(
                      leading: const Icon(Icons.info_outline_rounded),
                      title: const Text('关于'),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const _AboutScreen(),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 26),
              Builder(
                builder: (context) {
                  final isDark = Theme.of(context).brightness == Brightness.dark;
                  return Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: isDark ? const Color(0xFF1E2522) : const Color(0xFFF0F3F1),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: isDark ? const Color(0xFF2C3833) : const Color(0xFFDCE2DE),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('能力边界', style: TextStyle(fontWeight: FontWeight.w800)),
                        const SizedBox(height: 8),
                        Text(
                          '本应用提供课堂同步、签到、课件和随堂题辅助能力。'
                          '相关接口由雨课堂官方控制，部分功能是否可用取决于学校配置和服务端状态。'
                          '不会伪造动态签到码、不会自动生成答案，也没有绕过服务端风控。',
                          style: TextStyle(
                            height: 1.55,
                            color: isDark ? const Color(0xFFA5B2AC) : const Color(0xFF58615D),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
              const SizedBox(height: 16),
              ClassroomNoticePanel(
                message:
                    '当前自动签到策略：${state.autoCheckinMode.label}。'
                    '课堂接口由雨课堂官方控制，接口变化或动态二维码课堂可能需要重新适配。',
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _clearWebViewCache(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清除 WebView 缓存'),
        content: const Text('确定要清理内置网页的页面与资源缓存吗？不会清除当前账号登录状态。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('清除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    try {
      final controller = WebViewController();
      await controller.clearCache();
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已清除 WebView 缓存')),
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('清除失败：$e')),
      );
    }
  }

  Future<void> _showAutoSubmitLogs(BuildContext context) async {
    final logs = await state.autoSubmitStore.readLogs();
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('自动提交日志'),
        content: SizedBox(
          width: double.maxFinite,
          child: logs.isEmpty
              ? const Text('暂无日志')
              : SingleChildScrollView(
                  child: SelectableText(
                    logs.reversed.take(20).join('\n\n'),
                    style: const TextStyle(
                      fontSize: 12,
                      height: 1.5,
                    ),
                  ),
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  String _modeDescription(AutoCheckinMode mode) => switch (mode) {
    AutoCheckinMode.immediate => '应用在前台发现进行中的课堂时直接尝试签到',
    AutoCheckinMode.ask => '发现课堂后由首页按钮确认签到',
    AutoCheckinMode.notify => '只显示正在上课，不自动提交签到',
    AutoCheckinMode.off => '完全关闭自动签到',
  };

  Future<void> _editHomeNickname(BuildContext context) async {
    final controller = TextEditingController(text: state.homeNickname);
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('自定义首页昵称'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 24,
          decoration: const InputDecoration(
            labelText: '昵称',
            hintText: '留空则使用雨课堂昵称',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (value != null) await state.updateHomeNickname(value);
  }

  Future<void> _pickHomeAvatar(BuildContext context) async {
    final picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      imageQuality: 88,
      maxWidth: 1024,
      maxHeight: 1024,
    );
    if (picked == null) return;
    final directory = await getApplicationSupportDirectory();
    final rawName = picked.name;
    final dotIndex = rawName.lastIndexOf('.');
    final extension = (dotIndex != -1 && dotIndex < rawName.length - 1)
        ? rawName.substring(dotIndex + 1).toLowerCase()
        : 'jpg';
    final target = File(
      '${directory.path}/home_avatar_'
      '${DateTime.now().millisecondsSinceEpoch}.'
      '$extension',
    );
    await picked.saveTo(target.path);
    final oldPath = state.homeAvatarPath;
    await state.updateHomeAvatarPath(target.path);
    await _deleteManagedAvatar(oldPath);
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('本地首页头像已更新')));
    }
  }

  Future<void> _deleteManagedAvatar(String path) async {
    if (path.isEmpty || path.startsWith('http')) return;
    final file = File(path);
    if (!await file.exists()) return;
    final directory = await getApplicationSupportDirectory();
    if (file.parent.path == directory.path) {
      await file.delete();
    }
  }

  Future<void> _editExportDirectory(
    BuildContext context,
    String currentPath,
    bool isCustom,
  ) async {
    final defaultDir = await FilePlatformHelper.getDefaultExportDirectory();
    if (!context.mounted) return;

    final controller = TextEditingController(
      text: isCustom ? (state.exportDirectory ?? '') : currentPath,
    );
    try {
      await showDialog<void>(
        context: context,
        builder: (dialogCtx) => AlertDialog(
          title: const Text('设置课件导出目录'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '课件默认导出至手机公开「下载」文件夹，方便直接查看与管理：',
                style: TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                decoration: const InputDecoration(
                  labelText: '存储绝对路径',
                  hintText: '/storage/emulated/0/Download/晴课堂_课件导出',
                ),
                maxLines: 2,
              ),
              const SizedBox(height: 8),
              Text(
                '系统默认路径：\n$defaultDir',
                style: const TextStyle(fontSize: 11, color: Colors.grey),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () async {
                await state.updateExportDirectory(null);
                if (dialogCtx.mounted) Navigator.pop(dialogCtx);
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('已恢复为系统默认下载目录')),
                  );
                }
              },
              child: const Text('恢复默认'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialogCtx),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () async {
                final text = controller.text.trim();
                await state.updateExportDirectory(text.isEmpty ? null : text);
                if (dialogCtx.mounted) Navigator.pop(dialogCtx);
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('已更新课件导出路径')),
                  );
                }
              },
              child: const Text('保存'),
            ),
          ],
        ),
      );
    } finally {
      controller.dispose();
    }
  }
}

class _HomeAvatarPreview extends StatelessWidget {
  const _HomeAvatarPreview({required this.path});

  final String path;

  @override
  Widget build(BuildContext context) {
    if (path.isEmpty) {
      return const CircleAvatar(child: Icon(Icons.person_outline_rounded));
    }
    final ImageProvider<Object>? provider = path.startsWith('http')
        ? NetworkImage(path)
        : FileImage(File(path));
    return CircleAvatar(
      backgroundImage: provider,
      onBackgroundImageError: provider != null ? (_, _) {} : null,
      child: provider == null ? const Icon(Icons.broken_image_outlined) : null,
    );
  }
}

class _SettingsLabel extends StatelessWidget {
  const _SettingsLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: Text(
        text,
        style: const TextStyle(
          color: Color(0xFF69716D),
          fontSize: 13,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _AboutScreen extends StatelessWidget {
  const _AboutScreen();

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final subtleColor = isDark ? const Color(0xFF9EABA4) : const Color(0xFF58615D);

    return Scaffold(
      appBar: AppBar(title: const Text('关于晴课堂')),
      body: SafeArea(
        top: false,
        child: LayoutBuilder(
          builder: (context, viewport) {
            return SingleChildScrollView(
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: viewport.maxHeight),
                child: IntrinsicHeight(
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 520),
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          children: [
                            const SizedBox(height: 32),
                            Container(
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(24),
                                border: Border.all(
                                  color: isDark
                                      ? const Color(0xFF2C3833)
                                      : const Color(0xFFE3E7E5),
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withValues(alpha: 0.06),
                                    blurRadius: 16,
                                    offset: const Offset(0, 6),
                                  ),
                                ],
                              ),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(24),
                                child: Image.asset(
                                  'assets/icon/icon.png',
                                  width: 100,
                                  height: 100,
                                  fit: BoxFit.contain,
                                ),
                              ),
                            ),
                            const SizedBox(height: 16),
                            const Text(
                              '晴课堂',
                              style: TextStyle(
                                fontSize: 22,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              '版本 0.1.0',
                              style: TextStyle(
                                fontSize: 13,
                                color: subtleColor,
                              ),
                            ),
                            const SizedBox(height: 24),
                            Card(
                              child: Padding(
                                padding: const EdgeInsets.all(16),
                                child: const Text(
                                  '“晴课堂”是一款面向雨课堂的轻量辅助客户端，具备实时课堂同步与自动签到、随堂习题推送与草稿防丢、课件预加载与多格式离线导出（PDF / HTML / 图片），以及作业与任务中心提醒等功能。',
                                  style: TextStyle(height: 1.6),
                                ),
                              ),
                            ),
                            const SizedBox(height: 12),
                            const ClassroomNoticePanel(
                              message:
                                  '相关课堂、作业与签到接口均由雨课堂官方控制，部分功能可用性取决于学校配置及服务端状态。'
                                  '应用不会伪造动态签到码、不会自动生成答案，也不绕过服务端风控。',
                            ),
                            const SizedBox(height: 24),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
