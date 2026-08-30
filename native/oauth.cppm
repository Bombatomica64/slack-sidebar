// SPDX-License-Identifier: MIT
//
// Slack OAuth2 sign-in with a real local callback.
//
// The whole authorization code flow without anyone copying a code by hand: a
// loopback listener on the app's registered redirect URL, the browser opened at
// Slack's consent page, the callback received here, the code exchanged, and the
// resulting tokens put in the keyring.
//
// Two things are forced on us rather than chosen. Slack classifies a loopback
// redirect as a non-web URI and demands PKCE (RFC 7636) for it, so the
// challenge/verifier pair is mandatory. And Slack requires https for registered
// redirect URLs, so the listener has to speak TLS - hence a self-signed
// certificate, generated once into the cache directory, which the browser warns
// about the first time. That warning is expected: the certificate never leaves
// this machine.

module;

#include <openssl/bn.h>
#include <openssl/evp.h>
#include <openssl/pem.h>
#include <openssl/rsa.h>
#include <openssl/x509.h>
#include <openssl/x509v3.h>

#include <QByteArray>
#include <QEventLoop>
#include <QFile>
#include <QJsonObject>
#include <QList>
#include <QProcess>
#include <QRandomGenerator>
#include <QSslCertificate>
#include <QSslConfiguration>
#include <QSslKey>
#include <QSslSocket>
#include <QString>
#include <QStringList>
#include <QTcpServer>
#include <QTimer>
#include <QUrl>
#include <QUrlQuery>

#include <cstdio>
#include <utility>

export module slack.oauth;

import slack.util;
import slack.keyring;
import slack.net;

namespace u = slack::util;

namespace {

// What the sidebar actually needs. Kept in one place because a scope missing
// here shows up much later as a confusing missing_scope from one subcommand.
const QStringList& userScopes() {
    static const QStringList scopes{
        u::qs("channels:history"), u::qs("channels:read"), u::qs("channels:write"),
        u::qs("groups:history"), u::qs("groups:read"), u::qs("groups:write"),
        u::qs("im:history"), u::qs("im:read"), u::qs("im:write"),
        u::qs("mpim:history"), u::qs("mpim:read"), u::qs("mpim:write"),
        u::qs("users:read"), u::qs("chat:write"), u::qs("reactions:write"),
        u::qs("search:read"), u::qs("emoji:read")};
    return scopes;
}

QByteArray page(const char* heading, const char* detail) {
    return QByteArrayLiteral(
               "<!doctype html><html><head><meta charset=\"utf-8\">"
               "<title>Slack</title></head>"
               "<body style=\"font-family:system-ui;background:#11112d;color:#f3edf7;"
               "display:flex;align-items:center;justify-content:center;height:100vh;margin:0\">"
               "<div style=\"text-align:center\"><h2 style=\"margin:0 0 .4em\">") +
           heading + QByteArrayLiteral("</h2><p style=\"opacity:.7;margin:0\">") + detail +
           QByteArrayLiteral("</p></div></body></html>");
}

// URL-safe base64 without padding, which is what RFC 7636 asks for.
QString base64Url(const QByteArray& bytes) {
    return QString::fromLatin1(bytes.toBase64(QByteArray::Base64UrlEncoding | QByteArray::OmitTrailingEquals));
}

QByteArray randomBytes(int count) {
    QByteArray out(count, '\0');
    QRandomGenerator::system()->generate(out.begin(), out.end());
    return out;
}

// Generate the loopback certificate once. Written with the OpenSSL API rather
// than by shelling out to the openssl binary: Qt already links OpenSSL, so this
// removes a runtime dependency rather than adding one.
bool writeSelfSignedCert(const QString& certPath, const QString& keyPath) {
    EVP_PKEY* key = EVP_RSA_gen(2048);
    if (key == nullptr)
        return false;

    X509* cert = X509_new();
    bool ok = cert != nullptr;
    if (ok) {
        ASN1_INTEGER_set(X509_get_serialNumber(cert), 1);
        X509_gmtime_adj(X509_getm_notBefore(cert), 0);
        // Ten years: this is a local artefact whose expiry would only ever be a
        // confusing failure on a machine nobody has touched in a decade.
        X509_gmtime_adj(X509_getm_notAfter(cert), 60L * 60 * 24 * 3650);
        ok = X509_set_pubkey(cert, key) == 1;
    }
    if (ok) {
        X509_NAME* name = X509_get_subject_name(cert);
        X509_NAME_add_entry_by_txt(name, "CN", MBSTRING_ASC,
                                   reinterpret_cast<const unsigned char*>("localhost"), -1, -1, 0);
        ok = X509_set_issuer_name(cert, name) == 1;
    }
    if (ok) {
        // Browsers ignore the CN and want the name in a SAN.
        X509V3_CTX context;
        X509V3_set_ctx_nodb(&context);
        X509V3_set_ctx(&context, cert, cert, nullptr, nullptr, 0);
        X509_EXTENSION* san = X509V3_EXT_conf_nid(nullptr, &context, NID_subject_alt_name,
                                                  "DNS:localhost,IP:127.0.0.1");
        if (san != nullptr) {
            X509_add_ext(cert, san, -1);
            X509_EXTENSION_free(san);
        }
        ok = X509_sign(cert, key, EVP_sha256()) > 0;
    }

    if (ok) {
        FILE* certFile = std::fopen(certPath.toLocal8Bit().constData(), "wb");
        ok = certFile != nullptr && PEM_write_X509(certFile, cert) == 1;
        if (certFile != nullptr)
            std::fclose(certFile);
    }
    if (ok) {
        FILE* keyFile = std::fopen(keyPath.toLocal8Bit().constData(), "wb");
        ok = keyFile != nullptr &&
             PEM_write_PrivateKey(keyFile, key, nullptr, nullptr, 0, nullptr, nullptr) == 1;
        if (keyFile != nullptr)
            std::fclose(keyFile);
    }

    if (cert != nullptr)
        X509_free(cert);
    EVP_PKEY_free(key);

    // The private key of a listener that receives an authorization code.
    QFile::setPermissions(keyPath, QFileDevice::ReadOwner | QFileDevice::WriteOwner);
    return ok;
}

// A QTcpServer that hands out TLS sockets. Subclassing overrides a virtual,
// which needs no moc - the whole reason this binary builds without one.
class LoopbackServer : public QTcpServer {
public:
    LoopbackServer(QSslConfiguration config, bool useTls)
        : config_(std::move(config)), useTls_(useTls) {}

