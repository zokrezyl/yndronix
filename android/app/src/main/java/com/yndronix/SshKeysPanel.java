package com.yndronix;

import android.app.Activity;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Context;
import android.content.Intent;
import android.system.Os;
import android.view.View;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.Toast;

import java.io.File;
import java.io.FileOutputStream;
import java.io.RandomAccessFile;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

/**
 * "SSH keys" tab: create / display / share the device's login key, and manage
 * the authorized_keys that are allowed to open a session. Key generation shells
 * out to the bundled ssh-keygen through {@link Shell}; everything else is plain
 * file work in the app's own data dir.
 */
final class SshKeysPanel {

    private final Activity activity;
    private final Shell shell;
    private final File sshDir;
    private final File privateKey;
    private final File publicKey;
    private final File authorizedKeys;

    private final ScrollView root;
    private TextView keyInfo;
    private TextView authInfo;
    private TextView status;

    SshKeysPanel(Activity activity, Shell shell) {
        this.activity = activity;
        this.shell = shell;
        this.sshDir = new File(shell.home, ".ssh");
        this.privateKey = new File(sshDir, "id_ed25519");
        this.publicKey = new File(sshDir, "id_ed25519.pub");
        this.authorizedKeys = new File(sshDir, "authorized_keys");

        this.root = new ScrollView(activity);
        root.addView(buildColumn());
        refresh();
    }

    View view() {
        return root;
    }

    private LinearLayout buildColumn() {
        LinearLayout column = Ui.column(activity);

        column.addView(Ui.heading(activity, "Your login key"));
        column.addView(Ui.label(activity,
                "This key logs you in over SSH (port 8022, user 'yndronix'). "
                        + "Keep the private half secret; share only the public half."));

        keyInfo = Ui.mono(activity);
        column.addView(keyInfo);

        column.addView(Ui.buttonRow(activity, Arrays.asList(
                Ui.button(activity, "Generate", v -> generate()),
                Ui.button(activity, "Copy public", v -> copyPublic()),
                Ui.button(activity, "Share public", v -> sharePublic()))));

        column.addView(Ui.button(activity,
                "Authorize this key (allow it to log in)", v -> authorizeOwnKey()));

        column.addView(Ui.heading(activity, "authorized_keys"));
        column.addView(Ui.label(activity, "Public keys currently permitted to log in:"));
        authInfo = Ui.mono(activity);
        column.addView(authInfo);
        column.addView(Ui.button(activity, "Refresh", v -> refresh()));

        status = Ui.mono(activity);
        status.setText("");
        column.addView(status);

        return column;
    }

    private void refresh() {
        background(() -> {
            final String keyText;
            if (publicKey.exists()) {
                String pub = readText(publicKey).trim();
                String fingerprint = fingerprint();
                keyText = (fingerprint != null ? fingerprint + "\n\n" : "") + pub;
            } else {
                keyText = "(no key yet — tap Generate)";
            }
            final String authText = authorizedKeys.exists() ? summariseAuthorized() : "(none)";
            onUi(() -> {
                keyInfo.setText(keyText);
                authInfo.setText(authText);
            });
        });
    }

    private String fingerprint() {
        if (shell.sshKeygen == null || !publicKey.exists()) {
            return null;
        }
        Shell.Result result = shell.exec(
                Arrays.asList(shell.sshKeygen, "-l", "-f", publicKey.getAbsolutePath()));
        return result.ok() ? result.output.trim() : null;
    }

    private void generate() {
        setStatus("generating ed25519 key ...");
        background(() -> {
            try {
                // noinspection ResultOfMethodCallIgnored
                sshDir.mkdirs();
                Os.chmod(sshDir.getAbsolutePath(), 0700);
            } catch (Exception ignored) {
            }
            // ssh-keygen refuses to overwrite an existing file, so clear first.
            // noinspection ResultOfMethodCallIgnored
            privateKey.delete();
            // noinspection ResultOfMethodCallIgnored
            publicKey.delete();

            Shell.Result result;
            if (shell.sshKeygen != null) {
                result = shell.exec(Arrays.asList(shell.sshKeygen,
                        "-t", "ed25519", "-N", "", "-C", "yndronix@android",
                        "-f", privateKey.getAbsolutePath()));
            } else {
                result = shell.sh("ssh-keygen -t ed25519 -N '' -C yndronix@android -f "
                        + shellQuote(privateKey.getAbsolutePath()));
            }
            final String message = result.ok()
                    ? "key generated" : "keygen failed:\n" + result.output.trim();
            onUi(() -> {
                setStatus(message);
                refresh();
            });
        });
    }

