#!/bin/sh
set -eu

install_error() {
    printf 'envy installer: %s\n' "$1" >&2
    exit 1
}

install_confirm() (
    # stdin may contain the installer itself; only the terminal owns answers.
    exec 3<> /dev/tty
    printf 'Install age with %s? [y/N]: ' "$1" >&3
    IFS= read -r install_answer <&3 || exit 1
    case $install_answer in y|Y|yes|YES) exit 0 ;; *) exit 1 ;; esac
)

install_age() {
    if command -v age > /dev/null 2>&1 && command -v age-keygen > /dev/null 2>&1; then
        return
    fi
    if command -v brew > /dev/null 2>&1; then
        install_manager=brew
    elif command -v apt-get > /dev/null 2>&1; then
        install_manager=apt-get
    else
        install_error 'install age and age-keygen manually, then re-run this installer (brew install age or sudo apt-get install age)'
    fi
    if [ "$install_yes" != yes ] && ! install_confirm "$install_manager" 2> /dev/null; then
        install_error 'age installation declined or no terminal available; install age and age-keygen manually, then re-run (brew install age or sudo apt-get install age); use --yes to skip confirmation'
    fi
    case $install_manager in
        brew) brew install age < /dev/null || install_error 'could not install age with brew' ;;
        apt-get)
            if [ "$(id -u)" = 0 ]; then
                if ! { apt-get update < /dev/null && apt-get install -y age < /dev/null; }; then
                    install_error 'could not install age with apt-get'
                fi
            elif command -v sudo > /dev/null 2>&1; then
                # sudo reads its password from the terminal, not the script pipe.
                if ! { sudo apt-get update < /dev/null && sudo apt-get install -y age < /dev/null; }; then
                    install_error 'could not install age with apt-get'
                fi
            else
                install_error 'apt-get requires root or sudo; install age manually, then re-run'
            fi
            ;;
    esac
    if ! command -v age > /dev/null 2>&1 || ! command -v age-keygen > /dev/null 2>&1; then
        install_error 'package installation did not provide age and age-keygen'
    fi
}

install_hook() (
    install_rc=$1
    if [ -e "$install_rc" ] || [ -L "$install_rc" ]; then
        [ -f "$install_rc" ] || install_error 'shell startup file is not a regular file'
        # A damaged block must not result in two competing hook registrations.
        install_markers=$(awk '
            $0 == "# >>> envy >>>" { starts++; start = NR }
            $0 == "# <<< envy <<<" { ends++; end = NR }
            END {
                if (!starts && !ends) print "absent"
                else if (starts == 1 && ends == 1 && start < end) print "present"
                else print "invalid"
            }' "$install_rc") || install_error 'cannot inspect shell startup file'
        case $install_markers in
            present) return ;;
            invalid) install_error 'damaged envy startup block; remove it and re-run the installer' ;;
        esac
    fi
    # Begin with a newline so an existing final line need not end with one.
    cat >> "$install_rc" <<'HOOK' || install_error 'cannot write shell startup file'

# >>> envy >>>
case ":$PATH:" in
    *":$HOME/.local/bin:"*) ;;
    *) PATH="$HOME/.local/bin:$PATH" ;;
esac
export PATH
eval "$(command envy hook)"
# <<< envy <<<
HOOK
)

install_yes=no
install_url=
while [ "$#" -gt 0 ]; do
    case $1 in
        --yes) install_yes=yes ;;
        --help|-h)
            printf '%s\n' 'Usage: install.sh [--yes] [<store-url>]' \
                'ENVY_INSTALL_SOURCE overrides the envy download URL with a URL or local file.'
            exit 0
            ;;
        --)
            shift
            if [ "$#" -gt 1 ] || [ -n "$install_url" ]; then
                install_error 'usage: install.sh [--yes] [<store-url>]'
            fi
            install_url=${1-}
            break
            ;;
        -*) install_error 'usage: install.sh [--yes] [<store-url>]' ;;
        *)
            if [ -n "$install_url" ] || [ -z "$1" ]; then
                install_error 'usage: install.sh [--yes] [<store-url>]'
            fi
            install_url=$1
            ;;
    esac
    shift
done

[ -n "${HOME-}" ] || install_error 'HOME must be set'
command -v git > /dev/null 2>&1 || install_error 'missing dependency: git; install git and re-run'
install_age

install_dir=$HOME/.local/bin
install_source=${ENVY_INSTALL_SOURCE:-https://raw.githubusercontent.com/smrdotgg/envy/main/envy}
install_temp=
trap '[ -z "$install_temp" ] || rm -rf "$install_temp"' 0
trap 'exit 1' HUP INT TERM
mkdir -p "$install_dir" || install_error 'cannot create install directory'
install_temp=$(mktemp -d "$install_dir/.envy-install.XXXXXX") || install_error 'cannot create temporary directory'
if [ -f "$install_source" ]; then
    cp "$install_source" "$install_temp/envy" || install_error 'cannot copy envy source'
else
    command -v curl > /dev/null 2>&1 || install_error 'missing dependency: curl; install curl or set ENVY_INSTALL_SOURCE to a local file'
    curl -fsSL "$install_source" -o "$install_temp/envy" || install_error 'could not download envy'
fi
[ -s "$install_temp/envy" ] || install_error 'downloaded envy is empty'
sh -n "$install_temp/envy" || install_error 'downloaded envy failed shell syntax validation'
if [ -d "$install_dir/envy" ]; then
    install_error 'envy install path is a directory'
fi
if [ ! -x "$install_dir/envy" ] || ! cmp -s "$install_temp/envy" "$install_dir/envy"; then
    chmod 755 "$install_temp/envy"
    mv "$install_temp/envy" "$install_dir/envy" || install_error 'cannot install envy'
fi

if command -v bash > /dev/null 2>&1; then install_hook "$HOME/.bashrc"; fi
if command -v zsh > /dev/null 2>&1; then install_hook "$HOME/.zshrc"; fi

if [ -n "$install_url" ]; then
    install_store=${XDG_DATA_HOME:-$HOME/.local/share}/envy/store
    install_identity=${XDG_DATA_HOME:-$HOME/.local/share}/envy/identity
    if [ -e "$install_store" ] || [ -e "$install_identity" ]; then
        install_origin=$(git -C "$install_store" config --get remote.origin.url 2> /dev/null) ||
            install_error 'existing local state is incomplete; recover it with envy init or envy unlock'
        # Git records an absolute origin for a relative local clone. Compare
        # existing local directories by physical path, including symlink aliases.
        if [ "$install_origin" != "$install_url" ] &&
            [ -d "$install_origin" ] && [ -d "$install_url" ]; then
            install_origin=$(CDPATH='' cd -- "$install_origin" && pwd -P) ||
                install_error 'cannot resolve existing local store URL'
            install_url=$(CDPATH='' cd -- "$install_url" && pwd -P) ||
                install_error 'cannot resolve local store URL'
        fi
        [ "$install_origin" = "$install_url" ] || install_error 'machine already uses a different store URL'
        # ls validates the format and identity without decrypting or fetching.
        "$install_dir/envy" ls > /dev/null < /dev/null || exit 1
    else
        "$install_dir/envy" init "$install_url" < /dev/null
    fi
fi
printf '%s\n' 'envy installed; open a new bash or zsh shell to load the hook.'