    // Filled in by the first callback that carries a code or an error.
    QString code;
    QString state;
    QString error;
    bool done = false;

    std::function<void()> onDone;

protected:
    void incomingConnection(qintptr descriptor) override {
        auto* socket = new QSslSocket(this);
        if (!socket->setSocketDescriptor(descriptor)) {
            socket->deleteLater();
            return;
        }
        QObject::connect(socket, &QSslSocket::readyRead, socket, [this, socket] { read(socket); });
        QObject::connect(socket, &QSslSocket::disconnected, socket, &QObject::deleteLater);
        if (useTls_) {
            socket->setSslConfiguration(config_);
            // A self-signed certificate is exactly what we served; the browser
            // decides whether to trust it, we do not need to verify ourselves.
            QObject::connect(socket, &QSslSocket::sslErrors, socket,
                             [socket](const QList<QSslError>&) { socket->ignoreSslErrors(); });
            socket->startServerEncryption();
        }
    }

private:
    void read(QSslSocket* socket) {
        buffer_ += socket->readAll();
        // Only the request line matters, and it arrives in the first packet of
        // any request a browser makes.
        const qsizetype endOfLine = buffer_.indexOf('\n');
        if (endOfLine < 0)
            return;
        const QByteArray line = buffer_.left(endOfLine).trimmed();
        buffer_.clear();

        const QList<QByteArray> parts = line.split(' ');
        const QUrlQuery query(parts.size() >= 2 ? QUrl(QString::fromUtf8(parts[1])).query() : QString());
        const QString gotCode = query.queryItemValue(u::qs("code"));
        const QString gotError = query.queryItemValue(u::qs("error"));

        if (gotCode.isEmpty() && gotError.isEmpty()) {
            // A favicon request or a stray probe must not end the wait.
            respond(socket, 404, QByteArrayLiteral("not found"));
            return;
        }

        code = gotCode;
        state = query.queryItemValue(u::qs("state"));
        error = gotError;
        respond(socket, 200,
                gotCode.isEmpty()
                    ? page("Sign-in failed", "Check the sidebar for the reason.")
                    : page("Connected", "You can close this tab and go back to the sidebar."));
        if (!done) {
            done = true;
            if (onDone)
                onDone();
        }
    }

