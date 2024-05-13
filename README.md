# macpavolume

This is a very simple utility written in Swift for modern macOS that allows you to control the default sink and source volume on a PulseAudio server.

Run `./macpavolume --help` for CLI argument help.

## Other operating systems

If you want to control PulseAudio's volume on another operating system, use one of the following:

- pavucontrol, which is a semi-cross-platform tool that does a lot more than just manage the default sink/source volumes,
- gnome-volume-control, which is fairly tightly tied to the GNOME platform and runs well on Linux,
- kmix, which is fairly tightly tied to the KDE platform and runs well on Linux,
- pavucontrol-qt-sandsmark, which only depends on Qt and libpulse and should run on any platform that supports these libraries.