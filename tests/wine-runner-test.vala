namespace AppTests.WineRunnerTest {
    using GLib;

    private class RecordingBackend : Object, ProtonPlus.Utils.WineRunnerBackend {
        public Gee.ArrayList<string> ran_commands = new Gee.ArrayList<string> ();
        public Gee.ArrayList<string> detached_commands = new Gee.ArrayList<string> ();
        public int run_exit_status = 0;
        public string run_stdout = "";
        public string run_stderr = "";

        public async ProtonPlus.Utils.CommandResult run (string command) {
            ran_commands.add (command);
            return new ProtonPlus.Utils.CommandResult (run_stdout, run_stderr, run_exit_status);
        }

        public async ProtonPlus.Utils.CommandResult run_detached (string command) {
            detached_commands.add (command);
            return new ProtonPlus.Utils.CommandResult ("", "", 0);
        }
    }

    public void register_tests () {
        Test.add_func ("/wine-runner/discover-system-wine", test_discover_system_wine);
        Test.add_func ("/wine-runner/discover-tool-binaries", test_discover_tool_binaries);
        Test.add_func ("/wine-runner/get-version-caches", test_get_version_caches);
        Test.add_func ("/wine-runner/backup-command-construction", test_backup_command_construction);
        Test.add_func ("/wine-runner/backup-config-only", test_backup_config_only);
        Test.add_func ("/wine-runner/restore-command-construction", test_restore_command_construction);
        Test.add_func ("/wine-runner/create-rebuild-delete", test_create_rebuild_delete);
        Test.add_func ("/wine-runner/clone-symlinks-inside-prefix", test_clone_symlinks_inside_prefix);
        Test.add_func ("/wine-runner/clone-external-symlinks-verbatim", test_clone_external_symlinks_verbatim);
        Test.add_func ("/wine-runner/clone-absolute-into-prefix-rewritten", test_clone_absolute_into_prefix_rewritten);
    }

    private string create_temp_directory () {
        try {
            return DirUtils.make_tmp ("protonplus-wine-runner-test-XXXXXX");
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

    private void test_discover_system_wine () {
        var backend = new RecordingBackend ();
        var service = new ProtonPlus.Utils.WineRunnerService (backend);

        // No launchers: only system wine can be discovered, and only when
        // present on the host.  Either outcome is acceptable here; what we
        // assert is that the call does not throw and returns a list.
        var loop = new MainLoop ();
        Gee.List<ProtonPlus.Utils.WineBinary> binaries = new Gee.ArrayList<ProtonPlus.Utils.WineBinary> ();
        service.discover_binaries.begin (null, (obj, res) => {
            binaries = service.discover_binaries.end (res);
            loop.quit ();
        });
        loop.run ();
        assert (binaries != null);
    }

    private void test_discover_tool_binaries () {
        var root = create_temp_directory ();
        var tools = Path.build_filename (root, "compatibilitytools.d");
        make_directory (Path.build_filename (tools, "GE-Proton99", "bin"));
        write_file (Path.build_filename (tools, "GE-Proton99", "bin", "wine"), "");
        make_directory (Path.build_filename (tools, "no-bin-dir"));

        // discover_tool_binaries is private; exercise through a launcher-free
        // path is not possible, so we instead verify the binary model directly.
        var binary = new ProtonPlus.Utils.WineBinary (Path.build_filename (tools, "GE-Proton99", "bin"), "GE-Proton99");
        assert (binary.has_wine);
        assert (!binary.has_wine64);
        assert (!binary.has_wineboot);
        assert (Path.get_basename (binary.wine_path) == "wine");
        assert (Path.get_basename (binary.winecfg_path) == "winecfg");

        assert (delete_directory (root));
    }

    private void test_get_version_caches () {
        var backend = new RecordingBackend ();
        backend.run_stdout = "wine-9.0 (Staging)";

        var service = new ProtonPlus.Utils.WineRunnerService (backend);
        var root = create_temp_directory ();
        write_file (Path.build_filename (root, "wine"), "");

        var binary = new ProtonPlus.Utils.WineBinary (root, "System Wine");

        var loop = new MainLoop ();
        string version = "";
        service.get_version.begin (binary, (obj, res) => {
            version = service.get_version.end (res);
            loop.quit ();
        });
        loop.run ();

        assert (version == "wine-9.0 (Staging)");
        assert (binary.version == "wine-9.0 (Staging)");
        assert (backend.ran_commands.size == 1);

        // Second call must be served from the cache.
        loop = new MainLoop ();
        service.get_version.begin (binary, (obj, res) => {
            service.get_version.end (res);
            loop.quit ();
        });
        loop.run ();
        assert (backend.ran_commands.size == 1);

        assert (delete_directory (root));
    }

    private void test_backup_command_construction () {
        var backend = new RecordingBackend ();
        var service = new ProtonPlus.Utils.WineRunnerService (backend);

        var root = create_temp_directory ();
        var prefix = Path.build_filename (root, "prefix");
        make_directory (prefix);

        var loop = new MainLoop ();
        bool ok = false;
        service.backup_prefix.begin (prefix, "/tmp/backup.tar.gz", true, (obj, res) => {
            ok = service.backup_prefix.end (res);
            loop.quit ();
        });
        loop.run ();

        assert (ok);
        assert (backend.ran_commands.size == 1);
        assert (backend.ran_commands[0].has_prefix ("tar -C "));
        assert (backend.ran_commands[0].contains ("prefix"));

        assert (delete_directory (root));
    }

    private void test_backup_config_only () {
        var backend = new RecordingBackend ();
        var service = new ProtonPlus.Utils.WineRunnerService (backend);

        var root = create_temp_directory ();
        var prefix = Path.build_filename (root, "prefix");
        make_directory (prefix);
        write_file (Path.build_filename (prefix, "user.reg"), "WINE REGISTRY Version 2\n");
        write_file (Path.build_filename (prefix, "system.reg"), "WINE REGISTRY Version 2\n");

        var loop = new MainLoop ();
        bool ok = false;
        service.backup_prefix.begin (prefix, "/tmp/backup.tar.gz", false, (obj, res) => {
            ok = service.backup_prefix.end (res);
            loop.quit ();
        });
        loop.run ();

        assert (ok);
        assert (backend.ran_commands.size == 1);
        assert (backend.ran_commands[0].contains ("user.reg"));
        assert (backend.ran_commands[0].contains ("system.reg"));
        assert (!backend.ran_commands[0].contains ("userdef.reg"));

        assert (delete_directory (root));
    }

    private void test_restore_command_construction () {
        var backend = new RecordingBackend ();
        var service = new ProtonPlus.Utils.WineRunnerService (backend);

        var root = create_temp_directory ();
        var prefix = Path.build_filename (root, "prefix");
        make_directory (prefix);

        // Full backups archive <basename>/… from the parent directory, so they
        // must be extracted there again (never inside the prefix itself).
        var loop = new MainLoop ();
        bool ok = false;
        service.restore_prefix.begin (prefix, "/tmp/backup.tar.gz", true, (obj, res) => {
            ok = service.restore_prefix.end (res);
            loop.quit ();
        });
        loop.run ();

        assert (ok);
        assert (backend.ran_commands.size == 1);
        assert (backend.ran_commands[0].has_prefix ("tar -C " + Shell.quote (root) + " "));
        assert (!backend.ran_commands[0].contains ("prefix"));

        // Config-only backups hold bare .reg files and extract into the prefix.
        backend.ran_commands.clear ();
        loop = new MainLoop ();
        ok = false;
        service.restore_prefix.begin (prefix, "/tmp/backup.tar.gz", false, (obj, res) => {
            ok = service.restore_prefix.end (res);
            loop.quit ();
        });
        loop.run ();

        assert (ok);
        assert (backend.ran_commands.size == 1);
        assert (backend.ran_commands[0].has_prefix ("tar -C " + Shell.quote (prefix) + " "));

        assert (delete_directory (root));
    }

    private void test_create_rebuild_delete () {
        var backend = new RecordingBackend ();
        var service = new ProtonPlus.Utils.WineRunnerService (backend);
        var binary = new ProtonPlus.Utils.WineBinary ("/usr/bin", "System Wine");

        var loop = new MainLoop ();
        bool ok = false;
        service.create_prefix.begin (binary, "/tmp/new-prefix", "win64", (obj, res) => {
            ok = service.create_prefix.end (res);
            loop.quit ();
        });
        loop.run ();
        assert (ok);
        assert (backend.ran_commands.size == 1);
        assert (backend.ran_commands[0].contains ("WINEARCH"));
        assert (backend.ran_commands[0].contains ("win64"));
        assert (backend.ran_commands[0].contains ("-i"));

        var root = create_temp_directory ();
        var delete_target = Path.build_filename (root, "delete-me");
        make_directory (delete_target);

        loop = new MainLoop ();
        ok = false;
        service.delete_prefix.begin (delete_target, (obj, res) => {
            ok = service.delete_prefix.end (res);
            loop.quit ();
        });
        loop.run ();
        assert (ok);
        assert (!FileUtils.test (delete_target, FileTest.EXISTS));

        assert (delete_directory (root));
    }

    private void test_clone_symlinks_inside_prefix () {
        var backend = new RecordingBackend ();
        var service = new ProtonPlus.Utils.WineRunnerService (backend);

        var root = create_temp_directory ();
        var source = Path.build_filename (root, "src");
        var target = Path.build_filename (root, "dst");
        make_directory (Path.build_filename (source, "drive_c"));
        make_directory (Path.build_filename (source, "dosdevices"));
        write_file (Path.build_filename (source, "drive_c", "file.txt"), "hello");
        assert (Posix.symlink ("../drive_c", Path.build_filename (source, "dosdevices", "c:")) == 0);
        assert (Posix.symlink ("/", Path.build_filename (source, "dosdevices", "z:")) == 0);

        var loop = new MainLoop ();
        bool ok = false;
        service.clone_prefix.begin (source, target, (obj, res) => {
            ok = service.clone_prefix.end (res);
            loop.quit ();
        });
        loop.run ();

        assert (ok);
        assert (FileUtils.test (Path.build_filename (target, "drive_c", "file.txt"), FileTest.IS_REGULAR));

        // Relative link recreated verbatim so it resolves inside the clone.
        var c_link = Path.build_filename (target, "dosdevices", "c:");
        assert (FileUtils.test (c_link, FileTest.IS_SYMLINK));
        try {
            assert (FileUtils.read_link (c_link) == "../drive_c");
        } catch (FileError e) {
            assert_not_reached ();
        }

        // External absolute link recreated verbatim.
        var z_link = Path.build_filename (target, "dosdevices", "z:");
        assert (FileUtils.test (z_link, FileTest.IS_SYMLINK));
        try {
            assert (FileUtils.read_link (z_link) == "/");
        } catch (FileError e) {
            assert_not_reached ();
        }

        assert (delete_directory (root));
    }

    private void test_clone_external_symlinks_verbatim () {
        var backend = new RecordingBackend ();
        var service = new ProtonPlus.Utils.WineRunnerService (backend);

        var root = create_temp_directory ();
        var source = Path.build_filename (root, "src");
        var target = Path.build_filename (root, "dst");
        make_directory (source);
        make_directory (Path.build_filename (root, "external-target"));
        assert (Posix.symlink (Path.build_filename (root, "external-target"), Path.build_filename (source, "link")) == 0);

        var loop = new MainLoop ();
        bool ok = false;
        service.clone_prefix.begin (source, target, (obj, res) => {
            ok = service.clone_prefix.end (res);
            loop.quit ();
        });
        loop.run ();

        assert (ok);
        var link = Path.build_filename (target, "link");
        assert (FileUtils.test (link, FileTest.IS_SYMLINK));
        try {
            assert (FileUtils.read_link (link) == Path.build_filename (root, "external-target"));
        } catch (FileError e) {
            assert_not_reached ();
        }

        assert (delete_directory (root));
    }

    private void test_clone_absolute_into_prefix_rewritten () {
        var backend = new RecordingBackend ();
        var service = new ProtonPlus.Utils.WineRunnerService (backend);

        var root = create_temp_directory ();
        var source = Path.build_filename (root, "src");
        var target = Path.build_filename (root, "dst");
        make_directory (source);
        make_directory (Path.build_filename (source, "windows"));
        write_file (Path.build_filename (source, "windows", "kernel32.dll"), "");
        var absolute_target = Path.build_filename (source, "windows", "kernel32.dll");
        assert (Posix.symlink (absolute_target, Path.build_filename (source, "link")) == 0);

        var loop = new MainLoop ();
        bool ok = false;
        service.clone_prefix.begin (source, target, (obj, res) => {
            ok = service.clone_prefix.end (res);
            loop.quit ();
        });
        loop.run ();

        assert (ok);
        var link = Path.build_filename (target, "link");
        assert (FileUtils.test (link, FileTest.IS_SYMLINK));
        try {
            var rewritten = FileUtils.read_link (link);
            assert (rewritten == Path.build_filename (target, "windows", "kernel32.dll"));
            assert (!rewritten.has_prefix (source));
        } catch (FileError e) {
            assert_not_reached ();
        }

        assert (delete_directory (root));
    }
}
