package com.engikode.enginote

import android.app.AlertDialog
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.print.PrintAttributes
import android.print.PrintManager
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
import android.graphics.Color
import android.view.Gravity
import android.widget.FrameLayout
import android.widget.TextView
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.result.contract.ActivityResultContracts
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
 *  Not here yet: the screen recorder and the camera bubble (the page hides them when the app
 *  has no recorder).
 */
class MainActivity : ComponentActivity() {
    private lateinit var webView: WebView
    private var chooser: ValueCallback<Array<Uri>>? = null
    private var printer: WebView? = null // kept while its print dialog is up
    private var pendingText = ""

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
        penLog.text = penLines.joinToString("
")
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

        // The page's doorway to the app: window.AndroidShell.postMessage(json), from the app's own page only.
        if (WebViewFeature.isFeatureSupported(WebViewFeature.WEB_MESSAGE_LISTENER)) {
            WebViewCompat.addWebMessageListener(webView, "AndroidShell", setOf("https://$HOST")) { _, message, _, isMainFrame, _ ->
                if (isMainFrame) fromPage(message)
            }
        }

        penLog = TextView(this).apply {
            setTextColor(Color.WHITE)
            setBackgroundColor(0x99000000.toInt())
            textSize = 11f
            setPadding(12, 6, 12, 6)
            text = "pen log: waiting for the pen"
            isClickable = false
        }
        setContentView(FrameLayout(this).apply {
            addView(webView, FrameLayout.LayoutParams(-1, -1))
            addView(penLog, FrameLayout.LayoutParams(-2, -2, Gravity.BOTTOM or Gravity.START))
        })
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
    }
}
