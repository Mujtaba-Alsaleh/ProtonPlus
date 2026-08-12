namespace ProtonPlus.Utils {
    using ProtonPlus.Models;

    /* A discovered Wine binary and its runnable sibling tools.  The bin
     * directory is the location that hosts wine, wineboot, winecfg and
     * explorer, which all live together for both system Wine and installed
     * runner tarballs. */
    public class WineBinary : Object {
        public string bin_dir { get; construct; }
        public string display_name { get; construct; }
        public string wine_path { get; construct; }
        public string wineboot_path { get; construct; }
        public string winecfg_path { get; construct; }
        public string version { get; set; default = ""; }

        public WineBinary (string bin_dir, string display_name) {
            Object (
                bin_dir: bin_dir,
                display_name: display_name,
                wine_path: Path.build_filename (bin_dir, "wine"),
                wineboot_path: Path.build_filename (bin_dir, "wineboot"),
                winecfg_path: Path.build_filename (bin_dir, "winecfg")
            );
        }

        public bool has_wine {
            get { return FileUtils.test (wine_path, FileTest.EXISTS); }
        }

        public bool has_wine64 {
            get { return FileUtils.test (Path.build_filename (bin_dir, "wine64"), FileTest.EXISTS); }
        }

        public bool has_wineboot {
            get { return FileUtils.test (wineboot_path, FileTest.EXISTS); }
        }

        public bool has_winecfg {
            get { return FileUtils.test (winecfg_path, FileTest.EXISTS); }
        }
    }

    /* Command-execution seam so the service can run against fixtures instead
     * of a real prefix.  Mirror of SystemctlBackend / SteamRestartBackend. */
    public interface WineRunnerBackend : Object {
        public abstract async CommandResult run (string command);
        public abstract async CommandResult run_detached (string command);
    }

    public class HostWineRunnerBackend : Object, WineRunnerBackend {
        private static Gee.List<Subprocess> detached_processes = new Gee.ArrayList<Subprocess> ();

        public async CommandResult run (string command) {
            return yield System.run_command (command);
        }

        public async CommandResult run_detached (string command) {
            try {
                var command_line = Globals.IS_FLATPAK ? "flatpak-spawn --host " + command : command;
                string[] argv;
                Shell.parse_argv (command_line, out argv);

                var launcher = new SubprocessLauncher (
                    SubprocessFlags.STDOUT_SILENCE | SubprocessFlags.STDERR_SILENCE
                );
                launcher.set_stdin_file_path ("/dev/null");
                launcher.set_child_setup (detach_child_session);

                var process = launcher.spawnv (argv);
                // Keep a strong reference so the child outlives the caller.
                // GSubprocess is not reaped until it is waited on; the child
                // keeps running independently either way.
                detached_processes.add (process);
                return new CommandResult ("", "", 0);
            } catch (Error e) {
                return new CommandResult ("", e.message, -1);
            }
        }

        private static void detach_child_session () {
            if (Posix.setsid () < 0)
                Posix._exit (127);
        }
    }

    public class WineRunnerService : Object {
        private WineRunnerBackend backend;

        public WineRunnerService (WineRunnerBackend? backend = null) {
            this.backend = backend ?? new HostWineRunnerBackend ();
        }

        private string build_env_command (string prefix, string wine_path, string[] args,
            string[]? extra_env = null) {
            var parts = new Gee.ArrayList<string> ();
            parts.add ("env");
            parts.add ("WINEPREFIX=%s".printf (Shell.quote (prefix)));
            if (extra_env != null) {
                foreach (var env in extra_env)
                    parts.add (env);
            }
            parts.add (Shell.quote (wine_path));
            foreach (var arg in args)
                parts.add (Shell.quote (arg));
            return string.joinv (" ", parts.to_array ());
        }

        public async Gee.List<WineBinary> discover_binaries (Gee.LinkedList<Launcher>? launchers = null) {
            var result = new Gee.ArrayList<WineBinary> ();
            var seen = new Gee.HashSet<string> ();

            var system = find_system_wine ();
            if (system != null) {
                result.add ((!) system);
                seen.add (((!) system).bin_dir);
            }

            if (launchers == null)
                return result;

            foreach (var launcher in launchers) {
                foreach (var group in launcher.groups) {
                    foreach (var root in launcher.get_managed_tool_directories (group)) {
                        discover_tool_binaries (root, seen, result);
                    }
                }
            }

            return result;
        }

        private WineBinary? find_system_wine () {
            string? path = null;
            if (!Globals.IS_FLATPAK) {
                path = Environment.find_program_in_path ("wine");
                if (path == null)
                    path = Environment.find_program_in_path ("wine64");
            } else {
                var probe = System.run_command_sync ("which wine");
                if (probe.strip () != "" && !probe.contains ("which: no"))
                    path = probe.strip ();
            }

            if (path == null)
                return null;

            var bin_dir = Path.get_dirname (path);
            return new WineBinary (bin_dir, _ ("System Wine"));
        }

        private void discover_tool_binaries (string root, Gee.HashSet<string> seen, Gee.ArrayList<WineBinary> result) {
            FileEnumerator? enumerator = null;
            try {
                var directory = File.new_for_path (root);
                if (!directory.query_exists ())
                    return;

                enumerator = directory.enumerate_children (
                    FileAttribute.STANDARD_NAME + "," + FileAttribute.STANDARD_TYPE,
                    FileQueryInfoFlags.NOFOLLOW_SYMLINKS,
                    null
                );

                FileInfo? file_info;
                while ((file_info = enumerator.next_file (null)) != null) {
                    if (file_info.get_file_type () != FileType.DIRECTORY)
                        continue;

                    var tool_dir = Path.build_filename (root, file_info.get_name ());
                    var candidate = new WineBinary (Path.build_filename (tool_dir, "bin"), file_info.get_name ());
                    if (seen.contains (candidate.bin_dir))
                        continue;

                    if (candidate.has_wine || candidate.has_wine64) {
                        seen.add (candidate.bin_dir);
                        result.add (candidate);
                    }
                }
            } catch (Error e) {
                warning (e.message);
            } finally {
                if (enumerator != null) {
                    try {
                        enumerator.close (null);
                    } catch (Error e) {
                        warning (e.message);
                    }
                }
            }
        }

        public async string get_version (WineBinary binary) {
            if (binary.version != "")
                return binary.version;

            if (!binary.has_wine && !binary.has_wine64)
                return "";

            var result = yield backend.run ("%s --version".printf (Shell.quote (binary.wine_path)));
            if (result.exit_status != 0)
                return "";

            var version = result.stdout.strip ();
            if (version == "")
                version = result.stderr.strip ();

            binary.version = version;
            return version;
        }

        public async bool create_prefix (WineBinary binary, string prefix, string arch) {
            if (!binary.has_wineboot)
                return false;

            var command = "env WINEPREFIX=%s WINEARCH=%s %s -i".printf (
                Shell.quote (prefix),
                Shell.quote (arch),
                Shell.quote (binary.wineboot_path)
            );
            var result = yield backend.run (command);
            return result.exit_status == 0;
        }

        public async bool rebuild_prefix (WineBinary binary, string prefix, string arch) {
            if (!(yield delete_prefix (prefix)))
                return false;
            return yield create_prefix (binary, prefix, arch);
        }

        public async bool delete_prefix (string path) {
            return yield Filesystem.delete_directory (path);
        }

        public async bool clone_prefix (string source, string target) {
            if (!FileUtils.test (source, FileTest.IS_DIR))
                return false;

            if (!FileUtils.test (target, FileTest.IS_DIR)) {
                if (!Filesystem.create_directory (target))
                    return false;
            }

            return yield clone_directory (source, target, source, target);
        }

        /* Symlink-aware replication: never dereference a link.  Relative links
         * are recreated verbatim so their in-tree targets follow the clone.
         * Absolute links that resolve inside the source prefix are rewritten to
         * the corresponding location in the target; links that point elsewhere
         * (/, /dev, home dirs) are recreated verbatim. */
        private async bool clone_directory (string source, string target, string source_root, string target_root) {
            try {
                var directory = File.new_for_path (source);
                var enumerator = yield directory.enumerate_children_async (
                    FileAttribute.STANDARD_NAME + "," + FileAttribute.STANDARD_TYPE,
                    FileQueryInfoFlags.NOFOLLOW_SYMLINKS
                );

                FileInfo? file_info;
                while ((file_info = enumerator.next_file ()) != null) {
                    var source_path = Path.build_filename (source, file_info.get_name ());
                    var target_path = Path.build_filename (target, file_info.get_name ());

                    switch (file_info.get_file_type ()) {
                    case FileType.DIRECTORY:
                        if (!Filesystem.create_directory (target_path))
                            return false;
                        if (!(yield clone_directory (source_path, target_path, source_root, target_root)))
                            return false;
                        break;
                    case FileType.SYMBOLIC_LINK:
                        if (!clone_symlink (source_path, target_path, source_root, target_root))
                            return false;
                        break;
                    default:
                        if (!(yield Filesystem.copy_file (source_path, target_path)))
                            return false;
                        break;
                    }
                }
            } catch (Error e) {
                warning (e.message);
                return false;
            }

            return true;
        }

        private bool clone_symlink (string source_path, string target_path, string source_root, string target_root) {
            string link_target;
            try {
                link_target = FileUtils.read_link (source_path);
            } catch (FileError e) {
                warning (e.message);
                return false;
            }

            var new_target = link_target;
            if (Path.is_absolute (link_target)) {
                var resolved = Filename.canonicalize (link_target, null);
                if (resolved != null && path_is_within (resolved, source_root)) {
                    var relative = resolved.substring (source_root.length);
                    new_target = target_root + relative;
                }
            }

            try {
                File.new_for_path (target_path).make_symbolic_link (new_target);
                return true;
            } catch (Error e) {
                warning (e.message);
                return false;
            }
        }

        private static bool path_is_within (string path, string root) {
            if (path == root)
                return true;
            var prefix = root;
            if (!prefix.has_suffix ("/"))
                prefix += "/";
            return path.has_prefix (prefix);
        }

        public async bool backup_prefix (string prefix, string dest, bool full) {
            string command;
            if (full) {
                var parent = Path.get_dirname (prefix);
                var basename = Path.get_basename (prefix);
                command = "tar -C %s -czf %s %s".printf (
                    Shell.quote (parent),
                    Shell.quote (dest),
                    Shell.quote (basename)
                );
            } else {
                var parent = prefix;
                var names = new Gee.ArrayList<string> ();
                foreach (var name in new string[] { "system.reg", "user.reg", "userdef.reg" }) {
                    if (FileUtils.test (Path.build_filename (prefix, name), FileTest.EXISTS))
                        names.add (name);
                }
                if (names.size == 0)
                    return false;

                var name_args = new Gee.ArrayList<string> ();
                foreach (var name in names)
                    name_args.add (Shell.quote (name));
                command = "tar -C %s -czf %s %s".printf (
                    Shell.quote (parent),
                    Shell.quote (dest),
                    string.joinv (" ", name_args.to_array ())
                );
            }

            var result = yield backend.run (command);
            return result.exit_status == 0;
        }

        public async bool restore_prefix (string prefix, string backup, bool full) {
            string command;
            if (full) {
                // A full backup archives <basename>/… from the prefix's parent
                // directory, so it must be extracted there again.
                var parent = Path.get_dirname (prefix);
                if (!FileUtils.test (parent, FileTest.IS_DIR))
                    return false;
                command = "tar -C %s -xzf %s".printf (Shell.quote (parent), Shell.quote (backup));
            } else {
                if (!FileUtils.test (prefix, FileTest.IS_DIR)) {
                    if (!Filesystem.create_directory (prefix))
                        return false;
                }
                command = "tar -C %s -xzf %s".printf (Shell.quote (prefix), Shell.quote (backup));
            }

            var result = yield backend.run (command);
            return result.exit_status == 0;
        }

        public async CommandResult test_prefix (WineBinary binary, string prefix) {
            if (!binary.has_wineboot)
                return new CommandResult ("", _ ("Wine boot tool not found."), -1);

            // wineboot -u validates and initializes the registry of an existing
            // prefix.  A broken prefix fails here before any GUI is launched.
            var wineboot = yield backend.run (
                "env WINEPREFIX=%s %s -u".printf (
                    Shell.quote (prefix),
                    Shell.quote (binary.wineboot_path)
                )
            );
            if (wineboot.exit_status != 0)
                return wineboot;

            // Launch the bundled Notepad window as the visible smoke test.
            return yield backend.run_detached (
                build_env_command (prefix, binary.wine_path, { "notepad" })
            );
        }

        public async CommandResult open_winecfg (WineBinary binary, string prefix) {
            if (!binary.has_winecfg)
                return new CommandResult ("", _ ("Wine configuration tool not found."), -1);
            return yield backend.run_detached (
                build_env_command (prefix, binary.winecfg_path, {})
            );
        }

        public async CommandResult open_explorer (WineBinary binary, string prefix) {
            return yield backend.run_detached (
                build_env_command (prefix, binary.wine_path, { "explorer" })
            );
        }

        public async CommandResult run_executable (WineBinary binary, string prefix, string exe_path) {
            return yield backend.run_detached (
                build_env_command (prefix, binary.wine_path, { exe_path })
            );
        }
    }
}
