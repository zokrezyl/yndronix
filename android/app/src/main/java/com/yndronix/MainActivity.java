package com.yndronix;

import android.Manifest;
import android.app.Activity;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.graphics.Typeface;
import android.os.Build;
import android.os.Bundle;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.Button;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.TextView;

import java.io.File;

/**
 * Launcher + home screen. On first run it extracts the baked store and starts
 * the foreground service that runs the supervisor (runit -> sshd); once ready it
 * presents two tabs: SSH-key management and installed-package browsing. The UI
 * is built in code (the app ships no res/ layouts and no UI toolkit).
 */
public class MainActivity extends Activity {

    private TextView status;
    private Button tabKeys;
    private Button tabPackages;
    private FrameLayout content;
    private View placeholder;

    private SshKeysPanel keysPanel;
    private PackagesPanel packagesPanel;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setContentView(buildChrome());

        // Target 33+ needs a runtime grant for the foreground-service notification.
        // Request it but don't block startup on the result -- the service runs
        // either way; only the notification is suppressed if denied.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU
                && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS)
                        != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(new String[]{Manifest.permission.POST_NOTIFICATIONS}, 1);
        }

        new Thread(this::setup, "yndronix-setup").start();
    }

    private View buildChrome() {
        LinearLayout rootLayout = new LinearLayout(this);
        rootLayout.setOrientation(LinearLayout.VERTICAL);
        rootLayout.setBackgroundColor(Ui.BG);
        int pad = Ui.dp(this, 16);

        TextView title = new TextView(this);
        title.setText("yndronix");
        title.setTextColor(Ui.ACCENT);
        title.setTypeface(Typeface.DEFAULT_BOLD);
        title.setTextSize(20f);
        title.setPadding(pad, pad, pad, Ui.dp(this, 4));
        rootLayout.addView(title);

        status = new TextView(this);
        status.setTextColor(Ui.MUTED);
        status.setTextSize(12f);
        status.setTypeface(Typeface.MONOSPACE);
        status.setPadding(pad, 0, pad, Ui.dp(this, 8));
        status.setText("starting ...");
        rootLayout.addView(status);

        LinearLayout tabs = new LinearLayout(this);
        tabs.setOrientation(LinearLayout.HORIZONTAL);
        tabKeys = tabButton("SSH keys", v -> showKeys());
        tabPackages = tabButton("Packages", v -> showPackages());
        tabs.addView(tabKeys);
        tabs.addView(tabPackages);
        rootLayout.addView(tabs);
        setTabsEnabled(false);

        content = new FrameLayout(this);
        content.setLayoutParams(new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f));
        rootLayout.addView(content);

        TextView preparing = new TextView(this);
        preparing.setText("Preparing the environment ...");
        preparing.setTextColor(Ui.MUTED);
        preparing.setGravity(Gravity.CENTER);
        preparing.setPadding(pad, pad, pad, pad);
        placeholder = preparing;
        content.addView(placeholder);

        return rootLayout;
    }

    private Button tabButton(String text, View.OnClickListener onClick) {
        Button button = new Button(this);
        button.setText(text);
        button.setAllCaps(false);
        button.setTextColor(Ui.FG);
        button.setOnClickListener(onClick);
        button.setLayoutParams(new LinearLayout.LayoutParams(
                0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f));
        return button;
    }

    private void setTabsEnabled(boolean enabled) {
        tabKeys.setEnabled(enabled);
        tabPackages.setEnabled(enabled);
    }

    private void setup() {
        try {
            File dataDir = new File(getApplicationInfo().dataDir);
            Installer.ensureExtracted(getAssets(), dataDir, this::setStatus);

            Intent service = new Intent(this, YndService.class);
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(service);
            } else {
                startService(service);
            }
            setStatus("ssh ready — port 8022, user 'yndronix'");
            runOnUiThread(() -> {
                setTabsEnabled(true);
                showKeys();
            });
        } catch (Exception e) {
            setStatus("ERROR: " + e);
        }
    }

    private void showKeys() {
        if (keysPanel == null) {
            keysPanel = new SshKeysPanel(this, Shell.forContext(this));
        }
        swapContent(keysPanel.view());
        highlight(tabKeys, tabPackages);
    }

    private void showPackages() {
        if (packagesPanel == null) {
            packagesPanel = new PackagesPanel(this, Shell.forContext(this));
        }
        swapContent(packagesPanel.view());
        highlight(tabPackages, tabKeys);
    }

    private void swapContent(View panel) {
        content.removeAllViews();
        if (panel.getParent() instanceof ViewGroup) {
            ((ViewGroup) panel.getParent()).removeView(panel);
        }
        content.addView(panel);
    }

    private void highlight(Button active, Button inactive) {
        active.setTextColor(Ui.ACCENT);
        inactive.setTextColor(Ui.FG);
    }

    private void setStatus(String message) {
        runOnUiThread(() -> status.setText(message));
    }
}
