#
# ~/.bashrc
#

# If not running interactively, don't do anything
[[ $- != *i* ]] && return

# Craft the prompt.
[ 'id -u' = '0' ] && PS1='$\e[0;31m$HOSTNAME$\e[0;34m [\w] #\e[0m'||
PS1='\e[0;32m\u@\h\e[0;34m [\w] $\e[0m '
PS1=${PS1}'\n$ '

#[ 'id -u' = '0' ] && PS1='[$PWD] # > ' || PS1='[$PWD] $ > '
#PS2='> '
#export PS1 PS2

# General env vars.
export HISTSIZE=2000

export TZ="America/Sao_Paulo"

# Aliases to soft-replace GNU coreutils with uutils.
#for coreutils_util in /usr/bin/uu-*; do
#	alias "$(echo $coreutils_util | cut -d '-' -f2)"="$coreutils_util"
#done

# Other aliases.
alias ls='exa --color-scale --sort=type --group-directories-first'
alias sudo='doas'
alias sudoedit='doas rnano'
alias nvim='helix'
alias nano='helix'
alias code='helix'
alias svm='systemctl --user start firecracker@main && until ssh -o ConnectTimeout=1 -o BatchMode=yes work@172.16.0.2 true 2>/dev/null; do sleep 1; done && ssh work@172.16.0.2' # start_vm
alias dvm='systemctl --user stop firecracker@main' # stop_vm
alias btt='doas /usr/local/bin/bt-toggle'
alias tusb='doas /usr/local/bin/usb-temp'
alias btgb='bluetoothctl power on && sleep 3 && bluetoothctl connect 5C:5E:0A:53:0B:81 && exit' # Galaxy Buds Core
alias bted='bluetoothctl power on && sleep 3 && bluetoothctl connect 08:F0:B6:68:83:91 && exit' # EDIFIER W820NB Plus

# Start desktop environment.
if [ -z $DISPLAY ] && [ "$(tty)" = "/dev/tty1" ]; then
  if command -v sway >/dev/null 2>&1; then
    bash ~/.config/sway/lock.sh &
    exec sway
  elif command -v river >/dev/null 2>&1; then
    bash ~/.config/sway/lock.sh &
    exec river -no-xwayland -c '"$(cat ~/.config/river/init)"'
  else
    bash ~/.config/lock.sh &
    exec /usr/lib/plasma-dbus-run-session-if-needed startplasma-wayland
  fi
fi

# Mute all microphones using pactl
if [[ $USER != "work" ]]; then
  pactl list short sources | while read source; do
    source_id=$(echo $source | cut '-d ' -f1)
    pactl set-source-volume $source_id 0%
  done
fi

