package com.yndronix;

import android.Manifest;
import android.app.Activity;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.os.Build;
import android.os.Bundle;
import android.widget.ScrollView;
import android.widget.TextView;

import java.io.File;

/**
 * Thin launcher: on first run it extracts the baked store, then starts the
 * foreground service that runs the supervisor (runit -> sshd). The text view
 * shows progress and the connection hint.
 */
public class MainActivity extends Activity {

    private TextView view;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        view = new TextView(this);
        view.setTextSize(12f);
        view.setPadding(24, 24, 24, 24);
        ScrollView scroll = new ScrollView(this);
        scroll.addView(view);
        setContentView(scroll);

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

    private void setup() {
        try {
            File dataDir = new File(getApplicationInfo().dataDir);
            Installer.ensureExtracted(getAssets(), dataDir, this::append);

            Intent service = new Intent(this, YndService.class);
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(service);
            } else {
                startService(service);
            }
            append("supervisor starting ...");
            append("");
            append("ssh -i yndronix_test_ed25519 -p 8022 yndronix@<phone-ip>");
            append("(log: " + new File(dataDir, "run/boot.log") + ")");
        } catch (Exception e) {
            append("ERROR: " + e);
        }
    }

    private void append(String message) {
        runOnUiThread(() -> view.append(message + "\n"));
    }
}
