package site.jiclub.gongxiaohu_flutter

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private var notificationPermissionResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        createAutoSubmitNotificationChannel()

        // 通知权限通道
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "site.jiclub/notifications",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "requestPermission" -> requestNotificationPermission(result)
                "isGranted" -> result.success(hasNotificationPermission())
                else -> result.notImplemented()
            }
        }

        // 课件导出文件与分享通道
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "site.jiclub/file_helper",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "getPublicDownloadsDirectory" -> {
                    try {
                        val downloadDir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
                        result.success(downloadDir.absolutePath)
                    } catch (e: Exception) {
                        result.error("GET_DOWNLOAD_DIR_FAILED", e.message, null)
                    }
                }
                "openFile" -> {
                    val filePath = call.argument<String>("path")
                    val mimeType = call.argument<String>("mimeType") ?: "*/*"
                    if (filePath.isNullOrBlank()) {
                        result.error("INVALID_PATH", "文件路径不能为空", null)
                        return@setMethodCallHandler
                    }
                    try {
                        val file = File(filePath)
                        if (!file.exists()) {
                            result.error("FILE_NOT_FOUND", "文件不存在: $filePath", null)
                            return@setMethodCallHandler
                        }
                        val uri: Uri = FileProvider.getUriForFile(
                            this,
                            "${applicationContext.packageName}.fileprovider",
                            file
                        )
                        val intent = Intent(Intent.ACTION_VIEW).apply {
                            setDataAndType(uri, mimeType)
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        }
                        val chooser = Intent.createChooser(intent, "打开课件").apply {
                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        }
                        startActivity(chooser)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("OPEN_FAILED", e.message, null)
                    }
                }
                "shareFile" -> {
                    val filePath = call.argument<String>("path")
                    val mimeType = call.argument<String>("mimeType") ?: "*/*"
                    val title = call.argument<String>("title") ?: "分享课件"
                    if (filePath.isNullOrBlank()) {
                        result.error("INVALID_PATH", "文件路径不能为空", null)
                        return@setMethodCallHandler
                    }
                    try {
                        val file = File(filePath)
                        if (!file.exists()) {
                            result.error("FILE_NOT_FOUND", "文件不存在: $filePath", null)
                            return@setMethodCallHandler
                        }
                        val uri: Uri = FileProvider.getUriForFile(
                            this,
                            "${applicationContext.packageName}.fileprovider",
                            file
                        )
                        val intent = Intent(Intent.ACTION_SEND).apply {
                            type = mimeType
                            putExtra(Intent.EXTRA_STREAM, uri)
                            putExtra(Intent.EXTRA_SUBJECT, title)
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        }
                        val chooser = Intent.createChooser(intent, title).apply {
                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        }
                        startActivity(chooser)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("SHARE_FAILED", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun createAutoSubmitNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java)
        val channel = NotificationChannel(
            "ykt_auto_submit",
            "雨课堂自动提交",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "保持课堂连接并在老师发题后提交预选答案"
        }
        manager.createNotificationChannel(channel)
    }

    private fun requestNotificationPermission(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            hasNotificationPermission()
        ) {
            result.success(true)
            return
        }
        if (notificationPermissionResult != null) {
            result.error("pending", "Notification permission request is pending", null)
            return
        }
        notificationPermissionResult = result
        requestPermissions(
            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
            NOTIFICATION_PERMISSION_REQUEST,
        )
    }

    private fun hasNotificationPermission(): Boolean {
        return Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == NOTIFICATION_PERMISSION_REQUEST) {
            notificationPermissionResult?.success(hasNotificationPermission())
            notificationPermissionResult = null
        }
    }

    companion object {
        private const val NOTIFICATION_PERMISSION_REQUEST = 4021
    }
}
