#!/bin/sh
set -euo pipefail

if [[ $(id -u) -ge 1000 ]] && shopt -q login_shell && [[ "$(tty)" =~ ^/dev/tty[0-9] ]]; then
  find "$HOME" -mindepth 1 -maxdepth 1 \
    ! -name "Downloads" \
    ! -name ".config" \
    ! -name ".var" \
    ! -name ".azure" \
    ! -name ".kube" \
    ! -name ".identity" \
    ! -name ".identity-blob" \
    ! -name "keep" \
    -exec rm -rf {} +

  find "$HOME/.config" -mindepth 1 -maxdepth 1 \
    ! -name "chromium" \
    -exec rm -rf {} +

  find "$HOME/.config/chromium" -mindepth 1 -maxdepth 1 \
    ! -name "Default" \
    -exec rm -rf {} +

  find "$HOME/.var" -mindepth 1 -maxdepth 1 \
    ! -name "app" \
    -exec rm -rf {} +

  find "$HOME/.kube" -mindepth 1 -maxdepth 1 \
    ! -name "config" \
    -exec rm -rf {} +

  cp -r /etc/dotfiles/.* "$HOME" || echo "Error copying dotfiles."
fi