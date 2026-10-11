package com.engikode.enginote

import android.content.Context
import android.graphics.SurfaceTexture
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaMuxer
import android.media.projection.MediaProjection
import android.net.Uri
import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLExt
import android.opengl.EGLSurface
import android.opengl.GLES11Ext
import android.opengl.GLES20
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.view.Surface
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.max
import kotlin.math.min

/**
 * Records the tablet's screen, with the microphone, as an MP4 in Movies/EngiNote (Recordings.kt).
 *
 * The screen is captured whole (MediaProjection) into a texture; only the 16:9 band across its
 * middle is drawn into the video encoder. That band is exactly where the page puts its 16:9 window
 * (full width, centred), and the page's recording controls sit outside it, so they are never in
 * the picture. With 16:9 off, the whole screen is kept.
 *
 * The screen only sends a picture when something changes, so the last one is drawn again a few
 * times a second: the movie then has a steady picture to cut, and a pause leaves no hole.
 * Time is the device's clock; a pause is taken out of it, so the movie runs straight on.
 *
 * Unlike the iPad's, the movie is written in one piece: if the app is killed in the middle, that
 * recording is lost. (The recording runs in a foreground service, which keeps that unlikely.)
 *
 * None of this can be run off the device: it was written against the documentation and is only
 * proven by recording on the tablet.
 */
class Recorder(private val context: Context, private val mic: Mic) {
    class Params(
        val quality: String, val wide: Boolean, val microphone: Boolean, val title: String,
        val screenW: Int, val screenH: Int, val dpi: Int,
    )

    private class Quality(val width: Int, val height: Int, val bitRate: Int)

    private class Piece(val track: Int, val data: ByteBuffer, val info: MediaCodec.BufferInfo)

    companion object {
        /** The choices offered by the page (index.html, #rec-quality): the names must match. */
        private val QUALITIES = mapOf(
            "high" to Quality(1920, 1080, 8_000_000),
            "standard" to Quality(1920, 1080, 4_000_000),
            "small" to Quality(1280, 720, 2_000_000),
        )
        private const val FRAME_MS = 33L          // the picture is made about thirty times a second
        private const val KEEPALIVE_NS = 200_000_000L // an unchanging screen is drawn again after this long
        private const val VOICE_SHIFT_NS = 0L     // how much later (+) or earlier (-) the voice is written than heard: the knob if voice and picture do not line up
        private const val RECORDABLE = 0x3142     // EGL_RECORDABLE_ANDROID
    }

    /** Called on the main thread, once, if the recording cannot go on (with why). The caller then stops it. */
    var onFailure: ((String) -> Unit)? = null

    private val main = Handler(Looper.getMainLooper())

    // The file and the muxer.
    private var entry: Recordings.Entry? = null
    private var muxer: MediaMuxer? = null
    private val muxLock = Any()
    private var tracksWanted = 1
    private var tracksAdded = 0
    private var muxStarted = false
    private var wrote = false
    private val lastPts = longArrayOf(-1, -1)
    private val waiting = ArrayList<Piece>()

    // The picture.
    private var projection: MediaProjection? = null
    private var display: VirtualDisplay? = null
    private var videoEncoder: MediaCodec? = null
    private var videoThread: Thread? = null
    private var gl: HandlerThread? = null
    private lateinit var glHandler: Handler
    private var eglDisplay: EGLDisplay = EGL14.EGL_NO_DISPLAY
    private var eglContext: EGLContext = EGL14.EGL_NO_CONTEXT
    private var eglSurface: EGLSurface = EGL14.EGL_NO_SURFACE
    private var inputSurface: Surface? = null
    private var texture: SurfaceTexture? = null
    private var textureId = 0
    private var program = 0
    private var outW = 0
    private var outH = 0
    private val matrix = FloatArray(16)
    private lateinit var positions: FloatBuffer
    private lateinit var coords: FloatBuffer
    private val newFrame = AtomicBoolean(false)
    private var hasFrame = false
    private var lastDraw = 0L
    private var lastFramePts = -1L
    @Volatile private var rendering = false

    // The voice.
    private var audioEncoder: MediaCodec? = null
    private var audioThread: Thread? = null
    private val audioLock = Any()
    private var audioEnded = false
    @Volatile private var soundPieces = 0

    // Time.
    private var startNanos = 0L
    @Volatile private var pausedTotal = 0L
    private var pausedAt = 0L
    @Volatile var isPaused = false
        private set
    private val active = AtomicBoolean(false)
    @Volatile private var aborted = false
    private var failure: String? = null

