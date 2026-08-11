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

        public Box () {
            Object (orientation: Gtk.Orientation.VERTICAL, spacing: 0);
            set_vexpand (true);

            build_ui ();
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
                expanded = false
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

            details_rows[prefix.path] = new Gee.ArrayList<Adw.PreferencesRow> ();

            return row;
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
    }
}
