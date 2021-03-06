/* Copyright 2016 Software Freedom Conservancy Inc.
 *
 * Copyright 2011 Valentín Barros Puertas <valentin(at)sanva(dot)net>
 * Copyright 2018 Ricardo Fantin da Costa <ricardofantin(at)gmail(dot)com>
 * Copyright 2018 Narendra A <narendra_m_a(at)yahoo(dot)com>
 * 
 * This software is licensed under the GNU LGPL (version 2.1 or later).
 * See the COPYING file in this distribution.
 */

#include "shotwell-facedetect.hpp"
#include "dbus-interface.h"

const char* FACEDETECT_INTERFACE_NAME = "org.gnome.Shotwell.Faces1";
const char* FACEDETECT_PATH = "/org/gnome/shotwell/faces";

// DBus binding functions
static gboolean on_handle_detect_faces(ShotwellFaces1 *object,
                                       GDBusMethodInvocation *invocation,
                                       const gchar *arg_image,
                                       const gchar *arg_cascade,
                                       gdouble arg_scale,
                                       gboolean arg_infer) {
    GVariantBuilder *builder;
    GVariant *faces;
    std::vector<FaceRect> rects = 
        detectFaces(arg_image, arg_cascade, arg_scale, arg_infer);
    // Construct return value
    builder = g_variant_builder_new(G_VARIANT_TYPE ("a(ddddad)"));
    for (std::vector<FaceRect>::const_iterator r = rects.begin(); r != rects.end(); r++) {
        GVariantBuilder *arr_builder = g_variant_builder_new(G_VARIANT_TYPE ("ad"));
        for (std::vector<double>::const_iterator v = r->vec.begin(); v != r->vec.end(); v++) {
            GVariant *d = g_variant_new("d", *v);
            g_variant_builder_add(arr_builder, "d", d);
        }
        GVariant *vec = g_variant_new("ad", arr_builder);
        g_variant_builder_unref(arr_builder);
        GVariant *rect = g_variant_new("(dddd@ad)", r->x, r->y, r->width, r->height, vec);
        g_variant_builder_add(builder, "@(ddddad)", rect);
        g_debug("Returning %f,%f-%f", r->x, r->y, r->vec.back());
    }
    faces = g_variant_new("a(ddddad)", builder);
    g_variant_builder_unref (builder);
    // Call return
    shotwell_faces1_complete_detect_faces(object, invocation,
                                          faces);
    return TRUE;
}

static gboolean on_handle_load_net(ShotwellFaces1 *object,
                                   GDBusMethodInvocation *invocation,
                                   const gchar *arg_net) {
    bool ret = loadNet(arg_net);
    // Call return
    shotwell_faces1_complete_load_net(object, invocation,
                                      ret);
    return TRUE;
}

static gboolean on_handle_face_to_vec(ShotwellFaces1 *object,
                                      GDBusMethodInvocation *invocation,
                                      const gchar *arg_image) {
    GVariantBuilder *builder;
    GVariant *ret;
    std::vector<double> vec = faceToVec(arg_image);
    builder = g_variant_builder_new(G_VARIANT_TYPE ("ad"));
    for (std::vector<double>::const_iterator r = vec.begin(); r != vec.end(); r++) {
        GVariant *v = g_variant_new("d", *r);
        g_variant_builder_add(builder, "d", v);
    }
    ret = g_variant_new("ad", builder);
    g_variant_builder_unref(builder);
    shotwell_faces1_complete_face_to_vec(object, invocation,
                                         ret);
    return TRUE;
}

static gboolean on_handle_terminate(ShotwellFaces1 *object,
                                    GDBusMethodInvocation *invocation,
                                    gpointer user_data) {
    g_debug("Exiting...");
    shotwell_faces1_complete_terminate(object, invocation);
    g_main_loop_quit(reinterpret_cast<GMainLoop *>(user_data));

    return TRUE;
}

