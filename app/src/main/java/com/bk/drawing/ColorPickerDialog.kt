package com.bk.drawing

import android.app.AlertDialog
import android.content.Context
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.text.Editable
import android.text.InputFilter
import android.text.InputType
import android.text.TextWatcher
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.TextView

// ColorPickerDialog — Design A. Wraps an HsvSquareView + HueSliderView with
// a numeric readout (H / S / V) plus editable HEX and RGB triplet fields.
//
// Commit semantics (per user feedback): the brush color and recents stay
// untouched while the user is exploring inside the picker. The internal
// HSV state, the SV square, the hue slider, and every readout/input update
// live, but the parent's onColorPicked callback only fires once when the
// user confirms with "Done". Dismissing by tapping outside or pressing
// Back discards the change.
//
// Cross-input updates: the hex and RGB fields each re-derive the picker's
// HSV state when the user types. A `suppressTextWatchers` flag breaks the
// feedback loop when WE'RE the ones writing into a field (e.g. the SV
// square dragged → we update the hex display).

class ColorPickerDialog(
    private val context: Context,
    initialRgb: Int,
    private val mono: Typeface?,
    private val monoSemibold: Typeface?,
    private val onColorPicked: (rgb: Int) -> Unit,
) {
    // Current HSV state. Initialized from the initial RGB so the UI opens
    // pointing at the user's current color.
    private val hsv = FloatArray(3).also {
        Color.colorToHSV(0xFF000000.toInt() or initialRgb, it)
    }

    private val density: Float get() = context.resources.displayMetrics.density
    private fun dp(v: Int): Int = (v * density).toInt()

    private lateinit var hsvSquare: HsvSquareView
    private lateinit var hueSlider: HueSliderView
    private lateinit var hCell: TextView
    private lateinit var sCell: TextView
    private lateinit var vCell: TextView
    private lateinit var hexEdit: EditText
    private lateinit var rEdit: EditText
    private lateinit var gEdit: EditText
    private lateinit var bEdit: EditText
    private lateinit var preview: View

    // Set true while we're the ones updating a watched EditText, so the
    // TextWatcher knows to skip the round-trip back into HSV state.
    private var suppressTextWatchers = false

    fun show() {
        val ink     = context.getColor(R.color.ink)
        val inkSoft = context.getColor(R.color.inkSoft)
        val paper   = context.getColor(R.color.paper)
        val deep    = context.getColor(R.color.paperDeep)
        val rule    = context.getColor(R.color.rule)

        // ----- root vertical column ----------------------------------------
        val root = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(paper)
            setPadding(dp(18), dp(18), dp(18), dp(18))
        }

        // ----- title row ---------------------------------------------------
        val titleRow = LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        titleRow.addView(TextView(context).apply {
            text = "PICKER"
            typeface = monoSemibold ?: Typeface.MONOSPACE
            textSize = 11f
            letterSpacing = 0.08f
            setTextColor(ink)
        }, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        titleRow.addView(TextView(context).apply {
            text = "HSV · square + hue"
            typeface = mono ?: Typeface.MONOSPACE
            textSize = 9f
            letterSpacing = 0.04f
            setTextColor(inkSoft)
        }, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.WRAP_CONTENT,
            ViewGroup.LayoutParams.WRAP_CONTENT))
        root.addView(titleRow, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            ViewGroup.LayoutParams.WRAP_CONTENT
        ).apply { bottomMargin = dp(14) })

        // ----- HSV square (240×240) ---------------------------------------
        hsvSquare = HsvSquareView(context).apply {
            hue        = hsv[0]
            saturation = hsv[1]
            value      = hsv[2]
            onSvChange = { s, v ->
                hsv[1] = s; hsv[2] = v
                refreshFromHsv()
            }
        }
        root.addView(hsvSquare, LinearLayout.LayoutParams(dp(240), dp(240)).apply {
            bottomMargin = dp(8)
            gravity = Gravity.CENTER_HORIZONTAL
        })

        // ----- hue slider (240×16) ----------------------------------------
        hueSlider = HueSliderView(context).apply {
            hue = hsv[0]
            onHueChange = { h ->
                hsv[0] = h
                hsvSquare.hue = h
                refreshFromHsv()
            }
        }
        root.addView(hueSlider, LinearLayout.LayoutParams(dp(240), dp(16)).apply {
            bottomMargin = dp(12)
            gravity = Gravity.CENTER_HORIZONTAL
        })

        // ----- numeric readout (H / S / V) — read-only -------------------
        val cells = LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
        }
        hCell = makeReadoutCell("H", "0°", deep, rule, ink, inkSoft, weight = 1f)
        sCell = makeReadoutCell("S", "0%", deep, rule, ink, inkSoft, weight = 1f)
        vCell = makeReadoutCell("V", "0%", deep, rule, ink, inkSoft, weight = 1f)
        cells.addView(hCell.parent as View)
        cells.addView(sCell.parent as View)
        cells.addView(vCell.parent as View)
        root.addView(cells, LinearLayout.LayoutParams(
            dp(240), ViewGroup.LayoutParams.WRAP_CONTENT
        ).apply {
            bottomMargin = dp(8)
            gravity = Gravity.CENTER_HORIZONTAL
        })

        // ----- editable HEX field ----------------------------------------
        val hexRow = LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        hexRow.addView(TextView(context).apply {
            text = "HEX"
            typeface = mono ?: Typeface.MONOSPACE
            textSize = 10f
            setTextColor(inkSoft)
            letterSpacing = 0.06f
        }, LinearLayout.LayoutParams(
            dp(36), ViewGroup.LayoutParams.WRAP_CONTENT))
        hexEdit = makeInputField("#000000",
            // 7 chars max — leading '#' plus 6 hex digits.
            maxLen = 7,
            ink = ink, paper = paper, rule = rule)
        hexEdit.setOnFocusChangeListener { _, hasFocus ->
            if (!hasFocus) commitHexInput()
        }
        hexEdit.addTextChangedListener(simpleWatcher {
            if (suppressTextWatchers) return@simpleWatcher
            commitHexInput()
        })
        hexRow.addView(hexEdit, LinearLayout.LayoutParams(
            0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        root.addView(hexRow, LinearLayout.LayoutParams(
            dp(240), ViewGroup.LayoutParams.WRAP_CONTENT
        ).apply {
            bottomMargin = dp(8)
            gravity = Gravity.CENTER_HORIZONTAL
        })

        // ----- RGB triplet row (R / G / B) -------------------------------
        val rgbRow = LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        rEdit = makeRgbCell("R", ink, paper, rule, inkSoft)
        gEdit = makeRgbCell("G", ink, paper, rule, inkSoft)
        bEdit = makeRgbCell("B", ink, paper, rule, inkSoft)
        for (e in listOf(rEdit, gEdit, bEdit)) {
            e.setOnFocusChangeListener { _, hasFocus ->
                if (!hasFocus) commitRgbInputs()
            }
            e.addTextChangedListener(simpleWatcher {
                if (suppressTextWatchers) return@simpleWatcher
                commitRgbInputs()
            })
            // Each cell-wrapper is the EditText's parent (a LinearLayout).
            rgbRow.addView(e.parent as View)
        }
        root.addView(rgbRow, LinearLayout.LayoutParams(
            dp(240), ViewGroup.LayoutParams.WRAP_CONTENT
        ).apply {
            bottomMargin = dp(14)
            gravity = Gravity.CENTER_HORIZONTAL
        })

        // ----- live preview swatch ----------------------------------------
        preview = View(context).apply {
            background = GradientDrawable().apply {
                shape = GradientDrawable.RECTANGLE
                setStroke(dp(1).coerceAtLeast(1), ink)
            }
        }
        root.addView(preview, LinearLayout.LayoutParams(dp(240), dp(36)).apply {
            gravity = Gravity.CENTER_HORIZONTAL
        })

        refreshFromHsv()  // seed every input + preview from the initial state

        // ----- in-content button row --------------------------------------
        // Cancel + Done styled to match the rest of the app (paper bg,
        // monospace, sienna for the primary action). Replaces the
        // default AlertDialog button bar so the dialog doesn't look
        // like default Material.
        val hot = context.getColor(R.color.hot)
        val buttonRow = LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.END
        }
        val cancelBtn = TextView(context).apply {
            text = "Cancel"
            typeface = mono ?: Typeface.MONOSPACE
            textSize = 12f
            setTextColor(ink)
            setPadding(dp(16), dp(10), dp(16), dp(10))
            isClickable = true; isFocusable = true
        }
        val doneBtn = TextView(context).apply {
            text = "Done"
            typeface = monoSemibold ?: Typeface.MONOSPACE
            textSize = 12f
            setTextColor(hot)
            setPadding(dp(16), dp(10), dp(16), dp(10))
            isClickable = true; isFocusable = true
        }
        buttonRow.addView(cancelBtn, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.WRAP_CONTENT,
            ViewGroup.LayoutParams.WRAP_CONTENT))
        buttonRow.addView(doneBtn, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.WRAP_CONTENT,
            ViewGroup.LayoutParams.WRAP_CONTENT))
        root.addView(buttonRow, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            ViewGroup.LayoutParams.WRAP_CONTENT).apply {
                topMargin = dp(12)
            })

        // ----- show as dialog ---------------------------------------------
        // Negative button explicitly cancels; tapping outside / Back also
        // dismisses without calling onColorPicked. Only the positive
        // button commits.
        val dialog = AlertDialog.Builder(context)
            .setView(root)
            .create()
        dialog.show()
        dialog.window?.setBackgroundDrawable(
            android.graphics.drawable.ColorDrawable(paper))

        cancelBtn.setOnClickListener { dialog.dismiss() }
        doneBtn.setOnClickListener {
            val rgb = Color.HSVToColor(hsv) and 0xFFFFFF
            dialog.dismiss()
            onColorPicked(rgb)
        }
    }

    /** One read-only cell: stacked label + value box. */
    private fun makeReadoutCell(
        label: String, initial: String,
        bg: Int, rule: Int, ink: Int, soft: Int,
        weight: Float,
    ): TextView {
        val cell = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            background = GradientDrawable().apply {
                shape = GradientDrawable.RECTANGLE
                setColor(bg)
                setStroke(dp(1).coerceAtLeast(1), rule)
            }
            setPadding(dp(8), dp(6), dp(8), dp(6))
        }
        cell.addView(TextView(context).apply {
            text = label
            typeface = mono ?: Typeface.MONOSPACE
            textSize = 9f
            setTextColor(soft)
            letterSpacing = 0.06f
        })
        val valueView = TextView(context).apply {
            text = initial
            typeface = monoSemibold ?: Typeface.MONOSPACE
            textSize = 12f
            setTextColor(ink)
        }
        cell.addView(valueView)
        cell.layoutParams = LinearLayout.LayoutParams(0,
            ViewGroup.LayoutParams.WRAP_CONTENT, weight).apply {
            marginEnd = dp(6)
        }
        return valueView
    }

    /** One editable RGB cell — small label on top, EditText below. */
    private fun makeRgbCell(label: String, ink: Int, paper: Int,
                            rule: Int, soft: Int): EditText {
        val cell = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
        }
        cell.addView(TextView(context).apply {
            text = label
            typeface = mono ?: Typeface.MONOSPACE
            textSize = 9f
            setTextColor(soft)
            letterSpacing = 0.06f
        })
        // RGB inputs accept 0-255. maxLen = 3 chars. We validate on commit.
        val edit = makeInputField("0", maxLen = 3, ink = ink,
            paper = paper, rule = rule, numeric = true)
        cell.addView(edit, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            ViewGroup.LayoutParams.WRAP_CONTENT))
        cell.layoutParams = LinearLayout.LayoutParams(0,
            ViewGroup.LayoutParams.WRAP_CONTENT, 1f).apply {
            marginEnd = dp(6)
        }
        return edit
    }

    private fun makeInputField(
        initial: String, maxLen: Int, ink: Int, paper: Int, rule: Int,
        numeric: Boolean = false,
    ): EditText {
        return EditText(context).apply {
            setText(initial)
            typeface = monoSemibold ?: Typeface.MONOSPACE
            textSize = 12f
            setTextColor(ink)
            // Single-line; the picker is compact and these fields hold
            // small fixed-width values.
            isSingleLine = true
            setBackgroundColor(paper)
            background = GradientDrawable().apply {
                shape = GradientDrawable.RECTANGLE
                setColor(paper)
                setStroke(dp(1).coerceAtLeast(1), rule)
            }
            setPadding(dp(8), dp(6), dp(8), dp(6))
            inputType = if (numeric)
                InputType.TYPE_CLASS_NUMBER
            else
                InputType.TYPE_CLASS_TEXT
            filters = arrayOf<InputFilter>(InputFilter.LengthFilter(maxLen))
            // The dialog is small; avoid eating Enter as a newline.
            imeOptions = android.view.inputmethod.EditorInfo.IME_ACTION_DONE
        }
    }

    /** Tiny TextWatcher helper to avoid the verbose anonymous-class form
     *  at every callsite. The `after` callback fires after every text
     *  change. */
    private fun simpleWatcher(after: () -> Unit): TextWatcher {
        return object : TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) {}
            override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) {}
            override fun afterTextChanged(s: Editable?) { after() }
        }
    }

    /** Parse the hex field. If valid, update HSV and refresh the rest of
     *  the UI (without echoing back into the hex field itself). */
    private fun commitHexInput() {
        val raw = hexEdit.text.toString().trim().removePrefix("#")
        if (raw.length != 6) return
        val rgb = runCatching { Integer.parseInt(raw, 16) }.getOrNull() ?: return
        Color.colorToHSV(0xFF000000.toInt() or rgb, hsv)
        hsvSquare.hue        = hsv[0]
        hsvSquare.saturation = hsv[1]
        hsvSquare.value      = hsv[2]
        hsvSquare.invalidate()
        hueSlider.hue = hsv[0]
        hueSlider.invalidate()
        refreshFromHsv(skipHex = true)
    }

    /** Parse R/G/B fields. If all valid, update HSV and refresh the rest. */
    private fun commitRgbInputs() {
        val r = rEdit.text.toString().toIntOrNull() ?: return
        val g = gEdit.text.toString().toIntOrNull() ?: return
        val b = bEdit.text.toString().toIntOrNull() ?: return
        if (r !in 0..255 || g !in 0..255 || b !in 0..255) return
        val rgb = (r shl 16) or (g shl 8) or b
        Color.colorToHSV(0xFF000000.toInt() or rgb, hsv)
        hsvSquare.hue        = hsv[0]
        hsvSquare.saturation = hsv[1]
        hsvSquare.value      = hsv[2]
        hsvSquare.invalidate()
        hueSlider.hue = hsv[0]
        hueSlider.invalidate()
        refreshFromHsv(skipRgb = true)
    }

    /** Rewrite every output (readout, hex, RGB, preview) from the current
     *  hsv tuple. skipHex / skipRgb let us avoid clobbering whatever the
     *  user just typed into one of those fields (the trigger). */
    private fun refreshFromHsv(skipHex: Boolean = false, skipRgb: Boolean = false) {
        val rgb = Color.HSVToColor(hsv) and 0xFFFFFF
        hCell.text = "${hsv[0].toInt()}°"
        sCell.text = "${(hsv[1] * 100).toInt()}%"
        vCell.text = "${(hsv[2] * 100).toInt()}%"
        suppressTextWatchers = true
        try {
            if (!skipHex) hexEdit.setText(String.format("#%06X", rgb))
            if (!skipRgb) {
                rEdit.setText(((rgb shr 16) and 0xFF).toString())
                gEdit.setText(((rgb shr 8)  and 0xFF).toString())
                bEdit.setText(( rgb         and 0xFF).toString())
            }
        } finally {
            suppressTextWatchers = false
        }
        (preview.background as? GradientDrawable)?.setColor(0xFF000000.toInt() or rgb)
    }
}
