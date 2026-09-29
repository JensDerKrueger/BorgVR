# borgvr.gsccommands

# Import a QVIS (.dat) or NRRD (.nrrd/.nhdr) volume and capture one image
# every 5 degrees during a complete rotation around the y axis.

set inputFile fileinput "QVIS- oder NRRD-Eingabedatei auswählen"
set outputFile input "Name der Ausgabedatei im BorgVR-Datenverzeichnis"
set description input "Beschreibung des Datensatzes"

setimportbricksize 32
setimportoverlap 2
setbordermode 0

log File import started
importfile $inputFile $outputFile $description
log File import completed

opendataset $outputFile
resetrotation
setdir rotation-frames
setDisplaySync false
waitloaded

repeat 72 as $i
screenshot frame-$i.png
addrotationy 5
waitloaded
endrepeat

log 360 degree rotation capture completed
