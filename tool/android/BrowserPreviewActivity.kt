package io.github.wkj2333666.android_ssh_codex

import android.app.Activity
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Intent
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.net.Uri
import android.net.http.SslError
import android.os.Bundle
import android.text.TextUtils
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.webkit.*
import android.widget.*
import java.io.ByteArrayInputStream
import java.io.File
import java.io.SequenceInputStream
import java.util.UUID

/** Unprivileged system WebView. Remote pages never receive a native bridge. */
class BrowserPreviewActivity : Activity() {
    companion object {
        const val IMAGE_REQUEST = 4106
        const val PAGE_REQUEST = 4107
        private const val IMAGE_ORIGIN = "https://image-preview.invalid"
        private const val VISUALIZATION_POLICY = "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: blob:; base-uri 'none'; form-action 'none'"
        fun validPage(uri: Uri): Boolean = uri.scheme in listOf("http", "https") &&
            uri.host == "127.0.0.1" && uri.userInfo == null &&
            (uri.port == -1 || uri.port in 1..65535)

        fun imageFile(context: android.content.Context, path: String): File {
            val file = File(path).canonicalFile
            require(file.name == "image" && file.parentFile?.name?.startsWith("codex-image-") == true &&
                file.parentFile?.parentFile == context.cacheDir.canonicalFile &&
                file.isFile && file.length() in 1L..(10L * 1024L * 1024L)) { "Invalid image cache" }
            return file
        }

        fun visualizationFile(context: android.content.Context, path: String): File {
            val file = File(path).canonicalFile
            require(file.name == "payload.bin" &&
                file.parentFile?.name?.startsWith("codex-download-") == true &&
                file.parentFile?.parentFile == context.cacheDir.canonicalFile &&
                file.isFile && file.length() in 1L..(8L * 1024L * 1024L)) { "Invalid visualization cache" }
            return file
        }
    }

    private var web: WebView? = null
    private var origin: Uri? = null
    private var image: File? = null
    private var visualization: File? = null
    private val visualizationUrl by lazy { "https://${UUID.randomUUID()}.visualization.invalid/" }
    private var fitScale = 1f
    private lateinit var status: TextView
    private lateinit var progress: ProgressBar
    private var address: TextView? = null
    private var historyBack: View? = null

    private fun sameOrigin(uri: Uri): Boolean {
        val start = origin ?: return false
        return validPage(uri) && uri.scheme == start.scheme && uri.host == start.host && uri.port == start.port
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        try {
            val path = intent.getStringExtra("path")
            val html = intent.getStringExtra("visualization")
            if (html != null) visualization = visualizationFile(this, html)
            else if (path != null) image = imageFile(this, path)
            else {
                origin = Uri.parse(intent.getStringExtra("url") ?: "")
                require(validPage(origin!!))
            }
            createPreview()
            setResult(RESULT_OK)
        } catch (_: Exception) {
            setResult(RESULT_CANCELED)
            Toast.makeText(this, "System WebView preview is unavailable", Toast.LENGTH_LONG).show()
            finish()
        }
    }