    val isActive: Boolean get() = active.get()

    /** Sound has actually reached the movie. (False a few seconds in means the voice is being lost.) */
    val hasSound: Boolean get() = soundPieces > 0

    /** Start. Returns what went wrong, or null. Main thread. */
    fun start(projection: MediaProjection, p: Params): String? {
        val quality = QUALITIES[p.quality] ?: QUALITIES.getValue("standard")
        val w = p.screenW
        val h = p.screenH

        // What part of the screen is kept, and how big the picture is.
        val cropX: Int; val cropY: Int; val cropW: Int; val cropH: Int
        if (p.wide) {
            if (w * 9 <= h * 16) { // not wider than 16:9: all the width, the 16:9 band across the middle
                cropW = w; cropH = w * 9 / 16; cropX = 0; cropY = (h - cropH) / 2
            } else {
                cropH = h; cropW = h * 16 / 9; cropY = 0; cropX = (w - cropW) / 2
            }
            outW = quality.width; outH = quality.height
        } else {
            cropX = 0; cropY = 0; cropW = w; cropH = h
            val boxW = if (w >= h) quality.width else quality.height
            val boxH = if (w >= h) quality.height else quality.width
            val scale = min(1.0, min(boxW.toDouble() / w, boxH.toDouble() / h))
            outW = (w * scale).toInt() / 2 * 2
            outH = (h * scale).toInt() / 2 * 2
        }

        try {
            entry = Recordings.create(context, p.title)
            muxer = MediaMuxer(entry!!.pfd.fileDescriptor, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
            tracksWanted = if (p.microphone) 2 else 1

            val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, outW, outH).apply {
                setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
                setInteger(MediaFormat.KEY_BIT_RATE, quality.bitRate)
                setInteger(MediaFormat.KEY_FRAME_RATE, 30)
                setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 2)
            }
            val encoder = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
            encoder.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            inputSurface = encoder.createInputSurface()
            encoder.start()
            videoEncoder = encoder

            if (p.microphone) {
                val sound = MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_AAC, Mic.RATE, 1).apply {
                    setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
                    setInteger(MediaFormat.KEY_BIT_RATE, 96_000)
                    setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 16384)
                }
                val sounder = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC)
                sounder.configure(sound, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
                sounder.start()
                audioEncoder = sounder
            }

            // The drawing thread, with its own EGL context, drawing into the encoder's surface.
            val thread = HandlerThread("EngiNote picture").also { it.start() }
            gl = thread
            glHandler = Handler(thread.looper)
            var problem: String? = null
            val ready = CountDownLatch(1)
            glHandler.post {
                try {
                    setUpGl(w, h, cropX, cropY, cropW, cropH)
                } catch (e: Exception) {
                    problem = e.message ?: e.toString()
                }
                ready.countDown()
            }
            if (!ready.await(5, TimeUnit.SECONDS)) throw IllegalStateException("the picture could not be set up in time")
            problem?.let { throw IllegalStateException(it) }

            // The screen itself.
            this.projection = projection
            projection.registerCallback(object : MediaProjection.Callback() {
                override fun onStop() {
                    if (active.get()) fail("the screen capture was stopped") // not the stop we asked for ourselves
                }
            }, main)
            display = projection.createVirtualDisplay(
                "EngiNote", w, h, p.dpi, DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR, Surface(texture!!), null, glHandler,
            )

            startNanos = System.nanoTime()
            pausedTotal = 0
            isPaused = false
            aborted = false
            active.set(true)
            rendering = true
            glHandler.post(tick)
            videoThread = Thread { runDrain(videoEncoder!!, true) }.also { it.name = "EngiNote video"; it.start() }
            if (audioEncoder != null) {
                audioThread = Thread { runDrain(audioEncoder!!, false) }.also { it.name = "EngiNote sound"; it.start() }
                mic.sink = { bytes, n, at -> onAudio(bytes, n, at) }
            }
            return null
        } catch (e: Exception) {
            val why = e.message ?: e.toString()
            active.set(false)
            aborted = true
            mic.sink = null
            tearDown()
            return why
        }
    }

    fun pause() {
        if (!active.get() || isPaused) return
        pausedAt = System.nanoTime()
        isPaused = true
    }

    fun resume() {
        if (!active.get() || !isPaused) return
        pausedTotal += System.nanoTime() - pausedAt
        isPaused = false
    }

    /** Stop, finish the movie and say how it went (on the main thread): the movie, or why not. */
    fun stop(done: (Uri?, String?) -> Unit) {
        if (!active.compareAndSet(true, false)) {
            main.post { done(null, "nothing was being recorded") }
            return
        }
        mic.sink = null
        Thread {
            if (isPaused) resume()
            rendering = false
            try { display?.release() } catch (e: Exception) { /* gone already */ }
            try { projection?.stop() } catch (e: Exception) { /* gone already */ }
            val ended = CountDownLatch(1)
            glHandler.post {
                try { videoEncoder?.signalEndOfInputStream() } catch (e: Exception) { fail("the picture could not be finished") }
                ended.countDown()
            }
            ended.await(2, TimeUnit.SECONDS)
            synchronized(audioLock) {
                audioEnded = true
                val encoder = audioEncoder
                if (encoder != null) {
                    try {
                        val i = encoder.dequeueInputBuffer(200_000)
                        if (i >= 0) encoder.queueInputBuffer(i, 0, 0, max(0, (System.nanoTime() - startNanos - pausedTotal) / 1000), MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                    } catch (e: Exception) { /* the drain below ends on its own timeout */ }
                }
            }
            videoThread?.join(5000)
            audioThread?.join(5000)
            aborted = true // anything still waiting for its end gives up
            val saved = finishFile()
            tearDown()
            val why = failure ?: if (saved == null) "nothing was recorded" else null
            main.post { done(saved, why) }
        }.start()
    }

    // MARK: Drawing

    private val tick = object : Runnable {
        override fun run() {
            if (!rendering) return
            try {
                val now = System.nanoTime()
                val fresh = newFrame.get()
                if (isPaused) {
                    if (newFrame.getAndSet(false)) texture?.updateTexImage() // keep the screen's queue empty
                } else if (fresh || (hasFrame && now - lastDraw >= KEEPALIVE_NS)) {
                    draw(now)
                }
            } catch (e: Exception) {
                fail("the picture could not be drawn")
                return
            }
            glHandler.postDelayed(this, FRAME_MS)
        }
    }

    private fun draw(now: Long) {
        val st = texture ?: return
        if (newFrame.getAndSet(false)) {
            st.updateTexImage()
            hasFrame = true
        }
        if (!hasFrame) return
        st.getTransformMatrix(matrix)
        GLES20.glViewport(0, 0, outW, outH)
        GLES20.glUseProgram(program)
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, textureId)
        val position = GLES20.glGetAttribLocation(program, "aPosition")
        val coord = GLES20.glGetAttribLocation(program, "aTexCoord")
        GLES20.glEnableVertexAttribArray(position)
        GLES20.glVertexAttribPointer(position, 2, GLES20.GL_FLOAT, false, 8, positions)
        GLES20.glEnableVertexAttribArray(coord)
        GLES20.glVertexAttribPointer(coord, 2, GLES20.GL_FLOAT, false, 8, coords)
        GLES20.glUniformMatrix4fv(GLES20.glGetUniformLocation(program, "uTexMatrix"), 1, false, matrix, 0)
        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
        GLES20.glDisableVertexAttribArray(position)
        GLES20.glDisableVertexAttribArray(coord)
        var pts = max(0L, now - startNanos - pausedTotal)
        if (pts <= lastFramePts) pts = lastFramePts + 1_000_000
        lastFramePts = pts
        EGLExt.eglPresentationTimeANDROID(eglDisplay, eglSurface, pts)
        EGL14.eglSwapBuffers(eglDisplay, eglSurface)
        lastDraw = now
    }

    private fun setUpGl(w: Int, h: Int, cropX: Int, cropY: Int, cropW: Int, cropH: Int) {
        eglDisplay = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
        val version = IntArray(2)
        check(EGL14.eglInitialize(eglDisplay, version, 0, version, 1)) { "EGL would not start" }
        val wanted = intArrayOf(
            EGL14.EGL_RED_SIZE, 8, EGL14.EGL_GREEN_SIZE, 8, EGL14.EGL_BLUE_SIZE, 8, EGL14.EGL_ALPHA_SIZE, 8,
            EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT, RECORDABLE, 1, EGL14.EGL_NONE,
        )
        val configs = arrayOfNulls<EGLConfig>(1)
        val found = IntArray(1)
        check(EGL14.eglChooseConfig(eglDisplay, wanted, 0, configs, 0, 1, found, 0) && found[0] > 0) { "no suitable EGL configuration" }
        eglContext = EGL14.eglCreateContext(eglDisplay, configs[0], EGL14.EGL_NO_CONTEXT, intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 2, EGL14.EGL_NONE), 0)
        eglSurface = EGL14.eglCreateWindowSurface(eglDisplay, configs[0], inputSurface, intArrayOf(EGL14.EGL_NONE), 0)
        check(EGL14.eglMakeCurrent(eglDisplay, eglSurface, eglSurface, eglContext)) { "EGL would not draw" }

        program = buildProgram(
            "uniform mat4 uTexMatrix; attribute vec4 aPosition; attribute vec4 aTexCoord; varying vec2 vTexCoord;" +
                "void main() { gl_Position = aPosition; vTexCoord = (uTexMatrix * aTexCoord).xy; }",
            "#extension GL_OES_EGL_image_external : require\n" +
                "precision mediump float; varying vec2 vTexCoord; uniform samplerExternalOES sTexture;" +
                "void main() { gl_FragColor = texture2D(sTexture, vTexCoord); }",
        )
        val ids = IntArray(1)
        GLES20.glGenTextures(1, ids, 0)
        textureId = ids[0]
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, textureId)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)

        // The kept part of the screen, as fractions of it, bottom left first (the way texture space runs).
        val x0 = cropX.toFloat() / w
        val x1 = (cropX + cropW).toFloat() / w
        val y0 = 1f - (cropY + cropH).toFloat() / h
        val y1 = 1f - cropY.toFloat() / h
        positions = floats(-1f, -1f, 1f, -1f, -1f, 1f, 1f, 1f)
        coords = floats(x0, y0, x1, y0, x0, y1, x1, y1)

        val st = SurfaceTexture(textureId)
        st.setDefaultBufferSize(w, h)
        st.setOnFrameAvailableListener({ newFrame.set(true) }, glHandler)
        texture = st
    }

    private fun floats(vararg values: Float): FloatBuffer =
        ByteBuffer.allocateDirect(values.size * 4).order(ByteOrder.nativeOrder()).asFloatBuffer().apply { put(values); position(0) }

    private fun buildProgram(vertex: String, fragment: String): Int {
        fun compile(type: Int, source: String): Int {
            val shader = GLES20.glCreateShader(type)
            GLES20.glShaderSource(shader, source)
            GLES20.glCompileShader(shader)
            val ok = IntArray(1)
            GLES20.glGetShaderiv(shader, GLES20.GL_COMPILE_STATUS, ok, 0)
            check(ok[0] != 0) { "a shader would not compile: " + GLES20.glGetShaderInfoLog(shader) }
            return shader
        }
        val program = GLES20.glCreateProgram()
        GLES20.glAttachShader(program, compile(GLES20.GL_VERTEX_SHADER, vertex))
        GLES20.glAttachShader(program, compile(GLES20.GL_FRAGMENT_SHADER, fragment))
        GLES20.glLinkProgram(program)
        val ok = IntArray(1)
        GLES20.glGetProgramiv(program, GLES20.GL_LINK_STATUS, ok, 0)
        check(ok[0] != 0) { "the shaders would not link" }
        return program
    }

    // MARK: Sound

    private fun onAudio(bytes: ByteArray, n: Int, at: Long) {
        if (isPaused || !active.get()) return
        synchronized(audioLock) {
            val encoder = audioEncoder ?: return
            if (audioEnded) return
            try {
                val i = encoder.dequeueInputBuffer(5_000)
                if (i < 0) return
                val buffer = encoder.getInputBuffer(i) ?: return
                buffer.clear()
                val length = min(n, buffer.remaining())
                buffer.put(bytes, 0, length)
                val chunkNs = length / 2L * 1_000_000_000L / Mic.RATE
                val pts = max(0L, at - chunkNs + VOICE_SHIFT_NS - startNanos - pausedTotal) / 1000
                encoder.queueInputBuffer(i, 0, length, pts, 0)
                soundPieces++
            } catch (e: Exception) {
                fail("the sound could not be recorded")
            }
        }
    }

    // MARK: The file

    private fun runDrain(codec: MediaCodec, video: Boolean) {
        try {
            val info = MediaCodec.BufferInfo()
            var track = -1
            while (!aborted) {
                val i = codec.dequeueOutputBuffer(info, 10_000)
                if (i == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    track = addTrack(codec.outputFormat)
                } else if (i >= 0) {
                    val buffer = codec.getOutputBuffer(i)
                    val config = (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0
                    if (buffer != null && info.size > 0 && !config && track >= 0) write(track, buffer, info)
                    codec.releaseOutputBuffer(i, false)
                    if ((info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) return
                }
            }
        } catch (e: Exception) {
            fail(if (video) "the picture could not be written" else "the sound could not be written")
        }
    }

    private fun addTrack(format: MediaFormat): Int = synchronized(muxLock) {
        val m = muxer ?: return -1
        val id = m.addTrack(format)
        tracksAdded++
        if (tracksAdded == tracksWanted) {
            m.start()
            muxStarted = true
            for (piece in waiting) m.writeSampleData(piece.track, piece.data, piece.info)
            if (waiting.isNotEmpty()) wrote = true
            waiting.clear()
        }
        id
    }

    private fun write(track: Int, data: ByteBuffer, info: MediaCodec.BufferInfo) {
        synchronized(muxLock) {
            val m = muxer ?: return
            var pts = info.presentationTimeUs
            if (pts <= lastPts[track]) pts = lastPts[track] + 1 // the muxer wants each track's time to move on
            lastPts[track] = pts
            data.position(info.offset)
            data.limit(info.offset + info.size)
            if (!muxStarted) { // the other track has not begun yet: keep this for when it has
                val copy = ByteBuffer.allocate(info.size)
                copy.put(data)
                copy.flip()
                waiting.add(Piece(track, copy, MediaCodec.BufferInfo().apply { set(0, info.size, pts, info.flags) }))
                return
            }
            m.writeSampleData(track, data, MediaCodec.BufferInfo().apply { set(info.offset, info.size, pts, info.flags) })
            wrote = true
        }
    }

    /** Close the movie. The movie, or null if there is nothing in it (which is then deleted). */
    private fun finishFile(): Uri? {
        val file = entry ?: return null
        var good = false
        synchronized(muxLock) {
            try {
                if (muxStarted && wrote) {
                    muxer?.stop()
                    good = true
                }
            } catch (e: Exception) {
                if (failure == null) failure = "the movie could not be finished"
            }
            try { muxer?.release() } catch (e: Exception) { /* nothing to do */ }
            muxer = null
        }
        try { file.pfd.close() } catch (e: Exception) { /* nothing to do */ }
        entry = null
        return if (good) {
            Recordings.finish(context, file.uri)
            file.uri
        } else {
            Recordings.delete(context, file.uri)
            null
        }
    }

    private fun tearDown() {
        rendering = false
        try { display?.release() } catch (e: Exception) { /* nothing to do */ }
        display = null
        try { projection?.stop() } catch (e: Exception) { /* nothing to do */ }
        projection = null
        for (codec in listOf(videoEncoder, audioEncoder)) {
            try { codec?.stop() } catch (e: Exception) { /* nothing to do */ }
            try { codec?.release() } catch (e: Exception) { /* nothing to do */ }
        }
        videoEncoder = null
        audioEncoder = null
        synchronized(muxLock) {
            try { muxer?.release() } catch (e: Exception) { /* nothing to do */ }
            muxer = null
        }
        val thread = gl
        if (thread != null) {
            val cleaned = CountDownLatch(1)
            glHandler.post {
                try {
                    texture?.release()
                    if (eglDisplay != EGL14.EGL_NO_DISPLAY) {
                        EGL14.eglMakeCurrent(eglDisplay, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT)
                        if (eglSurface != EGL14.EGL_NO_SURFACE) EGL14.eglDestroySurface(eglDisplay, eglSurface)
                        if (eglContext != EGL14.EGL_NO_CONTEXT) EGL14.eglDestroyContext(eglDisplay, eglContext)
                        EGL14.eglReleaseThread()
                        EGL14.eglTerminate(eglDisplay)
                    }
                } catch (e: Exception) { /* nothing to do */ }
                cleaned.countDown()
            }
            cleaned.await(2, TimeUnit.SECONDS)
            thread.quitSafely()
            gl = null
        }
        texture = null
        inputSurface?.release()
        inputSurface = null
        if (entry != null) { // set up but never finished: no empty file is left behind
            try { entry?.pfd?.close() } catch (e: Exception) { /* nothing to do */ }
            Recordings.delete(context, entry!!.uri)
            entry = null
        }
    }

    private fun fail(reason: String) {
        if (failure != null) return
        failure = reason
        main.post { if (active.get()) onFailure?.invoke(reason) }
    }
}
