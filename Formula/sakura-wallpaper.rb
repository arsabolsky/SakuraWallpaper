class SakuraWallpaper < Formula
  desc "Video & image wallpaper manager for macOS"
  homepage "https://github.com/yueseqaz/SakuraWallpaper"
  url "https://github.com/yueseqaz/SakuraWallpaper/releases/download/v1.0.0/SakuraWallpaper.dmg"
  version "1.0.0"
  sha256 "8ae24dfc42432fd586887e348961e907b6d70d99e3a657e2c1a98d7fd62e6502"

  bottle :unneeded

  def install
    prefix.install "SakuraWallpaper.app"
  end

  def post_install
    (bin/"sakura-wallpaper").write <<~EOS
      #!/bin/bash
      open "#{prefix}/SakuraWallpaper.app"
    EOS
    chmod bin/"sakura-wallpaper"
  end
end
