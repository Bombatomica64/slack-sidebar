// SPDX-License-Identifier: MIT
//
// HTTP, on Qt Network.
//
// Presented synchronously because every subcommand is a short-lived process
// that makes a few requests and prints one object; an async API would buy
// nothing and cost a callback graph. What it does keep from being async
// underneath is real concurrency: requestMany() puts every request in flight at
// once on a single thread and runs one event loop until they all land. The
// shell version forked a curl per request and waited in batches of six.

module;

#include <QByteArray>
#include <QElapsedTimer>
#include <QEventLoop>
#include <QList>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QSslConfiguration>
#include <QString>
#include <QTimer>
#include <QUrl>
#include <QUrlQuery>

#include <functional>
#include <utility>
#include <vector>

export module slack.net;

import slack.util;

export namespace slack::net {

// Slack is never slow on purpose; a request that has not answered in this long
// has hit something broken, and the caller would rather have an error than a
// hung sidebar.
inline constexpr int kDefaultTimeoutMs = 25000;

struct Request {
    QString url;
    QString method = slack::util::qs("GET");     // GET or POST
    QList<std::pair<QByteArray, QByteArray>> headers;
    QByteArray body;                            // POST only
    QString contentType;                        // POST only
    int timeoutMs = kDefaultTimeoutMs;
    int maxRedirects = 0;                       // 0 disables following
    qint64 maxBytes = 0;                        // 0 means no cap
};

struct Response {
    int status = 0;
    QByteArray body;
    QString contentType;
    QString finalUrl;
    QString transportError;                     // empty unless the request never completed

    [[nodiscard]] bool transportOk() const { return transportError.isEmpty() && status > 0; }
};

// Percent-encode a form body the way Slack's API expects. Values are the
// caller's data, including message text, so nothing here interpolates.
QByteArray formEncode(const QList<std::pair<QString, QString>>& fields) {
    QUrlQuery query;
    for (const auto& [key, value] : fields)
        query.addQueryItem(QUrl::toPercentEncoding(key), QUrl::toPercentEncoding(value));
    return query.toString(QUrl::FullyEncoded).toUtf8();
}

QString appendQuery(const QString& url, const QList<std::pair<QString, QString>>& fields) {
    if (fields.isEmpty())
        return url;
    return url + (url.contains('?') ? '&' : '?') + QString::fromUtf8(formEncode(fields));
}

class Client {
public:
    Client() {
        // Redirects are opt-in per request: the Slack API never redirects, and
        // for link previews the redirect policy is part of the security story.
        manager_.setRedirectPolicy(QNetworkRequest::ManualRedirectPolicy);
        manager_.setAutoDeleteReplies(false);
    }

    Client(const Client&) = delete;
    Client& operator=(const Client&) = delete;

    [[nodiscard]] Response request(const Request& spec) {
        std::vector<Request> one{spec};
        return std::move(requestMany(one).front());
    }

    // Every request in flight at once, one event loop, one thread.
    [[nodiscard]] std::vector<Response> requestMany(const std::vector<Request>& specs) {
        std::vector<Response> out(specs.size());
        if (specs.empty())
            return out;

        QEventLoop loop;
        std::size_t outstanding = specs.size();
        // Redirect chains restart a request, so the same slot can be filled more
        // than once; the count only drops when a slot is finished for good.
        std::vector<int> redirectsLeft(specs.size());
        for (std::size_t i = 0; i < specs.size(); ++i)
            redirectsLeft[i] = specs[i].maxRedirects;

        // Declared before use so a redirect can call it again for the same slot.
        std::function<void(std::size_t, const QString&)> start;

        start = [&](std::size_t index, const QString& url) {
            const Request& spec = specs[index];
            QNetworkRequest request{QUrl(url)};
            for (const auto& [name, value] : spec.headers)
                request.setRawHeader(name, value);
            if (!spec.contentType.isEmpty())
                request.setHeader(QNetworkRequest::ContentTypeHeader, spec.contentType);
            request.setAttribute(QNetworkRequest::RedirectPolicyAttribute,
                                 QNetworkRequest::ManualRedirectPolicy);

            QNetworkReply* reply = spec.method == slack::util::qs("POST")
                                       ? manager_.post(request, spec.body)
                                       : manager_.get(request);

            auto* timeout = new QTimer(reply);
            timeout->setSingleShot(true);
            timeout->setInterval(spec.timeoutMs);
            QObject::connect(timeout, &QTimer::timeout, reply, [reply] { reply->abort(); });
            timeout->start();

            // A capped read is how a hostile server is stopped from making this
            // process hold a gigabyte: abort as soon as the body passes the cap
            // rather than trusting Content-Length.
            if (spec.maxBytes > 0) {
                QObject::connect(reply, &QNetworkReply::downloadProgress, reply,
                                 [reply, cap = spec.maxBytes](qint64 received, qint64) {
                                     if (received > cap)
                                         reply->abort();
                                 });
            }

            QObject::connect(reply, &QNetworkReply::finished, &loop, [&, index, reply] {
                Response& response = out[index];
                response.status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
                response.contentType = reply->header(QNetworkRequest::ContentTypeHeader).toString();
                response.finalUrl = reply->url().toString();

                const QUrl redirect = reply->attribute(QNetworkRequest::RedirectionTargetAttribute).toUrl();
                if (!redirect.isEmpty() && redirectsLeft[index] > 0) {
                    const QUrl next = reply->url().resolved(redirect);
                    --redirectsLeft[index];
                    reply->deleteLater();
                    // Only ever http(s), even mid-chain: a redirect to file:// or
                    // to a custom scheme is how an open fetcher gets abused.
                    if (next.scheme() == QLatin1String("http") || next.scheme() == QLatin1String("https")) {
                        start(index, next.toString());
                        return;
                    }
                    response.transportError = slack::util::qs("redirect to a non-http scheme");
                    if (--outstanding == 0)
                        loop.quit();
                    return;
                }

                if (reply->error() != QNetworkReply::NoError && response.status == 0)
                    response.transportError = reply->errorString();
                response.body = reply->readAll();
                if (spec.maxBytes > 0 && response.body.size() > spec.maxBytes)
                    response.body.truncate(static_cast<int>(spec.maxBytes));
                reply->deleteLater();
                if (--outstanding == 0)
                    loop.quit();
            });
        };

        for (std::size_t i = 0; i < specs.size(); ++i)
            start(i, specs[i].url);

        loop.exec();
        return out;
    }

private:
    QNetworkAccessManager manager_;
};

}  // namespace slack::net
