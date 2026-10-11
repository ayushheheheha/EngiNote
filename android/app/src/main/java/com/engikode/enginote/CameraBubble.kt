package com.engikode.enginote

import android.graphics.Color
import android.graphics.Outline
import android.graphics.drawable.GradientDrawable
import android.view.GestureDetector
import android.view.MotionEvent
import android.view.ScaleGestureDetector
import android.view.View
import android.view.ViewOutlineProvider
import android.widget.FrameLayout
import androidx.camera.core.CameraSelector
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.activity.ComponentActivity
import androidx.core.content.ContextCompat
import kotlin.math.max
import kotlin.math.min

/**
 * The camera bubble: the front camera's picture in a small view that floats over the app, so
 * whoever is teaching can be in the video too. One finger drags it anywhere on the screen, two
 * pinch it larger or smaller, and a double tap (or the page's button) gives it the next of its
 * four shapes. Where it is, how big it is and its shape are remembered.
 *
 * It is a view of the app's own, above the web view, because a page cannot use the camera. Being
 * on the screen it is in a recording of the screen (in a 16:9 recording: as far as it lies over
 * the 16:9 window; it may be put anywhere, that window or not).
 *
 * It has nothing to do with sound: the camera is opened for its picture alone.
 *
 * None of this can be run off the device: it is only proven on the tablet.
 */
class CameraBubble(private val activity: ComponentActivity) : FrameLayout(activity) {
    companion object {
        /** The names the page uses (app.js, SHAPES): they must match. */
        val SHAPES = listOf("circle", "square", "wide", "tall")
        private const val SHORT_SIDE = 0.5625f // 9 / 16
    }

    /** Called on the main thread with every outcome the page should know: whether the bubble is
     *  showing, and, when it was asked for and is not, why. */
    var onNews: ((Boolean, String?) -> Unit)? = null

    var shape = "circle"
        private set
    private val density = resources.displayMetrics.density
    private var side = 180 * density // its longer side
    // Its middle, as fractions of the screen's width and height, so that it keeps its corner when the
    // tablet is turned. To begin with: at the right, inside the 16:9 window either way up.
    private var spotX = 0.84f
    private var spotY = 0.6f

    private val prefs = activity.getSharedPreferences("camera", 0)
    private val preview = PreviewView(activity).apply { implementationMode = PreviewView.ImplementationMode.COMPATIBLE }
    private val rim = GradientDrawable().apply { setStroke((2 * density).toInt(), Color.argb(217, 255, 255, 255)); setColor(Color.TRANSPARENT) }
    private var provider: ProcessCameraProvider? = null

    private var lastX = Float.NaN
    private var lastY = Float.NaN

    private val taps = GestureDetector(activity, object : GestureDetector.SimpleOnGestureListener() {
        override fun onDown(e: MotionEvent) = true
        override fun onDoubleTap(e: MotionEvent): Boolean {
            reshape(SHAPES[(SHAPES.indexOf(shape) + 1) % SHAPES.size])
            onNews?.invoke(true, null)
            return true
        }
    })
    private val pinch = ScaleGestureDetector(activity, object : ScaleGestureDetector.SimpleOnScaleGestureListener() {
        override fun onScale(detector: ScaleGestureDetector): Boolean {
            val parentSide = (parent as? View)?.let { min(it.width, it.height) } ?: 0
            side = (side * detector.scaleFactor).coerceIn(90 * density, max(90 * density, parentSide * 0.9f))
            fit()
            return true
        }
    })

    init {
        visibility = GONE
        setBackgroundColor(Color.BLACK)
        elevation = 8 * density
        addView(preview, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
        foreground = rim
        clipToOutline = true // this is what gives the picture its shape
        outlineProvider = object : ViewOutlineProvider() {
            override fun getOutline(view: View, outline: Outline) {
                outline.setRoundRect(0, 0, view.width, view.height, radius(view.width, view.height))
            }
        }
        prefs.getString("shape", null)?.let { if (it in SHAPES) shape = it }
        side = prefs.getFloat("side", side)
        spotX = prefs.getFloat("x", spotX)
        spotY = prefs.getFloat("y", spotY)
    }

    private fun radius(w: Int, h: Int): Float = if (shape == "circle") min(w, h) / 2f else 14 * density

    /** Its size for its shape and side, kept wholly on the screen. */
    private fun fit() {
        val w = if (shape == "tall") side * SHORT_SIDE else side
        val h = if (shape == "wide") side * SHORT_SIDE else side
        val params = (layoutParams as? LayoutParams) ?: LayoutParams(0, 0)
        params.width = w.toInt()
        params.height = h.toInt()
        layoutParams = params
        rim.cornerRadius = radius(w.toInt(), h.toInt())
        invalidateOutline()
        place()
    }

    /** Put it where it was last left, moved in if the screen has changed shape. */
    fun place() {
        val screen = parent as? View ?: return
        if (screen.width == 0) return
        val w = width.takeIf { it > 0 } ?: layoutParams.width
        val h = height.takeIf { it > 0 } ?: layoutParams.height
        x = (spotX * screen.width - w / 2f).coerceIn(0f, max(0f, (screen.width - w).toFloat()))
        y = (spotY * screen.height - h / 2f).coerceIn(0f, max(0f, (screen.height - h).toFloat()))
    }

    fun reshape(next: String) {
        if (next !in SHAPES) return
        shape = next
        fit()
        remember()
    }

    private fun remember() {
        prefs.edit().putString("shape", shape).putFloat("side", side).putFloat("x", spotX).putFloat("y", spotY).apply()
    }

    fun turnOn() {
        visibility = VISIBLE
        fit()
        val future = ProcessCameraProvider.getInstance(activity)
        future.addListener({
            try {
                val camera = future.get()
                provider = camera
                val picture = Preview.Builder().build().also { it.setSurfaceProvider(preview.surfaceProvider) }
                camera.unbindAll()
                camera.bindToLifecycle(activity, CameraSelector.DEFAULT_FRONT_CAMERA, picture)
                onNews?.invoke(true, null)
            } catch (e: Exception) {
                visibility = GONE
                onNews?.invoke(false, "The camera could not be started.")
            }
        }, ContextCompat.getMainExecutor(activity))
    }

    fun turnOff() {
        provider?.unbindAll()
        visibility = GONE
        onNews?.invoke(false, null)
    }

    override fun onTouchEvent(e: MotionEvent): Boolean {
        taps.onTouchEvent(e)
        pinch.onTouchEvent(e)
        val screen = parent as? View ?: return true
        when (e.actionMasked) {
            MotionEvent.ACTION_DOWN -> { lastX = e.rawX; lastY = e.rawY }
            MotionEvent.ACTION_POINTER_DOWN, MotionEvent.ACTION_POINTER_UP -> { lastX = Float.NaN; lastY = Float.NaN } // two fingers pinch; the one left moves it again
            MotionEvent.ACTION_MOVE -> if (!pinch.isInProgress && e.pointerCount == 1) {
                if (lastX.isNaN()) {
                    lastX = e.rawX; lastY = e.rawY
                } else {
                    spotX = (spotX + (e.rawX - lastX) / screen.width).coerceIn(0f, 1f)
                    spotY = (spotY + (e.rawY - lastY) / screen.height).coerceIn(0f, 1f)
                    lastX = e.rawX; lastY = e.rawY
                    place()
                }
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> remember()
        }
        return true
    }
}
