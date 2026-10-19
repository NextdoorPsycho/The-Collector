package com.example.model_app

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ImageDecoder
import android.graphics.Matrix
import android.media.ExifInterface
import android.os.Build
import android.os.Handler
import android.os.Looper
import com.google.android.gms.tasks.Tasks
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.Text
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.latin.TextRecognizerOptions
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class LocalCardScanner(private val context: Context) : MethodChannel.MethodCallHandler {
    private val executor = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private val recognizer = TextRecognition.getClient(TextRecognizerOptions.DEFAULT_OPTIONS)
    private var busy = false
    private var disposed = false
    private var liveOcrOffset = 0
    private data class PendingWork(val result: MethodChannel.Result,
        val operation: () -> Map<String, Any>)
    private val foreground = ArrayDeque<PendingWork>()

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "recognize" && call.method != "detectFrame") {
            result.notImplemented()
            return
        }
        val path = call.argument<String>("path")
        if (call.method == "recognize" && (path == null || !File(path).isFile)) {
            result.error("invalid_image", "The selected image is unavailable.", null)
            return
        }
        if (disposed) {
            result.error("scanner_unavailable", "Image analysis is unavailable.", null)
            return
        }
        val pending = PendingWork(result) {
            if (call.method == "detectFrame") {
                detectFrame(call.arguments as? Map<*, *>
                    ?: throw IllegalArgumentException("Camera frame is unavailable."))
            } else {
                recognize(path!!, call.argument<Boolean>("multipleCards") == true)
            }
        }
        if (busy) {
            if (call.method == "detectFrame") {
                result.error("scanner_busy", "Image analysis is already running.", null)
            } else if (foreground.size < 8) {
                foreground.addLast(pending)
            } else {
                result.error("scanner_queue_full", "Too many images are waiting for analysis.", null)
            }
            return
        }
        start(pending)
    }

    private fun start(pending: PendingWork) {
        busy = true
        executor.execute {
            try {
                val output = pending.operation()
                main.post {
                    busy = false
                    if (!disposed) {
                        pending.result.success(output)
                        drainForeground()
                    }
                }
            } catch (error: Exception) {
                main.post {
                    busy = false
                    if (!disposed) {
                        pending.result.error("recognition_failed", error.message, null)
                        drainForeground()
                    }
                }
            }
        }
    }

    private fun drainForeground() {
        if (foreground.isNotEmpty()) start(foreground.removeFirst())
    }

    private fun detectFrame(arguments: Map<*, *>): Map<String, Any> {
        val bitmap = LiveCardDetector.bitmap(arguments)
        try {
            val rectangles = LiveCardDetector.quadrilaterals(bitmap)
            val includeText = arguments["includeText"] == true
            val count = rectangles.size
            val selected = if (count == 0) emptySet() else (0 until minOf(2, count))
                .map { (liveOcrOffset + it) % count }.toSet()
            if (includeText && count > 0) liveOcrOffset = (liveOcrOffset + 2) % count
            val cards = rectangles.mapIndexed { index, rectangle ->
                val points = rectangle.corners
                var lines: List<Map<String, Any>> = emptyList()
                val warnings = mutableListOf("experimental_rectangle")
                if (includeText && selected.contains(index)) {
                    val crop = LiveCardDetector.rectify(bitmap, points)
                    try {
                        val text = Tasks.await(recognizer.process(InputImage.fromBitmap(crop, 0)),
                            5, TimeUnit.SECONDS)
                        lines = text.textBlocks.flatMap { it.lines }
                            .sortedBy { it.boundingBox?.top ?: 0 }
                            .mapNotNull { lineMap(it, crop.width, crop.height) }.take(64)
                        val hasTitle = text.textBlocks.flatMap { it.lines }.any { line ->
                            val box = line.boundingBox
                            box != null && box.top.toDouble() / crop.height < 0.13 &&
                                box.height().toDouble() / crop.height < 0.07 &&
                                box.width().toDouble() / crop.width > 0.10 &&
                                line.text.count { it.isLetter() } >= 3
                        }
                        if (!hasTitle) warnings.add("incomplete_card")
                        if (crop.height < 500) warnings.add("small_image")
                    } finally {
                        crop.recycle()
                    }
                }
                mapOf("corners" to points.map { mapOf("x" to it.x.toDouble(), "y" to it.y.toDouble()) },
                    "confidence" to rectangle.borderSupport, "lines" to lines, "warnings" to warnings)
            }
            return mapOf("width" to bitmap.width, "height" to bitmap.height,
                "rectanglesSupported" to true, "cards" to cards)
        } finally {
            bitmap.recycle()
        }
    }

    private fun recognize(path: String, multiple: Boolean): Map<String, Any> {
        val bitmap = decodeUpright(path)
        try {
            val text = Tasks.await(
                recognizer.process(InputImage.fromBitmap(bitmap, 0)), 45, TimeUnit.SECONDS)
            val directory = File(context.cacheDir, "ScanCrops")
            check(directory.isDirectory || directory.mkdirs()) { "Cannot create image cache." }
            val crop = File(directory, "${UUID.randomUUID()}.jpg")
            crop.outputStream().use { stream ->
                check(bitmap.compress(Bitmap.CompressFormat.JPEG, 94, stream)) { "Cannot save image crop." }
            }
            val lines = text.textBlocks.flatMap { block -> block.lines }
                .sortedBy { line -> line.boundingBox?.top ?: 0 }
                .mapNotNull { line -> lineMap(line, bitmap.width, bitmap.height) }
            val warnings = mutableListOf("no_card_rectangle")
            // Android currently recognizes one guided card per image, without segmentation.
            if (multiple) warnings.add("multi_card_segmentation_unavailable")
            if (bitmap.height < 700) warnings.add("small_image")
            if (lines.isEmpty()) warnings.add("no_text")
            val item = mapOf(
                "imagePath" to crop.absolutePath,
                "width" to bitmap.width,
                "height" to bitmap.height,
                "rectified" to false,
                "sourceCorners" to listOf(
                    mapOf("x" to 0.0, "y" to 0.0), mapOf("x" to 1.0, "y" to 0.0),
                    mapOf("x" to 1.0, "y" to 1.0), mapOf("x" to 0.0, "y" to 1.0)),
                "lines" to lines,
                "warnings" to warnings)
            return mapOf("imagePath" to path, "width" to bitmap.width,
                "height" to bitmap.height, "crops" to listOf(item))
        } finally {
            bitmap.recycle()
        }
    }

    private fun lineMap(line: Text.Line, width: Int, height: Int): Map<String, Any>? {
        val box = line.boundingBox ?: return null
        return mapOf(
            "text" to line.text,
            "confidence" to line.confidence.toDouble(),
            "alternatives" to emptyList<String>(),
            "bounds" to mapOf(
                "x" to (box.left.toDouble() / width).coerceIn(0.0, 1.0),
                "y" to (box.top.toDouble() / height).coerceIn(0.0, 1.0),
                "width" to (box.width().toDouble() / width).coerceIn(0.0, 1.0),
                "height" to (box.height().toDouble() / height).coerceIn(0.0, 1.0)))
    }

    private fun decodeUpright(path: String): Bitmap {
        if (Build.VERSION.SDK_INT >= 28) {
            return ImageDecoder.decodeBitmap(ImageDecoder.createSource(File(path))) { decoder, info, _ ->
                decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
                val longest = maxOf(info.size.width, info.size.height)
                if (longest > 4096) {
                    val scale = 4096.0 / longest
                    decoder.setTargetSize((info.size.width * scale).toInt().coerceAtLeast(1),
                        (info.size.height * scale).toInt().coerceAtLeast(1))
                }
            }
        }
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(path, bounds)
        val options = BitmapFactory.Options()
        while (maxOf(bounds.outWidth, bounds.outHeight) / options.inSampleSize > 4096) {
            options.inSampleSize *= 2
        }
        val bitmap = BitmapFactory.decodeFile(path, options)
            ?: throw IllegalArgumentException("This image cannot be decoded. Choose another image.")
        val orientation = ExifInterface(path).getAttributeInt(
            ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)
        val matrix = Matrix()
        when (orientation) {
            ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> matrix.setScale(-1f, 1f)
            ExifInterface.ORIENTATION_ROTATE_180 -> matrix.setRotate(180f)
            ExifInterface.ORIENTATION_FLIP_VERTICAL -> matrix.setScale(1f, -1f)
            ExifInterface.ORIENTATION_TRANSPOSE -> { matrix.setRotate(90f); matrix.postScale(-1f, 1f) }
            ExifInterface.ORIENTATION_ROTATE_90 -> matrix.setRotate(90f)
            ExifInterface.ORIENTATION_TRANSVERSE -> { matrix.setRotate(-90f); matrix.postScale(-1f, 1f) }
            ExifInterface.ORIENTATION_ROTATE_270 -> matrix.setRotate(-90f)
        }
        if (matrix.isIdentity) return bitmap
        val upright = Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, matrix, true)
        if (upright !== bitmap) bitmap.recycle()
        return upright
    }

    fun close() {
        disposed = true
        foreground.clear()
        executor.execute { recognizer.close() }
        executor.shutdown()
    }
}
