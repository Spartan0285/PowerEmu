.section .text
.globl _start
_start:
 lis 1,0x21
 li 10,0x4000
 mtmsr 10
 isync
loop:
 li 3,258
 lis 4,0x21
 addi 4,4,-256
 lis 7,0x22
 lis 8,0x21
 addi 8,8,-128
 lis 9,0x23
 lis 10,0x23
 ori 10,10,0x1000
 lis 11,0x23
 ori 11,11,0x2000
 stw 11,0(10)
 lis 11,0x23
 ori 11,11,0x3000
 stw 11,4(10)
 stw 9,8(10)
 stw 7,0xa0(10)
 li 10,0
 stw 10,0(4)
 stw 10,4(4)
 stw 10,8(4)
 li 10,1234
 stw 10,12(4)
 lis 10,0x3ff0
 stw 10,16(4)
 li 10,7
 stw 10,56(4)
 li 10,0
 stw 10,0(8)
 stw 10,8(8)
 li 10,6789
 stw 10,12(8)
 lis 10,0x3ff0
 stw 10,16(8)
 li 10,7
 stw 10,56(8)
 li 10,1
 stw 10,0(7)
 li 10,2
 stw 10,4(7)
 li 10,2048
 stw 10,8(7)
 lis 10,0x24
 stw 10,12(7)
 bl sm_entry
core_return:
 lis 10,0x10
wait:
 addic. 10,10,-1
 bne wait
 b loop
sm_entry:
 mflr 3
 stw 3,8(1)
 stwu 1,-0x50(1)
 lwz 3,0(7)
 addi 1,1,0x50
 lwz 0,8(1)
 mtlr 0
sm_exit:
 blr