    static void respond(QSslSocket* socket, int status, const QByteArray& body) {
        const QByteArray head = "HTTP/1.1 " + QByteArray::number(status) +
                                (status == 200 ? " OK" : " Not Found") +
                                "\r\nContent-Type: text/html; charset=utf-8"
                                "\r\nContent-Length: " +
                                QByteArray::number(body.size()) + "\r\nConnection: close\r\n\r\n";
        socket->write(head);
        socket->write(body);
        socket->flush();
        socket->disconnectFromHost();
    }

    QSslConfiguration config_;
    bool useTls_;
    QByteArray buffer_;
};

}  // namespace

export namespace slack::oauth {

// Runs the whole flow and returns the object to print. Never throws; every
// failure path is an {ok:false} object with something actionable in it.
QJsonObject signIn(const QString& redirect, int timeoutSeconds) {
    const QString clientId = keyring::lookup(keyring::kClientId);
    const QString clientSecret = keyring::lookup(keyring::kClientSecret);
    if (clientId.isEmpty() || clientSecret.isEmpty()) {
        return {{"ok", false},
                {"error", u::qs("no app credentials stored - add the Client ID and Client Secret "
                                "in the plugin settings first (Basic Information -> App "
                                "Credentials in Slack)")}};
    }

    const QUrl parsed(redirect);
    const QString host = parsed.host();
    if (host != u::qs("localhost") && host != u::qs("127.0.0.1")) {
        return {{"ok", false},
                {"error", u::qs("the redirect must point at localhost so the plugin can receive "
                                "the callback itself; ") +
                              redirect + u::qs(" cannot be listened on")}};
    }
    const bool useTls = parsed.scheme() == u::qs("https");
    const int port = parsed.port(useTls ? 443 : 80);

    // PKCE. The verifier never leaves this process until the exchange; only its
    // SHA-256 goes to Slack in the authorize URL.
    const QString verifier = base64Url(randomBytes(48));
    const QString challenge =
        base64Url(QCryptographicHash::hash(verifier.toUtf8(), QCryptographicHash::Sha256));
    const QString state = base64Url(randomBytes(24));

    QSslConfiguration config = QSslConfiguration::defaultConfiguration();
    if (useTls) {
        u::ensureDir(u::cacheDir());
        const QString certPath = u::cacheDir() + u::qs("/loopback-cert.pem");
        const QString keyPath = u::cacheDir() + u::qs("/loopback-key.pem");
        if (!QFile::exists(certPath) || !QFile::exists(keyPath)) {
            if (!writeSelfSignedCert(certPath, keyPath)) {
                return {{"ok", false},
                        {"error", u::qs("could not create a certificate for the local callback")}};
            }
        }
        QFile certFile(certPath);
        QFile keyFile(keyPath);
        if (!certFile.open(QIODevice::ReadOnly) || !keyFile.open(QIODevice::ReadOnly))
            return {{"ok", false}, {"error", u::qs("could not read the local callback certificate")}};
        config.setLocalCertificate(QSslCertificate(certFile.readAll(), QSsl::Pem));
        config.setPrivateKey(QSslKey(keyFile.readAll(), QSsl::Rsa, QSsl::Pem));
    }

    LoopbackServer server(config, useTls);
    if (!server.listen(QHostAddress(u::qs("127.0.0.1")), static_cast<quint16>(port))) {
        return {{"ok", false},
                {"error", u::qs("cannot listen on ") + redirect + u::qs(": ") + server.errorString()}};
    }

    QUrlQuery authorizeQuery;
    authorizeQuery.addQueryItem(u::qs("client_id"), clientId);
    authorizeQuery.addQueryItem(u::qs("user_scope"), userScopes().join(','));
    authorizeQuery.addQueryItem(u::qs("redirect_uri"), redirect);
    authorizeQuery.addQueryItem(u::qs("state"), state);
    authorizeQuery.addQueryItem(u::qs("code_challenge"), challenge);
    authorizeQuery.addQueryItem(u::qs("code_challenge_method"), u::qs("S256"));
    QUrl authorize(u::qs("https://slack.com/oauth/v2/authorize"));
    authorize.setQuery(authorizeQuery);
    const QString authorizeUrl = authorize.toString();

    u::log(u::qs("listening on ") + redirect);
    if (!QProcess::startDetached(u::qs("xdg-open"), {authorizeUrl}))
        u::log(u::qs("could not open a browser; visit: ") + authorizeUrl);

    QEventLoop loop;
    QTimer deadline;
    deadline.setSingleShot(true);
    bool timedOut = false;
    QObject::connect(&deadline, &QTimer::timeout, &loop, [&] {
        timedOut = true;
        loop.quit();
    });
    server.onDone = [&loop] { loop.quit(); };
    deadline.start(timeoutSeconds * 1000);
    loop.exec();
    server.close();

    if (timedOut) {
        return {{"ok", false},
                {"error", u::qs("timed out waiting for the Slack callback")},
                {"authorizeUrl", authorizeUrl}};
    }
    if (!server.error.isEmpty())
        return {{"ok", false}, {"error", u::qs("Slack refused the authorization: ") + server.error}};
    // The state check is what stops a page you happened to have open from
    // completing somebody else's sign-in through your listener.
    if (server.state != state)
        return {{"ok", false}, {"error", u::qs("callback state did not match; the sign-in was not completed")}};

    u::log(u::qs("exchanging the code"));
    net::Client http;
    net::Request exchange;
    exchange.method = u::qs("POST");
    exchange.url = u::qs("https://slack.com/api/oauth.v2.access");
    exchange.contentType = u::qs("application/x-www-form-urlencoded; charset=utf-8");
    exchange.body = net::formEncode({{u::qs("client_id"), clientId},
                                     {u::qs("client_secret"), clientSecret},
                                     {u::qs("code"), server.code},
                                     {u::qs("code_verifier"), verifier},
                                     {u::qs("redirect_uri"), redirect}});
    const net::Response exchanged = http.request(exchange);
    if (!exchanged.transportOk())
        return {{"ok", false}, {"error", u::qs("could not reach Slack: ") + exchanged.transportError}};

    bool parsedOk = false;
    const QJsonObject response = u::parseObject(exchanged.body, &parsedOk);
    if (!parsedOk)
        return {{"ok", false}, {"error", u::qs("unreadable response from Slack")}};
    if (!u::boolean(response, "ok")) {
        return {{"ok", false},
                {"error", u::qs("token exchange failed: ") +
                              u::str(response, "error", u::qs("unknown error"))}};
    }

    const QJsonObject authed = u::object(response, "authed_user");
    const QString token = u::str(authed, "access_token", u::str(response, "access_token"));
    const QString refresh = u::str(authed, "refresh_token", u::str(response, "refresh_token"));
    const int expires = authed.value(u::qs("expires_in")).toInt(response.value(u::qs("expires_in")).toInt());
    if (token.isEmpty())
        return {{"ok", false}, {"error", u::qs("Slack returned no user token; the app must request user scopes")}};

    // Verify before storing: a token that cannot answer auth.test would leave
    // the sidebar looking signed in and doing nothing.
    net::Request check;
    check.url = u::qs("https://slack.com/api/auth.test");
    check.headers.append({QByteArrayLiteral("Authorization"), ("Bearer " + token).toUtf8()});
    const net::Response checked = http.request(check);
    const QJsonObject who = u::parseObject(checked.body);
    if (!u::boolean(who, "ok")) {
        return {{"ok", false},
                {"error", u::qs("the new token failed auth.test: ") +
                              u::str(who, "error", u::qs("unknown"))}};
    }

    keyring::store(keyring::kUserToken, u::qs("Slack User Token"), token);
    if (!refresh.isEmpty())
        keyring::store(keyring::kUserRefreshToken, u::qs("Slack User Refresh Token"), refresh);

    return {{"ok", true},
            {"user", u::str(who, "user")},
            {"userId", u::str(who, "user_id")},
            {"team", u::str(who, "team")},
            {"rotating", token.startsWith(u::qs("xoxe."))},
            {"refreshStored", !refresh.isEmpty()},
            {"expiresIn", expires},
            {"scopes", u::str(authed, "scope")}};
}

}  // namespace slack::oauth
