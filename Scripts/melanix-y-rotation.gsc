# borgvr.gsccommands

# Capture a full y-axis rotation of the Melanix dataset.
# Output goes into a "test" subdirectory next to the dataset.

opendataset 386A5CB2-B41C-497D-A949-4C0323D7C7B1 # melanix
setdir test
logfile melanix-y-rotation.log
log Melanix y-axis rotation capture
logtime
setfpswindow 1.0
setDisplaySync false
logMetalInfo true

rendermode tflighting
resetrotation
settranslation 0 0
zoom 1
waitloaded
resetfps
logfps
screenshot melanix-y-000.png

repeat 360 as $i
addrotationy 1
waitloaded
screenshot melanix-y-$i.png
endrepeat

logfps
log Melanix y-axis rotation capture complete
