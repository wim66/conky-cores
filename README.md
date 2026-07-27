# conky-cores

A compact Conky widget for Linux that renders per-core CPU activity in a glassy Lua/Cairo style.

It shows each logical CPU in its own small card with:

- a rolling mini graph of recent load
- the current load percentage
- the current clock speed in GHz

The widget also detects physical cores and SMT threads, so the layout can group threads by physical core and label them as “Core X” or “Core X - Thread Y”.

![Preview](preview.png)

## Files

- `conky.conf` — Conky configuration that loads `widget.lua`.
- `widget.lua` — Lua drawing code for the per-core display.
- `index.html` — a simple landing page describing the widget.

## Features

- automatic logical CPU detection with `nproc`
- optional physical-core detection with `lscpu` for more accurate labels and header readouts
- SMT-aware grouping of threads by physical core
- per-core graph, load, and frequency readout
- configurable layout with `cores_per_row`, `vertical_align`, and a canvas debug overlay
- liquid-glass rendering with rounded cards, highlights, and adjustable colors

## Requirements

- Conky with Lua and Cairo support
- `nproc` available on the system
- Linux with `/proc/cpuinfo`
- `lscpu` is recommended for physical-core grouping and CPU-model detection

## Installation

1. Clone the repository:

   ```sh
   git clone https://github.com/wim66/conky-cores.git
   cd conky-cores
   ```

2. Start Conky from the repository folder:

   ```sh
   ./autostart.sh
   ```

   or directly:

   ```sh
   conky -c ./conky.conf
   ```

3. If needed, adjust the window position and size in `conky.conf`.

## Customization

The main behavior and styling options live in the `CFG` table at the top of `widget.lua`.

Useful settings include:

- `cores_per_row` — number of cells shown per row (default `2`)
- `graph_history_length` — number of samples kept in the rolling graph (default `60`)
- `vertical_align` — `top`, `middle`, or a fixed pixel value
- `debug_show_canvas` — shows a canvas-size overlay for sizing help
- `glass_base_color` / `glass_base_alpha` — base tint and opacity of the glass panels
- `colors` — text and accent colors

## Notes

- The widget is designed to match the style of a companion Conky setup, but it can be used standalone.
- On systems with SMT/Hyper-Threading, the widget will group threads under the same physical core rather than treating every logical CPU as a separate core.
- If your machine has many cores, you may want to increase the window height or adjust `cores_per_row`.
