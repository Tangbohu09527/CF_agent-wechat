#include <QCoreApplication>
#include <QCryptographicHash>
#include <QFile>
#include <QFileInfo>
#include <QUrl>
#include <iostream>

int main(int argc, char **argv) {
    QCoreApplication app(argc, argv);
    if (argc != 4) return 2;
    const QByteArray encoded(argv[1]);
    for (unsigned char c : encoded) if (c > 127) return 3;
    const QUrl url = QUrl::fromEncoded(encoded, QUrl::StrictMode);
    if (!url.isValid() || !url.isLocalFile() || !url.host().isEmpty()) return 4;
    if (QFileInfo(url.toLocalFile()).fileName() != QString::fromUtf8(argv[2])) return 5;
    QFile file(url.toLocalFile());
    if (!file.open(QIODevice::ReadOnly)) return 6;
    const auto digest = QCryptographicHash::hash(file.readAll(), QCryptographicHash::Sha256).toHex();
    if (digest != QByteArray(argv[3])) return 7;
    std::cout << "qt_uri_exact_basename_and_bytes=true\n";
    return 0;
}
