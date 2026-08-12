namespace ProtonPlus.Utils {
    public class WinePrefix : GLib.Object {
        public string path { get; construct; }
        public string architecture { get; set; default = ""; }
        public string[] symlink_targets { get; set; }
        public string[] detected_dependencies { get; set; }
        public string[] dll_overrides { get; set; }
        public string[] detected_tweaks { get; set; }
        public DateTime? created_at { get; set; }
        public DateTime? modified_at { get; set; }

        public WinePrefix (string path) {
            Object (path: path);
        }

        public bool has_extra_dependencies {
            get { return detected_dependencies.length > 0; }
        }
    }

    public class WinePrefixManager : GLib.Object {
        private static WinePrefixManager? _instance = null;

        public static WinePrefixManager instance {
            get {
                if (_instance == null)
                    _instance = new WinePrefixManager ();
                return _instance;
            }
        }

        public static string get_architecture (string prefix_path) {
            return instance._check_wine_arch (prefix_path);
        }

        public static bool is_tool_prefix (string prefix_path, string home_path) {
            return instance._is_excluded (prefix_path, home_path);
        }

        public async Gee.List<WinePrefix> scan (string home_path, bool skip_tools) {
            SourceFunc callback = scan.callback;
            var results = new Gee.ArrayList<WinePrefix> ();
            new Thread<void> ("prefix-scan", () => {
                _scan_internal (home_path, skip_tools, results);
                Idle.add ((owned) callback);
            });
            yield;
            return results;
        }

        public async void scan_details (WinePrefix prefix) {
            SourceFunc callback = scan_details.callback;
            new Thread<void> ("prefix-details-scan", () => {
                _scan_details_internal (prefix);
                Idle.add ((owned) callback);
            });
            yield;
        }

        private string[] get_excluded_paths (string home) {
            return {
                home + "/.local/share/Steam/steamapps/compatdata",
                home + "/.steam/steam/steamapps/compatdata",
                home + "/.local/share/Steam/compatibilitytools.d",
                home + "/.steam/steam/compatibilitytools.d",
                home + "/.local/share/Steam/steamapps/common",
                home + "/.steam/steam/steamapps/common",
                home + "/.local/share/lutris",
                home + "/.var/app/net.lutris.Lutris",
                home + "/.config/heroic",
                home + "/Games/umu",
                home + "/.local/share/bottles"
            };
        }

        private bool _is_excluded (string path, string home) {
            foreach (string exclude in get_excluded_paths (home)) {
                if (path.has_prefix (exclude))
                    return true;
            }
            return false;
        }

        private string _check_wine_arch (string prefix_path) {
            string syswow64 = Path.build_filename (prefix_path, "drive_c", "windows", "syswow64");

            if (!FileUtils.test (prefix_path, FileTest.IS_DIR))
                return "";

            if (FileUtils.test (syswow64, FileTest.IS_DIR))
                return "64-bit";
            else
                return "32-bit";
        }

        private string[] _collect_symlinks (string pfx) {
            var targets = new Gee.ArrayList<string> ();
            _collect_symlinks_recursive (pfx, targets);
            var result = new string[targets.size];
            for (int i = 0; i < targets.size; i++)
                result[i] = targets[i];
            return result;
        }

        private void _collect_symlinks_recursive (string pfx, Gee.ArrayList<string> targets) {
            try {
                var root = File.new_for_path (pfx);
                if (!root.query_exists ())
                    return;

                var enumerator = root.enumerate_children (
                    FileAttribute.STANDARD_NAME + "," + FileAttribute.STANDARD_TYPE,
                    FileQueryInfoFlags.NOFOLLOW_SYMLINKS
                );

                FileInfo info;
                while ((info = enumerator.next_file ()) != null) {
                    string path = Path.build_filename (pfx, info.get_name ());

                    if (info.get_file_type () == FileType.SYMBOLIC_LINK) {
                        string target = FileUtils.read_link (path);
                        targets.add ("%s -> %s".printf (path, target));
                    } else if (info.get_file_type () == FileType.DIRECTORY) {
                        _collect_symlinks_recursive (path, targets);
                    }
                }
            } catch (Error e) {
                // Ignore permission errors
            }
        }

        private const string DLL_OVERRIDES_SECTION = "Software\\\\Wine\\\\DllOverrides";

        private static string? dependency_label_for (string name) {
            string lower = name.down ();
            switch (lower) {
                case "mscoree":
                    return ".NET Framework";
                case "concrt140":
                case "msvcp140":
                case "msvcp140_1":
                case "msvcp140_2":
                case "msvcp140_atomic_wait":
                case "msvcp140_codecvt_ids":
                case "vcruntime140":
                case "vcruntime140_1":
                case "vcamp140":
                case "vccorlib140":
                case "vcomp140":
                    return "Visual C++ 2015-2022";
                case "msvcp120":
                case "msvcr120":
                    return "Visual C++ 2013";
                case "msvcp110":
                case "msvcr110":
                    return "Visual C++ 2012";
                case "msvcp100":
                case "msvcr100":
                    return "Visual C++ 2010";
                case "msvcp90":
                case "msvcr90":
                    return "Visual C++ 2008";
                case "d3dx10_43":
                    return "DirectX 10";
                case "d3dcompiler_47":
                    return "DirectX Compiler";
                default:
                    break;
            }
            if (lower.has_prefix ("d3dx9_"))
                return "DirectX 9";
            return null;
        }

        private string[] _read_native_dll_overrides (string pfx) {
            var overrides = new Gee.TreeSet<string> ();
            string reg_path = Path.build_filename (pfx, "user.reg");
            if (!FileUtils.test (reg_path, FileTest.EXISTS))
                return {};

            string content;
            try {
                FileUtils.get_contents (reg_path, out content);
            } catch (FileError e) {
                return {};
            }

            Regex? override_regex = null;
            try {
                override_regex = new Regex ("^\"\\*?([^\"]+)\"\\s*=\\s*\"([^\"]*)\"");
            } catch (RegexError e) {
                warning (e.message);
            }
            bool in_section = false;
            foreach (string raw_line in content.split ("\n")) {
                string line = raw_line.strip ();
                if (line == "")
                    continue;

                if (line.has_prefix ("[")) {
                    int end = line.index_of ("]");
                    if (end > 1)
                        in_section = (line[1:end] == DLL_OVERRIDES_SECTION);
                    else
                        in_section = false;
                    continue;
                }

                if (!in_section || line.has_prefix ("#") || line.has_prefix (";"))
                    continue;

                if (override_regex == null)
                    continue;

                MatchInfo match;
                if (!override_regex.match (line, 0, out match))
                    continue;

                string name = match.fetch (1);
                string value = match.fetch (2);
                if (value.contains ("native")) {
                    if (name.has_prefix ("*"))
                        name = name[1:];
                    overrides.add (name);
                }
            }

            var result = new string[overrides.size];
            int i = 0;
            foreach (string name in overrides)
                result[i++] = name;
            return result;
        }

        private void _collect_runtime_info (WinePrefix prefix) {
            string[] overrides = _read_native_dll_overrides (prefix.path);
            prefix.dll_overrides = overrides;

            var labels = new Gee.TreeSet<string> ();
            foreach (string name in overrides) {
                string? label = dependency_label_for (name);
                if (label != null)
                    labels.add ((!) label);
            }

            var result = new string[labels.size];
            int i = 0;
            foreach (string label in labels)
                result[i++] = label;
            prefix.detected_dependencies = result;
        }

        private void _scan_internal (string home, bool skip_tools, Gee.ArrayList<WinePrefix> results) {
            var prefixes = new Gee.ArrayList<string> ();
            _find_drive_c_dirs (home, home, skip_tools, prefixes);

            foreach (string drive_c in prefixes) {
                string pfx_root = Path.get_dirname (drive_c);

                var prefix = new WinePrefix (pfx_root);
                prefix.architecture = _check_wine_arch (pfx_root);
                results.add (prefix);
            }

            results.sort ((a, b) => a.path.collate (b.path));
        }

        private const string APPDEFAULTS_SECTION = "Software\\\\Wine\\\\AppDefaults\\\\";

        private string[] _collect_tweaks (string pfx) {
            var tweaks = new Gee.TreeSet<string> ();

            int app_defaults_sections = _count_app_default_sections (pfx);
            if (app_defaults_sections > 0)
                tweaks.add (ngettext ("%d per-app setting", "%d per-app settings", app_defaults_sections).printf (app_defaults_sections));

            int extra_drives = _count_extra_drives (pfx);
            if (extra_drives > 0)
                tweaks.add (ngettext ("%d extra drive", "%d extra drives", extra_drives).printf (extra_drives));

            var result = new string[tweaks.size];
            int i = 0;
            foreach (string tweak in tweaks)
                result[i++] = tweak;
            return result;
        }

        /* Wine writes RelayExclude and host font imports into every prefix, so
         * only genuinely manual configuration is reported here: per-app
         * overrides and drive mappings beyond the standard c:, d:, z:. */
        private static int _count_app_default_sections (string pfx) {
            string reg_path = Path.build_filename (pfx, "user.reg");
            if (!FileUtils.test (reg_path, FileTest.EXISTS))
                return 0;

            string content;
            try {
                FileUtils.get_contents (reg_path, out content);
            } catch (FileError e) {
                return 0;
            }

            int count = 0;
            foreach (string raw_line in content.split ("\n")) {
                string line = raw_line.strip ();
                if (line.has_prefix ("[") && line[1:].has_prefix (APPDEFAULTS_SECTION))
                    count++;
            }
            return count;
        }

        private static int _count_extra_drives (string pfx) {
            string dosdevices = Path.build_filename (pfx, "dosdevices");
            if (!FileUtils.test (dosdevices, FileTest.IS_DIR))
                return 0;

            int count = 0;
            try {
                var dir = File.new_for_path (dosdevices);
                var enumerator = dir.enumerate_children (
                    FileAttribute.STANDARD_NAME,
                    FileQueryInfoFlags.NOFOLLOW_SYMLINKS
                );

                FileInfo info;
                while ((info = enumerator.next_file ()) != null) {
                    if (_is_extra_drive (info.get_name ()))
                        count++;
                }
            } catch (Error e) {
                // Ignore permission errors
            }
            return count;
        }

        private static bool _is_extra_drive (string name) {
            if (name.length < 2 || name[1] != ':')
                return false;
            char c = name[0];
            if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')))
                return false;
            string letter = name[0:1].down ();
            return letter != "c" && letter != "d" && letter != "z";
        }

        private void _collect_dates (WinePrefix prefix) {
            prefix.modified_at = _get_modification_time (prefix.path);

            var created = _get_creation_time (prefix.path);
            if (created == null) {
                string system_reg = Path.build_filename (prefix.path, "system.reg");
                if (FileUtils.test (system_reg, FileTest.EXISTS))
                    created = _get_modification_time (system_reg);
            }
            prefix.created_at = created;
        }

        private DateTime? _get_creation_time (string path) {
            try {
                var info = File.new_for_path (path).query_info (
                    FileAttribute.TIME_CREATED,
                    FileQueryInfoFlags.NONE,
                    null
                );
                uint64 unix_time = info.get_attribute_uint64 (FileAttribute.TIME_CREATED);
                if (unix_time == 0)
                    return null;
                return new DateTime.from_unix_local ((int64) unix_time);
            } catch (Error e) {
                return null;
            }
        }

        private DateTime? _get_modification_time (string path) {
            try {
                var info = File.new_for_path (path).query_info (
                    FileAttribute.TIME_MODIFIED,
                    FileQueryInfoFlags.NONE,
                    null
                );
                uint64 unix_time = info.get_attribute_uint64 (FileAttribute.TIME_MODIFIED);
                if (unix_time == 0)
                    return null;
                return new DateTime.from_unix_local ((int64) unix_time);
            } catch (Error e) {
                return null;
            }
        }

        private void _scan_details_internal (WinePrefix prefix) {
            prefix.symlink_targets = _collect_symlinks (prefix.path);
            _collect_runtime_info (prefix);
            prefix.detected_tweaks = _collect_tweaks (prefix.path);
            _collect_dates (prefix);
        }

        private void _find_drive_c_dirs (string root_path, string home, bool skip_tools, Gee.ArrayList<string> results) {
            try {
                var root = File.new_for_path (root_path);
                if (!root.query_exists ())
                    return;

                var enumerator = root.enumerate_children (
                    FileAttribute.STANDARD_NAME + "," + FileAttribute.STANDARD_TYPE,
                    FileQueryInfoFlags.NOFOLLOW_SYMLINKS
                );

                FileInfo info;
                while ((info = enumerator.next_file ()) != null) {
                    string path = Path.build_filename (root_path, info.get_name ());

                    if (info.get_file_type () == FileType.DIRECTORY) {
                        if (info.get_name () == "drive_c") {
                            results.add (path);
                        } else if (!(skip_tools && _is_excluded (path, home))) {
                            _find_drive_c_dirs (path, home, skip_tools, results);
                        }
                    }
                }
            } catch (Error e) {
                // Ignore permission errors
            }
        }
    }
}
