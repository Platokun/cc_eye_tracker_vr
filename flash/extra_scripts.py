"""
PlatformIO helper: flashes the prebuilt cc_eye_tracker_vr firmware.

Adds a single-click "Flash cc_eye_tracker_vr firmware" entry to the PlatformIO
sidebar, and also rewires PlatformIO's normal Upload command to write the same
prebuilt image.

Nothing is compiled here - the image is produced by build_and_flash.bat /
build_and_flash.sh in the repository root, and lands next to this folder.
"""

Import("env")  # noqa: F821  (PlatformIO injects this)

import os

# The merged image is written to the repository root, one level above this file.
FIRMWARE_REL = os.path.join(os.pardir, "openiris_xiao_esp32s3_usb_cam_merged.bin")
FLASH_OFFSET = "0x0"
BAUD = "921600"


def _firmware_path(env):
    return os.path.normpath(os.path.join(env.subst("$PROJECT_DIR"), FIRMWARE_REL))


def _esptool_cmd(env):
    """Return a full command prefix that runs esptool.

    Covers both packaging layouts platform-espressif32 has shipped:

      * ``tool-esptoolpy`` (esptool 4.x) -> ``esptool.py`` run by PlatformIO's
        own Python interpreter, i.e. ``"<python>" "<esptool.py>"``.
      * ``tool-esptool`` (esptool 5.x, standalone binary, no Python) ->
        ``esptool`` / ``esptool.exe`` used on its own as an executable.

    Last resort is the ``esptool`` Python module, which is only importable if
    someone installed it into PlatformIO's virtualenv.
    """
    python = env.subst("$PYTHONEXE")

    for package, names, needs_python in (
        ("tool-esptoolpy", ("esptool.py", "esptool"), True),
        ("tool-esptool", ("esptool.exe", "esptool"), False),
    ):
        try:
            pkg_dir = env.PioPlatform().get_package_dir(package)
        except Exception:
            pkg_dir = None
        if not pkg_dir:
            continue
        for name in names:
            candidate = os.path.join(pkg_dir, name)
            if os.path.isfile(candidate):
                if needs_python:
                    return '"%s" "%s"' % (python, candidate)
                return '"%s"' % candidate

    return '"%s" -m esptool' % python


def _build_command(env):
    """esptool write_flash for the merged image.

    --port is deliberately omitted so esptool auto-detects the single serial
    port - that is what makes this a one-click flasher.
    """
    return '%s --chip esp32s3 --baud %s write_flash %s "%s"' % (
        _esptool_cmd(env),
        BAUD,
        FLASH_OFFSET,
        _firmware_path(env),
    )


def _check_firmware(env, firmware=None):
    if firmware is None:
        firmware = _firmware_path(env)
    if not os.path.isfile(firmware):
        print("")
        print("ERROR: the firmware image was not found:")
        print("   %s" % firmware)
        print("")
        print("Run build_and_flash.bat (or ./build_and_flash.sh) first.")
        print("")
        return False
    return True


def flash_openiris(source, target, env):
    """Custom target: write the prebuilt image at 0x0."""
    firmware = _firmware_path(env)
    if not _check_firmware(env, firmware):
        return

    print("")
    print("=" * 62)
    print(" Flashing cc_eye_tracker_vr")
    print("=" * 62)
    print(" Board must already be in download mode:")
    print("   hold BOOT, plug the USB-C cable into the PC, release BOOT.")
    print(" The camera / OTG adapter must NOT be plugged in.")
    print("")

    # env.Execute() runs the command and returns its exit status, but SCons
    # does NOT fail the build because of it - PlatformIO would print
    # [SUCCESS] even when esptool could not open a port. Propagate the failure
    # so a failed flash is reported as FAILED.
    status = env.Execute(_build_command(env))
    if status:
        env.Exit(status)


# Single-click entry in the VS Code PlatformIO sidebar.
env.AddCustomTarget(  # noqa: F821
    name="flash_openiris",
    dependencies=None,
    actions=[flash_openiris],
    title="Flash cc_eye_tracker_vr firmware",
    description="Writes the prebuilt image at 0x0. Hold BOOT while plugging USB first.",
)

# Make the normal Upload toolbar arrow (and `pio run -t upload`) write the same
# image. UPLOADCMD must be a command *string*, not a Python callable, so SCons
# expands it when the upload action runs.
env.Replace(  # noqa: F821
    UPLOADCMD=_build_command(env),
)
