# Maintainer: andrea marano <andrea.marano.2003@gmail.com>
pkgname=omastart
pkgver=0.1.0
pkgrel=1
pkgdesc="Dead-simple startup package and service manager for Omarchy and Hyprland"
arch=('any')
url="https://github.com/vw5tywrl/omastart"
license=('MIT')
depends=('python' 'quickshell' 'hicolor-icon-theme')
optdepends=(
    'systemd: service inspection and log viewer'
    'hyprland: autostart.conf management'
)
source=("$pkgname-$pkgver.tar.gz::$url/archive/refs/tags/v$pkgver.tar.gz")
sha256sums=('9fe0e58b91d1c6c1f9ce6c8731cfde0531de275b15a617dee9043fc1de40ec80')

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
