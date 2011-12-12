if test "${beaglerev}" = "xMA"; then
echo "xM A doesnt have NAND"
exit
else if test "${beaglerev}" = "xMB"; then
echo "xM B doesnt have NAND"
exit
else if test "${beaglerev}" = "xMC"; then
echo "xM C doesnt have NAND"
exit
else
echo "Starting NAND UPGRADE, do not REMOVE SD CARD or POWER till Complete"
fatload mmc 0:1 0x80200000 MLO
nandecc hw
nand erase 0 80000
nand write 0x80200000 0 20000
nand write 0x80200000 20000 20000
nand write 0x80200000 40000 20000
nand write 0x80200000 60000 20000

fatload mmc 0:1 0x80300000 u-boot.bin
nandecc sw
nand erase 80000 160000
nand write 0x80300000 80000 160000
nand erase 260000 20000
echo "FLASH UPGRADE Complete"
exit
fi
fi
fi

