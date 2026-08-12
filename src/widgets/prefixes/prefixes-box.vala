namespace ProtonPlus.Widgets.Prefixes {
    public class Box : Gtk.Box {
        private Gtk.Box results_box;
        private Gtk.Box scan_prompt;
        private Gtk.Label status_label;
        private Gtk.Spinner spinner;
        private Gtk.Button rescan_button;
        private Gtk.Switch show_tools_switch;
        private Gtk.ScrolledWindow scrolled_window;
        private bool scanning = false;
        private bool pending_refresh = false;
        private Gee.HashSet<string> details_scanning = new Gee.HashSet<string> ();
        private Gee.HashMap<string, Gee.ArrayList<Adw.PreferencesRow>> details_rows = new Gee.HashMap<string, Gee.ArrayList<Adw.PreferencesRow>> ();

        private Utils.WineRunnerService wine_runner = new Utils.WineRunnerService ();
        private Gee.List<Utils.WineBinary> runners = new Gee.ArrayList<Utils.WineBinary> ();
        private Utils.WineBinary? selected_runner = null;
        private Gee.LinkedList<Models.Launcher>? launchers = null;
        private Gtk.DropDown runner_dropdown;
        private Gtk.Label version_label;

        public signal void toast_sent (string title);

        public Box () {
            Object (orientation: Gtk.Orientation.VERTICAL, spacing: 0);
            set_vexpand (true);

            build_ui ();
        }

        public void initialize (Gee.LinkedList<Models.Launcher> launchers) {
            this.launchers = launchers;
            refresh_runners.begin ();
        }

        public void show_prefixes_page () {
            if (scrolled_window.get_vadjustment () != null)
                scrolled_window.get_vadjustment ().value = 0;
        }

        private void build_ui () {
            var content_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 12) {
                margin_top = 12,
                margin_bottom = 12,
                margin_start = 12,
                margin_end = 12
            };

            var header_box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8) {
                halign = Gtk.Align.START
            };
            status_label = new Gtk.Label (null) {
                halign = Gtk.Align.START,
                xalign = 0
            };
            status_label.add_css_class ("heading");
            spinner = new Gtk.Spinner () {
                visible = false
            };
            header_box.append (spinner);
            header_box.append (status_label);
            content_box.append (header_box);

            results_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 12);
            content_box.append (results_box);

            scrolled_window = new Gtk.ScrolledWindow () {
                hscrollbar_policy = Gtk.PolicyType.NEVER,
                vexpand = true,
                child = new Adw.Clamp () {
                    maximum_size = 975,
                    child = content_box
                }
            };
            append (scrolled_window);

            var action_bar = new Gtk.ActionBar ();
            rescan_button = new Gtk.Button.from_icon_name ("view-refresh-symbolic") {
                valign = Gtk.Align.CENTER
            };
            rescan_button.set_tooltip_text (_ ("Rescan"));
            rescan_button.clicked.connect (() => refresh.begin ());
            action_bar.pack_start (rescan_button);

            var runner_box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8) {
                valign = Gtk.Align.CENTER
            };
            runner_box.append (new Gtk.Label (_ ("Runner:")));
            runner_dropdown = new Gtk.DropDown (null, null) {
                valign = Gtk.Align.CENTER,
                selected = 0
            };
            runner_dropdown.notify["selected-item"].connect (on_runner_selected);
            runner_box.append (runner_dropdown);
            version_label = new Gtk.Label (null) {
                valign = Gtk.Align.CENTER,
                css_classes = { "dim-label" }
            };
            runner_box.append (version_label);
            action_bar.pack_start (runner_box);

            show_tools_switch = new Gtk.Switch () {
                valign = Gtk.Align.CENTER,
                active = false
            };
            show_tools_switch.notify["active"].connect (() => {
                refresh.begin ();
            });
            var toggle_box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8) {
                valign = Gtk.Align.CENTER
            };
            toggle_box.append (new Gtk.Label (_ ("Show tool prefixes")));
            toggle_box.append (show_tools_switch);
            action_bar.pack_end (toggle_box);

            var new_prefix_button = new Gtk.Button.from_icon_name ("list-add-symbolic") {
                valign = Gtk.Align.CENTER
            };
            new_prefix_button.set_tooltip_text (_ ("Create a new Wine prefix"));
            new_prefix_button.clicked.connect (show_new_prefix_dialog);
            action_bar.pack_end (new_prefix_button);
            append (action_bar);

            build_scan_prompt ();
            results_box.append (scan_prompt);
        }

        private void build_scan_prompt () {
            scan_prompt = new Gtk.Box (Gtk.Orientation.VERTICAL, 8) {
                halign = Gtk.Align.CENTER,
                valign = Gtk.Align.CENTER,
                margin_top = 48,
                margin_bottom = 48
            };

            var icon = new Gtk.Image.from_icon_name ("drive-harddisk-symbolic");
            icon.pixel_size = 48;
            icon.add_css_class ("dim-label");
            scan_prompt.append (icon);

            var title = new Gtk.Label (_ ("No Wine prefixes scanned yet")) {
                css_classes = { "title-1" }
            };
            scan_prompt.append (title);

            var subtitle = new Gtk.Label (_ ("Scan your home directory to discover Wine prefixes.")) {
                css_classes = { "dim-label" },
                wrap = true
            };
            scan_prompt.append (subtitle);

            var button = new Gtk.Button.with_label (_ ("Scan for Wine prefixes")) {
                css_classes = { "suggested-action" },
                margin_top = 8
            };
            button.clicked.connect (() => refresh.begin ());
            scan_prompt.append (button);
        }

        private void clear_results () {
            var child = results_box.get_first_child ();
            while (child != null) {
                results_box.remove (child);
                child = results_box.get_first_child ();
            }
        }

        private void show_scan_prompt () {
            if (scan_prompt.get_parent () == null)
                results_box.append (scan_prompt);
        }

        public async void refresh () {
            if (scanning) {
                pending_refresh = true;
                return;
            }

            scanning = true;
            rescan_button.sensitive = false;
            spinner.visible = true;
            spinner.start ();
            status_label.label = _ ("Scanning for Wine prefixes…");
            clear_results ();

            var home = Environment.get_home_dir ();
            var prefixes = yield Utils.WinePrefixManager.instance.scan (home, !show_tools_switch.active);

            if (prefixes.size == 0) {
                status_label.label = _ ("No Wine prefixes found");
                show_scan_prompt ();
            } else {
                status_label.label = ngettext ("%u Wine prefix found", "%u Wine prefixes found", prefixes.size).printf (prefixes.size);
                var group = new Adw.PreferencesGroup ();
                foreach (var prefix in prefixes) {
                    group.add (create_prefix_expander (prefix));
                }
                results_box.append (group);
            }

            spinner.stop ();
            spinner.visible = false;
            rescan_button.sensitive = true;
            scanning = false;

            if (pending_refresh) {
                pending_refresh = false;
                refresh.begin ();
            }
        }

        private Adw.ExpanderRow create_prefix_expander (Utils.WinePrefix prefix) {
            var row = new Adw.ExpanderRow () {
                title = prefix.path,
                subtitle = get_architecture_display (prefix),
                expanded = false,
                enable_expansion = false
            };
            row.set_tooltip_text (prefix.path);

            var details_button = new Gtk.Button.from_icon_name ("system-search-symbolic") {
                valign = Gtk.Align.CENTER
            };
            details_button.add_css_class ("flat");
            details_button.set_tooltip_text (_ ("Scan details"));

            var details_spinner = new Gtk.Spinner () {
                visible = false
            };
            details_button.clicked.connect (() => scan_prefix_details.begin (prefix, row, details_button, details_spinner));
            row.add_suffix (details_button);
            row.add_suffix (details_spinner);

            var actions_button = new Gtk.MenuButton () {
                icon_name = "view-more-symbolic",
                valign = Gtk.Align.CENTER
            };
            actions_button.add_css_class ("flat");
            actions_button.set_tooltip_text (_ ("Prefix actions"));
            var popover = new Gtk.Popover () {
                child = build_actions_box (prefix)
            };
            actions_button.set_popover (popover);
            ProtonPlus.Widgets.Window.register_popover_for_controller (popover, actions_button);
            row.add_suffix (actions_button);

            details_rows[prefix.path] = new Gee.ArrayList<Adw.PreferencesRow> ();

            return row;
        }

        private Gtk.Box build_actions_box (Utils.WinePrefix prefix) {
            var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0) {
                margin_top = 6,
                margin_bottom = 6
            };
            box.set_size_request (220, -1);

            var test_run = make_action_button ("media-playback-start-symbolic", _ ("Test Run"));
            test_run.clicked.connect (() => on_test_run.begin (prefix));
            box.append (test_run);

            var winecfg = make_action_button ("preferences-system-symbolic", _ ("Open Winecfg"));
            winecfg.clicked.connect (() => on_open_winecfg.begin (prefix));
            box.append (winecfg);

            var explorer = make_action_button ("folder-symbolic", _ ("Open Explorer"));
            explorer.clicked.connect (() => on_open_explorer.begin (prefix));
            box.append (explorer);

            var run_exe = make_action_button ("document-open-symbolic", _ ("Run Executable…"));
            run_exe.clicked.connect (() => show_run_executable_dialog (prefix));
            box.append (run_exe);

            box.append (new Gtk.Separator (Gtk.Orientation.HORIZONTAL));

            var backup = make_action_button ("document-save-symbolic", _ ("Backup…"));
            backup.clicked.connect (() => show_backup_dialog (prefix));
            box.append (backup);

            var restore = make_action_button ("document-revert-symbolic", _ ("Restore…"));
            restore.clicked.connect (() => show_restore_dialog (prefix));
            box.append (restore);

            var clone = make_action_button ("edit-copy-symbolic", _ ("Clone…"));
            clone.clicked.connect (() => show_clone_dialog (prefix));
            box.append (clone);

            var rebuild = make_action_button ("view-refresh-symbolic", _ ("Rebuild"));
            rebuild.clicked.connect (() => show_rebuild_dialog (prefix));
            box.append (rebuild);

            var delete_action = make_action_button ("edit-delete-symbolic", _ ("Delete"));
            delete_action.clicked.connect (() => show_delete_dialog (prefix));
            box.append (delete_action);

            return box;
        }

        private Gtk.Button make_action_button (string icon, string label) {
            var button = new Gtk.Button () {
                halign = Gtk.Align.FILL
            };
            button.add_css_class ("flat");
            var inner = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8) {
                margin_start = 12,
                margin_end = 12,
                margin_top = 4,
                margin_bottom = 4
            };
            inner.append (new Gtk.Image.from_icon_name (icon));
            inner.append (new Gtk.Label (label) {
                xalign = 0
            });
            button.child = inner;
            return button;
        }

        private void attach_folder_picker (Adw.EntryRow row, string title) {
            var button = new Gtk.Button.from_icon_name ("folder-open-symbolic") {
                valign = Gtk.Align.CENTER
            };
            button.set_tooltip_text (_ ("Browse…"));
            row.add_suffix (button);
            button.clicked.connect (() => {
                var folder_dialog = new Gtk.FileDialog () {
                    title = title
                };
                folder_dialog.select_folder.begin (get_root () as Gtk.Window, null, (obj, res) => {
                    try {
                        var file = folder_dialog.select_folder.end (res);
                        if (file != null)
                            row.text = file.get_path ();
                    } catch (Error e) {
                        warning (e.message);
                    }
                });
            });
        }

        private void attach_file_picker (Adw.EntryRow row, string title) {
            var button = new Gtk.Button.from_icon_name ("folder-open-symbolic") {
                valign = Gtk.Align.CENTER
            };
            button.set_tooltip_text (_ ("Browse…"));
            row.add_suffix (button);
            button.clicked.connect (() => {
                var file_dialog = new Gtk.FileDialog () {
                    title = title
                };
                file_dialog.open.begin (get_root () as Gtk.Window, null, (obj, res) => {
                    try {
                        var file = file_dialog.open.end (res);
                        if (file != null)
                            row.text = file.get_path ();
                    } catch (Error e) {
                        warning (e.message);
                    }
                });
            });
        }

        private async void on_test_run (Utils.WinePrefix prefix) {
            var runner = get_selected_runner ();
            if (runner == null)
                return;
            var result = yield wine_runner.test_prefix (runner, prefix.path);
            if (result.exit_status != 0)
                toast_sent (_ ("Couldn't test prefix: %s").printf (get_result_message (result)));
            else
                toast_sent (_ ("Prefix works correctly"));
        }

        private async void on_open_winecfg (Utils.WinePrefix prefix) {
            var runner = get_selected_runner ();
            if (runner == null)
                return;
            var result = yield wine_runner.open_winecfg (runner, prefix.path);
            if (result.exit_status != 0)
                toast_sent (_ ("Couldn't open Wine configuration: %s").printf (get_result_message (result)));
        }

        private async void on_open_explorer (Utils.WinePrefix prefix) {
            var runner = get_selected_runner ();
            if (runner == null)
                return;
            var result = yield wine_runner.open_explorer (runner, prefix.path);
            if (result.exit_status != 0)
                toast_sent (_ ("Couldn't open Explorer: %s").printf (get_result_message (result)));
        }

        private async void on_run_executable (Utils.WinePrefix prefix, string exe_path) {
            if (exe_path == "") {
                toast_sent (_ ("No executable path given"));
                return;
            }
            var runner = get_selected_runner ();
            if (runner == null)
                return;
            var result = yield wine_runner.run_executable (runner, prefix.path, exe_path);
            if (result.exit_status != 0)
                toast_sent (_ ("Couldn't run executable: %s").printf (get_result_message (result)));
        }

        private string get_result_message (Utils.CommandResult result) {
            if (result.stderr.strip () != "")
                return result.stderr.strip ();
            if (result.stdout.strip () != "")
                return result.stdout.strip ();
            return _ ("unknown error");
        }

        private Utils.WineBinary? get_selected_runner () {
            if (selected_runner == null) {
                toast_sent (_ ("No Wine runner available"));
                return null;
            }
            return selected_runner;
        }

        private async void refresh_runners () {
            runners = yield wine_runner.discover_binaries (launchers);

            var names = new Gtk.StringList (null);
            foreach (var runner in runners)
                names.append (runner.display_name);

            if (runners.size == 0)
                names.append (_ ("No Wine found"));

            runner_dropdown.model = names;
            runner_dropdown.selected = 0;
            on_runner_selected ();
        }

        private void on_runner_selected () {
            var index = (int) runner_dropdown.selected;
            if (index >= 0 && index < runners.size) {
                selected_runner = runners[index];
                update_version.begin (runners[index]);
            } else {
                selected_runner = null;
                version_label.label = "";
            }
        }

        private async void update_version (Utils.WineBinary runner) {
            if (runner.version == "")
                yield wine_runner.get_version (runner);
            if (runner.version != "")
                version_label.label = runner.version;
            else
                version_label.label = _ ("Version unknown");
        }

        private async void scan_prefix_details (Utils.WinePrefix prefix, Adw.ExpanderRow row, Gtk.Button details_button, Gtk.Spinner details_spinner) {
            if (details_scanning.contains (prefix.path))
                return;
            details_scanning.add (prefix.path);

            details_button.visible = false;
            details_spinner.visible = true;
            details_spinner.start ();

            yield Utils.WinePrefixManager.instance.scan_details (prefix);

            populate_prefix_rows (row, prefix);
            row.enable_expansion = true;
            row.expanded = true;

            details_spinner.stop ();
            details_spinner.visible = false;
            details_button.visible = true;
            details_scanning.remove (prefix.path);
        }

        private void populate_prefix_rows (Adw.ExpanderRow row, Utils.WinePrefix prefix) {
            var rows = details_rows[prefix.path] ?? new Gee.ArrayList<Adw.PreferencesRow> ();
            foreach (var detail_row in rows) {
                row.remove (detail_row);
            }
            rows.clear ();

            var arch_row = new Adw.ActionRow () {
                title = _ ("Architecture"),
                subtitle = get_architecture_display (prefix)
            };
            row.add_row (arch_row);
            rows.add (arch_row);

            if (prefix.symlink_targets.length > 0) {
                var symlink_header = new Adw.ActionRow () {
                    title = _ ("Symlinks"),
                    subtitle = ngettext ("%u symlink", "%u symlinks", prefix.symlink_targets.length).printf (prefix.symlink_targets.length)
                };
                row.add_row (symlink_header);
                rows.add (symlink_header);

                foreach (var symlink in prefix.symlink_targets) {
                    var link_row = new Adw.ActionRow () {
                        title = _ ("Symlink"),
                        subtitle = symlink
                    };
                    row.add_row (link_row);
                    rows.add (link_row);
                }
            } else {
                var no_symlinks_row = new Adw.ActionRow () {
                    title = _ ("Symlinks"),
                    subtitle = _ ("No symlinks")
                };
                row.add_row (no_symlinks_row);
                rows.add (no_symlinks_row);
            }

            var deps_row = new Adw.ActionRow () {
                title = _ ("Dependencies"),
                subtitle = prefix.detected_dependencies.length > 0
                    ? string.joinv (", ", prefix.detected_dependencies)
                    : _ ("None")
            };
            row.add_row (deps_row);
            rows.add (deps_row);

            var overrides_row = new Adw.ActionRow () {
                title = _ ("DLL overrides"),
                subtitle = build_override_list (prefix.dll_overrides)
            };
            row.add_row (overrides_row);
            rows.add (overrides_row);

            if (prefix.created_at != null) {
                var created_row = new Adw.ActionRow () {
                    title = _ ("Created"),
                    subtitle = format_date (prefix.created_at)
                };
                row.add_row (created_row);
                rows.add (created_row);
            }

            if (prefix.modified_at != null) {
                var modified_row = new Adw.ActionRow () {
                    title = _ ("Modified"),
                    subtitle = format_date (prefix.modified_at)
                };
                row.add_row (modified_row);
                rows.add (modified_row);
            }

            var tweaks_row = new Adw.ActionRow () {
                title = _ ("Detected tweaks"),
                subtitle = prefix.detected_tweaks.length > 0
                    ? string.joinv (", ", prefix.detected_tweaks)
                    : _ ("None detected")
            };
            row.add_row (tweaks_row);
            rows.add (tweaks_row);
        }

        private string format_date (DateTime dt) {
            return dt.format ("%Y-%m-%d %H:%M");
        }

        private const int MAX_OVERRIDES_SHOWN = 8;

        private string build_override_list (string[] overrides) {
            if (overrides.length == 0)
                return _ ("None");

            int shown = int.min (overrides.length, MAX_OVERRIDES_SHOWN);
            var parts = new Gee.ArrayList<string> ();
            for (int i = 0; i < shown; i++)
                parts.add (overrides[i]);

            string joined = string.joinv (", ", parts.to_array ());
            if (overrides.length > shown) {
                joined += ngettext (", +%u more override", ", +%u more overrides", overrides.length - shown).printf (overrides.length - shown);
            }
            return joined;
        }

        private string get_architecture_display (Utils.WinePrefix prefix) {
            switch (prefix.architecture) {
                case "64-bit":
                    return _ ("64-bit");
                case "32-bit":
                    return _ ("32-bit");
                default:
                    return _ ("Unknown");
            }
        }

        private string get_winearch (Utils.WinePrefix prefix) {
            if (prefix.architecture == "32-bit")
                return "win32";
            return "win64";
        }

        private void show_new_prefix_dialog () {
            var dialog = new Adw.AlertDialog (_ ("Create a New Wine Prefix"),
                _ ("Choose a name, architecture, and location for the new prefix."));
            dialog.add_response ("cancel", _ ("Cancel"));
            dialog.add_response ("create", _ ("Create"));
            dialog.set_default_response ("create");
            dialog.set_close_response ("cancel");
            dialog.set_response_appearance ("create", Adw.ResponseAppearance.SUGGESTED);

            var name_row = new Adw.EntryRow () {
                title = _ ("Name"),
                text = "my-prefix"
            };
            name_row.set_activates_default (true);

            var dir_row = new Adw.EntryRow () {
                title = _ ("Location"),
                text = Environment.get_home_dir ()
            };
            attach_folder_picker (dir_row, _ ("Select Location"));

            var arch_row = new Adw.ComboRow () {
                title = _ ("Architecture"),
                model = new Gtk.StringList ({"win64", "win32"}),
                selected = 0
            };

            var win32_warning = new Gtk.Label (
                _ ("32-bit prefixes are not supported by all Wine builds, notably WoW64. Some runners can no longer create 32-bit prefixes.")) {
                wrap = true,
                xalign = 0,
                visible = false,
                css_classes = { "error" }
            };
            arch_row.notify["selected"].connect (() => {
                win32_warning.visible = (arch_row.selected == 1);
            });

            var extra = new Adw.PreferencesGroup ();
            extra.add (name_row);
            extra.add (dir_row);
            extra.add (arch_row);
            extra.add (win32_warning);
            dialog.set_extra_child (extra);

            dialog.response.connect ((response) => {
                if (response != "create")
                    return;
                create_new_prefix.begin (name_row.text.strip (), dir_row.text.strip (), arch_row.selected == 0 ? "win64" : "win32");
            });

            ProtonPlus.Widgets.Window.present_dialog_for_controller (dialog, this);
        }

        private async void create_new_prefix (string name, string dir, string arch) {
            if (name == "" || name.has_prefix (".") || name.contains (Path.DIR_SEPARATOR_S)) {
                toast_sent (_ ("Invalid prefix name"));
                return;
            }
            if (!FileUtils.test (dir, FileTest.IS_DIR)) {
                toast_sent (_ ("Location does not exist"));
                return;
            }

            var runner = get_selected_runner ();
            if (runner == null)
                return;

            var target = Path.build_filename (dir, name);
            if (FileUtils.test (target, FileTest.EXISTS)) {
                toast_sent (_ ("A prefix named “%s” already exists").printf (name));
                return;
            }

            toast_sent (_ ("Creating prefix “%s”…").printf (name));
            if (yield wine_runner.create_prefix (runner, target, arch))
                toast_sent (_ ("Prefix “%s” created").printf (name));
            else
                toast_sent (_ ("Couldn't create prefix “%s”").printf (name));

            refresh.begin ();
        }

        private void show_run_executable_dialog (Utils.WinePrefix prefix) {
            if (get_selected_runner () == null)
                return;

            var dialog = new Adw.AlertDialog (_ ("Run Executable"),
                _ ("Enter the path of an executable to run inside %s.").printf (prefix.path));
            dialog.add_response ("cancel", _ ("Cancel"));
            dialog.add_response ("run", _ ("Run"));
            dialog.set_default_response ("run");
            dialog.set_close_response ("cancel");
            dialog.set_response_appearance ("run", Adw.ResponseAppearance.SUGGESTED);

            var path_row = new Adw.EntryRow () {
                title = _ ("Path"),
                text = ""
            };
            path_row.set_activates_default (true);
            attach_file_picker (path_row, _ ("Select Executable"));

            var extra = new Adw.PreferencesGroup ();
            extra.add (path_row);
            dialog.set_extra_child (extra);

            dialog.response.connect ((response) => {
                if (response != "run")
                    return;
                on_run_executable.begin (prefix, path_row.text.strip ());
            });

            ProtonPlus.Widgets.Window.present_dialog_for_controller (dialog, this);
        }

        private void show_backup_dialog (Utils.WinePrefix prefix) {
            if (get_selected_runner () == null)
                return;

            var dialog = new Adw.AlertDialog (_ ("Backup Prefix"),
                _ ("Create an archive of %s.").printf (prefix.path));
            dialog.add_response ("cancel", _ ("Cancel"));
            dialog.add_response ("backup", _ ("Backup"));
            dialog.set_default_response ("backup");
            dialog.set_close_response ("cancel");
            dialog.set_response_appearance ("backup", Adw.ResponseAppearance.SUGGESTED);

            var name_row = new Adw.EntryRow () {
                title = _ ("Name"),
                text = Path.get_basename (prefix.path)
            };
            name_row.set_activates_default (true);

            var dir_row = new Adw.EntryRow () {
                title = _ ("Location"),
                text = Environment.get_home_dir ()
            };
            attach_folder_picker (dir_row, _ ("Select Location"));

            var full_row = new Adw.SwitchRow () {
                title = _ ("Full backup"),
                subtitle = _ ("Include all files. Disable to save only the registry.")
            };
            full_row.set_active (true);

            var extra = new Adw.PreferencesGroup ();
            extra.add (name_row);
            extra.add (dir_row);
            extra.add (full_row);
            dialog.set_extra_child (extra);

            dialog.response.connect ((response) => {
                if (response != "backup")
                    return;
                backup_prefix_checked.begin (prefix, name_row.text.strip (), dir_row.text.strip (), full_row.active);
            });

            ProtonPlus.Widgets.Window.present_dialog_for_controller (dialog, this);
        }

        private async void backup_prefix_checked (Utils.WinePrefix prefix, string name, string dir, bool full) {
            if (name == "" || name.contains (Path.DIR_SEPARATOR_S)) {
                toast_sent (_ ("Invalid file name"));
                return;
            }
            if (!FileUtils.test (dir, FileTest.IS_DIR)) {
                toast_sent (_ ("Location does not exist"));
                return;
            }

            var dest = Path.build_filename (dir, name + ".tar.gz");
            if (FileUtils.test (dest, FileTest.EXISTS)) {
                if (!(yield confirm_overwrite (dest)))
                    return;
            }

            toast_sent (_ ("Backing up %s…").printf (Path.get_basename (prefix.path)));
            if (yield wine_runner.backup_prefix (prefix.path, dest, full))
                toast_sent (_ ("Backup saved to %s").printf (dest));
            else
                toast_sent (_ ("Couldn't back up prefix"));
        }

        private async bool confirm_overwrite (string dest) {
            bool confirmed = false;
            var loop = new MainLoop ();

            var dialog = new Adw.AlertDialog (_ ("Overwrite File?"),
                _ ("%s already exists. Overwrite it?").printf (dest));
            dialog.add_response ("cancel", _ ("Cancel"));
            dialog.add_response ("overwrite", _ ("Overwrite"));
            dialog.set_default_response ("cancel");
            dialog.set_close_response ("cancel");
            dialog.set_response_appearance ("overwrite", Adw.ResponseAppearance.DESTRUCTIVE);

            dialog.response.connect ((response) => {
                confirmed = (response == "overwrite");
                loop.quit ();
            });
            dialog.closed.connect (() => loop.quit ());

            ProtonPlus.Widgets.Window.present_dialog_for_controller (dialog, this);
            loop.run ();
            return confirmed;
        }

        private void show_restore_dialog (Utils.WinePrefix prefix) {
            if (get_selected_runner () == null)
                return;

            var dialog = new Adw.AlertDialog (_ ("Restore Prefix"),
                _ ("Restore %s from a backup archive.").printf (prefix.path));
            dialog.add_response ("cancel", _ ("Cancel"));
            dialog.add_response ("restore", _ ("Restore"));
            dialog.set_default_response ("restore");
            dialog.set_close_response ("cancel");
            dialog.set_response_appearance ("restore", Adw.ResponseAppearance.SUGGESTED);

            var backup_row = new Adw.EntryRow () {
                title = _ ("Backup file"),
                text = ""
            };
            backup_row.set_activates_default (true);
            attach_file_picker (backup_row, _ ("Select Backup File"));

            var full_row = new Adw.SwitchRow () {
                title = _ ("Full restore"),
                subtitle = _ ("The archive contains all files. Disable to restore only the registry.")
            };
            full_row.set_active (true);

            var extra = new Adw.PreferencesGroup ();
            extra.add (backup_row);
            extra.add (full_row);
            dialog.set_extra_child (extra);

            dialog.response.connect ((response) => {
                if (response != "restore")
                    return;
                restore_prefix_checked.begin (prefix, backup_row.text.strip (), full_row.active);
            });

            ProtonPlus.Widgets.Window.present_dialog_for_controller (dialog, this);
        }

        private async void restore_prefix_checked (Utils.WinePrefix prefix, string backup, bool full) {
            if (backup == "") {
                toast_sent (_ ("No backup file given"));
                return;
            }
            if (!FileUtils.test (backup, FileTest.EXISTS)) {
                toast_sent (_ ("Backup file not found"));
                return;
            }
            toast_sent (_ ("Restoring %s…").printf (Path.get_basename (prefix.path)));
            if (yield wine_runner.restore_prefix (prefix.path, backup, full))
                toast_sent (_ ("Prefix restored"));
            else
                toast_sent (_ ("Couldn't restore prefix"));

            refresh.begin ();
        }

        private void show_clone_dialog (Utils.WinePrefix prefix) {
            if (get_selected_runner () == null)
                return;

            var dialog = new Adw.AlertDialog (_ ("Clone Prefix"),
                _ ("Copy %s to a new prefix.").printf (prefix.path));
            dialog.add_response ("cancel", _ ("Cancel"));
            dialog.add_response ("clone", _ ("Clone"));
            dialog.set_default_response ("clone");
            dialog.set_close_response ("cancel");
            dialog.set_response_appearance ("clone", Adw.ResponseAppearance.SUGGESTED);

            var name_row = new Adw.EntryRow () {
                title = _ ("Name"),
                text = Path.get_basename (prefix.path) + "-copy"
            };
            name_row.set_activates_default (true);

            var dir_row = new Adw.EntryRow () {
                title = _ ("Location"),
                text = Path.get_dirname (prefix.path)
            };
            attach_folder_picker (dir_row, _ ("Select Location"));

            var extra = new Adw.PreferencesGroup ();
            extra.add (name_row);
            extra.add (dir_row);
            dialog.set_extra_child (extra);

            dialog.response.connect ((response) => {
                if (response != "clone")
                    return;
                clone_prefix_checked.begin (prefix, name_row.text.strip (), dir_row.text.strip ());
            });

            ProtonPlus.Widgets.Window.present_dialog_for_controller (dialog, this);
        }

        private async void clone_prefix_checked (Utils.WinePrefix prefix, string name, string dir) {
            if (name == "" || name.has_prefix (".") || name.contains (Path.DIR_SEPARATOR_S)) {
                toast_sent (_ ("Invalid prefix name"));
                return;
            }
            if (!FileUtils.test (dir, FileTest.IS_DIR)) {
                toast_sent (_ ("Location does not exist"));
                return;
            }

            var target = Path.build_filename (dir, name);
            if (FileUtils.test (target, FileTest.EXISTS)) {
                toast_sent (_ ("A prefix named “%s” already exists").printf (name));
                return;
            }

            toast_sent (_ ("Cloning %s…").printf (Path.get_basename (prefix.path)));
            if (yield wine_runner.clone_prefix (prefix.path, target))
                toast_sent (_ ("Prefix cloned to %s").printf (target));
            else
                toast_sent (_ ("Couldn't clone prefix"));

            refresh.begin ();
        }

        private void show_rebuild_dialog (Utils.WinePrefix prefix) {
            if (get_selected_runner () == null)
                return;

            var dialog = new Adw.AlertDialog (_ ("Rebuild Prefix?"),
                _ ("%s will be deleted and recreated with a fresh registry. Installed applications and files will be lost.").printf (prefix.path));
            dialog.add_response ("cancel", _ ("Cancel"));
            dialog.add_response ("rebuild", _ ("Rebuild"));
            dialog.set_default_response ("cancel");
            dialog.set_close_response ("cancel");
            dialog.set_response_appearance ("rebuild", Adw.ResponseAppearance.DESTRUCTIVE);

            dialog.response.connect ((response) => {
                if (response != "rebuild")
                    return;
                rebuild_prefix_checked.begin (prefix);
            });

            ProtonPlus.Widgets.Window.present_dialog_for_controller (dialog, this);
        }

        private async void rebuild_prefix_checked (Utils.WinePrefix prefix) {
            var runner = get_selected_runner ();
            if (runner == null)
                return;

            toast_sent (_ ("Rebuilding %s…").printf (Path.get_basename (prefix.path)));
            if (yield wine_runner.rebuild_prefix (runner, prefix.path, get_winearch (prefix)))
                toast_sent (_ ("Prefix rebuilt"));
            else
                toast_sent (_ ("Couldn't rebuild prefix"));

            refresh.begin ();
        }

        private void show_delete_dialog (Utils.WinePrefix prefix) {
            var dialog = new Adw.AlertDialog (_ ("Delete Prefix?"),
                _ ("%s will be permanently deleted. Installed applications and files will be lost.").printf (prefix.path));
            dialog.add_response ("cancel", _ ("Cancel"));
            dialog.add_response ("delete", _ ("Delete"));
            dialog.set_default_response ("cancel");
            dialog.set_close_response ("cancel");
            dialog.set_response_appearance ("delete", Adw.ResponseAppearance.DESTRUCTIVE);

            dialog.response.connect ((response) => {
                if (response != "delete")
                    return;
                delete_prefix_checked.begin (prefix);
            });

            ProtonPlus.Widgets.Window.present_dialog_for_controller (dialog, this);
        }

        private async void delete_prefix_checked (Utils.WinePrefix prefix) {
            toast_sent (_ ("Deleting %s…").printf (Path.get_basename (prefix.path)));
            if (yield wine_runner.delete_prefix (prefix.path))
                toast_sent (_ ("Prefix deleted"));
            else
                toast_sent (_ ("Couldn't delete prefix"));

            refresh.begin ();
        }
    }
}
