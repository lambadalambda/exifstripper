# ExifStripper

Dependency-free utilities for working with EXIF and related metadata.

Currently provides:

- Lossless GPS stripping (no re-encode) for JPEG, WebP, PNG and ISO-BMFF (HEIC/AVIF)
- Description extraction from common metadata (EXIF/IPTC/XMP)

## Installation

The package can be installed
by adding `exif_stripper` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:exif_stripper, "~> 0.1.1"}
  ]
end
```

## Usage

Strip GPS metadata in-place:

```elixir
ExifStripper.GpsStripper.strip_gps_data("/tmp/in.jpg", "/tmp/in.jpg")
```

Read a description:

```elixir
ExifStripper.Description.read_file("/tmp/image.jpg", max_length: 500)
```

## Tests

The test suite uses `exiftool` as an oracle, so `exiftool` must be available in `PATH`.
