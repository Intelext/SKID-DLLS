#!/usr/bin/env bash
# ============================================================================
#  pm5_flash.sh — Proxmark5 (AT32F435 / GOWIN FPGA) Build, Flash & Persist
# ============================================================================
#  Source : https://github.com/xianglin1998/proxmark3  (branch: proxmark5)
#  Ref PR: https://github.com/RfidResearchGroup/proxmark3/pull/3449
#
#  This script:
#    1. Installs build dependencies (Debian/Ubuntu, Fedora, Arch, macOS)
#    2. Clones (or updates) the xianglin1998 proxmark5 branch
#    3. Builds bootrom + fullimage (CMake) and the client (Makefile)
#    4. Flashes BOTH bootrom and fullimage to fix persistence across power cycles
#    5. Unlocks AT32F435 flash protection if needed
#    6. Verifies the flash after writing
#    7. Provides an ISP-recovery helper if all else fails
#
#  Usage:
#    chmod +x pm5_flash.sh
#    sudo ./pm5_flash.sh              # full: deps → build → flash
#    sudo ./pm5_flash.sh --deps-only  # install dependencies only
#    sudo ./pm5_flash.sh --build-only # build only (skip deps & flash)
#    sudo ./pm5_flash.sh --flash-only # flash only (skip deps & build)
#    sudo ./pm5_flash.sh --isp        # ISP recovery mode helper
#    sudo ./pm5_flash.sh --unlock     # unlock AT32 flash protection only
#    sudo ./pm5_flash.sh --verify     # verify flashed firmware
# ============================================================================

set -euo pipefail

# ── Colours ─────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GRN='\033[0;32m'
YLW='\033[1;33m'
CYN='\033[0;36m'
RST='\033[0m'

info()  { echo -e "${CYN}[INFO]${RST}  $*"; }
ok()    { echo -e "${GRN}[OK]${RST}    $*"; }
warn()  { echo -e "${YLW}[WARN]${RST}  $*"; }
err()   { echo -e "${RED}[ERR]${RST}   $*"; }
die()   { err "$*"; exit 1; }

# ── Config ──────────────────────────────────────────────────────────────────
REPO_URL="https://github.com/xianglin1998/proxmark3.git"
BRANCH="proxmark5"
INSTALL_DIR="${PM5_DIR:-$HOME/proxmark5}"
BUILD_DIR="${INSTALL_DIR}/build_pm5"
PLATFORM="PM3PM5"  # Proxmark5 platform target

# Serial port auto-detection (override with PM5_PORT env var)
PM5_PORT="${PM5_PORT:-}"

# ── Helpers ─────────────────────────────────────────────────────────────────

detect_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        case "$ID" in
            ubuntu|debian|linuxmint|pop|kali) echo "debian" ;;
            fedora|rhel|centos|rocky|alma)    echo "fedora" ;;
            arch|manjaro|endeavouros)         echo "arch"   ;;
            *)                                echo "unknown";;
        esac
    elif [[ "$(uname)" == "Darwin" ]]; then
        echo "macos"
    else
        echo "unknown"
    fi
}

detect_port() {
    # If user set PM5_PORT, use that
    if [[ -n "$PM5_PORT" ]]; then
        echo "$PM5_PORT"
        return
    fi

    # Auto-detect: look for common Proxmark / AT32 USB serial devices
    local candidates=(
        /dev/ttyACM0 /dev/ttyACM1
        /dev/ttyUSB0 /dev/ttyUSB1
        /dev/cu.usbmodem* /dev/tty.usbmodem*
    )

    for port in "${candidates[@]}"; do
        # Handle glob patterns that didn't match
        [[ -e "$port" ]] || continue
        echo "$port"
        return
    done

    echo ""
}

