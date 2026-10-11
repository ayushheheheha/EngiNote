package com.engikode.enginote

import android.Manifest
import android.app.AlertDialog
import android.app.Dialog
import android.content.Intent
import android.content.pm.ActivityInfo
import android.content.pm.PackageManager
import android.graphics.Color
import android.media.projection.MediaProjectionManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.print.PrintAttributes
import android.print.PrintManager
import android.util.DisplayMetrics
import android.view.Gravity
import android.view.InputDevice
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.WindowManager
import android.webkit.JsResult
import android.webkit.ValueCallback
import android.webkit.WebChromeClient
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.FrameLayout
import android.widget.MediaController
import android.widget.TextView
import android.widget.Toast
import android.widget.VideoView
import androidx.activity.ComponentActivity
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.ContextCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.webkit.WebMessageCompat
import androidx.webkit.WebViewAssetLoader
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import org.json.JSONObject

/**
 * The whole screen: a web view showing the web app (the files in assets/, copied there by
 * .github/workflows/android.yml), edge to edge with no bars.
 *
 * What this adds to the web app:
 *  - The pen's side button, which a web page is never told about, passed on as the same 'pencil'
 *    event the iPad app sends (see app.js): a click is 'tap' (eraser on and off), a click held for
 *    half a second, or the pen's second button, is 'squeeze' (undo).
 *  - The dialogs behind confirm() and alert(), which a bare web view does not show.
 *  - Choosing files to import, and saving a backup (the page's 'save' message).
 *  - Printing a note as a PDF (the page's 'print' message): Android's print dialog can save one.
 *  - Recording the screen as a 16:9 movie (Recorder.kt), started and stopped by the page (the
 *    'recorder' message), which is told how it goes (a 'recorder' event on its window).
 *  - The recordings themselves: the page lists them as a folder, and asks for one to be played,
 *    shared or deleted (the 'recordings' message; the list goes back as a 'recordings' event).
 *  - The mic check (the 'mic' message, 'mic' events) and the camera bubble (CameraBubble.kt, the
 *    'camera' message, 'camera' events).
 *
 *  The page was written for the iPad app, and talks to it with window.webkit.messageHandlers.<name>
 *  .postMessage(...). Here a small script (SHIM) gives it the same four doorways, and they all lead
 *  to window.AndroidShell.postMessage, with the doorway's name as the message's "type".
 */
class MainActivity : ComponentActivity() {
    private lateinit var webView: WebView
    private lateinit var bubble: CameraBubble
    private var chooser: ValueCallback<Array<Uri>>? = null
    private var printer: WebView? = null // kept while its print dialog is up
    private var pendingText = ""

    private val mic = Mic(
        onLevel = { level -> send("mic", JSONObject().put("levels", org.json.JSONArray().put(level))) },
        onFailed = { why -> send("mic", JSONObject().put("on", false).put("message", why)) },
    )

    // The pen's buttons as last seen, so that a press and its release can be told apart.
    private var primaryDownAt = -1L
    private var secondaryDown = false
    private var lastButtons = -1
    private var lastTool = -1

    // ponytail: a log of the raw pen input, drawn over the page, until the pad's pen is known to work.
    private lateinit var penLog: TextView
    private val penLines = ArrayDeque<String>()
    private fun log(line: String) {
        penLines.addLast(line)
        while (penLines.size > 9) penLines.removeFirst()
        penLog.text = penLines.joinToString(separator = "\u000A")
    }

