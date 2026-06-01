package dev.voiceinput.mobile

import android.content.Context
import android.graphics.Color
import android.graphics.drawable.ColorDrawable
import android.inputmethodservice.InputMethodService
import android.util.Log
import android.util.TypedValue
import android.view.View
import android.view.ViewGroup
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputMethodManager
import android.widget.FrameLayout
import io.flutter.FlutterInjector
import io.flutter.embedding.android.FlutterTextureView
import io.flutter.embedding.android.FlutterView
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

/**
 * IME service that hosts a Flutter UI as the system keyboard.
 *
 * The Flutter engine runs the `ime_main` entrypoint (declared in
 * lib/ime_main.dart) and is cached under [ENGINE_ID] so subsequent IME
 * activations reuse the warm engine. The cache survives across
 * onCreateInputView/onFinishInput cycles, eliminating the cold-start latency.
 *
 * Bridge to Dart is via MethodChannel "voiceinput/ime":
 *   Dart -> Kotlin
 *     - commitText(text: String)            inject text into the focused editor
 *     - commitKey(name: "enter"|"tab"|"space"|"backspace")
 *     - clearAll()                          select-all + delete
 *     - switchToPreviousIme()               return to the previous IME
 *     - showImePicker()                     open the system input method chooser
 *   Kotlin -> Dart
 *     - onStartInput { packageName: String?, fieldType: String }
 *     - onFinishInput
 */
class VoiceInputIme : InputMethodService() {

    companion object {
        const val ENGINE_ID = "voiceinput.ime.engine"
        const val CHANNEL = "voiceinput/ime"
        const val TAG = "VoiceInputIme"
    }

    private var engine: FlutterEngine? = null
    private var flutterView: FlutterView? = null
    private var channel: MethodChannel? = null

    override fun onCreate() {
        super.onCreate()
        Log.i(TAG, "onCreate")
        // Strip the default IME panel background so the area above our 260dp
        // keyboard is visually transparent (combined with onComputeInsets, the
        // host app shows through and gets touch events).
        window?.window?.setBackgroundDrawable(ColorDrawable(Color.TRANSPARENT))
        engine = obtainEngine(this)
        Log.i(TAG, "engine obtained: $engine")
        channel = MethodChannel(engine!!.dartExecutor.binaryMessenger, CHANNEL).apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "commitText" -> {
                        val text = call.argument<String>("text") ?: ""
                        currentInputConnection?.commitText(text, 1)
                        result.success(true)
                    }
                    "commitKey" -> {
                        when (call.argument<String>("name")) {
                            "enter" -> currentInputConnection?.commitText("\n", 1)
                            "tab" -> currentInputConnection?.commitText("\t", 1)
                            "space" -> currentInputConnection?.commitText(" ", 1)
                            "backspace" -> currentInputConnection?.deleteSurroundingText(1, 0)
                        }
                        result.success(true)
                    }
                    "clearAll" -> {
                        // Select-all + delete works in most editors; ExtractedText
                        // would be more reliable but requires extra round-trips.
                        currentInputConnection?.performContextMenuAction(android.R.id.selectAll)
                        currentInputConnection?.commitText("", 1)
                        result.success(true)
                    }
                    "switchToPreviousIme" -> {
                        val handled = switchToPreviousInputMethod()
                        if (!handled) showImePicker()
                        result.success(handled)
                    }
                    "showImePicker" -> {
                        showImePicker()
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    // Default InputMethodService enters fullscreen / extract mode in landscape
    // and on some OEMs even in portrait, which makes the keyboard pane render
    // as the whole screen. We never want that — this is a voice keyboard, not
    // a full-screen editor.
    override fun onEvaluateFullscreenMode(): Boolean = false
    override fun onEvaluateInputViewShown(): Boolean = true

    // Tell the system "only the bottom 260dp of my IME window is the actual
    // keyboard; above that is overlay that should pass touches through and
    // show the host app underneath". This is the same mechanism Sogou/Gboard
    // use to keep the host app visible and resized above the keyboard.
    override fun onComputeInsets(outInsets: InputMethodService.Insets?) {
        super.onComputeInsets(outInsets)
        if (outInsets == null) return
        val panelPx = TypedValue.applyDimension(
            TypedValue.COMPLEX_UNIT_DIP, 200f, resources.displayMetrics,
        ).toInt()
        val windowH = window?.window?.decorView?.height ?: 0
        val topInset = (windowH - panelPx).coerceAtLeast(0)
        outInsets.contentTopInsets = topInset
        outInsets.visibleTopInsets = topInset
        outInsets.touchableInsets = InputMethodService.Insets.TOUCHABLE_INSETS_CONTENT
    }

    override fun onCreateInputView(): View {
        Log.i(TAG, "onCreateInputView")
        flutterView?.detachFromFlutterEngine()

        val height = TypedValue.applyDimension(
            TypedValue.COMPLEX_UNIT_DIP, 200f, resources.displayMetrics,
        ).toInt()
        val container = FrameLayout(this).apply {
            layoutParams = ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                height,
            )
        }
        // isOpaque=false lets Dart-side transparent regions (the area above
        // our 260dp panel) show the host app underneath, instead of a solid
        // grey block. Without this the IME panel always paints fully opaque.
        val textureView = FlutterTextureView(this).apply { isOpaque = false }
        val view = FlutterView(this, textureView)
        view.layoutParams = FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            ViewGroup.LayoutParams.MATCH_PARENT,
        )
        flutterView = view
        view.attachToFlutterEngine(engine!!)
        container.addView(view)
        Log.i(TAG, "view attached: height=${height}px")
        return container
    }

    override fun onStartInput(info: EditorInfo?, restarting: Boolean) {
        super.onStartInput(info, restarting)
        channel?.invokeMethod(
            "onStartInput",
            mapOf(
                "packageName" to info?.packageName,
                "fieldType" to describeFieldType(info?.inputType ?: 0),
                "restarting" to restarting,
            ),
        )
    }

    override fun onFinishInput() {
        super.onFinishInput()
        channel?.invokeMethod("onFinishInput", null)
    }

    override fun onDestroy() {
        flutterView?.detachFromFlutterEngine()
        flutterView = null
        // Keep the engine alive in the cache so re-opening the keyboard is fast.
        // The OS reaps it when the process is killed.
        channel = null
        super.onDestroy()
    }

    private fun showImePicker() {
        val imm = getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager
        imm.showInputMethodPicker()
    }

    private fun describeFieldType(inputType: Int): String {
        val cls = inputType and EditorInfo.TYPE_MASK_CLASS
        return when (cls) {
            EditorInfo.TYPE_CLASS_TEXT -> "text"
            EditorInfo.TYPE_CLASS_NUMBER -> "number"
            EditorInfo.TYPE_CLASS_PHONE -> "phone"
            EditorInfo.TYPE_CLASS_DATETIME -> "datetime"
            else -> "unknown"
        }
    }
}

/** Lazily obtain or build the cached Flutter engine pointed at ime_main. */
fun obtainEngine(context: Context): FlutterEngine {
    val cache = FlutterEngineCache.getInstance()
    val existing = cache.get(VoiceInputIme.ENGINE_ID)
    if (existing != null) return existing

    val engine = FlutterEngine(context.applicationContext)
    engine.dartExecutor.executeDartEntrypoint(
        DartExecutor.DartEntrypoint(
            FlutterInjector.instance().flutterLoader().findAppBundlePath(),
            "imeMain",
        ),
    )
    cache.put(VoiceInputIme.ENGINE_ID, engine)
    return engine
}
