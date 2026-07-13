package com.fenghuo.mixin.fenghuo_chat

import android.content.ContentValues
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream

class MainActivity : FlutterActivity() {
  private val channelName = "fenghuo/gallery"

  override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)
    MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
      .setMethodCallHandler { call, result ->
        if (call.method == "saveImage") {
          val bytes = call.argument<ByteArray>("bytes")
          val name = (call.argument<String>("name") ?: "fenghuo_${System.currentTimeMillis()}").trim()
          val mime = (call.argument<String>("mime") ?: "image/jpeg").trim()
          if (bytes == null || bytes.isEmpty()) {
            result.error("invalid_args", "bytes_empty", null)
            return@setMethodCallHandler
          }
          try {
            val uri = saveImageToGallery(bytes, name, mime)
            result.success(uri.toString())
          } catch (e: Exception) {
            result.error("save_failed", e.message ?: "save_failed", null)
          }
          return@setMethodCallHandler
        }
        result.notImplemented()
      }
  }

  private fun saveImageToGallery(bytes: ByteArray, name: String, mime: String): Uri {
    val safeName = if (name.isEmpty()) "fenghuo_${System.currentTimeMillis()}" else name
    val displayName = if (safeName.contains(".")) safeName else "${safeName}.jpg"

    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
      val resolver = applicationContext.contentResolver
      val values = ContentValues().apply {
        put(MediaStore.MediaColumns.DISPLAY_NAME, displayName)
        put(MediaStore.MediaColumns.MIME_TYPE, mime.ifEmpty { "image/jpeg" })
        put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_PICTURES + File.separator + "Fenghuo")
        put(MediaStore.MediaColumns.IS_PENDING, 1)
      }
      val uri = resolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values)
        ?: throw IllegalStateException("insert_failed")
      resolver.openOutputStream(uri)?.use { it.write(bytes) } ?: throw IllegalStateException("open_output_failed")
      values.clear()
      values.put(MediaStore.MediaColumns.IS_PENDING, 0)
      resolver.update(uri, values, null, null)
      return uri
    }

    val dir = File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_PICTURES), "Fenghuo")
    if (!dir.exists()) dir.mkdirs()
    val file = File(dir, displayName)
    FileOutputStream(file).use { it.write(bytes) }
    MediaScannerConnection.scanFile(
      applicationContext,
      arrayOf(file.absolutePath),
      arrayOf(mime.ifEmpty { "image/jpeg" }),
      null
    )
    return Uri.fromFile(file)
  }
}
