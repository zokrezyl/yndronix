package com.yndronix;

import android.content.Context;
import android.content.pm.ApplicationInfo;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileReader;
import java.io.InputStream;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/**
 * Runs bundled store binaries from the UI, reusing the same musl-loader + ynss
 * (LD_PRELOAD) plumbing the supervisor uses. Android 10+ forbids execve() of
 * files in the app data dir, so every store binary is launched through the
 * loader shipped in nativeLibraryDir; ynss then answers getpw / getgr lookups
 * from the synthesized user db and reroutes any further data-dir execs. The
 * paths (store bash, ssh-keygen, PATH, the ynss lib) are read from the bundle's
 * svc/paths.env, which the build writes with fully-substituted on-device paths.
 */
final class Shell {

    final File loader;   // nativeLibraryDir/libyndld.so
    final File dataDir;  // /data/data/com.yndronix
    final File run;      // dataDir/run
    final File home;     // run/home
    final String bash;
    final String sshKeygen;
    private final String path;
    private final String nssLib;

    private Shell(File loader, File dataDir, Map<String, String> env) {
        this.loader = loader;
        this.dataDir = dataDir;
        this.run = new File(dataDir, "run");
        this.home = new File(run, "home");
        this.bash = env.get("BASH");
        this.sshKeygen = env.get("SSH_KEYGEN");
        this.path = env.get("PATH");
        this.nssLib = env.get("NSS_WRAPPER_LIB");
    }

    static Shell forContext(Context context) {
        ApplicationInfo info = context.getApplicationInfo();
        File dataDir = new File(info.dataDir);
        File loader = new File(info.nativeLibraryDir, "libyndld.so");
        Map<String, String> env = new HashMap<>();
        readEnvFile(new File(dataDir, "svc/paths.env"), env);
        readEnvFile(new File(dataDir, "svc/launch.env"), env);
        return new Shell(loader, dataDir, env);
    }

    /** True once the store is extracted and the loader/bash are resolvable. */
    boolean isReady() {
        return loader.canExecute() && bash != null
                && new File(dataDir, ".store-extracted").exists();
    }

    static final class Result {
        final int code;
        final String output;

        Result(int code, String output) {
            this.code = code;
            this.output = output;
        }

        boolean ok() {
            return code == 0;
        }
    }

    /**
     * Runs a store binary (argv[0] = absolute program path) through the loader,
     * with the yndronix runtime environment. stdout+stderr are captured together.
     */
    Result exec(List<String> argv) {
        List<String> command = new ArrayList<>();
        command.add(loader.getAbsolutePath());
        command.addAll(argv);

        ProcessBuilder builder = new ProcessBuilder(command);
        builder.redirectErrorStream(true);
        Map<String, String> env = builder.environment();
        if (nssLib != null) {
            env.put("LD_PRELOAD", nssLib);
        }
        env.put("NSS_WRAPPER_PASSWD", new File(run, "etc/passwd").getAbsolutePath());
        env.put("NSS_WRAPPER_GROUP", new File(run, "etc/group").getAbsolutePath());
        env.put("YND_LINKER", loader.getAbsolutePath());
        env.put("YND_PRELOADED", "1");
        env.put("HOME", home.getAbsolutePath());
        env.put("TMPDIR", new File(run, "tmp").getAbsolutePath());
        if (path != null) {
            env.put("PATH", path);
        }

        try {
            Process process = builder.start();
            StringBuilder out = new StringBuilder();
            try (InputStream in = process.getInputStream()) {
                byte[] buffer = new byte[8192];
                int read;
                while ((read = in.read(buffer)) != -1) {
                    out.append(new String(buffer, 0, read, "UTF-8"));
                }
            }
            int code = process.waitFor();
            return new Result(code, out.toString());
        } catch (Exception e) {
            return new Result(-1, "exec failed: " + e);
        }
    }

    /** Runs a shell one-liner via the store bash (PATH-resolved commands). */
    Result sh(String script) {
        List<String> argv = new ArrayList<>();
        argv.add(bash);
        argv.add("-c");
        argv.add(script);
        return exec(argv);
    }

    private static void readEnvFile(File file, Map<String, String> into) {
        try (BufferedReader reader = new BufferedReader(new FileReader(file))) {
            String line;
            while ((line = reader.readLine()) != null) {
                line = line.trim();
                if (line.isEmpty() || line.startsWith("#")) {
                    continue;
                }
                if (line.startsWith("export ")) {
                    line = line.substring("export ".length());
                }
                int eq = line.indexOf('=');
                if (eq <= 0) {
                    continue;
                }
                String key = line.substring(0, eq).trim();
                String value = line.substring(eq + 1).trim();
                if (value.length() >= 2 && value.charAt(0) == '"'
                        && value.charAt(value.length() - 1) == '"') {
                    value = value.substring(1, value.length() - 1);
                }
                into.put(key, value);
            }
        } catch (Exception ignored) {
            // paths.env only exists after first-launch extraction; callers guard
            // on isReady() / null fields.
        }
    }
}
