# `mpv_thumbnail_script.lua`

[![](docs/mpv_thumbnail_script.jpg "Thumbnail preview for Sintel (2010) on mpv's seekbar")](https://www.youtube.com/watch?v=a9cmt176WDI)
[*Click the image or here to see the script in action*](https://www.youtube.com/watch?v=a9cmt176WDI)

*(You might also be interested in [`mpv_crop_script.lua`](https://github.com/TheAMM/mpv_crop_script))*

----

## What is it?

`mpv_thumbnail_script.lua` is a script/replacement OSC for [mpv](https://github.com/mpv-player/mpv) to display preview thumbnails when hovering over the seekbar, without any external dependencies[<sup>1</sup>](#footnotes), cross-platform-ly[<sup>2</sup>](#footnotes)!

The script supports all four built-in OSC layouts, [as seen in this Youtube video](https://www.youtube.com/watch?v=WsfWmO41p8A).  
The script will also do multiple passes over the video, generating thumbnails with increasing frequency until the target is reached.
This allows you to preview the end of the file before every thumbnail has been generated.

## How do I install it?

Grab both the `mpv_thumbnail_script_server.lua` and `mpv_thumbnail_script_client_osc.lua` from the [releases page](https://github.com/TheAMM/mpv_thumbnail_script/releases) (or [see below](#development) how to "build" (concatenate) it yourself) and place them both to your mpv's `scripts` directory. (**Note!** Also see Configuration below)  

For example:
  * Linux/Unix/Mac: `~/.config/mpv/scripts/mpv_thumbnail_script_server.lua` & `~/.config/mpv/scripts/mpv_thumbnail_script_client_osc.lua`
  * Windows: `%APPDATA%\Roaming\mpv\scripts\mpv_thumbnail_script_server.lua` & `%APPDATA%\Roaming\mpv\scripts\mpv_thumbnail_script_client_osc.lua`

See the [Files section](https://mpv.io/manual/master/#files) in mpv's manual for more info.

The script can also use FFmpeg for faster thumbnail generation, which is highly recommended.  
Just make sure `ffmpeg[.exe]` is in your `PATH`.

**Note:** You will need a rather new version of mpv due to [the new binds](https://github.com/mpv-player/mpv/commit/957e9a37db6611fe0879bd2097131df5e09afd47#diff-5d10e79e2d65d30d34f98349f4ed08e4) used in the patched `osc.lua`.

## How do I use it?

Just open a file and hover over the seekbar!  
Although by default, videos over an hour will require you to press the `T` (that's `shift+t`) keybind.
You may change this duration check in the configuration (`autogenerate_max_duration`).

**Also of note:** the script does not manage the thumbnails in any way, you should clear the directory from time to time.

## Configuration

**Note!** Because this script replaces the built-in OSC, you will have to set `osc=no` in your mpv's [main config file](https://mpv.io/manual/master/#files).

Create a file called `mpv_thumbnail_script.conf` inside your mpv's `lua-settings` directory to adjust the script's options.

For example:
  * Linux/Unix/Mac: `~/.config/mpv/lua-settings/mpv_thumbnail_script.conf`
  * Windows: `%APPDATA%\Roaming\mpv\lua-settings\mpv_thumbnail_script.conf`

See the [Files section](https://mpv.io/manual/master/#files) in mpv's manual for more info.

In this file you may set the following options:
```ini
# The thumbnail cache directory.
# On Windows this defaults to %TEMP%\mpv_thumbs_cache,
# and on other platforms to /tmp/mpv_thumbs_cache.
# The directory will be created automatically, but must be writeable!
cache_directory=/tmp/my_mpv_thumbnails

# Whether to generate thumbnails automatically on video load, without a keypress
# Defaults to yes
autogenerate=[yes/no]

# Only automatically thumbnail videos shorter than this (in seconds)
# You will have to press T (or your own keybind) to enable the thumbnail previews
# Set to 0 to disable the check, ie. thumbnail videos no matter how long they are
# Defaults to 3600 (one hour)
autogenerate_max_duration=3600

# Use mpv to generate thumbnail even if ffmpeg is found in PATH
# It's better to use ffmpeg, but the choice is yours
# Defaults to no
prefer_mpv=[yes/no]

# Enable to disable the built-in keybind ("T") to add your own, see after the block
disable_keybinds=[yes/no]

# The maximum dimensions of the thumbnails, in pixels
# Defaults to 200 and 200
thumbnail_width=200
thumbnail_height=200

# The thumbnail count target
# (This will result in a thumbnail every ~10 seconds for a 25 minute video)
thumbnail_count=150

# The above target count will be adjusted by the minimum and
# maximum time difference between thumbnails.
# The thumbnail_count will be used to calculate a target separation,
# and min/max_delta will be used to constrict it.

# In other words, thumbnails will be:
# - at least min_delta seconds apart (limiting the amount)
# - at most max_delta seconds apart (raising the amount if needed)
# Defaults to 5 and 90, values are seconds
min_delta=5
max_delta=90
# 120 seconds aka 2 minutes will add more thumbnails only when the video is over 5 hours long!
```

With `disable_keybind=yes`, you can add your own keybind to [`input.conf`](https://mpv.io/manual/master/#input-conf) with `script-binding generate-thumbnails`, for example:
```ini
shift+alt+s script-binding generate-thumbnails
```

## Development

Included in the repository is the `concat_files.py` tool I use for automatically concatenating files upon their change, and also mapping changes to the output file back to the source files. It's really handy on stack traces when mpv gives you a line and column on the output file - no need to hunt down the right place in the source files!

The script requires Python 3, so install that. Nothing more, though. Call it with `concat_files.py cat_osc.json`.

You may also, of course, just `cat` the files together yourself. See the [`cat_osc.json`](cat_osc.json)/[`cat_server.json`](cat_server.json) for the order.

### Donation

If you *really* get a kick out of this (weirdo), you can [paypal me](https://www.paypal.me/TheAMM) or send bitcoins to `1K9FH7J3YuC9EnQjjDZJtM4EFUudHQr52d`. Just having the option there, is all.

#### Footnotes
<sup>1</sup>You *may* need to add `mpv[.exe]` to your `PATH` (and *will* have to add `ffmpeg[.exe]` if you want faster generation).

<sup>2</sup>Developed & tested on Windows and Linux (Ubuntu), but it *should* work on Mac and whatnot as well, if <sup>1</sup> has been taken care of.
