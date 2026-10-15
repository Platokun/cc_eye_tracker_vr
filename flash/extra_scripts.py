"""
PlatformIO helper: flashes the prebuilt cc_eye_tracker_vr firmware.

Adds a single-click "Flash cc_eye_tracker_vr firmware" entry to the PlatformIO
sidebar, and also rewires PlatformIO's normal Upload command to write the same
prebuilt image.

Nothing is compiled here - the image is produced by build.sh / build.bat in the
repository root and written to out/.
"""

Import("env")  # noqa: F821  (PlatformIO injects this)

import os

IMAGE_NAME = "openiris_xiao_esp32s3_usb_cam_merged.bin"

# Where the merged image might be, relative to this project directory, in the
# order we prefer them. The first one that exists wins, so the same script
# works for the repository layout (out/ one level up) and for a standalone copy
# of this folder that carries its own out/ directory.
FIRMWARE_CANDIDATES = (
    os.path.join(os.pardir, "out", IMAGE_NAME),   # repository layout
    os.path.join("out", IMAGE_NAME),              # self-contained copy
    os.path.join(os.pardir, IMAGE_NAME),          # older layout, repo root
    IMAGE_NAME,                                   # loose next to platformio.ini
)

FLASH_OFFSET = "0x0"
BAUD = "921600"


def _firmware_path(env):
    project_dir = env.subst("$PROJECT_DIR")
    paths = [os.path.normpath(os.path.join(project_dir, rel)) for rel in FIRMWARE_CANDIDATES]
    for path in paths:
        if os.path.isfile(path):
            return path
    # Nothing found: return the preferred location so the error message is useful.
    return paths[0]


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


def _check_firmware(env):
    firmware = _firmware_path(env)
    if os.path.isfile(firmware):
        return True

    project_dir = env.subst("$PROJECT_DIR")
    print("")
    print("ERROR: the firmware image was not found.")
    print("")
    print("Looked for:")
    for rel in FIRMWARE_CANDIDATES:
        print("   %s" % os.path.normpath(os.path.join(project_dir, rel)))
    print("")
    print("Build it first: ./build.sh  (Linux/macOS)  or  build.bat  (Windows)")
    print("")
    return False


def flash_openiris(source, target, env):
    """Custom target: write the prebuilt image at 0x0."""
    if not _check_firmware(env):
        # Nothing to flash is a failure, not a success.
        env.Exit(1)
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
