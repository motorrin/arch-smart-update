<div align="center">
  <img src="https://github.com/user-attachments/assets/a4c7914d-a5c0-4834-86a7-b05aacde33d4" width="15%" />

![Bash](https://img.shields.io/badge/Language-Bash-4EAA25?style=for-the-badge&logo=gnu-bash)
![CachyOS](https://img.shields.io/badge/OS-CachyOS-008B8B?style=for-the-badge&logo=linux&logoColor=white)
![EndeavourOS](https://img.shields.io/badge/OS-EndeavourOS-7F3F98?style=for-the-badge&logo=endeavouros&logoColor=white)
![Arch Linux](https://img.shields.io/badge/OS-Arch_Linux-1793D1?style=for-the-badge&logo=arch-linux)
![License](https://img.shields.io/badge/License-MIT-blue?style=for-the-badge)

<br>

**[Skip to Installation](#installation)**

</div>

**arch-smart-update** is a bash wrapper designed to safeguard system updates on vanilla **Arch Linux** and its derivatives. Instead of updating blindly, it gives you complete control over the upgrade process by presenting **package build dates**, **package descriptions**, official **Arch news** alerts, and stability recommendations from an intelligent **Update Advisor** — enabling you to make an informed decision before delegating the actual transactions directly to **pacman**, an **AUR helper**, or **topgrade**.

The script also supports distribution-specific utilities on **EndeavourOS** (such as `eos-update`) and **CachyOS** (such as `arch-update`), while remaining fully compatible with any other Arch-based system.

⚠️ **IMPORTANT DISCLAIMER:** The update recommendations provided by the Advisor are helpful guidelines, not absolute rules. As an Arch Linux user, **you are the system administrator** and hold ultimate responsibility for your machine. Always review the update list and use your own judgment before pressing "Y". The author is not responsible for any broken systems, unbootable kernels, or data loss!

---

![01](https://github.com/user-attachments/assets/6e7902f7-1f66-40b8-89ed-e036a1def653)
![02](https://github.com/user-attachments/assets/bd4fb48c-20cc-4f84-886f-4685b1a0a9fc)

---

## Daemon preview (optional, can be activated on first launch)

![03](https://github.com/user-attachments/assets/a4c8fbbb-3195-4ece-9bab-d82b6e56fea4)

---

## ✨ Why You Need This Script (Key Features)

- **⚡ Safe RAM-Based Sync (`/tmp`):** The script never touches your live local pacman database during the checking phase. All database syncing and calculations are done in an isolated temporary directory in your RAM (`/tmp/checkupdates-db...`). This 100% prevents catastrophic "partial upgrade" scenarios if you decide to cancel the update.
- **🧠 Smart Update Advisor:** Automatically analyzes the criticality of pending packages. If a system-crashing update (like the Linux kernel, `glibc`, or NVIDIA drivers) was released less than 24 hours ago, the script strongly advises you to wait, ensuring upstream stability before you apply it.
- **📰 Arch News Integration (RSS):** Fetches the latest official Arch Linux news feed. If there’s a recent post requiring manual intervention, you'll get a bright warning before you press "Y". 
- **🛡️ Automated Pacman DB Backups:** Automatically creates a `.tar.zst` backup (using fast Zstandard compression) of your `/var/lib/pacman/local` database before applying any changes. It keeps the last 5 copies so you can always roll back seamlessly.
- **🚀 Smart Mirror Management:** Monitors your mirrorlist age and sync speeds. If mirrors are older than 7 days or time out, it detects the instability and offers to automatically refresh them via `reflector`, `eos-rankmirrors`, or `cachyos-rate-mirrors`.
- **📊 Rich CLI Analytics:** Displays a beautifully formatted, color-coded terminal table showing update types (MAJOR, MINOR, PATCH, CALVER, EPOCH), package age in hours, download sizes, repositories, and descriptions.
- **🔒 Intelligent Lock File Removal:** Detects a stale `/var/lib/pacman/db.lck` file and checks if a package manager is actually running. It uses `fuser` if available, or natively extracts the lock PID and scans the process table (`pgrep` / `/proc`) as a fallback to safely remove phantom locks.
- **🚨 IgnorePkg Conflict Checker:** If you have frozen packages via `pacman.conf`, the script simulates the update in the background and warns you of any dependency breakages caused by skipped packages.
- **🧹 Automated System Cleanup:** Optional post-update cleanup that safely removes orphaned packages, clears partial downloads, empties the pacman/AUR cache, vacuums the systemd journal (keeping 100M), and clears user thumbnail caches.
- **🧩 Seamless Ecosystem Integration:** Full, native support for AUR helpers (`yay`, `paru`), as well as synergy with `eos-update` and `topgrade` to handle your Flatpaks, firmwares, and dotfiles.
- **👻 Background Daemon & Notifications:** You can allow the script to run in the background using a user systemd timer. It silently checks for updates using `fakeroot` (no sudo required) and sends interactive desktop notifications via `libnotify`. Features a smart 3-notification limit for Arch News to prevent spam.

---

## ⚙️ Package Categorization & Threat Levels

The script recognizes hundreds of packages (from DEs to base system components) and categorizes them into four threat levels, calculating a safe "cooldown" period:

- **☢️ NUKE (System Core):** `glibc`, `linux`, `nvidia`, `systemd`, `grub`, `cryptsetup`.
  > *Recommendation:* Wait **24 hours**.
- **❗ CRIT & DEs (Crucial Services & Desktop Environments):** `mesa`, `wayland`, `dbus`, `KDE Plasma`, `GNOME`, `Hyprland`, etc.
  > *Recommendation:* Wait **12 hours**.
- **⭐ FEAT (General Features & Utilities):** Audio/Network stacks, Frameworks, EOS apps.
  > *Recommendation:* Wait **6 hours**.
- **📦 Standard Packages & AUR:**
  > *Recommendation:* Wait **3 hours**.
- **💡 Customizing the lists:** You don't have to wait for an update to add your specific apps to these categories! You can easily append your own packages to the NUKE, CRIT, or FEAT lists using the settings.conf file, and your changes will survive all future script updates.

---

## 📁 Configuration & Customization

On its first run, the script creates a configuration folder at `~/.config/arch-smart-update/`, downloads the latest default templates from GitHub, and helps you set up standard features. Whenever you launch the script manually, it will display the exact path to your active configuration file at the very top.

To ensure your personal settings are never overwritten by script updates, the configuration is split into two types:

**1. Developer Managed (Auto-updating via GitHub):**
- `packages.conf` — The master list of categorized packages.
- `*.default.conf` — Templates showing the latest recommended syntax.

**2. User Managed (Safe from overwrites):**
- `settings.conf` — Your master configuration file. Here you can configure:
  - **General Settings:** `PROMPT_MIRROR_REFRESH`, `MAX_BACKUP_COPIES`, `AUR_HELPER_OVERRIDE`, `ENABLE_POST_CLEANUP`.
  - **Daemon & Logging:** Configure `ENABLE_BACKGROUND_CHECK`, systemd timer intervals, and `GENERATE_LOGS`.
  - **Overrides:** Define a `CUSTOM_REFLECTOR_CMD` or define `CUSTOM_CMDS` (e.g., `flatpak update -y`) to run instead of the standard utilities.
  - **User Packages:** Add your own apps to the arrays (e.g., `USER_CRITICAL_PKGS=("my-important-app")`) to integrate them into the Advisor's threat levels.

Whenever the master configuration on GitHub is updated, the script will quietly pull the changes without touching your custom files. If new features or options are introduced to `settings.default.conf` that are missing in your active `settings.conf`, the script will display a notice. You can safely merge and align your active configuration to adopt these new options (while fully preserving all your custom settings, user packages, and custom update commands) by running the script with the --reconfigure flag.

## 📋 Dependencies

The script relies on standard system utilities, but make sure you have the following packages installed:

`sudo pacman -S curl python bash tar gawk coreutils zstd grep sed`

*(Note: The python package provides python3 for the Arch News RSS check, zstd is required for accelerated local database backups, and util-linux provides the script utility used for interactive terminal emulation).*

**Optional Dependencies:**
- `base-devel` (specifically `fakeroot`) — Required for the background daemon to sync databases without sudo privileges.
- `libnotify` — Required for desktop notifications in daemon mode.
- `psmisc` — Provides the `fuser` utility for standard lock file analysis (though the script features a native fallback if missing).

<a name="installation"></a>
## 🛠️ Installation

## Option 1: Install from AUR (Recommended)
The script is officially available in the Arch User Repository. You can install it using your favorite AUR helper:

For yay:  
`yay -S arch-smart-update`  
For paru:  
`paru -S arch-smart-update`

## Option 2: Manual Installation
If you choose to install the script manually, keep in mind that you will also have to manually download new versions to ensure stability:

1. `cd ~`  
2. `curl -O https://raw.githubusercontent.com/motorrin/arch-smart-update/main/arch-smart-update.sh`  
3. `chmod +x arch-smart-update.sh`

## ❓ How do I use this script?

If you installed via AUR, the command is globally available as:  
`arch-smart-update`

If you installed Manually, the command is:  
`~/arch-smart-update.sh`

## ⌨️ Why write so many letters? Create an alias!

### 1. Check which shell you are using:
`echo $SHELL`

### 2. Open your configuration file:
For bash:  
`nano ~/.bashrc`  
For zsh:  
`nano ~/.zshrc`  
For fish:  
`nano ~/.config/fish/config.fish`

### 3. Add the alias to the very end of the file:

If you installed via AUR:  
`alias up="arch-smart-update"`

If you installed Manually:  
`alias up="$HOME/arch-smart-update.sh"`

### 4. Apply the changes immediately:

For bash:  
`source ~/.bashrc`  
For zsh:  
`source ~/.zshrc`  
For fish:  
`source ~/.config/fish/config.fish`

## 🗑️ Uninstalling the script

### 1. Make sure the background process is not running:

`systemctl --user disable --now arch-smart-update.timer`

### 2. Remove the script (run one depending on your installation method):

AUR:  
`sudo pacman -Rns arch-smart-update`

Manual *(if you downloaded it to a different folder, change the path accordingly)*:  
`rm ~/arch-smart-update.sh`

### 3. Remove configuration files, logs, news cache, and icon:

`rm -rf ~/.config/arch-smart-update`

### 4. Remove generated systemd files:

`rm -f ~/.config/systemd/user/arch-smart-update.service`  
`rm -f ~/.config/systemd/user/arch-smart-update.timer`  
`systemctl --user daemon-reload`

### 5. Delete Pacman database backups:

`sudo rm -f /var/lib/pacman/backup/pacman_database_*.tar.zst`
`sudo rm -f /var/lib/pacman/backup/pacman_database_*.tar.gz`

### 6. Clear AUR helper build cache (if installed via AUR):

`rm -rf ~/.cache/yay/arch-smart-update`

`rm -rf ~/.cache/paru/clone/arch-smart-update`
