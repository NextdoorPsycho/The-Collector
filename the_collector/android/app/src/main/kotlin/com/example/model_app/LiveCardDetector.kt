package com.example.model_app

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.PointF
import kotlin.math.abs
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min

internal data class LiveQuad(val corners: List<PointF>, val borderSupport: Double)

internal object LiveCardDetector {
    fun bitmap(arguments: Map<*, *>): Bitmap {
        val width = (arguments["width"] as? Number)?.toInt() ?: 0
        val height = (arguments["height"] as? Number)?.toInt() ?: 0
        val stride = (arguments["bytesPerRow"] as? Number)?.toInt() ?: 0
        val bytes = arguments["bytes"] as? ByteArray
            ?: throw IllegalArgumentException("Camera frame pixels are unavailable.")
        val bgra = arguments["format"] == "bgra8888"
        val channels = if (bgra) 4 else 1
        require(width in 1..4096 && height in 1..4096 && stride >= width * channels
            && bytes.size >= (height - 1) * stride + width * channels)
        val pixels = IntArray(width * height)
        for (y in 0 until height) for (x in 0 until width) {
            val offset = y * stride + x * channels
            val b = bytes[offset].toInt() and 255
            val g = if (bgra) bytes[offset + 1].toInt() and 255 else b
            val r = if (bgra) bytes[offset + 2].toInt() and 255 else b
            pixels[y * width + x] = (255 shl 24) or (r shl 16) or (g shl 8) or b
        }
        val source = Bitmap.createBitmap(pixels, width, height, Bitmap.Config.ARGB_8888)
        val rotation = (arguments["rotation"] as? Number)?.toInt() ?: 0
        if (rotation == 0) return source
        require(rotation == 90 || rotation == 180 || rotation == 270)
        val matrix = Matrix().apply { setRotate(rotation.toFloat()) }
        val upright = Bitmap.createBitmap(source, 0, 0, width, height, matrix, true)
        if (upright !== source) source.recycle()
        return upright
    }

    fun quadrilaterals(bitmap: Bitmap): List<LiveQuad> {
        val scale = min(1.0, 640.0 / max(bitmap.width, bitmap.height))
        val width = max(1, (bitmap.width * scale).toInt())
        val height = max(1, (bitmap.height * scale).toInt())
        if (width < 8 || height < 8) return emptyList()
        val small = Bitmap.createScaledBitmap(bitmap, width, height, true)
        val pixels = IntArray(width * height)
        small.getPixels(pixels, 0, width, 0, 0, width, height)
        if (small !== bitmap) small.recycle()
        val gray = IntArray(pixels.size) { index ->
            val p = pixels[index]
            (((p shr 16) and 255) * 77 + ((p shr 8) and 255) * 150 + (p and 255) * 29) shr 8
        }
        val edges = BooleanArray(pixels.size)
        for (y in 1 until height - 1) for (x in 1 until width - 1) {
            val p = y * width + x
            val gx = -gray[p - width - 1] + gray[p - width + 1] - 2 * gray[p - 1] + 2 * gray[p + 1]
                - gray[p + width - 1] + gray[p + width + 1]
            val gy = -gray[p - width - 1] - 2 * gray[p - width] - gray[p - width + 1]
                + gray[p + width - 1] + 2 * gray[p + width] + gray[p + width + 1]
            if (abs(gx) + abs(gy) > 180) edges[p] = true
        }
        val connected = BooleanArray(edges.size)
        for (y in 1 until height - 1) for (x in 1 until width - 1) {
            if (edges[y * width + x]) {
                for (dy in -1..1) for (dx in -1..1) connected[(y + dy) * width + x + dx] = true
            }
        }
        val visited = BooleanArray(edges.size)
        val queue = IntArray(edges.size)
        val proposals = mutableListOf<LiveQuad>()
        for (start in connected.indices) {
            if (!connected[start] || visited[start]) continue
            var head = 0
            var tail = 1
            queue[0] = start
            visited[start] = true
            val points = mutableListOf<PointF>()
            while (head < tail) {
                val p = queue[head++]
                val x = p % width
                val y = p / width
                if (edges[p] && points.size < 20000) points.add(PointF(x.toFloat(), y.toFloat()))
                for (dy in -1..1) for (dx in -1..1) {
                    val nx = x + dx
                    val ny = y + dy
                    if (nx !in 0 until width || ny !in 0 until height) continue
                    val next = ny * width + nx
                    if (connected[next] && !visited[next]) {
                        visited[next] = true
                        queue[tail++] = next
                    }
                }
            }
            if (points.size < 80 || tail > edges.size / 2) continue
            val hull = convexHull(points).toMutableList()
            while (hull.size > 4) {
                val remove = hull.indices.minBy { index ->
                    abs(cross(hull[(index + hull.size - 1) % hull.size], hull[index], hull[(index + 1) % hull.size]))
                }
                hull.removeAt(remove)
            }
            if (hull.size != 4) continue
            val area = polygonArea(hull)
            if (area < width * height * 0.006 || area > width * height * 0.95) continue
            val lengths = hull.indices.map { index -> distance(hull[index], hull[(index + 1) % 4]) }
            val first = (lengths[0] + lengths[2]) / 2
            val second = (lengths[1] + lengths[3]) / 2
            val ratio = min(first, second) / max(first, second)
            if (ratio !in 0.48..0.90) continue
            if (hull.indices.any { index ->
                val a = hull[(index + 3) % 4]
                val b = hull[index]
                val c = hull[(index + 1) % 4]
                val cosine = ((a.x - b.x) * (c.x - b.x) + (a.y - b.y) * (c.y - b.y)) /
                    (distance(a, b) * distance(c, b))
                abs(cosine) > 0.6
            }) continue
            val borderHits = hull.indices.sumOf { index ->
                val a = hull[index]
                val b = hull[(index + 1) % 4]
                (0..15).count { step ->
                    val x = (a.x + (b.x - a.x) * step / 15).toInt()
                    val y = (a.y + (b.y - a.y) * step / 15).toInt()
                    (-3..3).any { dy -> (-3..3).any { dx ->
                        val nx = x + dx
                        val ny = y + dy
                        nx in 0 until width && ny in 0 until height && edges[ny * width + nx]
                    } }
                }
            }
            if (borderHits < 40) continue
            val topLeft = hull.indices.minBy { index -> hull[index].x + hull[index].y }
            val ordered = (0..3).map { index ->
                val point = hull[(topLeft + index) % 4]
                PointF(point.x / width, point.y / height)
            }
            proposals.add(LiveQuad(ordered, borderHits / 64.0))
        }
        val accepted = mutableListOf<LiveQuad>()
        for (proposal in proposals.sortedByDescending { polygonArea(it.corners) }) {
            val box = bounds(proposal.corners)
            val nested = accepted.any { existing ->
                val outer = bounds(existing.corners)
                val overlap = max(0f, min(box[2], outer[2]) - max(box[0], outer[0])) *
                    max(0f, min(box[3], outer[3]) - max(box[1], outer[1]))
                overlap > (box[2] - box[0]) * (box[3] - box[1]) * 0.65
            }
            if (!nested) accepted.add(proposal)
            if (accepted.size == 8) break
        }
        return accepted
    }

