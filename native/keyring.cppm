// SPDX-License-Identifier: MIT
//
// The OS keyring, through libsecret directly.
//
// The shell version shelled out to secret-tool for every lookup, which meant a
// process per credential and a token passing through a pipe. secret-tool is a
// program that ships *with* libsecret, so calling the library costs nothing in
// portability and removes both.
//
// Tokens are read fresh on every call and never written anywhere but here.

module;

#include <libsecret/secret.h>

#include <QByteArray>
#include <QString>

export module slack.keyring;

namespace {

// One schema for everything this plugin stores, matching the attributes the
// shell version used (service/account) so an existing keyring keeps working.
const SecretSchema* schema() {
    static const SecretSchema s = {
        "org.noctalia.slack",
        SECRET_SCHEMA_DONT_MATCH_NAME,
        {
            {"service", SECRET_SCHEMA_ATTRIBUTE_STRING},
            {"account", SECRET_SCHEMA_ATTRIBUTE_STRING},
            {nullptr, SECRET_SCHEMA_ATTRIBUTE_STRING},
        },
        0, 0, 0, 0, 0, 0, 0, 0,
    };
    return &s;
}

constexpr const char* kService = "slack-agents";

}  // namespace

export namespace slack::keyring {

// The account names in use. Kept as constants because a typo in one of these
// silently reads an empty token and looks like "not signed in".
inline constexpr const char* kUserToken = "user-token";
inline constexpr const char* kBotToken = "bot-token";
inline constexpr const char* kUserRefreshToken = "user-refresh-token";
inline constexpr const char* kClientId = "client-id";
inline constexpr const char* kClientSecret = "client-secret";

// Empty when absent, when the keyring is locked, or when there is no secret
// service running at all. Every caller treats those the same way, so the
// distinction is not worth surfacing.
QString lookup(const char* account) {
    GError* error = nullptr;
    gchar* value = secret_password_lookup_sync(schema(), nullptr, &error,
                                               "service", kService,
                                               "account", account,
                                               nullptr);
    if (error != nullptr) {
        g_error_free(error);
        return {};
    }
    if (value == nullptr)
        return {};
    const QString out = QString::fromUtf8(value);
    // The library wipes the page before freeing it; the QString copy above is
    // ours to worry about, and it lives as long as the process does anyway.
    secret_password_free(value);
    return out;
}

bool store(const char* account, const QString& label, const QString& value) {
    GError* error = nullptr;
    const gboolean ok = secret_password_store_sync(
        schema(), SECRET_COLLECTION_DEFAULT, label.toUtf8().constData(),
        value.toUtf8().constData(), nullptr, &error,
        "service", kService,
        "account", account,
        nullptr);
    if (error != nullptr) {
        g_error_free(error);
        return false;
    }
    return ok != FALSE;
}

}  // namespace slack::keyring
