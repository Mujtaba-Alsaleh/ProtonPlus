namespace AppTests.PrefixesManagerTest {
    using GLib;

    public void register_tests () {
        Test.add_func ("/prefixes/scan-finds-drive-c", test_scan_finds_drive_c);
        Test.add_func ("/prefixes/scan-excludes-tool-prefixes", test_scan_excludes_tool_prefixes);
        Test.add_func ("/prefixes/architecture-detection", test_architecture_detection);
        Test.add_func ("/prefixes/discovery-skips-details", test_discovery_skips_details);
        Test.add_func ("/prefixes/symlink-listing", test_symlink_listing);
        Test.add_func ("/prefixes/dependency-detection", test_dependency_detection);
        Test.add_func ("/prefixes/clean-prefix-no-dependencies", test_clean_prefix_no_dependencies);
        Test.add_func ("/prefixes/ignores-symlinked-directories", test_ignores_symlinked_directories);
        Test.add_func ("/prefixes/tweak-detection", test_tweak_detection);
        Test.add_func ("/prefixes/tweak-detection-clean", test_tweak_detection_clean);
        Test.add_func ("/prefixes/scan-prefix-path", test_scan_prefix_path);
    }

    private string create_temp_directory () {
        try {
            return DirUtils.make_tmp ("protonplus-prefixes-test-XXXXXX");
        } catch (FileError e) {
            critical ("Could not create test directory: %s", e.message);
            assert_not_reached ();
        }
    }

    private bool delete_directory (string path) {
        var loop = new MainLoop ();
        bool deleted = false;

        ProtonPlus.Utils.Filesystem.delete_directory.begin (path, (obj, result) => {
            assert (obj == null);
            deleted = ProtonPlus.Utils.Filesystem.delete_directory.end (result);
            loop.quit ();
        });
        loop.run ();

        return deleted;
    }

    private void make_directory (string path) {
        if (DirUtils.create_with_parents (path, 0755) != 0)
            assert_not_reached ();
    }

    private void write_file (string path, string content) {
        try {
            FileUtils.set_contents (path, content);
        } catch (FileError e) {
            critical ("Could not write test file: %s", e.message);
            assert_not_reached ();
        }
    }

    private Gee.List<ProtonPlus.Utils.WinePrefix> scan (string home, bool skip_tools) {
        var loop = new MainLoop ();
        Gee.List<ProtonPlus.Utils.WinePrefix> result = new Gee.ArrayList<ProtonPlus.Utils.WinePrefix> ();
        ProtonPlus.Utils.WinePrefixManager.instance.scan.begin (home, skip_tools, (obj, res) => {
            result = ProtonPlus.Utils.WinePrefixManager.instance.scan.end (res);
            loop.quit ();
        });
        loop.run ();
        return result;
    }

    private void scan_details (ProtonPlus.Utils.WinePrefix prefix) {
        var loop = new MainLoop ();
        ProtonPlus.Utils.WinePrefixManager.instance.scan_details.begin (prefix, (obj, res) => {
            ProtonPlus.Utils.WinePrefixManager.instance.scan_details.end (res);
            loop.quit ();
        });
        loop.run ();
    }

    private ProtonPlus.Utils.WinePrefix? find_prefix (Gee.List<ProtonPlus.Utils.WinePrefix> prefixes, string path) {
        foreach (var prefix in prefixes) {
            if (prefix.path == path)
                return prefix;
        }
        return null;
    }

    private bool has_prefix (Gee.List<ProtonPlus.Utils.WinePrefix> prefixes, string path) {
        return find_prefix (prefixes, path) != null;
    }

    private void test_scan_finds_drive_c () {
        var root = create_temp_directory ();
        var home = Path.build_filename (root, "home");
        make_directory (Path.build_filename (home, "prefix-one", "drive_c", "windows"));
        make_directory (Path.build_filename (home, "nested", "prefix-two", "drive_c"));

        var prefixes = scan (home, true);
        assert (has_prefix (prefixes, Path.build_filename (home, "prefix-one")));
        assert (has_prefix (prefixes, Path.build_filename (home, "nested", "prefix-two")));

        assert (delete_directory (root));
    }

    private void test_scan_excludes_tool_prefixes () {
        var root = create_temp_directory ();
        var home = Path.build_filename (root, "home");
        var excluded = new string[] {
            Path.build_filename (home, ".local", "share", "Steam", "steamapps", "compatdata", "12345"),
            Path.build_filename (home, ".steam", "steam", "steamapps", "compatdata", "12345"),
            Path.build_filename (home, ".local", "share", "Steam", "compatibilitytools.d", "GE-Proton"),
            Path.build_filename (home, ".local", "share", "lutris", "wine"),
            Path.build_filename (home, ".config", "heroic", "Prefix"),
            Path.build_filename (home, ".local", "share", "bottles", "prefix")
        };
        foreach (string prefix in excluded) {
            make_directory (Path.build_filename (prefix, "drive_c", "windows"));
        }
        var user_prefix = Path.build_filename (home, "user-prefix");
        make_directory (Path.build_filename (user_prefix, "drive_c", "windows"));

        var skipped = scan (home, true);
        foreach (string prefix in excluded)
            assert (!has_prefix (skipped, prefix));
        assert (has_prefix (skipped, user_prefix));

        var all = scan (home, false);
        foreach (string prefix in excluded)
            assert (has_prefix (all, prefix));

        assert (delete_directory (root));
    }

    private void test_architecture_detection () {
        var root = create_temp_directory ();
        var home = Path.build_filename (root, "home");
        var prefix64 = Path.build_filename (home, "pfx64");
        var prefix32 = Path.build_filename (home, "pfx32");
        make_directory (Path.build_filename (prefix64, "drive_c", "windows", "syswow64"));
        make_directory (Path.build_filename (prefix32, "drive_c", "windows"));

        var prefixes = scan (home, true);
        assert (((!) find_prefix (prefixes, prefix64)).architecture == "64-bit");
        assert (((!) find_prefix (prefixes, prefix32)).architecture == "32-bit");
        assert (ProtonPlus.Utils.WinePrefixManager.get_architecture (prefix64) == "64-bit");
        assert (ProtonPlus.Utils.WinePrefixManager.get_architecture (prefix32) == "32-bit");
        assert (ProtonPlus.Utils.WinePrefixManager.get_architecture (Path.build_filename (home, "missing")) == "");

        assert (delete_directory (root));
    }

    private void test_discovery_skips_details () {
        var root = create_temp_directory ();
        var home = Path.build_filename (root, "home");
        var prefix = Path.build_filename (home, "pfx");
        make_directory (Path.build_filename (prefix, "drive_c", "windows", "system32"));
        make_directory (Path.build_filename (prefix, "drive_c", "windows", "Fonts"));
        write_file (Path.build_filename (prefix, "drive_c", "windows", "system32", "msvcp140.dll"), "");
        assert (Posix.symlink ("/nonexistent-target", Path.build_filename (prefix, "drive_c", "link")) == 0);

        var prefixes = scan (home, true);
        var found = find_prefix (prefixes, prefix);
        assert (found != null);
        assert (((!) found).symlink_targets.length == 0);
        assert (((!) found).detected_dependencies.length == 0);
        assert (!((!) found).has_extra_dependencies);

        assert (delete_directory (root));
    }

    private void test_symlink_listing () {
        var root = create_temp_directory ();
        var home = Path.build_filename (root, "home");
        var prefix = Path.build_filename (home, "pfx");
        make_directory (Path.build_filename (prefix, "drive_c", "windows"));
        var link_path = Path.build_filename (prefix, "drive_c", "link");
        assert (Posix.symlink ("/nonexistent-target", link_path) == 0);

        var prefixes = scan (home, true);
        var found = find_prefix (prefixes, prefix);
        assert (found != null);
        scan_details ((!) found);
        assert (((!) found).symlink_targets.length == 1);
        assert (((!) found).symlink_targets[0].has_prefix (link_path));

        assert (delete_directory (root));
    }

    private void test_dependency_detection () {
        var root = create_temp_directory ();
        var home = Path.build_filename (root, "home");
        var prefix = Path.build_filename (home, "pfx");
        make_directory (Path.build_filename (prefix, "drive_c", "windows"));
        write_file (Path.build_filename (prefix, "user.reg"),
            "[Software\\\\Wine\\\\DllOverrides]\n"
            + "\"*msvcp140\"=\"native,builtin\"\n"
            + "\"*vcruntime140_1\"=\"native,builtin\"\n"
            + "\"*d3dx9_24\"=\"native\"\n"
            + "\"*d3dx9_43\"=\"native\"\n"
            + "\"*mscoree\"=\"native\"\n"
            + "\"*gdiplus\"=\"native\"\n");

        var prefixes = scan (home, true);
        var found = find_prefix (prefixes, prefix);
        assert (found != null);
        scan_details ((!) found);
        assert (((!) found).has_extra_dependencies);

        bool has_vc = false;
        bool has_dx9 = false;
        bool has_dotnet = false;
        foreach (string dep in ((!) found).detected_dependencies) {
            if (dep == "Visual C++ 2015-2022")
                has_vc = true;
            if (dep == "DirectX 9")
                has_dx9 = true;
            if (dep == ".NET Framework")
                has_dotnet = true;
        }
        assert (has_vc);
        assert (has_dx9);
        assert (has_dotnet);

        assert (((!) found).dll_overrides.length == 6);
        assert ("msvcp140" in ((!) found).dll_overrides);
        assert ("vcruntime140_1" in ((!) found).dll_overrides);
        assert ("d3dx9_24" in ((!) found).dll_overrides);
        assert ("d3dx9_43" in ((!) found).dll_overrides);
        assert ("mscoree" in ((!) found).dll_overrides);
        assert ("gdiplus" in ((!) found).dll_overrides);

        assert (delete_directory (root));
    }

    private void test_clean_prefix_no_dependencies () {
        var root = create_temp_directory ();
        var home = Path.build_filename (root, "home");
        var prefix = Path.build_filename (home, "pfx");
        make_directory (Path.build_filename (prefix, "drive_c", "windows"));
        make_directory (Path.build_filename (prefix, "drive_c", "windows", "system32"));
        write_file (Path.build_filename (prefix, "drive_c", "windows", "system32", "msvcp140.dll"), "");
        write_file (Path.build_filename (prefix, "system.reg"), ".NET Framework Setup\nv4.0.30319\n");
        write_file (Path.build_filename (prefix, "user.reg"),
            "[Software\\\\Wine\\\\DllOverrides]\n");

        var prefixes = scan (home, true);
        var found = find_prefix (prefixes, prefix);
        assert (found != null);
        scan_details ((!) found);
        assert (!((!) found).has_extra_dependencies);
        assert (((!) found).detected_dependencies.length == 0);
        assert (((!) found).dll_overrides.length == 0);

        assert (delete_directory (root));
    }

    private void test_ignores_symlinked_directories () {
        var root = create_temp_directory ();
        var outside = Path.build_filename (root, "outside");
        var home = Path.build_filename (root, "home");
        make_directory (Path.build_filename (outside, "drive_c", "windows"));
        make_directory (home);
        assert (Posix.symlink (outside, Path.build_filename (home, "linked-outside")) == 0);

        var prefixes = scan (home, true);
        assert (prefixes.size == 0);

        assert (delete_directory (root));
    }

    private void test_tweak_detection () {
        var root = create_temp_directory ();
        var home = Path.build_filename (root, "home");
        var prefix = Path.build_filename (home, "pfx");
        make_directory (Path.build_filename (prefix, "drive_c", "windows"));
        make_directory (Path.build_filename (prefix, "dosdevices"));
        write_file (Path.build_filename (prefix, "user.reg"),
            "WINE REGISTRY Version 2\n"
            + "#arch=win64\n"
            + "[Software\\\\Wine\\\\AppDefaults\\\\foo.exe\\\\Graphics] 1\n"
            + "\"Setting\"=\"value\"\n"
            + "[Software\\\\Wine\\\\AppDefaults\\\\bar.exe\\\\DllOverrides] 1\n"
            + "[Software\\\\Wine\\\\Debug] 1\n"
            + "\"RelayExclude\"=\"ntdll.RtlEnterCriticalSection\"\n"
            + "[Software\\\\Wine\\\\Fonts\\\\External Fonts] 1\n"
            + "\"@Font1\"=\"Z:\\\\font1.ttf\"\n"
            + "\"@Font2\"=\"Z:\\\\font2.ttf\"\n");
        // Standard drives only (c:, d::, z:) plus com ports are not tweaks.
        assert (Posix.symlink ("..", Path.build_filename (prefix, "dosdevices", "c:")) == 0);
        assert (Posix.symlink ("/dev/cdrom", Path.build_filename (prefix, "dosdevices", "d::")) == 0);
        assert (Posix.symlink ("/", Path.build_filename (prefix, "dosdevices", "z:")) == 0);
        assert (Posix.symlink ("/dev/ttyS0", Path.build_filename (prefix, "dosdevices", "com1")) == 0);
        // A genuinely added drive is reported.
        assert (Posix.symlink ("/mnt/data", Path.build_filename (prefix, "dosdevices", "e:")) == 0);

        var prefixes = scan (home, true);
        var found = find_prefix (prefixes, prefix);
        assert (found != null);
        scan_details ((!) found);

        assert (((!) found).detected_tweaks.length == 2);

        bool has_app_defaults = false;
        bool has_drives = false;
        foreach (string tweak in ((!) found).detected_tweaks) {
            if (tweak.contains ("per-app setting"))
                has_app_defaults = true;
            if (tweak.contains ("extra drive"))
                has_drives = true;
            assert (!tweak.contains ("Debug relay"));
            assert (!tweak.contains ("external font"));
        }
        assert (has_app_defaults);
        assert (has_drives);

        assert (delete_directory (root));
    }

    private void test_tweak_detection_clean () {
        var root = create_temp_directory ();
        var home = Path.build_filename (root, "home");
        var prefix = Path.build_filename (home, "pfx");
        make_directory (Path.build_filename (prefix, "drive_c", "windows"));
        make_directory (Path.build_filename (prefix, "dosdevices"));
        write_file (Path.build_filename (prefix, "user.reg"),
            "WINE REGISTRY Version 2\n"
            + "[Software\\\\Wine\\\\DllOverrides]\n"
            + "[Software\\\\Wine\\\\Debug] 1\n"
            + "\"RelayExclude\"=\"ntdll.RtlEnterCriticalSection\"\n"
            + "[Software\\\\Wine\\\\Fonts\\\\External Fonts] 1\n"
            + "\"@Font1\"=\"Z:\\\\font1.ttf\"\n");
        assert (Posix.symlink ("..", Path.build_filename (prefix, "dosdevices", "c:")) == 0);
        assert (Posix.symlink ("/dev/cdrom", Path.build_filename (prefix, "dosdevices", "d::")) == 0);
        assert (Posix.symlink ("/", Path.build_filename (prefix, "dosdevices", "z:")) == 0);

        var prefixes = scan (home, true);
        var found = find_prefix (prefixes, prefix);
        assert (found != null);
        scan_details ((!) found);

        assert (((!) found).detected_tweaks.length == 0);

        assert (delete_directory (root));
    }

    private void test_scan_prefix_path () {
        var root = create_temp_directory ();
        var home = Path.build_filename (root, "home");
        var compatdata = Path.build_filename (home, ".local", "share", "Steam", "steamapps", "compatdata", "12345");
        var compatdata_pfx = Path.build_filename (compatdata, "pfx");
        make_directory (Path.build_filename (compatdata_pfx, "drive_c", "windows", "syswow64"));
        var user_prefix = Path.build_filename (home, "user-prefix");
        make_directory (Path.build_filename (user_prefix, "drive_c", "windows"));

        // The home scan keeps Steam compatdata out…
        var skipped = scan (home, true);
        assert (!has_prefix (skipped, compatdata));
        assert (has_prefix (skipped, user_prefix));

        // …but the targeted scan can focus it directly, resolving the real
        // Wine prefix root inside the compatdata container (`pfx`), the same
        // layout protontricks and prefixer use.
        var loop = new MainLoop ();
        ProtonPlus.Utils.WinePrefix? found = null;
        ProtonPlus.Utils.WinePrefixManager.instance.scan_prefix_path.begin (compatdata, (obj, res) => {
            found = ProtonPlus.Utils.WinePrefixManager.instance.scan_prefix_path.end (res);
            loop.quit ();
        });
        loop.run ();
        assert (found != null);
        assert (((!) found).path == compatdata_pfx);
        assert (((!) found).architecture == "64-bit");

        // A path that is already a Wine prefix root resolves directly.
        loop = new MainLoop ();
        ProtonPlus.Utils.WinePrefix? direct = null;
        ProtonPlus.Utils.WinePrefixManager.instance.scan_prefix_path.begin (user_prefix, (obj, res) => {
            direct = ProtonPlus.Utils.WinePrefixManager.instance.scan_prefix_path.end (res);
            loop.quit ();
        });
        loop.run ();
        assert (direct != null);
        assert (((!) direct).path == user_prefix);
        assert (((!) direct).architecture == "32-bit");

        // Non-prefix directories and missing paths yield nothing.
        loop = new MainLoop ();
        ProtonPlus.Utils.WinePrefix? missing = null;
        ProtonPlus.Utils.WinePrefixManager.instance.scan_prefix_path.begin (
            Path.build_filename (home, "nope"), (obj, res) => {
            missing = ProtonPlus.Utils.WinePrefixManager.instance.scan_prefix_path.end (res);
            loop.quit ();
        });
        loop.run ();
        assert (missing == null);

        assert (delete_directory (root));
    }
}
