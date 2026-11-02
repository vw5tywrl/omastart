# Maintainer: andrea marano <andrea.marano.2003@gmail.com>
pkgname=omastart
pkgver=0.1.0
pkgrel=1
pkgdesc="Dead-simple startup package and service manager for Omarchy and Hyprland"
arch=('any')
url="https://github.com/loathe/omastart"
license=('MIT')
depends=('python' 'quickshell' 'pacman-contrib' 'hicolor-icon-theme')
optdepends=(
    'systemd: service inspection and log viewer'
    'hyprland: autostart.conf management'
)
source=("$pkgname-$pkgver.tar.gz::$url/archive/refs/tags/v$pkgver.tar.gz")
sha256sums=('SKIP')

package() {
    cd "$srcdir/$pkgname-$pkgver"

    # Install Python backend and QML UI
    install -dm755 "$pkgdir/usr/share/$pkgname"
    cp -r bin omarchy_startup qml "$pkgdir/usr/share/$pkgname/"

    # Symlink binaries to /usr/bin
    install -dm755 "$pkgdir/usr/bin"
    ln -sf "/usr/share/$pkgname/bin/omarchy-startup" "$pkgdir/usr/bin/omastart"
    ln -sf "/usr/share/$pkgname/bin/omarchy-startup" "$pkgdir/usr/bin/omarchy-startup"

    # Install desktop launcher and icon
    install -Dm644 assets/omastart.desktop "$pkgdir/usr/share/applications/omastart.desktop"
    install -Dm644 assets/omarchy-startup.svg "$pkgdir/usr/share/icons/hicolor/scalable/apps/omarchy-startup.svg"

    # Install license
    install -Dm644 LICENSE "$pkgdir/usr/share/licenses/$pkgname/LICENSE"
}