static void on_name_acquired(GDBusConnection *connection,
                             const gchar *name, gpointer user_data) {
    g_debug("Got name %s", name);

    ShotwellFaces1 *interface = shotwell_faces1_skeleton_new();
    g_signal_connect(interface, "handle-detect-faces", G_CALLBACK (on_handle_detect_faces), nullptr);
    g_signal_connect(interface, "handle-terminate", G_CALLBACK (on_handle_terminate), user_data);
    g_signal_connect(interface, "handle-load-net", G_CALLBACK (on_handle_load_net), nullptr);
    g_signal_connect(interface, "handle-face-to-vec", G_CALLBACK (on_handle_face_to_vec), nullptr);

    GError *error = nullptr;
    g_dbus_interface_skeleton_export(G_DBUS_INTERFACE_SKELETON(interface), connection, FACEDETECT_PATH, &error);
    if (error != nullptr) {
        g_print("Failed to export interface: %s", error->message);
        g_clear_error(&error);
    }
}

static void on_name_lost(GDBusConnection *connection,
                         const gchar *name, gpointer user_data) {
    if (connection == nullptr) {
        g_debug("Unable to establish connection for name %s", name);
    } else {
        g_debug("Connection for name %s disconnected", name);
    }
    g_main_loop_quit((GMainLoop *)user_data);
}

static char* address = nullptr;

static GOptionEntry entries[] = {
    { "address", 'a', 0, G_OPTION_ARG_STRING, &address, "Use private DBus ADDRESS instead of session", "ADDRESS" },
    { nullptr }
};

static gboolean
on_authorize_authenticated_peer (GIOStream *iostream,
                                 GCredentials *credentials,
                                 gpointer user_data)
{
    GCredentials *own_credentials = nullptr;
    gboolean ret_val = FALSE;

    g_debug("Authorizing peer with credentials %s\n", g_credentials_to_string (credentials));

    if (credentials == nullptr)
        goto out;

    own_credentials = g_credentials_new ();

    {
        GError* error = nullptr;

        if (!g_credentials_is_same_user (credentials, own_credentials, &error))
        {
            g_warning ("Unable to authorize peer: %s", error->message);
            g_clear_error (&error);

            goto out;
        }
    }

    ret_val = TRUE;

out:
    g_clear_object (&own_credentials);

    return ret_val;
}

int main(int argc, char **argv) {
    GMainLoop *loop;
    GError *error = nullptr;
    GOptionContext *context;

    context = g_option_context_new ("- Shotwell face detection helper service");
    g_option_context_add_main_entries (context, entries, "shotwell");
    if (!g_option_context_parse (context, &argc, &argv, &error)) {
        g_print ("Failed to parse options: %s\n", error->message);
        exit(1);
    }

    loop = g_main_loop_new (nullptr, FALSE);


    // We are running on the sesion bus
    if (address == nullptr) {
        g_debug("Starting %s on G_BUS_TYPE_SESSION", argv[0]);
        g_bus_own_name(G_BUS_TYPE_SESSION, FACEDETECT_INTERFACE_NAME, G_BUS_NAME_OWNER_FLAGS_NONE,
                nullptr, on_name_acquired, on_name_lost, loop, nullptr);

    } else {
        g_debug("Starting %s on %s", argv[0], address);
        GDBusAuthObserver *observer = g_dbus_auth_observer_new ();
        g_signal_connect (G_OBJECT (observer), "authorize-authenticated-peer",
                G_CALLBACK (on_authorize_authenticated_peer), nullptr);

        GDBusConnection *connection = g_dbus_connection_new_for_address_sync (address,
                                                             G_DBUS_CONNECTION_FLAGS_AUTHENTICATION_CLIENT,
                                                             observer,
                                                             nullptr,
                                                             &error);
        if (connection != nullptr)
            on_name_acquired(connection, FACEDETECT_INTERFACE_NAME, loop);
    }

    if (error != nullptr) {
        g_error("Failed to get connection on %s bus: %s",
                address == nullptr ? "session" : "private",
                error->message);
    }

    g_main_loop_run (loop);
    return 0;
}
