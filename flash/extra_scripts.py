"""
PlatformIO helper: flashes the prebuilt cc_eye_tracker_vr firmware.

Adds a single-click "Flash cc_eye_tracker_vr firmware" entry to the PlatformIO
sidebar, and also rewires PlatformIO's normal Upload command to write the same
prebuilt image.

Nothing is compiled here - the image is produced by build_and_flash.bat /
build_and_flash.sh in the repository root.
"""

Import("env")  # noqa: F821  (PlatformIO injects this)

import os

# The merged image is written to the repository root, one level above this file.
FIRMWARE_REL = os.path.join(os.pardir, "openiris_xiao_esp32s3_usb_cam_merged.bin")
FLASH_OFFSET = "0x0"
BAUD = "921600"


def _firmware_path(env):
    return os.path.normpath(os.path.join(env.subst("$PROJECT_DIR"), FIRMWARE_REL))


def _esptool_module_arg(env):
    """Prefer the esptool bundled with the espressif32 platform."""
    try:
        pkg_dir = env.PioPlatform().get_package_dir("tool-esptoolpy")
    except Exception:
        pkg_dir = None

    if pkg_dir:
        candidate = os.path.join(pkg_dir, "esptool.py")
        if os.path.isfile(candidate):
            return '"%s"' % candidate

    return "-m esptool"


def _build_command(env, port=None):
    python = env.subst("$PYTHONEXE")
    esptool = _esptool_module_arg(env)
    firmware = _firmware_path(env)

    port = port or env.subst("$UPLOAD_PORT")
    port_arg = '--port "%s"' % port if port and port != "auto" else ""

    return '"%s" %s --chip esp32s3 %s --baud %s write_flash %s "%s"' % (
        python,
        esptool,
        port_arg,
        BAUD,
        FLASH_OFFSET,
        firmware,
    )


def _check_firmware(env):
    path = _firmware_path(env)
    if not os.path.isfile(path):
        print("")
        print("ERROR: the firmware image was not found:")
        print("   %s" % path)
        print("")
        print("Run build_and_flash.bat (or ./build_and_flash.sh) first.")
        print("")
        return None
    return path


def flash_openiris(source, target, env):
    if not _check_firmware(env):
        return

    print("")
    print("=" * 62)
    print(" Flashing cc_eye_tracker_vr")
    print("=" * 62)
    print(" If this fails: unplug, hold BOOT, plug USB-C back in, release BOOT.")
    print("")
    env.Execute(_build_command(env))


# Single-click entry in the VS Code PlatformIO sidebar.
env.AddCustomTarget(  # noqa: F821
    name="flash_openiris",
    dependencies=None,
    actions=[flash_openiris],
    title="Flash cc_eye_tracker_vr firmware",
    description="Writes the prebuilt image at 0x0. Hold BOOT while plugging USB first.",
    always_build=False,
)

# Make the normal Upload toolbar arrow do the same thing. UPLOADCMD must be a
# command string; PlatformIO substitutes $UPLOAD_PORT at upload time.
env.Replace(  # noqa: F821
    UPLOADCMD='"%s" %s --chip esp32s3 --port "$UPLOAD_PORT" --baud %s write_flash %s "%s"'
    % (
        env.subst("$PYTHONEXE"),
        _esptool_module_arg(env),
        BAUD,
        FLASH_OFFSET,
        _firmware_path(env),
    )
)