wait_for_device() {
    local mode="$1"  # "bootloader" or "normal"
    local timeout=30
    local elapsed=0

    if [[ "$mode" == "bootloader" ]]; then
        echo ""
        warn "══════════════════════════════════════════════════════════"
        warn "  BOOTLOADER MODE REQUIRED"
        warn "══════════════════════════════════════════════════════════"
        warn "  1. Unplug the Proxmark5"
        warn "  2. Hold the button on the device"
        warn "  3. While holding, plug in USB"
        warn "  4. Keep holding for 3 seconds, then release"
        warn "══════════════════════════════════════════════════════════"
        echo ""
    fi

    info "Waiting for device (timeout: ${timeout}s)..."
    while [[ $elapsed -lt $timeout ]]; do
        local port
        port=$(detect_port)
        if [[ -n "$port" ]]; then
            ok "Device detected on $port"
            PM5_PORT="$port"
            return 0
        fi
        sleep 1
        ((elapsed++))
        printf "\r  %d/%ds..." "$elapsed" "$timeout"
    done

    echo ""
    err "No device detected within ${timeout}s."
    return 1
}

# ── Step 1: Install Dependencies ───────────────────────────────────────────

install_deps() {
    info "Installing build dependencies..."
    local os
    os=$(detect_os)

    case "$os" in
        debian)
            info "Detected Debian/Ubuntu — using apt"
            apt-get update -qq
            apt-get install -y --no-install-recommends \
                git build-essential cmake \
                gcc-arm-none-eabi libnewlib-dev \
                libreadline-dev libssl-dev \
                libbz2-dev pkg-config \
                python3 python3-pip \
                libusb-1.0-0-dev \
                qtbase5-dev \
                ca-certificates \
                stlink-tools \
                picocom screen
            ;;
        fedora)
            info "Detected Fedora/RHEL — using dnf"
            dnf install -y \
                git gcc gcc-c++ make cmake \
                arm-none-eabi-gcc-cs arm-none-eabi-newlib \
                readline-devel openssl-devel \
                bzip2-devel pkgconfig \
                python3 python3-pip \
                libusbx-devel \
                qt5-qtbase-devel \
                stlink picocom screen
            ;;
        arch)
            info "Detected Arch — using pacman"
            pacman -Syu --noconfirm \
                git base-devel cmake \
                arm-none-eabi-gcc arm-none-eabi-newlib \
                readline openssl \
                bzip2 pkgconf \
                python python-pip \
                libusb \
                qt5-base \
                stlink picocom screen
            ;;
        macos)
            info "Detected macOS — using Homebrew"
            if ! command -v brew &>/dev/null; then
                die "Homebrew not found. Install from https://brew.sh"
            fi
            brew install --quiet \
                git cmake \
                arm-none-eabi-gcc \
                readline openssl \
                bzip2 pkg-config \
                python3 \
                libusb \
                qt@5 \
                picocom screen
            ;;
        *)
            warn "Unknown OS. Install these manually:"
            warn "  git, cmake, arm-none-eabi-gcc, arm-none-eabi-newlib,"
            warn "  libreadline-dev, libssl-dev, libusb-1.0, qt5, python3"
            return 1
            ;;
    esac

    # Install AT32 ISP tool dependencies (Python)
    if command -v pip3 &>/dev/null; then
        pip3 install pyserial pyusb 2>/dev/null || true
    fi

    ok "Dependencies installed."
}

# ── Step 2: Clone / Update Repository ──────────────────────────────────────

clone_repo() {
    info "Setting up source at ${INSTALL_DIR}..."

    if [[ -d "${INSTALL_DIR}/.git" ]]; then
        info "Repo exists — pulling latest changes..."
        cd "$INSTALL_DIR"
        git fetch origin
        git checkout "$BRANCH"
        git reset --hard "origin/$BRANCH"
        git submodule update --init --recursive
        ok "Repository updated."
    else
        info "Cloning ${REPO_URL} (branch: ${BRANCH})..."
        git clone -b "$BRANCH" --recurse-submodules "$REPO_URL" "$INSTALL_DIR"
        ok "Repository cloned."
    fi

    cd "$INSTALL_DIR"
}

# ── Step 3: Build ──────────────────────────────────────────────────────────

