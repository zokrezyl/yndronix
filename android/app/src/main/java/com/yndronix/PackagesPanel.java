package com.yndronix;

import android.app.Activity;
import android.view.View;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

import java.io.File;
import java.util.LinkedHashSet;
import java.util.Set;
import java.util.TreeMap;

/**
 * "Packages" tab: lists the tools installed in the yndronix environment. The
 * environment is a Nix profile (…-yndronix-env) whose bin/ directory symlinks
 * every user-facing tool into one place; resolving those links back to their
 * store paths yields the installed package set (name + version). No Nix daemon
 * or shell-out is needed — it is a plain read of the extracted store.
 */
final class PackagesPanel {

    private static final String STORE_MARKER = "/nix/store/";

    private final Activity activity;
    private final File store;
    private final ScrollView root;
    private TextView summary;
    private TextView list;

    PackagesPanel(Activity activity, Shell shell) {
        this.activity = activity;
        this.store = new File(shell.dataDir, "nix/store");
        this.root = new ScrollView(activity);
        root.addView(buildColumn());
        refresh();
    }

    View view() {
        return root;
    }

    private LinearLayout buildColumn() {
        LinearLayout column = Ui.column(activity);
        column.addView(Ui.heading(activity, "Installed packages"));
        column.addView(Ui.label(activity,
                "Tools available in your SSH session (the yndronix environment)."));
        summary = Ui.label(activity, "scanning ...");
        column.addView(summary);
        column.addView(Ui.button(activity, "Refresh", v -> refresh()));
        list = Ui.mono(activity);
        column.addView(list);
        return column;
    }

    private void refresh() {
        summary.setText("scanning ...");
        new Thread(() -> {
            TreeMap<String, String> packages = scan();
            final String text = render(packages);
            final String head = packages.size() + " packages";
            activity.runOnUiThread(() -> {
                summary.setText(head);
                list.setText(text.isEmpty() ? "(none found)" : text);
            });
        }, "yndronix-packages").start();
    }

    private static String render(TreeMap<String, String> packages) {
        StringBuilder body = new StringBuilder();
        for (java.util.Map.Entry<String, String> entry : packages.entrySet()) {
            body.append(entry.getKey());
            if (!entry.getValue().isEmpty()) {
                body.append("  ").append(entry.getValue());
            }
            body.append("\n");
        }
        return body.toString().trim();
    }

    /** name -> version, resolved from the yndronix-env profile's bin symlinks. */
    private TreeMap<String, String> scan() {
        TreeMap<String, String> result = new TreeMap<>(String.CASE_INSENSITIVE_ORDER);
        File[] entries = store.listFiles();
        if (entries == null) {
            return result;
        }

        File env = null;
        for (File entry : entries) {
            if (entry.getName().endsWith("-yndronix-env")) {
                env = entry;
                break;
            }
        }

        Set<String> storeDirs = new LinkedHashSet<>();
        File binDir = env != null ? new File(env, "bin") : null;
        if (binDir != null && binDir.isDirectory()) {
            File[] bins = binDir.listFiles();
            if (bins != null) {
                for (File bin : bins) {
                    String dir = resolveStoreDir(bin);
                    if (dir != null) {
                        storeDirs.add(dir);
                    }
                }
            }
        }
        if (storeDirs.isEmpty()) {
            // No env profile (older bundle): fall back to every top-level store path.
            for (File entry : entries) {
                if (entry.isDirectory()) {
                    storeDirs.add(entry.getName());
                }
            }
        }

        for (String dir : storeDirs) {
            String[] nameVersion = splitNameVersion(dir);
            if (nameVersion != null && !result.containsKey(nameVersion[0])) {
                result.put(nameVersion[0], nameVersion[1]);
            }
        }
        return result;
    }

    /** Follow a symlink and return the "<hash>-<name>-<version>" store dir it lands in. */
    private String resolveStoreDir(File file) {
        try {
            String real = file.getCanonicalPath();
            int index = real.indexOf(STORE_MARKER);
            if (index < 0) {
                return null;
            }
            String rest = real.substring(index + STORE_MARKER.length());
            int slash = rest.indexOf('/');
            return slash < 0 ? rest : rest.substring(0, slash);
        } catch (Exception e) {
            return null;
        }
    }

    /** "<hash>-<name>[-triple]-<version>" -> {readable name, version}. */
    private static String[] splitNameVersion(String storeDir) {
        int firstDash = storeDir.indexOf('-');
        if (firstDash < 0 || firstDash + 1 >= storeDir.length()) {
            return null;
        }
        String nameVersion = storeDir.substring(firstDash + 1);       // drop the hash
        nameVersion = nameVersion.replace("-aarch64-unknown-linux-musl", ""); // drop target triple
        for (int i = 0; i < nameVersion.length() - 1; i++) {
            if (nameVersion.charAt(i) == '-' && Character.isDigit(nameVersion.charAt(i + 1))) {
                return new String[]{
                        nameVersion.substring(0, i), nameVersion.substring(i + 1)};
            }
        }
        return new String[]{nameVersion, ""};
    }
}
