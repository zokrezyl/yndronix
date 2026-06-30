package com.yndronix;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.Service;
import android.content.Intent;
import android.os.Build;
import android.os.IBinder;
import android.os.PowerManager;
import android.util.Log;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileReader;
import java.io.IOException;

/**
 * Foreground service that owns the supervisor process. Android 10+ forbids
 * execve() of files in the app data dir, so it cannot run the bundle's svc/init
 * (an aarch64 shell script) directly. Instead it runs the musl loader shipped
 * in nativeLibraryDir -- an execve-allowed location -- and hands it the store
 * bash plus the init script: the loader mmaps and runs them. init synthesizes
 * the user db, generates host keys, writes sshd_config and finally exec()s
 * runsvdir to supervise sshd; the ynss LD_PRELOAD shim reroutes every later
 * data-dir exec through the same loader. waitFor() blocks for the lifetime of
 * the service, so as long as the foreground service lives, runit (and sshd) live.
 */
public class YndService extends Service {

    private static final String TAG = "yndronix";
    private static final String CHANNEL = "yndronix";
    private static final int NOTIF_ID = 1;

    private Process process;
    private PowerManager.WakeLock wakeLock;

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        startForeground(NOTIF_ID, buildNotification());
        acquireWakeLock();
        if (process == null) {
            new Thread(this::runInit, "yndronix-init").start();
        }
        return START_STICKY;
    }

    private void runInit() {
        try {
            File dataDir = new File(getApplicationInfo().dataDir);
            File init = new File(dataDir, "svc/init");
            File home = new File(dataDir, "run/home");
            // noinspection ResultOfMethodCallIgnored
            home.mkdirs();

            ProcessBuilder builder;
            File loader = new File(getApplicationInfo().nativeLibraryDir, "libyndld.so");
            if (loader.canExecute()) {
                // Run init through the musl loader (Android 10+ blocks direct
                // execve of the data-dir script). The loader needs a real ELF,
                // so we pass the on-device store bash (resolved by the bundle
                // into svc/launch.env) followed by the init script.
                String bash = readLaunchValue(new File(dataDir, "svc/launch.env"), "BASH");
                if (bash == null) {
                    throw new IllegalStateException("svc/launch.env is missing the BASH path");
                }
                builder = new ProcessBuilder(
                        loader.getAbsolutePath(), bash, init.getAbsolutePath());
                // The shim reads YND_LINKER to reroute every later data-dir exec.
                builder.environment().put("YND_LINKER", loader.getAbsolutePath());
            } else {
                // No loader present (a targetSdk <= 28 build): exec init directly.
                builder = new ProcessBuilder(init.getAbsolutePath());
            }

            builder.redirectErrorStream(true);
            File log = new File(dataDir, "run/boot.log");
            // noinspection ResultOfMethodCallIgnored
            log.getParentFile().mkdirs();
            builder.redirectOutput(ProcessBuilder.Redirect.appendTo(log));
            builder.environment().put("HOME", home.getAbsolutePath());
            builder.environment().put("TMPDIR", new File(dataDir, "run/tmp").getAbsolutePath());
            // Android's app seccomp filter kills (SIGSYS) some syscalls modern
            // glibc uses. Disable glibc's restartable-sequences (rseq), the usual
            // first offender, so the store binaries don't get killed at startup.
            builder.environment().put("GLIBC_TUNABLES", "glibc.pthread.rseq=0");

            Log.i(TAG, "starting supervisor via " + builder.command().get(0));
            process = builder.start();
            int code = process.waitFor();
            Log.w(TAG, "supervisor exited with code " + code);
        } catch (Exception e) {
            Log.e(TAG, "failed to start supervisor", e);
        }
    }

    /** Reads a single KEY=VALUE entry from the bundle's svc/launch.env. */
    private static String readLaunchValue(File file, String key) {
        String prefix = key + "=";
        try (BufferedReader reader = new BufferedReader(new FileReader(file))) {
            String line;
            while ((line = reader.readLine()) != null) {
                if (line.startsWith(prefix)) {
                    return line.substring(prefix.length()).trim();
                }
            }
        } catch (IOException e) {
            Log.e(TAG, "could not read " + file, e);
        }
        return null;
    }

    private void acquireWakeLock() {
        if (wakeLock == null) {
            PowerManager pm = (PowerManager) getSystemService(POWER_SERVICE);
            wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "yndronix:supervisor");
            wakeLock.setReferenceCounted(false);
        }
        if (!wakeLock.isHeld()) {
            wakeLock.acquire();
        }
    }

    private Notification buildNotification() {
        NotificationManager manager = (NotificationManager) getSystemService(NOTIFICATION_SERVICE);
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            NotificationChannel channel = new NotificationChannel(
                    CHANNEL, "yndronix", NotificationManager.IMPORTANCE_LOW);
            manager.createNotificationChannel(channel);
            return new Notification.Builder(this, CHANNEL)
                    .setContentTitle("yndronix")
                    .setContentText("ssh server running on port 8022")
                    .setSmallIcon(android.R.drawable.stat_sys_download_done)
                    .setOngoing(true)
                    .build();
        }
        // noinspection deprecation
        return new Notification.Builder(this)
                .setContentTitle("yndronix")
                .setContentText("ssh server running on port 8022")
                .setSmallIcon(android.R.drawable.stat_sys_download_done)
                .setOngoing(true)
                .build();
    }

    @Override
    public void onDestroy() {
        if (process != null) {
            process.destroy();
        }
        if (wakeLock != null && wakeLock.isHeld()) {
            wakeLock.release();
        }
        super.onDestroy();
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }
}