    private fun createPreview() {
        val showingImage = image != null
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            if (showingImage) setBackgroundColor(Color.BLACK)
        }
        root.setOnApplyWindowInsetsListener { view, insets ->
            @Suppress("DEPRECATION")
            view.setPadding(insets.systemWindowInsetLeft, insets.systemWindowInsetTop,
                insets.systemWindowInsetRight, insets.systemWindowInsetBottom)
            insets
        }
        root.addView(if (showingImage) createImageToolbar() else createBrowserToolbar())
        status = TextView(this).apply {
            if (showingImage) setTextColor(Color.WHITE)
            setPadding(dp(16), dp(6), dp(16), dp(6))
            text = if (showingImage) (intent.getStringExtra("name") ?: "Image").take(200) else ""
            maxLines = 3
        }
        status.visibility = if (showingImage) View.VISIBLE else View.GONE
        root.addView(status)
        val content = FrameLayout(this)
        progress = ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal).apply {
            visibility = View.GONE
        }
        val view = WebView(this)
        web = view
        // Keep the system's default canvas for pages without a CSS background.
        if (showingImage) view.setBackgroundColor(Color.BLACK)
        configureWebView(view)
        content.addView(view, FrameLayout.LayoutParams(-1, -1))
        content.addView(progress, FrameLayout.LayoutParams(-1, dp(3), Gravity.TOP))
        root.addView(content, LinearLayout.LayoutParams(-1, 0, 1f))
        setContentView(root)
        view.loadUrl(when {
            showingImage -> "$IMAGE_ORIGIN/"
            visualization != null -> visualizationUrl
            else -> requireNotNull(origin).toString()
        })
    }

    private fun createImageToolbar(): View {
        val toolbar = LinearLayout(this).apply { gravity = Gravity.CENTER_VERTICAL }
        fun button(label: String, action: () -> Unit) {
            toolbar.addView(Button(this).apply {
                text = label
                contentDescription = label
                minWidth = 0
                setPadding(12, 0, 12, 0)
                setOnClickListener { action() }
            }, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
        }
        button("Close") { finish() }
        button("−") { web?.zoomOut() }
        button("+") { web?.zoomIn() }
        button("Fit") {
            @Suppress("DEPRECATION")
            web?.let { if (it.scale > 0f) it.zoomBy(fitScale / it.scale) }
        }
        return toolbar
    }

    private fun createBrowserToolbar(): View {
        val toolbar = LinearLayout(this).apply {
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(4), dp(2), dp(4), dp(2))
        }
        fun addIcon(icon: BrowserIcon, label: String, action: (View) -> Unit): View {
            val button = BrowserButton(icon, label).apply { setOnClickListener(action) }
            toolbar.addView(button, LinearLayout.LayoutParams(dp(48), dp(48)))
            return button
        }
        addIcon(BrowserIcon.CLOSE, "Close preview") { finish() }
        historyBack = addIcon(BrowserIcon.BACK, "Previous page") { web?.goBack() }.apply {
            isEnabled = false
            alpha = 0.38f
        }
        val location = TextView(this).apply {
            gravity = Gravity.CENTER_VERTICAL
            maxLines = 1
            ellipsize = TextUtils.TruncateAt.END
            textSize = 14f
            setPadding(dp(10), 0, dp(10), 0)
            background = android.graphics.drawable.GradientDrawable().apply {
                cornerRadius = dp(18).toFloat()
                setColor(Color.argb(24, Color.red(currentTextColor), Color.green(currentTextColor), Color.blue(currentTextColor)))
            }
        }
        address = location
        toolbar.addView(location, LinearLayout.LayoutParams(0, dp(34), 1f))
        if (visualization == null) updateBrowserChrome(null)
        else location.text = (intent.getStringExtra("name") ?: "Visualization").take(200)
        addIcon(BrowserIcon.RELOAD, "Reload page") {
            status.visibility = View.GONE
            web?.reload()
        }
        if (visualization == null) addIcon(BrowserIcon.MENU, "Page actions") { anchor ->
            PopupMenu(this, anchor).apply {
                menu.add("Open in browser").setOnMenuItemClickListener {
                    openExternal(currentPage())
                    true
                }
                menu.add("Copy address").setOnMenuItemClickListener {
                    val clipboard = getSystemService(ClipboardManager::class.java)
                    clipboard?.setPrimaryClip(ClipData.newPlainText("Page address", currentPage().toString()))
                    true
                }
                show()
            }
        }
        return toolbar
    }

    private fun currentPage(): Uri = web?.url?.let(Uri::parse)?.takeIf(::sameOrigin) ?: requireNotNull(origin)

    private fun updateBrowserChrome(url: String?) {
        if (visualization != null) return
        val location = address ?: return
        val uri = url?.let(Uri::parse)?.takeIf(::sameOrigin) ?: currentPage()
        location.text = "${uri.authority}${uri.encodedPath.orEmpty().takeUnless { it == "/" }.orEmpty()}"
        historyBack?.apply {
            isEnabled = web?.canGoBack() == true
            alpha = if (isEnabled) 1f else 0.38f
        }
    }

    private fun showStatus(message: String) {
        status.text = message
        status.visibility = View.VISIBLE
    }

    private fun dp(value: Int): Int = (resources.displayMetrics.density * value + 0.5f).toInt()

    private enum class BrowserIcon { CLOSE, BACK, RELOAD, MENU }

    private inner class BrowserButton(private val icon: BrowserIcon, label: String) : ImageButton(this@BrowserPreviewActivity) {
        private val ink = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = TextView(this@BrowserPreviewActivity).currentTextColor
            strokeWidth = 1.8f
            strokeCap = Paint.Cap.ROUND
        }

        init {
            contentDescription = label
            tooltipText = label
            val ripple = TypedValue()
            if (theme.resolveAttribute(android.R.attr.selectableItemBackgroundBorderless, ripple, true)) {
                setBackgroundResource(ripple.resourceId)
            }
        }

        override fun onDraw(canvas: Canvas) {
            super.onDraw(canvas)
            val size = dp(22).toFloat()
            canvas.save()
            canvas.translate((width - size) / 2f, (height - size) / 2f)
            canvas.scale(size / 24f, size / 24f)
            ink.style = Paint.Style.STROKE
            when (icon) {
                BrowserIcon.CLOSE -> {
                    canvas.drawLine(6f, 6f, 18f, 18f, ink)
                    canvas.drawLine(6f, 18f, 18f, 6f, ink)
                }
                BrowserIcon.BACK -> {
                    canvas.drawLine(5f, 12f, 19f, 12f, ink)
                    canvas.drawLine(5f, 12f, 11f, 6f, ink)
                    canvas.drawLine(5f, 12f, 11f, 18f, ink)
                }
                BrowserIcon.RELOAD -> {
                    canvas.drawArc(5f, 5f, 19f, 19f, 25f, 302f, false, ink)
                    canvas.drawLine(18f, 8f, 18f, 3f, ink)
                    canvas.drawLine(18f, 8f, 13f, 8f, ink)
                }
                BrowserIcon.MENU -> {
                    ink.style = Paint.Style.FILL
                    for (x in 5..19 step 7) canvas.drawCircle(x.toFloat(), 12f, 1.5f, ink)
                }
            }
            canvas.restore()
        }
    }

    private fun configureWebView(view: WebView) {
        view.settings.apply {
            javaScriptEnabled = image == null
            domStorageEnabled = image == null && visualization == null
            allowFileAccess = false
            allowContentAccess = false
            @Suppress("DEPRECATION")
            allowFileAccessFromFileURLs = false
            @Suppress("DEPRECATION")
            allowUniversalAccessFromFileURLs = false
            mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW
            setSupportZoom(true)
            builtInZoomControls = true
            displayZoomControls = false
            useWideViewPort = true
            loadWithOverviewMode = true
            mediaPlaybackRequiresUserGesture = true
            safeBrowsingEnabled = true
        }
        CookieManager.getInstance().setAcceptThirdPartyCookies(view, false)
        view.webChromeClient = object : WebChromeClient() {
            override fun onProgressChanged(view: WebView, value: Int) {
                progress.progress = value
                progress.visibility = if (value == 100) View.GONE else View.VISIBLE
            }
            override fun onPermissionRequest(request: PermissionRequest) { request.deny() }
        }
        view.webViewClient = object : WebViewClient() {
            override fun onPageStarted(view: WebView, url: String, favicon: android.graphics.Bitmap?) {
                if (image == null) status.visibility = View.GONE
            }
            override fun doUpdateVisitedHistory(view: WebView, url: String, isReload: Boolean) {
                updateBrowserChrome(url)
            }
            @Suppress("DEPRECATION")
            override fun onPageFinished(view: WebView, url: String) {
                if (image != null) fitScale = view.scale
                else updateBrowserChrome(url)
            }
            override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
                val uri = request.url
                if (image != null) return uri.toString() != "$IMAGE_ORIGIN/"
                if (visualization != null) return uri.toString() != visualizationUrl
                if (sameOrigin(uri)) return false
                // Redirects cannot silently launch another app.
                if (request.isForMainFrame && request.hasGesture()) openExternal(uri)
                else if (request.isForMainFrame) showStatus("Navigation blocked. Use Open in browser in the page menu.")
                return true
            }
            override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse? {
                visualization?.let { file ->
                    if (request.method != "GET" || request.url.toString() != visualizationUrl) return blocked()
                    return try {
                        WebResourceResponse("text/html", "UTF-8", 200, "OK",
                            mapOf("Content-Security-Policy" to VISUALIZATION_POLICY,
                                "Cache-Control" to "no-store",
                                "X-Content-Type-Options" to "nosniff"),
                            visualizationDocument(file))
                    } catch (_: Exception) {
                        blocked()
                    }
                }
                if (image == null) return null
                val url = request.url.toString()
                if (request.method == "GET" && url == "$IMAGE_ORIGIN/") {
                    val html = """<!doctype html><meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=8, user-scalable=yes"><style>html,body{margin:0;background:#000;width:100%;height:100%}img{display:block;width:100vw;height:100vh;object-fit:contain}</style><img src="/image" alt="Image">"""
                    return WebResourceResponse("text/html", "UTF-8", ByteArrayInputStream(html.toByteArray()))
                }
                if (request.method == "GET" && url == "$IMAGE_ORIGIN/image") {
                    return try {
                        val stream = image!!.inputStream().buffered()
                        val mime = java.net.URLConnection.guessContentTypeFromStream(stream) ?: "image/webp"
                        WebResourceResponse(mime, null, stream)
                    }
                    catch (_: Exception) { blocked() }
                }
                return blocked()
            }
            override fun onReceivedSslError(view: WebView, handler: SslErrorHandler, error: SslError) {
                handler.cancel()
                showStatus("TLS certificate rejected. Check the service certificate.")
            }
            override fun onReceivedError(view: WebView, request: WebResourceRequest, error: WebResourceError) {
                if (request.isForMainFrame) showStatus("Could not load page (${error.errorCode}). Check SSH forwarding, then reload.")
            }
            override fun onRenderProcessGone(view: WebView, detail: RenderProcessGoneDetail): Boolean {
                setResult(RESULT_CANCELED)
                finish()
                return true
            }
        }
        view.setDownloadListener { _, _, _, _, _ ->
            val hint = if (visualization == null) "Use Open in browser in the page menu to download files"
                else "Use Download HTML from the conversation"
            Toast.makeText(this, hint, Toast.LENGTH_LONG).show()
        }
    }

    private fun visualizationDocument(file: File): java.io.InputStream {
        val stream = file.inputStream().buffered()
        try {
            val start = ByteArray(1024)
            stream.mark(start.size)
            val length = stream.read(start).coerceAtLeast(0)
            stream.reset()
            val prefix = String(start, 0, length, Charsets.UTF_8).trimStart('\uFEFF', ' ', '\t', '\n', '\r')
            if (prefix.startsWith("<!doctype", ignoreCase = true) ||
                prefix.startsWith("<html", ignoreCase = true) ||
                prefix.startsWith("<head", ignoreCase = true)) return stream
            // Codex also emits HTML fragments, normally wrapped by its desktop host.
            val shell = """<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
                <style>
                :root{color-scheme:light dark;--foreground:#202124;--muted-foreground:#616874;--muted:#eef1f5;--blue:#235cac;--orange:#bb521e}
                @media(prefers-color-scheme:dark){:root{--foreground:#eef1f5;--muted-foreground:#abb3c0;--muted:#292e38;--blue:#83b8ff;--orange:#ffa771}}
                body{margin:0;padding:16px;font:16px system-ui,sans-serif;color:var(--foreground);background:Canvas}
                select,button{font:inherit}
                </style><body>""".trimIndent()
            return SequenceInputStream(ByteArrayInputStream(shell.toByteArray(Charsets.UTF_8)), stream)
        } catch (error: Exception) {
            stream.close()
            throw error
        }
    }

    private fun blocked() = WebResourceResponse("text/plain", "UTF-8", 403, "Blocked", emptyMap(), ByteArrayInputStream(byteArrayOf()))

    private fun openExternal(uri: Uri) {
        if (uri.scheme !in listOf("http", "https") || uri.host.isNullOrEmpty() || uri.userInfo != null) return
        try { startActivity(Intent(Intent.ACTION_VIEW, uri)) }
        catch (_: Exception) { Toast.makeText(this, "No browser available", Toast.LENGTH_SHORT).show() }
    }

    private fun goBack() { if (web?.canGoBack() == true) web?.goBack() else finish() }
    @Deprecated("Deprecated in Java")
    override fun onBackPressed() { goBack() }
    override fun onPause() { web?.onPause(); super.onPause() }
    override fun onResume() { super.onResume(); web?.onResume() }
    override fun onDestroy() {
        web?.let { (it.parent as? android.view.ViewGroup)?.removeView(it); it.stopLoading(); it.destroy() }
        web = null
        super.onDestroy()
    }
}