    private void authorizeOwnKey() {
        if (!publicKey.exists()) {
            toast("generate a key first");
            return;
        }
        background(() -> {
            String entry = readText(publicKey).trim();
            final boolean added = appendAuthorized(entry);
            onUi(() -> {
                setStatus(added ? "added to authorized_keys" : "key is already authorized");
                refresh();
            });
        });
    }

    private boolean appendAuthorized(String entry) {
        try {
            // noinspection ResultOfMethodCallIgnored
            sshDir.mkdirs();
            if (authorizedKeys.exists()) {
                for (String line : readText(authorizedKeys).split("\n")) {
                    if (line.trim().equals(entry)) {
                        return false;
                    }
                }
            }
            try (FileOutputStream out = new FileOutputStream(authorizedKeys, true)) {
                out.write((entry + "\n").getBytes("UTF-8"));
            }
            Os.chmod(authorizedKeys.getAbsolutePath(), 0600);
            return true;
        } catch (Exception e) {
            return false;
        }
    }

    private String summariseAuthorized() {
        List<String> shown = new ArrayList<>();
        for (String raw : readText(authorizedKeys).split("\n")) {
            String line = raw.trim();
            if (line.isEmpty() || line.startsWith("#")) {
                continue;
            }
            shown.add("• " + shortKey(line));
        }
        if (shown.isEmpty()) {
            return "(none)";
        }
        StringBuilder sb = new StringBuilder();
        for (String line : shown) {
            sb.append(line).append("\n");
        }
        return sb.toString().trim();
    }

    /** "type base64blob comment" -> "type …lastchars comment" (readable, safe). */
    private static String shortKey(String line) {
        String[] parts = line.split("\\s+");
        if (parts.length < 2) {
            return line;
        }
        String blob = parts[1];
        String tail = blob.length() > 12 ? "…" + blob.substring(blob.length() - 12) : blob;
        String comment = parts.length >= 3 ? "  " + parts[parts.length - 1] : "";
        return parts[0] + " " + tail + comment;
    }

    private void copyPublic() {
        if (!publicKey.exists()) {
            toast("no key yet");
            return;
        }
        String text = readText(publicKey).trim();
        ClipboardManager clipboard =
                (ClipboardManager) activity.getSystemService(Context.CLIPBOARD_SERVICE);
        clipboard.setPrimaryClip(ClipData.newPlainText("yndronix public key", text));
        toast("public key copied");
    }

    private void sharePublic() {
        if (!publicKey.exists()) {
            toast("no key yet");
            return;
        }
        Intent send = new Intent(Intent.ACTION_SEND);
        send.setType("text/plain");
        send.putExtra(Intent.EXTRA_SUBJECT, "yndronix SSH public key");
        send.putExtra(Intent.EXTRA_TEXT, readText(publicKey).trim());
        activity.startActivity(Intent.createChooser(send, "Share public key"));
    }

    private void setStatus(String message) {
        status.setText(message);
    }

    private void toast(String message) {
        Toast.makeText(activity, message, Toast.LENGTH_SHORT).show();
    }

    private void background(Runnable task) {
        new Thread(task, "yndronix-keys").start();
    }

    private void onUi(Runnable task) {
        activity.runOnUiThread(task);
    }

    private static String shellQuote(String value) {
        return "'" + value.replace("'", "'\\''") + "'";
    }

    private static String readText(File file) {
        try (RandomAccessFile reader = new RandomAccessFile(file, "r")) {
            byte[] bytes = new byte[(int) reader.length()];
            reader.readFully(bytes);
            return new String(bytes, "UTF-8");
        } catch (Exception e) {
            return "";
        }
    }
}