    // Asking the user: a system question, then what was to be done.
    private var afterPermissions: (() -> Unit)? = null
    private val askPermissions = registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
        val then = afterPermissions
        afterPermissions = null
        then?.invoke()
    }

    private val pickFiles = registerForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
        chooser?.onReceiveValue(WebChromeClient.FileChooserParams.parseResult(result.resultCode, result.data))
        chooser = null
    }

    private val saveFile = registerForActivityResult(ActivityResultContracts.CreateDocument("application/json")) { uri ->
        if (uri == null) return@registerForActivityResult
        try {
            contentResolver.openOutputStream(uri)?.use { it.write(pendingText.toByteArray()) }
            Toast.makeText(this, "Saved.", Toast.LENGTH_SHORT).show()
        } catch (e: Exception) {
            Toast.makeText(this, "Could not save the file.", Toast.LENGTH_LONG).show()
        }
        pendingText = ""
    }

    // The recording's asking for the screen, and what the page asked for with it.
    private var startBody: JSONObject? = null
    private var starting = false
    private val captureScreen = registerForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
        val data = result.data
        if (result.resultCode == RESULT_OK && data != null) {
            beginRecording(result.resultCode, data)
        } else {
            starting = false
            send("recorder", JSONObject().put("state", "idle").put("message", "Recording did not start: the screen was not shared."))
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        WindowCompat.setDecorFitsSystemWindows(window, false)
        window.attributes = window.attributes.apply { layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES }
        WindowInsetsControllerCompat(window, window.decorView).apply {
            systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            hide(WindowInsetsCompat.Type.systemBars())
        }

        // The web app is served at https://appassets.androidplatform.net/ from the assets folder.
        // It saves notes in the web view's storage, and that storage is kept per address. So this
        // address must NEVER change: under any other the saved notes would still be on the tablet
        // but the app would no longer see them.
        val assets = WebViewAssetLoader.Builder()
            .addPathHandler("/", WebViewAssetLoader.AssetsPathHandler(this))
            .build()

        webView = WebView(this)
        webView.settings.apply {
            javaScriptEnabled = true
            domStorageEnabled = true // IndexedDB and localStorage: where the notes are
            allowFileAccess = false
            allowContentAccess = false
            textZoom = 100
            cacheMode = WebSettings.LOAD_DEFAULT
        }
        webView.overScrollMode = WebView.OVER_SCROLL_NEVER
        webView.isVerticalScrollBarEnabled = false
        WebView.setWebContentsDebuggingEnabled(true) // chrome://inspect on a computer, for debugging

        webView.webViewClient = object : WebViewClient() {
            override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse? =
                assets.shouldInterceptRequest(request.url)

            // Only the app's own pages; a link out is not followed.
            override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest) = request.url.host != HOST
        }
        webView.webChromeClient = object : WebChromeClient() {
            override fun onJsAlert(view: WebView, url: String, message: String, result: JsResult): Boolean {
                AlertDialog.Builder(this@MainActivity).setMessage(message)
                    .setPositiveButton("OK") { _, _ -> result.confirm() }
                    .setOnCancelListener { result.confirm() }.show()
                return true
            }

            override fun onJsConfirm(view: WebView, url: String, message: String, result: JsResult): Boolean {
                AlertDialog.Builder(this@MainActivity).setMessage(message)
                    .setPositiveButton("OK") { _, _ -> result.confirm() }
                    .setNegativeButton("Cancel") { _, _ -> result.cancel() }
                    .setOnCancelListener { result.cancel() }.show()
                return true
            }

            override fun onShowFileChooser(view: WebView, callback: ValueCallback<Array<Uri>>, params: FileChooserParams): Boolean {
                chooser?.onReceiveValue(null)
                chooser = callback
                return try {
                    pickFiles.launch(params.createIntent())
                    true
                } catch (e: Exception) {
                    chooser = null
                    callback.onReceiveValue(null)
                    false
                }
            }
        }

        // The page's doorways to the app: window.AndroidShell.postMessage(json), from the app's own page only.
        val origins = setOf("https://$HOST")
        if (WebViewFeature.isFeatureSupported(WebViewFeature.WEB_MESSAGE_LISTENER)) {
            WebViewCompat.addWebMessageListener(webView, "AndroidShell", origins) { _, message, _, isMainFrame, _ ->
                if (isMainFrame) fromPage(message)
            }
        }
        if (WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT)) {
            WebViewCompat.addDocumentStartJavaScript(webView, SHIM, origins)
        }

        bubble = CameraBubble(this)
        bubble.onNews = { on, problem ->
            val news = JSONObject().put("on", on).put("shape", bubble.shape)
            if (problem != null) news.put("message", problem)
            send("camera", news)
        }
        penLog = TextView(this).apply {
            setTextColor(Color.WHITE)
            setBackgroundColor(0x99000000.toInt())
            textSize = 11f
            setPadding(12, 6, 12, 6)
            text = "pen log: waiting for the pen"
            isClickable = false
        }
        val root = FrameLayout(this).apply {
            addView(webView, FrameLayout.LayoutParams(-1, -1))
            addView(bubble, FrameLayout.LayoutParams(0, 0)) // over the page; hidden until the page asks for it
            addView(penLog, FrameLayout.LayoutParams(-2, -2, Gravity.BOTTOM or Gravity.START))
            // The tablet turned, or the window resized: the bubble must still be wholly on screen.
            addOnLayoutChangeListener { _, _, _, _, _, _, _, _, _ -> bubble.place() }
        }
        setContentView(root)

        Session.stopRequested = { stopRecording(null) }
        webView.loadUrl("https://$HOST/index.html")
    }

    // MARK: Messages from the page

    private fun fromPage(message: WebMessageCompat) {
        val body = try { JSONObject(message.data ?: return) } catch (e: Exception) { return }
        when (body.optString("type")) {
            "save" -> {
                pendingText = body.optString("text")
                saveFile.launch(body.optString("name", "EngiNote backup.json"))
            }
            "print" -> printNote(body.optString("name", "EngiNote"), body.optString("html"))
            "recorder" -> record(body)
            "recordings" -> recordings(body)
            "mic" -> checkMic(body)
            "camera" -> showCamera(body)
        }
    }

    /** An event on the page's window with `detail` as its detail. The detail travels as JSON, so
     *  whatever text is in it (an error message, say) cannot become code. */
    private fun send(event: String, detail: JSONObject) {
        runOnUiThread {
            webView.evaluateJavascript("window.dispatchEvent(new CustomEvent('$event', { detail: $detail }))", null)
        }
    }

    private fun has(permission: String) = checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED

    /** Ask for what is missing (the system asks the user), then do `then` whatever the answer was:
     *  it looks again at what it has. */
    private fun withPermissions(wanted: List<String>, then: () -> Unit) {
        val missing = wanted.filter { !has(it) }
        if (missing.isEmpty()) {
            then()
        } else {
            afterPermissions = then
            askPermissions.launch(missing.toTypedArray())
        }
    }

    /** The note as a document in a web view of its own (no scripts), handed to the print dialog. */
    private fun printNote(name: String, html: String) {
        val view = WebView(this)
        view.settings.javaScriptEnabled = false
        view.webViewClient = object : WebViewClient() {
            override fun onPageFinished(page: WebView, url: String) {
                val manager = getSystemService(PRINT_SERVICE) as PrintManager
                manager.print(name, page.createPrintDocumentAdapter(name), PrintAttributes.Builder().build())
            }
        }
        printer = view
        view.loadDataWithBaseURL(null, html, "text/html", "utf-8", null)
    }

    // MARK: Recording

    private fun record(body: JSONObject) {
        val recorder = Session.recorder
        when (body.optString("action")) {
            "start" -> startRecording(body)
            "pause" -> if (recorder != null) {
                recorder.pause()
                send("recorder", JSONObject().put("state", "paused"))
            } else {
                send("recorder", JSONObject().put("state", "idle"))
            }
            "resume" -> if (recorder != null) {
                recorder.resume()
                send("recorder", JSONObject().put("state", "recording"))
            } else {
                send("recorder", JSONObject().put("state", "idle"))
            }
            "stop" -> stopRecording(null)
            else -> send("recorder", JSONObject().put("state", if (recorder == null) "idle" else if (recorder.isPaused) "paused" else "recording"))
        }
    }

    private fun startRecording(body: JSONObject) {
        if (starting || Session.recorder != null) {
            send("recorder", JSONObject().put("state", if (Session.recorder?.isPaused == true) "paused" else if (Session.recorder != null) "recording" else "idle"))
            return
        }
        starting = true
        startBody = body
        val wanted = ArrayList<String>()
        if (body.optBoolean("microphone", true)) wanted.add(Manifest.permission.RECORD_AUDIO)
        if (Build.VERSION.SDK_INT >= 33) wanted.add(Manifest.permission.POST_NOTIFICATIONS) // for the notification that says the screen is being recorded
        withPermissions(wanted) {
            val manager = getSystemService(MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
            captureScreen.launch(manager.createScreenCaptureIntent())
        }
    }

    /** The user has agreed to share the screen: start the service that records it. */
    private fun beginRecording(code: Int, data: Intent) {
        val body = startBody ?: JSONObject()
        val wantMic = body.optBoolean("microphone", true)
        val micOk = wantMic && has(Manifest.permission.RECORD_AUDIO) && mic.start(body.optBoolean("enhance", false))
        val note = when {
            !wantMic || micOk -> null
            !has(Manifest.permission.RECORD_AUDIO) -> "EngiNote is not allowed to use the microphone (Settings > Apps > EngiNote > Permissions): this recording has no sound."
            else -> "The microphone could not be started: this recording has no sound."
        }

        // The video is made in the way up the screen has now: turning the tablet would change its size.
        requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_LOCKED
        val metrics = DisplayMetrics()
        @Suppress("DEPRECATION")
        windowManager.defaultDisplay.getRealMetrics(metrics)
        val params = Recorder.Params(
            quality = body.optString("quality", "standard"), wide = body.optBoolean("wide", true), microphone = micOk,
            title = body.optString("title"), screenW = metrics.widthPixels, screenH = metrics.heightPixels, dpi = metrics.densityDpi,
        )
        Session.pending = Session.Pending(params, mic, code, data) { recorder, error ->
            starting = false
            if (recorder == null) {
                requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
                mic.sink = null
                mic.stopIfUnwanted()
                send("recorder", JSONObject().put("state", "idle").put("message", "Recording did not start: ${error ?: "the screen could not be recorded"}."))
            } else {
                recorder.onFailure = { why -> stopRecording(why) }
                window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON) // the screen must not lock in the middle of a lecture
                val news = JSONObject().put("state", "recording")
                if (note != null) news.put("message", note)
                send("recorder", news)
                // A voice that is not arriving must not be found out an hour later: look after a few seconds.
                if (micOk) webView.postDelayed({
                    val current = Session.recorder
                    if (current === recorder && !current.isPaused && !current.hasSound) {
                        send("recorder", JSONObject().put("state", "recording").put("message", "Warning: no sound is being recorded. Stop and start again; if it stays silent, switch Enhance the other way."))
                    }
                }, 5000)
            }
        }
        ContextCompat.startForegroundService(this, Intent(this, RecordService::class.java))
    }

    /** Stop, finish the movie and tell the page. `problem`: why, if it was not the user's choice. */
    private fun stopRecording(problem: String?) {
        val recorder = Session.recorder
        if (recorder == null) {
            send("recorder", JSONObject().put("state", "idle"))
            return
        }
        Session.recorder = null
        recorder.stop { uri, error ->
            window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
            stopService(Intent(this, RecordService::class.java))
            mic.stopIfUnwanted()
            val trouble = problem ?: error
            val place = "the Gallery and Files, under Movies > EngiNote"
            val message = when {
                uri == null -> "Recording failed: ${trouble ?: "nothing was recorded"}."
                trouble != null -> "Recording stopped: $trouble. What was recorded is in $place."
                else -> "Recording saved. It is in $place."
            }
            send("recorder", JSONObject().put("state", "idle").put("message", message))
        }
    }

    // MARK: The recordings folder

    /** Play, share or delete one recording, as the page asks; then, whatever was asked (also just
     *  "list"), send the page the list as it now stands. */
    private fun recordings(body: JSONObject) {
        val name = body.optString("name")
        val action = body.optString("action")
        Thread {
            val uri = if (name.isNotEmpty()) Recordings.find(this, name) else null
            if (uri != null) {
                when (action) {
                    "play" -> runOnUiThread { play(uri) }
                    "share" -> runOnUiThread { share(uri) }
                    "delete" -> Recordings.delete(this, uri) // the page has already asked the user if they are sure
                }
            }
            val files = Recordings.list(this)
            send("recordings", JSONObject().put("files", files))
        }.start()
    }

    private fun play(uri: Uri) {
        val video = VideoView(this)
        video.setVideoURI(uri)
        video.setMediaController(MediaController(this).also { it.setAnchorView(video) })
        val frame = FrameLayout(this).apply {
            setBackgroundColor(Color.BLACK)
            addView(video, FrameLayout.LayoutParams(-1, -1, Gravity.CENTER))
        }
        val player = Dialog(this, android.R.style.Theme_Black_NoTitleBar_Fullscreen)
        player.setContentView(frame)
        player.setOnDismissListener { video.stopPlayback() }
        player.show()
        video.start()
    }

    private fun share(uri: Uri) {
        val send = Intent(Intent.ACTION_SEND).setType("video/mp4").putExtra(Intent.EXTRA_STREAM, uri).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        startActivity(Intent.createChooser(send, "Save or share"))
    }

    // MARK: The mic check

    private fun checkMic(body: JSONObject) {
        val on = body.optBoolean("on")
        mic.checking = on
        if (!on) {
            mic.stopIfUnwanted()
            return
        }
        withPermissions(listOf(Manifest.permission.RECORD_AUDIO)) {
            if (!mic.checking) return@withPermissions // switched off while the question was up
            when {
                !has(Manifest.permission.RECORD_AUDIO) -> {
                    mic.checking = false
                    send("mic", JSONObject().put("on", false).put("message", "EngiNote is not allowed to use the microphone (Settings > Apps > EngiNote > Permissions)."))
                }
                !mic.start(body.optBoolean("enhance", false)) -> {
                    mic.checking = false
                    send("mic", JSONObject().put("on", false).put("message", "The microphone could not be started."))
                }
            }
        }
    }

    // MARK: The camera bubble

    private fun showCamera(body: JSONObject) {
        body.optString("shape").takeIf { it.isNotEmpty() }?.let { bubble.reshape(it) } // a name it does not know changes nothing
        if (!body.optBoolean("on")) {
            bubble.turnOff()
            return
        }
        withPermissions(listOf(Manifest.permission.CAMERA)) {
            if (has(Manifest.permission.CAMERA)) {
                bubble.turnOn()
            } else {
                bubble.onNews?.invoke(false, "EngiNote is not allowed to use the camera (Settings > Apps > EngiNote > Permissions).")
            }
        }
    }

    // MARK: The pen

    private fun tellPage(gesture: String) {
        webView.evaluateJavascript("window.dispatchEvent(new CustomEvent('pencil', { detail: '$gesture' }))", null)
    }

    /** A press of the pen's button is read from the button state each pen event carries, as events
     *  that announce a press are not sent by every tablet. Some pens report their button as the
     *  mouse's right button, so that counts too. */
    private fun watchPen(e: MotionEvent) {
        val tool = e.getToolType(0)
        val pen = tool == MotionEvent.TOOL_TYPE_STYLUS || tool == MotionEvent.TOOL_TYPE_ERASER || e.isFromSource(InputDevice.SOURCE_STYLUS)
        if (!pen) return
        if (tool != lastTool) { lastTool = tool; log("tool $tool source 0x${Integer.toHexString(e.source)}") }
        val state = e.buttonState
        if (state != lastButtons) { lastButtons = state; log("buttons 0x${Integer.toHexString(state)} action ${e.actionMasked}") }
        if (e.actionMasked == MotionEvent.ACTION_BUTTON_PRESS || e.actionMasked == MotionEvent.ACTION_BUTTON_RELEASE) {
            log("button ${if (e.actionMasked == MotionEvent.ACTION_BUTTON_PRESS) "press" else "release"} ${e.actionButton}")
        }
        val primary = (state and (MotionEvent.BUTTON_STYLUS_PRIMARY or MotionEvent.BUTTON_SECONDARY)) != 0
        val secondary = (state and MotionEvent.BUTTON_STYLUS_SECONDARY) != 0
        if (primary && primaryDownAt < 0) primaryDownAt = e.eventTime
        if (!primary && primaryDownAt >= 0) {
            val gesture = if (e.eventTime - primaryDownAt >= HOLD_MS) "squeeze" else "tap"
            log("-> $gesture")
            tellPage(gesture)
            primaryDownAt = -1
        }
        if (secondary && !secondaryDown) { log("-> squeeze (second button)"); tellPage("squeeze") }
        secondaryDown = secondary
    }

    override fun dispatchTouchEvent(e: MotionEvent): Boolean {
        watchPen(e)
        return super.dispatchTouchEvent(e)
    }

    // A pen hovering over the screen reports its button here, not as a touch.
    override fun dispatchGenericMotionEvent(e: MotionEvent): Boolean {
        watchPen(e)
        return super.dispatchGenericMotionEvent(e)
    }

    // Some pens (Android 14 and later) send their buttons as keys instead. Seen before the page
    // can use them; any other key from a pen-like device is only logged.
    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        val code = event.keyCode
        val stylus = code == KeyEvent.KEYCODE_STYLUS_BUTTON_PRIMARY || code == KeyEvent.KEYCODE_STYLUS_BUTTON_SECONDARY ||
            code == KeyEvent.KEYCODE_STYLUS_BUTTON_TERTIARY || code == KeyEvent.KEYCODE_STYLUS_BUTTON_TAIL
        val fromPen = ((event.device?.sources ?: 0) and InputDevice.SOURCE_STYLUS) != 0
        if (stylus || fromPen) {
            if (event.repeatCount == 0) log("key ${KeyEvent.keyCodeToString(code)} ${if (event.action == KeyEvent.ACTION_DOWN) "down" else "up"}")
        }
        if (!stylus) return super.dispatchKeyEvent(event)
        if (event.action == KeyEvent.ACTION_UP) {
            val held = event.eventTime - event.downTime >= HOLD_MS
            val gesture = if (code == KeyEvent.KEYCODE_STYLUS_BUTTON_PRIMARY && !held) "tap" else "squeeze"
            log("-> $gesture")
            tellPage(gesture)
        }
        return true
    }

    companion object {
        const val HOST = "appassets.androidplatform.net"
        const val HOLD_MS = 500L // a click held this long counts as the squeeze

        /** The page's doorways to the app, in the shape the iPad app gives them (see the class comment). */
        private const val SHIM = """(function () {
  var door = function (type) {
    return { postMessage: function (body) { window.AndroidShell.postMessage(JSON.stringify(Object.assign({ type: type }, body))); } };
  };
  window.webkit = { messageHandlers: { recorder: door('recorder'), recordings: door('recordings'), mic: door('mic'), camera: door('camera') } };
})();"""
    }
}