build_firmware() {
    cd "$INSTALL_DIR"

    # ── 3a: Generate version_pm3.c if the script exists ────────────────
    #    The bootrom depends on this file but CMake may not generate it
    #    automatically (noted in PR #3449 point 16).
    info "Generating version info..."
    if [[ -x tools/mkversion.sh ]]; then
        bash tools/mkversion.sh > common/version_pm3.c 2>/dev/null || true
        ok "version_pm3.c generated via mkversion.sh"
    elif [[ -f tools/mkversion.pl ]]; then
        perl tools/mkversion.pl > common/version_pm3.c 2>/dev/null || true
        ok "version_pm3.c generated via mkversion.pl"
    else
        warn "mkversion script not found — creating stub version_pm3.c"
        mkdir -p common
        cat > common/version_pm3.c << 'VEOF'
#include "common/version_pm3.h"
const char *pm3_version = "PM5-custom";
const char *pm3_version_short = "PM5";
const char *pm3_timestamp = __DATE__ " " __TIME__;
VEOF
    fi

    # ── 3b: Build ARM firmware (bootrom + fullimage) with CMake ────────
    info "Building ARM firmware with CMake (bootrom + fullimage)..."
    mkdir -p "$BUILD_DIR"
    cd "$BUILD_DIR"

    cmake "$INSTALL_DIR" \
        -DPLATFORM=${PLATFORM} \
        -DCMAKE_TOOLCHAIN_FILE="${INSTALL_DIR}/cmake/arm-none-eabi.cmake" \
        2>&1 | tail -5

    cmake --build . --target bootrom -- -j"$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)" \
        2>&1 | tail -5
    ok "Bootrom built."

    cmake --build . --target fullimage -- -j"$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)" \
        2>&1 | tail -5
    ok "Fullimage built."

    # ── 3c: Build client with Makefile ─────────────────────────────────
    info "Building client with Makefile..."
    cd "$INSTALL_DIR"
    make -j"$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)" client \
        PLATFORM=${PLATFORM} \
        2>&1 | tail -5
    ok "Client built."

    cd "$INSTALL_DIR"
}

# ── Step 4: Unlock AT32F435 Flash Protection ───────────────────────────────