    fun rectify(source: Bitmap, points: List<PointF>): Bitmap {
        val corners = points.map { PointF(it.x * source.width, it.y * source.height) }
        val width = max(1, ((distance(corners[0], corners[1]) + distance(corners[2], corners[3])) / 2).toInt())
        val height = max(1, ((distance(corners[1], corners[2]) + distance(corners[3], corners[0])) / 2).toInt())
        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        val matrix = Matrix()
        val from = corners.flatMap { listOf(it.x, it.y) }.toFloatArray()
        val to = floatArrayOf(0f, 0f, width.toFloat(), 0f, width.toFloat(), height.toFloat(), 0f, height.toFloat())
        check(matrix.setPolyToPoly(from, 0, to, 0, 4))
        Canvas(bitmap).drawBitmap(source, matrix, Paint(Paint.FILTER_BITMAP_FLAG))
        if (height >= width) return bitmap
        val rotation = Matrix().apply { setRotate(90f) }
        val upright = Bitmap.createBitmap(bitmap, 0, 0, width, height, rotation, true)
        if (upright !== bitmap) bitmap.recycle()
        return upright
    }

    private fun cross(a: PointF, b: PointF, c: PointF): Double =
        ((b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)).toDouble()

    private fun distance(a: PointF, b: PointF): Double = hypot((b.x - a.x).toDouble(), (b.y - a.y).toDouble())

    private fun polygonArea(points: List<PointF>): Double = abs(points.indices.sumOf { index ->
        val a = points[index]
        val b = points[(index + 1) % points.size]
        (a.x * b.y - b.x * a.y).toDouble()
    }) / 2

    private fun bounds(points: List<PointF>): FloatArray = floatArrayOf(
        points.minOf { it.x }, points.minOf { it.y }, points.maxOf { it.x }, points.maxOf { it.y })

    private fun convexHull(points: List<PointF>): List<PointF> {
        val sorted = points.distinctBy { Pair(it.x, it.y) }.sortedWith(compareBy<PointF> { it.x }.thenBy { it.y })
        val lower = mutableListOf<PointF>()
        for (point in sorted) {
            while (lower.size >= 2 && cross(lower[lower.size - 2], lower.last(), point) <= 0) lower.removeAt(lower.lastIndex)
            lower.add(point)
        }
        val upper = mutableListOf<PointF>()
        for (point in sorted.asReversed()) {
            while (upper.size >= 2 && cross(upper[upper.size - 2], upper.last(), point) <= 0) upper.removeAt(upper.lastIndex)
            upper.add(point)
        }
        return lower.dropLast(1) + upper.dropLast(1)
    }
}
