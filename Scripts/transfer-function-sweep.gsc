# borgvr.gsccommands
#
# Run on an open scalar dataset in TF rendering mode. Sweep is created next to
# a local .data file, or in the configured data folder for a built-in dataset.
# Matching filenames are overwritten.
# If interrupted, load Sweep/original-channel0.tf1d to restore the saved TF.

set channel 0
set width 6
set maxWidth 512
set grid 4095
set span $width * $grid
set divisor $span * $span * $span
set rounding $divisor / 2

setdir Sweep
set original gettransferfunction $channel
savetf $channel "original-channel${channel}.tf1d"

repeat 101 as step
  set name "sweep-${step}"
  if $step < 100
    set name "sweep-0${step}"
    if $step < 10
      set name "sweep-00${step}"
    endif
  endif

  # Build the standard 4096-entry LUT on x = index / 4095.
  # Integer coordinates below use units of 1 / (100 * 4095).
  set start $step * $grid
  set zeros $start / 100 + 1
  set firstWhite $start + $span + 99
  set firstWhite $firstWhite / 100
  if $zeros > $grid
    set zeros $grid
  endif
  if $firstWhite > $grid
    set firstWhite $grid
  endif
  set whites $grid - $firstWhite

  # The last entry can still be in the ramp as its lower edge nears 100%.
  set x 100 * $grid - $start
  set last 255
  if $x < $span
    set slope 3 * $span - 2 * $x
    set value 255 * $x * $x * $slope + $rounding
    set last $value / $divisor
  endif

  # Assemble the flat regions by doubling blocks rather than appending one row at a time.
  set head "["
  set tail "[${last},${last},${last},${last}]]"
  set black "[0,0,0,0],"
  set white "[255,255,255,255],"
  repeat 12
    set halfBlack $zeros / 2
    set halfWhite $whites / 2
    set blackBit $zeros - $halfBlack * 2
    set whiteBit $whites - $halfWhite * 2
    if $blackBit
      set head "${head}${black}"
    endif
    if $whiteBit
      set tail "${white}${tail}"
    endif
    set zeros $halfBlack
    set whites $halfWhite
    set black "${black}${black}"
    set white "${white}${white}"
  endrepeat

  # Smoothstep(t) = t*t*(3-2*t). Use the same value for all four components.
  set ramp " "
  set first $start / 100 + 1
  set middle $firstWhite - $first
  if $middle > 0
    repeat $middle as offset
      set x 100 * $first + 100 * $offset - $start
      set slope 3 * $span - 2 * $x
      set value 255 * $x * $x * $slope + $rounding
      set v $value / $divisor
      set ramp "${ramp}[${v},${v},${v},${v}],"
    endrepeat
  endif

  settransferfunctionjson $channel "${head}${ramp}${tail}"
  waitframes 1
  screenshot "${name}.png" true $maxWidth
endrepeat

settransferfunction $channel "$original"
log "Saved sweep-000.png through sweep-100.png and restored the original transfer function."
