import 'package:flutter/material.dart';

class ClassroomNoticePanel extends StatelessWidget {
  const ClassroomNoticePanel({
    required this.message,
    this.onDismiss,
    super.key,
  });

  final String message;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? const Color(0xFF2A1C1C) : const Color(0xFFFDECEC);
    final border = isDark ? const Color(0xFF4A2B2B) : const Color(0xFFF0C8C8);
    final text = isDark ? const Color(0xFFE8B2B2) : const Color(0xFF7D302A);
    final iconColor = isDark ? const Color(0xFFF08C8C) : const Color(0xFF9A3F35);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.info_outline_rounded,
                size: 20,
                color: iconColor,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  message,
                  style: TextStyle(
                    height: 1.55,
                    color: text,
                  ),
                ),
              ),
            ],
          ),
          if (onDismiss != null) ...[
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: onDismiss,
                style: TextButton.styleFrom(
                  foregroundColor: iconColor,
                ),
                child: const Text('不再提醒'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
