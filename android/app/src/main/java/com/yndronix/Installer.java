package com.yndronix;

import android.content.res.AssetManager;
import android.system.ErrnoException;
import android.system.Os;
import android.util.Log;

import org.apache.commons.compress.archivers.tar.TarArchiveEntry;
import org.apache.commons.compress.archivers.tar.TarArchiveInputStream;
import org.apache.commons.compress.compressors.brotli.BrotliCompressorInputStream;

import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.OutputStream;

/**
 * One-time, first-launch extraction of the relocated Nix store.
 *
 * The store ships baked into the APK as assets/store.tar.br (a brotli-compressed
 * tar of {nix, svc}). The first-launch extraction has to run anyway -- a Nix
 * store has symlinks, exec bits and hardlinks that a passive unzip cannot
 * recreate -- so it costs nothing to brotli-decompress in the same pass, which
 * keeps the APK ~5x smaller. Android has no install hook, so this runs on first
 * launch, unpacking into the app's own data dir -- which IS /data/data/com.yndronix,
 * the exact path every store binary's interpreter and RUNPATH were built against.
 *
 * Symlinks, exec bits and hardlinks are preserved (the store is full of all three);
 * without that the closure does not run.
 */
final class Installer {

    private static final String TAG = "yndronix";
    private static final String ASSET = "store.tar.br";
    private static final String MARKER = ".store-extracted";

    interface Progress {
        void log(String message);
    }

    private Installer() {
    }

    static boolean isExtracted(File dataDir) {
        return new File(dataDir, MARKER).exists();
    }

    /** Extracts the store into dataDir if it has not been extracted yet. */
    static void ensureExtracted(AssetManager assets, File dataDir, Progress progress)
            throws Exception {
        if (isExtracted(dataDir)) {
            progress.log("store already extracted");
            return;
        }
        progress.log("extracting store (first launch, brotli) ...");
        long started = System.currentTimeMillis();
        int entries = extract(assets, dataDir, progress);
        // Mark complete only after a clean run.
        if (!new File(dataDir, MARKER).createNewFile()) {
            Log.w(TAG, "could not write extraction marker");
        }
        long seconds = (System.currentTimeMillis() - started) / 1000;
        progress.log("extracted " + entries + " entries in " + seconds + "s");
    }

    private static int extract(AssetManager assets, File dataDir, Progress progress)
            throws Exception {
        int count = 0;
        try (InputStream raw = assets.open(ASSET, AssetManager.ACCESS_STREAMING);
             BrotliCompressorInputStream brotli = new BrotliCompressorInputStream(raw);
             TarArchiveInputStream tar = new TarArchiveInputStream(brotli)) {

            TarArchiveEntry entry;
            byte[] buffer = new byte[1 << 16];
            while ((entry = tar.getNextTarEntry()) != null) {
                File target = new File(dataDir, entry.getName());
                String path = target.getAbsolutePath();

                if (entry.isDirectory()) {
                    target.mkdirs();
                } else if (entry.isSymbolicLink()) {
                    target.getParentFile().mkdirs();
                    delete(target);
                    Os.symlink(entry.getLinkName(), path);
                } else if (entry.isLink()) {
                    // Hardlink: target was written earlier in the stream.
                    target.getParentFile().mkdirs();
                    delete(target);
                    File source = new File(dataDir, entry.getLinkName());
                    try {
                        Os.link(source.getAbsolutePath(), path);
                    } catch (ErrnoException e) {
                        copyFile(source, target); // fall back to a plain copy
                    }
                } else {
                    target.getParentFile().mkdirs();
                    try (OutputStream out = new FileOutputStream(target)) {
                        int n;
                        while ((n = tar.read(buffer)) != -1) {
                            out.write(buffer, 0, n);
                        }
                    }
                    // Preserve the mode (exec bits matter: store binaries are 0555).
                    Os.chmod(path, entry.getMode() & 07777);
                }
                if (++count % 2000 == 0) {
                    progress.log("  " + count + " entries ...");
                }
            }
        }
        return count;
    }

    private static void delete(File file) {
        if (file.exists() || isSymlink(file)) {
            // noinspection ResultOfMethodCallIgnored
            file.delete();
        }
    }

    private static boolean isSymlink(File file) {
        try {
            return !file.getAbsolutePath().equals(file.getCanonicalPath());
        } catch (Exception e) {
            return false;
        }
    }

    private static void copyFile(File source, File target) throws Exception {
        try (InputStream in = new java.io.FileInputStream(source);
             OutputStream out = new FileOutputStream(target)) {
            byte[] buffer = new byte[1 << 16];
            int n;
            while ((n = in.read(buffer)) != -1) {
                out.write(buffer, 0, n);
            }
        }
        Os.chmod(target.getAbsolutePath(), Os.stat(source.getAbsolutePath()).st_mode & 07777);
    }
}