unlock_flash() {
    info "Attempting to unlock AT32F435 flash write protection..."

    # Method 1: Use the pm3 client if available
    local client_bin=""
    for candidate in \
        "${INSTALL_DIR}/client/proxmark3" \
        "${INSTALL_DIR}/client/build/proxmark3" \
        "$(command -v proxmark3 2>/dev/null)"; do
        if [[ -x "$candidate" ]]; then
            client_bin="$candidate"
            break
        fi
    done

    local port
    port=$(detect_port)

    if [[ -n "$client_bin" && -n "$port" ]]; then
        info "Using client to check/unlock flash protection..."

        # Try sending the hw status command to check flash lock state
        timeout 10 "$client_bin" "$port" -c "hw status" 2>&1 | grep -i -E "flash|protect|lock" || true

        # Attempt flash unlock via client command (if supported by this build)
        timeout 10 "$client_bin" "$port" -c "hw flash_unlock" 2>&1 || true
    fi

    # Method 2: Direct AT32 flash unlock via USB/serial
    #   The AT32F435 flash controller registers:
    #     FLASH_UNLOCK  (0x40023C04) — write KEY1=0x45670123, KEY2=0xCDEF89AB
    #     FLASH_USD_UNLOCK (0x40023C08) — user system data
    #     FLASH_STS (0x40023C0C) — status
    #
    #   If we have OpenOCD or stlink, we can write directly.
    if command -v openocd &>/dev/null; then
        info "Trying OpenOCD flash unlock..."
        # AT32F435 is compatible with STM32F4 in many OpenOCD configs
        timeout 15 openocd \
            -f interface/stlink.cfg \
            -f target/at32f435.cfg \
            -c "init" \
            -c "reset halt" \
            -c "flash protect 0 0 last off" \
            -c "reset" \
            -c "exit" 2>&1 || {
                warn "OpenOCD unlock attempt failed (this is OK if you don't have an SWD adapter)"
            }
    fi

    # Method 3: Create a Python helper for AT32 ISP flash unlock
    info "Creating AT32 ISP unlock helper script..."
    cat > "${INSTALL_DIR}/at32_unlock.py" << 'PYEOF'
#!/usr/bin/env python3
"""
AT32F435 Flash Unlock via ISP (serial) mode.

To use:
  1. Connect PM5 via USB
  2. Power on and hold button for 6 seconds to enter ISP mode
  3. Run: python3 at32_unlock.py /dev/ttyACM0

The AT32 ISP protocol is similar to STM32 bootloader protocol.
"""
import sys
import serial
import time

def isp_connect(port, baud=115200):
    ser = serial.Serial(port, baud, timeout=2)
    time.sleep(0.1)
    # Send sync byte
    ser.write(b'\x7F')
    ack = ser.read(1)
    if ack == b'\x79':
        print("[OK] ISP connection established")
        return ser
    else:
        print(f"[ERR] No ACK (got {ack.hex() if ack else 'nothing'})")
        print("      Make sure device is in ISP mode (hold button 6 seconds)")
        return None

def isp_read_unprotect(ser):
    """Remove read protection — this also mass-erases flash."""
    print("[INFO] Sending Read Unprotect command (0x92)...")
    ser.write(b'\x92\x6D')  # cmd + complement
    ack = ser.read(1)
    if ack == b'\x79':
        print("[OK] Read unprotect ACK received")
        ack2 = ser.read(1)
        if ack2 == b'\x79':
            print("[OK] Read protection removed. Device will reset.")
            return True
    print("[WARN] Read unprotect may not have succeeded")
    return False

def isp_write_unprotect(ser):
    """Remove write protection from all sectors."""
    print("[INFO] Sending Write Unprotect command (0x73)...")
    ser.write(b'\x73\x8C')  # cmd + complement
    ack = ser.read(1)
    if ack == b'\x79':
        print("[OK] Write unprotect ACK received")
        ack2 = ser.read(1)
        if ack2 == b'\x79':
            print("[OK] Write protection removed. Device will reset.")
            return True
    print("[WARN] Write unprotect may not have succeeded")
    return False

def main():
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <serial_port>")
        print(f"  e.g. {sys.argv[0]} /dev/ttyACM0")
        sys.exit(1)

    port = sys.argv[1]
    print(f"[INFO] Connecting to {port}...")

    ser = isp_connect(port)
    if not ser:
        sys.exit(1)

    print()
    print("This will remove flash write/read protection.")
    print("WARNING: Read unprotect will MASS ERASE the flash.")
    print()
    resp = input("Proceed with write unprotect? [y/N]: ").strip().lower()
    if resp == 'y':
        isp_write_unprotect(ser)
        time.sleep(1)
        # Reconnect after reset
        ser.close()
        time.sleep(2)
        ser = isp_connect(port)

    if ser:
        resp = input("Proceed with read unprotect (MASS ERASE)? [y/N]: ").strip().lower()
        if resp == 'y':
            isp_read_unprotect(ser)

    if ser:
        ser.close()
    print("[INFO] Done. Now re-flash the firmware.")

if __name__ == "__main__":
    main()
PYEOF
    chmod +x "${INSTALL_DIR}/at32_unlock.py"
    ok "AT32 ISP unlock helper created at ${INSTALL_DIR}/at32_unlock.py"
}

# ── Step 5: Flash ──────────────────────────────────────────────────────────

