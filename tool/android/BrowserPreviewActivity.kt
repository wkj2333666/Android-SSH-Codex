package io.github.wkj2333666.android_ssh_codex

import android.app.Activity
import android.content.Intent
import android.graphics.Color
import android.net.Uri
import android.net.http.SslError
import android.os.Bundle
import android.view.Gravity
import android.view.View
import android.webkit.*
import android.widget.*
import java.io.ByteArrayInputStream
import java.io.File

/** Unprivileged system WebView. Remote pages never receive a native bridge. */
class BrowserPreviewActivity : Activity() {
    companion object {
        const val IMAGE_REQUEST = 4106
        const val PAGE_REQUEST = 4107
        private const val IMAGE_ORIGIN = "https://image-preview.invalid"
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
    }

    private var web: WebView? = null
    private var origin: Uri? = null
    private var image: File? = null
    private var fitScale = 1f
    private lateinit var status: TextView
    private lateinit var progress: ProgressBar

    private fun sameOrigin(uri: Uri): Boolean {
        val start = origin ?: return false
        return validPage(uri) && uri.scheme == start.scheme && uri.host == start.host && uri.port == start.port
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        try {
            val path = intent.getStringExtra("path")
            if (path != null) image = imageFile(this, path)
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
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(Color.BLACK)
        }
        root.setOnApplyWindowInsetsListener { view, insets ->
            @Suppress("DEPRECATION")
            view.setPadding(insets.systemWindowInsetLeft, insets.systemWindowInsetTop,
                insets.systemWindowInsetRight, insets.systemWindowInsetBottom)
            insets
        }
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
        if (image != null) {
            button("−") { web?.zoomOut() }
            button("+") { web?.zoomIn() }
            button("Fit") {
                @Suppress("DEPRECATION")
                web?.let { if (it.scale > 0f) it.zoomBy(fitScale / it.scale) }
            }
        } else {
            button("Back") { goBack() }
            button("Reload") { web?.reload() }
            button("External") { openExternal(web?.url?.let(Uri::parse) ?: origin!!) }
        }
        root.addView(toolbar)
        status = TextView(this).apply {
            setTextColor(Color.WHITE)
            text = if (image != null) (intent.getStringExtra("name") ?: "Image").take(200)
                else "${origin!!.authority}${origin!!.path.orEmpty()}"
            maxLines = 2
        }
        root.addView(status)
        progress = ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal)
        root.addView(progress, LinearLayout.LayoutParams(-1, 4))
        val view = WebView(this)
        web = view
        view.setBackgroundColor(Color.BLACK)
        view.settings.apply {
            javaScriptEnabled = image == null
            domStorageEnabled = image == null
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
            @Suppress("DEPRECATION")
            override fun onPageFinished(view: WebView, url: String) {
                if (image != null) fitScale = view.scale
            }
            override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
                val uri = request.url
                if (image != null) return uri.toString() != "$IMAGE_ORIGIN/"
                if (sameOrigin(uri)) return false
                // Redirects cannot silently launch another app.
                if (request.isForMainFrame && request.hasGesture()) openExternal(uri)
                else if (request.isForMainFrame) status.text = "Navigation blocked. Use External to open in a browser."
                return true
            }
            override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse? {
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
                status.text = "TLS certificate rejected. Check the service certificate or use External."
            }
            override fun onReceivedError(view: WebView, request: WebResourceRequest, error: WebResourceError) {
                if (request.isForMainFrame) status.text = "Page could not load (${error.errorCode}). Check SSH forwarding and reload."
            }
            override fun onRenderProcessGone(view: WebView, detail: RenderProcessGoneDetail): Boolean {
                setResult(RESULT_CANCELED)
                finish()
                return true
            }
        }
        view.setDownloadListener { _, _, _, _, _ ->
            Toast.makeText(this, "Use External to download this web page’s files", Toast.LENGTH_LONG).show()
        }
        root.addView(view, LinearLayout.LayoutParams(-1, 0, 1f))
        setContentView(root)
        view.loadUrl(if (image != null) "$IMAGE_ORIGIN/" else origin.toString())
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
