/* Copyright 2016 Software Freedom Conservancy Inc.
 * Copyright 2019 Jens Georg <mail@jensge.org>
 *
 * This software is licensed under the GNU LGPL (version 2.1 or later).
 * See the COPYING file in this distribution.
 */

namespace PublishingUI {

[GtkTemplate (ui = "/org/gnome/Shotwell/ui/static_message_pane_widget.ui")]
public class StaticMessagePane : Spit.Publishing.DialogPane, Gtk.Box {
    [GtkChild]
    private Gtk.Label static_msg_label;

    public Gtk.Widget get_widget() {
        return this;
    }

    public Spit.Publishing.DialogPane.GeometryOptions get_preferred_geometry() {
        return Spit.Publishing.DialogPane.GeometryOptions.NONE;
    }

    public void on_pane_installed() {
    }

    public void on_pane_uninstalled() {
    }

    public StaticMessagePane(string message_string, bool enable_markup = false) {
        Object();

        if (enable_markup) {
            static_msg_label.set_markup(message_string);
            static_msg_label.set_line_wrap(true);
            static_msg_label.set_use_markup(true);
        } else {
            static_msg_label.set_label(message_string);
        }
    }
}

public class AccountFetchWaitPane : StaticMessagePane {
    public AccountFetchWaitPane() {
        base(_("Fetching account information…"));
    }
}

public class LoginWaitPane : StaticMessagePane {
    public LoginWaitPane() {
        base(_("Logging in…"));
    }
}

} // namespace PublishingUI