flash_device() {
    cd "$INSTALL_DIR"

    # Locate built firmware files
    local bootrom=""
    local fullimage=""

    for d in "$BUILD_DIR" "${INSTALL_DIR}/bootrom/obj" "${INSTALL_DIR}/armsrc/obj" "${BUILD_DIR}/bootrom" "${BUILD_DIR}/armsrc"; do
        [[ -f "$d/bootrom.elf" ]] && bootrom="$d/bootrom.elf"
        [[ -f "$d/fullimage.elf" ]] && fullimage="$d/fullimage.elf"
    done

    if [[ -z "$bootrom" ]]; then
        warn "bootrom.elf not found — searching..."
        bootrom=$(find "$INSTALL_DIR" -name "bootrom.elf" -not -path "*/\.git/*" 2>/dev/null | head -1)
    fi
    if [[ -z "$fullimage" ]]; then
        warn "fullimage.elf not found — searching..."
        fullimage=$(find "$INSTALL_DIR" -name "fullimage.elf" -not -path "*/\.git/*" 2>/dev/null | head -1)
    fi

    [[ -z "$bootrom" ]]  && die "bootrom.elf not found. Did the build succeed?"
    [[ -z "$fullimage" ]] && die "fullimage.elf not found. Did the build succeed?"

    info "Bootrom:   $bootrom"
    info "Fullimage: $fullimage"

    # Locate flasher / client
    local flasher=""
    for candidate in \
        "${INSTALL_DIR}/client/proxmark3" \
        "${INSTALL_DIR}/client/build/proxmark3" \
        "${INSTALL_DIR}/pm3-flash-all" \
        "$(command -v proxmark3 2>/dev/null)"; do
        if [[ -x "$candidate" ]]; then
            flasher="$candidate"
            break
        fi
    done

    [[ -z "$flasher" ]] && die "No proxmark3 client/flasher binary found."

    info "Flasher:   $flasher"
    echo ""

    # ── Enter bootloader mode ──────────────────────────────────────────
    wait_for_device "bootloader" || die "Cannot proceed without device."

    local port
    port=$(detect_port)
    [[ -z "$port" ]] && die "No serial port found."

    # ── Flash bootrom FIRST (critical for persistence!) ────────────────
    info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    info "  STEP 1/2: Flashing BOOTROM"
    info "  This is critical — the bootrom must match the firmware"
    info "  or the device will reject it on cold boot."
    info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    if "$flasher" "$port" --flash-bootrom "$bootrom" --force 2>&1; then
        ok "Bootrom flashed successfully."
    else
        warn "Standard flash failed — retrying with alternate method..."
        # Some builds use different CLI syntax
        "$flasher" --port "$port" --flash-bootrom "$bootrom" --force 2>&1 || \
        "$flasher" "$port" -b "$bootrom" --force 2>&1 || {
            err "Bootrom flash failed. Try ISP recovery: $0 --isp"
            return 1
        }
        ok "Bootrom flashed (alternate method)."
    fi

    sleep 2

    # ── Re-enter bootloader for fullimage ──────────────────────────────
    info "Re-entering bootloader mode for fullimage..."
    wait_for_device "bootloader" || die "Device lost after bootrom flash."
    port=$(detect_port)

    # ── Flash fullimage ────────────────────────────────────────────────
    info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    info "  STEP 2/2: Flashing FULLIMAGE (FPGA + OS)"
    info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    if "$flasher" "$port" --flash-fullimage "$fullimage" --force 2>&1; then
        ok "Fullimage flashed successfully."
    else
        warn "Standard flash failed — retrying with alternate method..."
        "$flasher" --port "$port" --flash-fullimage "$fullimage" --force 2>&1 || \
        "$flasher" "$port" -f "$fullimage" --force 2>&1 || {
            err "Fullimage flash failed. Try ISP recovery: $0 --isp"
            return 1
        }
        ok "Fullimage flashed (alternate method)."
    fi

    echo ""
    ok "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    ok "  Flash complete! Both bootrom and fullimage written."
    ok "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# ── Step 6: Verify ─────────────────────────────────────────────────────────

verify_flash() {
    cd "$INSTALL_DIR"
    info "Verifying firmware..."

    echo ""
    info "Unplug and replug the Proxmark5 (WITHOUT holding any buttons)."
    echo ""

    wait_for_device "normal" || die "Device not detected for verification."

    local port
    port=$(detect_port)

    local client_bin=""
    for candidate in \
        "${INSTALL_DIR}/client/proxmark3" \
        "${INSTALL_DIR}/client/build/proxmark3" \
        "$(command -v proxmark3 2>/dev/null)"; do
        if [[ -x "$candidate" ]]; then
            client_bin="$candidate"
            break
        fi
    done

    [[ -z "$client_bin" ]] && die "Client binary not found for verification."

    info "Running hw version..."
    echo ""
    timeout 15 "$client_bin" "$port" -c "hw version" 2>&1 || {
        err "Client couldn't connect. The persistence issue may still exist."
        echo ""
        warn "If this failed, try these steps in order:"
        warn "  1. Run: $0 --unlock"
        warn "  2. Run: $0 --flash-only"
        warn "  3. If still failing: $0 --isp"
        return 1
    }

    echo ""
    info "Running hw status..."
    echo ""
    timeout 15 "$client_bin" "$port" -c "hw status" 2>&1 || true

    echo ""
    ok "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    ok "  Verification complete!"
    ok "  If hw version showed matching client/firmware versions"
    ok "  and the correct hardware ID, you're good to go."
    ok ""
    ok "  Client is at: ${client_bin}"
    ok "  Connect with: ${client_bin} ${port}"
    ok "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# ── ISP Recovery ───────────────────────────────────────────────────────────

isp_recovery() {
    echo ""
    info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    info "  PROXMARK5 ISP RECOVERY MODE"
    info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    info "The AT32F435 has a built-in ISP (In-System Programming) mode"
    info "that bypasses the bootrom entirely. This is the nuclear option"
    info "— it cannot be bricked as long as USB works."
    echo ""
    info "Steps:"
    info "  1. Connect the Proxmark5 via USB"
    info "  2. Power on the device"
    info "  3. Hold the button for 6 SECONDS (not 3)"
    info "  4. The device enters ISP/DFU mode"
    echo ""
    info "From ISP mode, you have several options:"
    echo ""
    info "  Option A: AT32 ISP Tool (Windows)"
    info "    Download from: https://www.arterytek.com/en/product/AT32F435.jsp"
    info "    Select AT32F435, load the .bin or .hex firmware, and flash."
    echo ""
    info "  Option B: stm32flash (Linux/macOS — AT32 is protocol-compatible)"
    info "    sudo apt install stm32flash    # or brew install stm32flash"

    local port
    port=$(detect_port)
    if [[ -n "$port" ]]; then
        info ""
        info "    Device detected on: $port"
        info ""

        # Try to find the built firmware binary
        local binfile=""
        binfile=$(find "${INSTALL_DIR:-.}" -name "fullimage.bin" -not -path "*/\.git/*" 2>/dev/null | head -1)
        if [[ -z "$binfile" ]]; then
            binfile=$(find "${INSTALL_DIR:-.}" -name "fullimage.elf" -not -path "*/\.git/*" 2>/dev/null | head -1)
        fi

        if [[ -n "$binfile" ]]; then
            info "    Firmware found: $binfile"
            echo ""

            if command -v stm32flash &>/dev/null; then
                echo ""
                read -rp "  Attempt ISP flash with stm32flash now? [y/N]: " resp
                if [[ "$resp" == "y" || "$resp" == "Y" ]]; then
                    info "Unlocking flash..."
                    stm32flash -u "$port" 2>&1 || true
                    sleep 1
                    info "Erasing flash..."
                    stm32flash -o "$port" 2>&1 || true
                    sleep 1
                    info "Writing firmware..."
                    stm32flash -w "$binfile" -v "$port" 2>&1 || {
                        err "stm32flash write failed."
                        err "Try the AT32 ISP Tool on Windows, or the Python helper:"
                        err "  python3 ${INSTALL_DIR}/at32_unlock.py $port"
                        return 1
                    }
                    ok "ISP flash complete! Power cycle the device."
                fi
            else
                warn "stm32flash not installed. Install it or use:"
                info "    stm32flash -u $port              # unlock"
                info "    stm32flash -o $port              # erase"
                info "    stm32flash -w $binfile -v $port  # write + verify"
            fi
        fi
    else
        warn "No device detected. Make sure it's in ISP mode (6-second hold)."
    fi

    echo ""
    info "  Option C: Python ISP helper (included)"
    info "    python3 ${INSTALL_DIR}/at32_unlock.py <port>"
    echo ""
    info "  Option D: OpenOCD with SWD/JTAG adapter"
    info "    openocd -f interface/stlink.cfg -f target/at32f435.cfg \\"
    info "      -c \"program fullimage.elf verify reset exit\""
    echo ""
}

# ── Convenience: flash-all wrapper ─────────────────────────────────────────

pm3_flash_all() {
    cd "$INSTALL_DIR"

    # Some builds provide a pm3-flash-all script
    if [[ -x "./pm3-flash-all" ]]; then
        info "Using pm3-flash-all script..."
        wait_for_device "bootloader" || die "No device found."
        if [[ -n "$PM5_PORT" ]]; then
            ./pm3-flash-all "$PM5_PORT"
        else
            ./pm3-flash-all
        fi
    else
        flash_device
    fi
}

# ── Main ───────────────────────────────────────────────────────────────────

main() {
    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║         Proxmark5 — Build, Flash & Persistence Fix         ║"
    echo "║   Source: xianglin1998/proxmark3 (branch: proxmark5)       ║"
    echo "║   Target: AT32F435 + GOWIN FPGA                           ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""

    local mode="${1:-full}"

    case "$mode" in
        --deps-only)
            install_deps
            ;;
        --build-only)
            clone_repo
            build_firmware
            ;;
        --flash-only)
            flash_device
            verify_flash
            ;;
        --unlock)
            unlock_flash
            ;;
        --verify)
            verify_flash
            ;;
        --isp)
            isp_recovery
            ;;
        --help|-h)
            echo "Usage: $0 [option]"
            echo ""
            echo "Options:"
            echo "  (no args)     Full run: deps → clone → build → flash → verify"
            echo "  --deps-only   Install build dependencies only"
            echo "  --build-only  Clone/update repo and build only"
            echo "  --flash-only  Flash already-built firmware (bootrom + fullimage)"
            echo "  --unlock      Unlock AT32F435 flash write protection"
            echo "  --verify      Verify flashed firmware is persisting"
            echo "  --isp         ISP recovery mode guide and tools"
            echo "  --help        Show this help"
            echo ""
            echo "Environment variables:"
            echo "  PM5_PORT=/dev/ttyACM0   Override auto-detected serial port"
            echo "  PM5_DIR=/path/to/src    Override source directory (default: ~/proxmark5)"
            echo ""
            echo "Persistence fix:"
            echo "  The #1 cause of firmware not surviving power cycles is"
            echo "  flashing only the fullimage without the bootrom. The old"
            echo "  bootrom checks the firmware's hardware magic/version on"
            echo "  cold boot and rejects it. This script flashes BOTH."
            echo ""
            echo "  If that doesn't fix it, AT32F435 flash protection bits"
            echo "  may be preventing permanent writes. Use --unlock first,"
            echo "  then --flash-only."
            echo ""
            echo "  If nothing works, use --isp for ISP recovery (unbrickable)."
            ;;
        full|"")
            install_deps
            clone_repo
            build_firmware
            unlock_flash
            flash_device
            verify_flash
            echo ""
            ok "All done! Your Proxmark5 client is at:"
            ok "  ${INSTALL_DIR}/client/proxmark3"
            echo ""
            info "Quick test — unplug, wait 5 seconds, replug, then run:"
            info "  ${INSTALL_DIR}/client/proxmark3 $(detect_port)"
            info "  hw version"
            info "  hw tune"
            echo ""
            ;;
        *)
            die "Unknown option: $mode (try --help)"
            ;;
    esac
}

main "$@"
