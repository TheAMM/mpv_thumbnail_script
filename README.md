# `mpv_thumbnail_script.lua`

[![](docs/mpv_thumbnail_script.gif "Thumbnail preview for Sintel (2010) on mpv's seekbar")](https://www.youtube.com/watch?v=a9cmt176WDI)
[*Click the image (or here) to view a YouTube video of the script in action*](https://www.youtube.com/watch?v=a9cmt176WDI)

*(You might also be interested in [`mpv_crop_script.lua`](https://github.com/TheAMM/mpv_crop_script))*

----

## What is it?

`mpv_thumbnail_script.lua` is a script/replacement OSC for [mpv](https://github.com/mpv-player/mpv) to display preview thumbnails when hovering over the seekbar, without any external dependencies[<sup>1</sup>](#footnotes), cross-platform-ly[<sup>2</sup>](#footnotes)!

The script supports all four built-in OSC layouts, [as seen in this Youtube video](https://www.youtube.com/watch?v=WsfWmO41p8A).  
The script will also do multiple passes over the video, generating thumbnails with increasing frequency until the target is reached.
This allows you to preview the end of the file before every thumbnail has been generated.

## How do I install it?

Grab both the two `.lua`s from the [**releases page**](https://github.com/TheAMM/mpv_thumbnail_script/releases) and place them both to your mpv's `scripts` directory.

For example:
  * Linux/Unix/Mac: `~/.config/mpv/scripts/mpv_thumbnail_script_server.lua` & `~/.config/mpv/scripts/mpv_thumbnail_script_client_osc.lua`
  * Windows: `%APPDATA%\mpv\scripts\mpv_thumbnail_script_server.lua` & `%APPDATA%\mpv\scripts\mpv_thumbnail_script_client_osc.lua`

(See the [Files section](https://mpv.io/manual/master/#files) in mpv's manual for more info.)

You should also read the [Configuration](#configuration) section.

While the script doesn't need external dependencies and can work with mpv alone, it can also use FFmpeg for *slightly* faster thumbnail generation; just make sure `ffmpeg[.exe]` is in your `PATH` and `prefer_mpv` is set to `no` in your configuration.

***However,*** FFmpeg does not support "ordered chapters" in MKVs (segment linking, ie. an `.mkv` references another `.mkv`), which can break the thumbnailing process. You have been warned.

In general, you should just use multiple worker scripts ([Configuration](#configuration)) instead of taking the FFmpeg-risk.

**Note:** You will need a rather new version of mpv due to [the new binds](https://github.com/mpv-player/mpv/commit/957e9a37db6611fe0879bd2097131df5e09afd47#diff-5d10e79e2d65d30d34f98349f4ed08e4) used in the patched `osc.lua`.

## How do I use it?

Just open a file and hover over the seekbar!  
Although by default, videos over an hour will require you to press the `T` (that's `shift+t`) keybind.
You may change this duration check in the configuration (`autogenerate_max_duration`).

**Also of note:** the script does not manage the thumbnails in any way, you should clear the directory from time to time.

## Configuration

**Note!** Because this script replaces the built-in OSC, you will have to set `osc=no` in your mpv's [main config file](https://mpv.io/manual/master/#files).


**Multithreading:**  
This script can use multiple concurrent thumbnailing jobs.  
Simply copy the `mpv_thumbnail_script_server.lua` once or twice (`mpv_thumbnail_script_server-1.lua`, `mpv_thumbnail_script_server-2.lua`) and the workers will automatically register themselves with the core.  
This improves thumbnailing speed a bunch, but you will quickly max out your CPU - I recommend only having two or three copies of the script.  
(Why multiple copies of the same file? mpv gives each script their own thread - easy multithreading!)

To adjust the script's options, create a file called `mpv_thumbnail_script.conf` inside your mpv's `script-opts` directory.

For example:
  * Linux/Unix/Mac: `~/.config/mpv/script-opts/mpv_thumbnail_script.conf`
  * Windows: `%APPDATA%\mpv\script-opts\mpv_thumbnail_script.conf`

(See the [Files section](https://mpv.io/manual/master/#files) in mpv's manual for more info.)



In this file you may set the following options:
```ini
# The thumbnail cache directory.
# On Windows this defaults to %TEMP%\mpv_thumbs_cache,
# and on other platforms to /tmp/mpv_thumbs_cache.
# The directory will be created automatically, but must be writeable!
# Use absolute paths, and take note that environment variables like %TEMP% are unsupported (despite the default)!
cache_directory=/tmp/my_mpv_thumbnails
# THIS IS NOT A WINDOWS PATH. COMMENT IT OUT OR ADJUST IT YOURSELF.

# Whether to generate thumbnails automatically on video load, without a keypress
# Defaults to yes
autogenerate=[yes/no]

# Only automatically thumbnail videos shorter than this (in seconds)
# You will have to press T (or your own keybind) to enable the thumbnail previews
# Set to 0 to disable the check, ie. thumbnail videos no matter how long they are
# Defaults to 3600 (one hour)
autogenerate_max_duration=3600

# Use mpv to generate thumbnail even if ffmpeg is found in PATH
# ffmpeg is slightly faster than mpv but lacks support for ordered chapters in MKVs,
# which can break the resulting thumbnails. You have been warned.
# Defaults to yes (don't use ffmpeg)
prefer_mpv=[yes/no]

# Explicitly disable subtitles on the mpv sub-calls
# mpv can and will by default render subtitles into the thumbnails.
# If this is not what you wish, set mpv_no_sub to yes
# Defaults to no
mpv_no_sub=[yes/no]

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

# Below are overrides for remote urls (you generally want less thumbnails, because it's slow!)
# Thumbnailing network paths will be done with mpv (leveraging youtube-dl)

# Allow thumbnailing network paths (naive check for "://")
# Defaults to no
thumbnail_network=[yes/no]
# Override thumbnail count, min/max delta, as above
remote_thumbnail_count=60
remote_min_delta=15
remote_max_delta=120

# Try to grab the raw stream and disable ytdl for the mpv subcalls
# Much faster than passing the url to ytdl again, but may cause problems with some sites
# Defaults to yes
remote_direct_stream=[yes/no]
```
(see [`src/options.lua`](/src/options.lua) for all possible options)

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
