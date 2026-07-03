package com.yndronix;

import android.content.Context;
import android.graphics.Typeface;
import android.util.TypedValue;
import android.view.View;
import android.view.ViewGroup;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.TextView;

import java.util.List;

/**
 * Tiny programmatic-UI helpers. The app carries no res/ layouts and pulls in no
 * UI toolkit (no AndroidX / Compose), so panels build their views in code; these
 * helpers keep that declarative and the styling consistent.
 */
final class Ui {

    static final int BG = 0xFF0E1416;      // near-black canvas
    static final int SURFACE = 0xFF141A1F; // raised surface (mono blocks)
    static final int FG = 0xFFE0E5E4;      // off-white text
    static final int MUTED = 0xFF9FA7A8;   // secondary text
    static final int ACCENT = 0xFF6BA892;  // mint accent

    private Ui() {
    }

    static int dp(Context context, float value) {
        return Math.round(TypedValue.applyDimension(
                TypedValue.COMPLEX_UNIT_DIP, value, context.getResources().getDisplayMetrics()));
    }

    static LinearLayout column(Context context) {
        LinearLayout layout = new LinearLayout(context);
        layout.setOrientation(LinearLayout.VERTICAL);
        int pad = dp(context, 16);
        layout.setPadding(pad, pad, pad, pad);
        return layout;
    }

    static TextView heading(Context context, String text) {
        TextView view = new TextView(context);
        view.setText(text);
        view.setTextColor(ACCENT);
        view.setTextSize(18f);
        view.setTypeface(Typeface.DEFAULT_BOLD);
        view.setPadding(0, dp(context, 16), 0, dp(context, 8));
        return view;
    }

    static TextView label(Context context, String text) {
        TextView view = new TextView(context);
        view.setText(text);
        view.setTextColor(MUTED);
        view.setTextSize(13f);
        view.setPadding(0, 0, 0, dp(context, 8));
        return view;
    }

    /** A selectable monospace block on a raised surface (keys, listings, logs). */
    static TextView mono(Context context) {
        TextView view = new TextView(context);
        view.setTextColor(FG);
        view.setTextSize(12f);
        view.setTypeface(Typeface.MONOSPACE);
        view.setTextIsSelectable(true);
        int pad = dp(context, 10);
        view.setPadding(pad, pad, pad, pad);
        view.setBackgroundColor(SURFACE);
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        lp.topMargin = dp(context, 4);
        view.setLayoutParams(lp);
        return view;
    }

    /** Full-width button (used standalone in a vertical column). */
    static Button button(Context context, String text, View.OnClickListener onClick) {
        Button button = new Button(context);
        button.setText(text);
        button.setAllCaps(false);
        button.setOnClickListener(onClick);
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        int margin = dp(context, 4);
        lp.setMargins(0, margin, 0, margin);
        button.setLayoutParams(lp);
        return button;
    }

    /** Lays out buttons side by side, each taking an equal share of the width. */
    static LinearLayout buttonRow(Context context, List<Button> buttons) {
        LinearLayout row = new LinearLayout(context);
        row.setOrientation(LinearLayout.HORIZONTAL);
        int margin = dp(context, 4);
        for (Button button : buttons) {
            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                    0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f);
            lp.setMargins(margin, margin, margin, margin);
            button.setLayoutParams(lp);
            row.addView(button);
        }
        return row;
    }
}
