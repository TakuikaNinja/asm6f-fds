; main program code
;
; Formatting:
; - Width: 132 Columns
; - Tab Size: 4, using tab
; - Comments: Column 57

; reset handler
Reset:
		lda FDS_CTRL_MIRROR								; get setting previously used by FDS BIOS
		and #$f7										; and set for vertical mirroring
		sta FDS_CTRL
		
		lda RST_TYPE_MIRROR								; retrieve the reset type we saved earlier
		sta RST_TYPE
		lda #$53										; and queue the soft reset type for next time
		sta RST_TYPE_MIRROR
		
		jsr InitMemory
		jsr InitNametables
		
		lda #$fd										; set VRAM buffer size to max value ($0302~$03ff)
		sta VRAM_BUFFER_SIZE
		
		lda #%00011110									; enable sprites/background and queue it for next NMI
		jsr UpdatePPUMask
		
		lda #%10000000									; enable NMIs & change background pattern map access
		sta PPU_CTRL
		sta PPU_CTRL_MIRROR
		
Main:
		jsr SpriteHandler
		jsr SetBGMode
		lda DisplayToggle
		beq +
		
		jsr TimerLogic
		jsr RNGLogic
		
+
		inc NMIReady

-
		lda NMIReady									; the usual NMI wait loop
		bne -
		beq Main										; unconditional branch back to main loop

; "NMI" routine which is entered to bypass the BIOS check
Bypass:
		lda #$00										; disable NMIs since we don't need them anymore
		sta PPU_CTRL
		
		lda #<NonMaskableInterrupt						; put real NMI handler in NMI vector 3
		sta NMI_3
		lda #>NonMaskableInterrupt
		sta NMI_3+1
		
		lda #$35										; tell the FDS that the BIOS "did its job"
		sta RST_FLAG
		lda #$ac
		sta RST_TYPE
		sta RST_TYPE_MIRROR								; save reset type to mirror as it will be clobbered
		
		jmp ($fffc)										; jump to reset FDS
		
; NMI handler
NonMaskableInterrupt:
		pha												; back up A
		lda NMIRunning									; exit if NMI is already in progress
		beq +
		
		pla
		rti

+
		inc NMIRunning									; set flag for NMI in progress
		
		txa												; back up X/Y
		pha
		tya
		pha
		
		lda NMIReady									; check if ready to do NMI logic (i.e. not a lag frame)
		beq NotReady
		
		lda NeedDMA										; do sprite DMA if required
		beq +
		
		jsr SpriteDMA
		dec NeedDMA
		
+
		lda NeedDraw									; transfer Data to PPU if required
		beq +
		
		jsr VRAMStructWrite
Struct:
	.dw BGData											; this can be overwritten
		jsr SetScroll									; reset scroll after PPUADDR writes
		dec NeedDraw
		
+
		lda NeedPPUMask									; write PPUMASK if required
		beq +
		
		lda PPU_MASK_MIRROR
		sta PPU_MASK
		dec NeedPPUMask

+
		dec NMIReady
		
		inc FrameCount									; increment frame timer
		bne +

		inc FrameCount+1
		
+
		jsr ReadOrDownVerifyPads						; read controllers, including expansion port (NOT DMC safe!)

NotReady:
		jsr SetScroll									; remember to set scroll on lag frames
		
		pla												; restore X/Y/A
		tay
		pla
		tax
		pla
		
		dec NMIRunning									; clear flag for NMI in progres before exiting
		rti
		
; IRQ handler (unused for now)
InterruptRequest:
		rti

UpdatePPUMask:
		sta PPU_MASK_MIRROR
		lda #$01
		sta NeedPPUMask
		rts

MoveSpritesOffscreen:
		lda #$ff										; fill OAM buffer with $ff to move offscreen
		ldx #$02
		ldy #$02
		jmp MemFill

InitObject:
		ldy #$00
		sty TestObject									; render flag
		sty TestObject+5								; animation frame
		sty TestObject+8								; object flags
		sty TestObject+9								; palette
		sty TestObject+11								; object index in OAM
		
		lda #$78										; position object at centre of screen
		sta ObjectY
		sta ObjectX
		
		lda #>TestObjectTiles							; tile arrangement pointer
		sta TestObject+6
		lda #<TestObjectTiles
		sta TestObject+7
		
		lda #$22										; height/width in tiles
		sta TestObject+10
		
		inc ObjectActive								; set active flag
		
		rts

SpriteHandler:
		jsr MoveSpritesOffscreen
		
		lda ObjectActive								; skip object init if already active
		bne +

		jsr InitObject

+
		jsr MoveObject									; move and position object
		lda ObjectY
		sta TestObject+1
		lda ObjectX
		sta TestObject+3

		lda #<TestObject								; put object pointer into ($00)
		sta temp
		lda #>TestObject
		sta temp+1
		
		lda #$01										; queue OAM DMA for the next NMI
		sta NeedDMA
		jmp UploadObject								; call BIOS routine to upload object to the OAM buffer

TestObjectTiles:
	.db $d0, $d2, $d1, $d3

MoveObject:
		lda #$00										; reset speed variables
		sta ObjectXSpeed
		sta ObjectYSpeed
		
		lda P1_HELD										; leave early if no directions held
		and #BUTTON_LEFT | #BUTTON_RIGHT | #BUTTON_UP | #BUTTON_DOWN
		bne MoveX
		
		rts

MoveX:													; move object horizontally, clamping within screen
		lda P1_HELD										; left
		and #BUTTON_LEFT
		beq +
		
		lda ObjectX										; don't move if at left edge
		beq +
		
		lda #$ff										; otherwise set X speed to -1
		sta ObjectXSpeed
		
+
		lda P1_HELD										; right
		and #BUTTON_RIGHT
		beq +
		
		lda ObjectX										; don't move if at right edge
		cmp #$f0
		bcs +
		
		lda #$01										; otherwise set X speed to 1
		sta ObjectXSpeed
		
+
		lda ObjectX										; add X speed to X position
		clc
		adc ObjectXSpeed
		sta ObjectX

MoveY:													; move object vertically, clamping within screen
		lda P1_HELD										; up
		and #BUTTON_UP
		beq +
		
		lda ObjectY										; don't move if at top edge
		beq +
		
		lda #$ff										; otherwise set Y speed to -1
		sta ObjectYSpeed
		
+
		lda P1_HELD										; down
		and #BUTTON_DOWN
		beq +
		
		lda ObjectY										; don't move if at bottom edge
		cmp #$e0
		bcs +
		
		lda #$01										; otherwise set Y speed to 1
		sta ObjectYSpeed

+
		lda ObjectY										; add Y speed to Y position
		clc
		adc ObjectYSpeed
		sta ObjectY
		
		rts

InitMemory:
		lda #$00
		tax
		
-
		sta $00,x										; clear $00~$f0
		inx
		cpx #$f1
		bne -
		
		ldx #$02										; clear RAM from $0200 (prevent OAM decay on reset)
		ldy #$07										; up to and including $0700
		jmp MemFill

InitNametables:
		lda #$20										; top-left
		jsr InitNametable
		lda #$24										; top-right

InitNametable:
		ldx #$00										; clear nametable & attributes for high address held in A
		ldy #$00
		jmp VRAMFill

TimerLogic:												; convert frame timer to hex chars
		lda FrameCount+1
		jsr NumToChars
		stx Frames
		sty Frames+1
		lda FrameCount
		jsr NumToChars
		stx Frames+2
		sty Frames+3
		rts

; AX+ TinyRand8
; https://codebase64.org/doku.php?id=base:ax_tinyrand8
Rand8:
	RAND_=$+1
		lda #35
		asl
	RAND=$+1
		eor #53
		sta RAND_
		adc RAND
		sta RAND
		rts

SetSeed:
		lda FrameCount
		and #217
		clc
		adc #<21263
		sta RAND
		lda FrameCount
		and #255-217
		adc #>21263
		sta RAND_
		rts

RNGLogic:
		ldx RAND
		lda P1_PRESSED									; seed RNG with frame count if Start pressed
		and #BUTTON_START
		beq +

		jsr SetSeed
		
+
		lda P1_PRESSED									; get RNG number if B pressed
		and #BUTTON_B
		beq +
		
		jsr Rand8
		tax
		
+
		txa
		jsr NumToChars
		stx RNG
		sty RNG+1
		rts


NumToChars:													; converts A into hex chars and puts them in X/Y
		pha
		and #$0f
		tay
		lda NybbleToChar,y
		sta temp
		pla
		lsr
		lsr
		lsr
		lsr
		tay
		lda NybbleToChar,y
		tax
		ldy temp
		rts

NybbleToChar:
	.db "0123456789ABCDEF"

SetBGMode:
		ldx BGMode										; BG mode 0 = palette + initial text, draw immediately
		bne +
		
		jsr DrawBG
		inc BGMode
		rts
		
+
		lda P1_PRESSED									; otherwise toggle BG modes 1/2 via A press
		and #BUTTON_A
		beq DrawBG										; skip toggle if not pressed
		
		lda DisplayToggle								; toggle BG mode and transfer to X
		eor #$01
		sta DisplayToggle
		tax
		inx

DrawBG:
		lda StructAddrsLo,x								; index into LUT and set Struct address in NMI handler
		sta Struct
		lda StructAddrsHi,x
		sta Struct+1
		
		lda #$01										; queue the VRAM transfer
		sta NeedDraw
		stx BGMode
+
		rts

StructAddrsLo:
	.db <BGData, <BlankData, <NumData
	
StructAddrsHi:
	.db >BGData, >BlankData, >NumData

BGData:													; VRAM transfer structure
Palettes:
	.db $3f, $00										; destination address (BIG endian)
	.db %00000000 | PaletteSize							; d7=increment mode (+1), d6=transfer mode (copy), length
	
PaletteData:
	.db $0f, $00, $10, $20
PaletteSize=$-PaletteData

TextData:
	.db $20, $87										; destination address (BIG endian)
	.db %00000000 | Text1Length							; d7=increment mode (+1), d6=transfer mode (copy), length
	
Chars1:
	.db "asm6f-fds-example"
Text1Length=$-Chars1

	.db $20, $a8										; destination address (BIG endian)
	.db %00000000 | Text2Length							; d7=increment mode (+1), d6=transfer mode (copy), length
	
Chars2:
	.db "by TakuikaNinja"
Text2Length=$-Chars2
	.db $ff												; terminator

BlankData:
	.db $20, $e9										; destination address (BIG endian)
	.db %01000000 | FramesLength						; d7=increment mode (+1), d6=transfer mode (fill), length
	.db " "
	.db $21, $09										; destination address (BIG endian)
	.db %01000000 | RNGLength						; d7=increment mode (+1), d6=transfer mode (fill), length
	.db " "
	.db $ff												; terminator

NumData:
	.db $20, $e9										; destination address (BIG endian)
	.db %00000000 | FramesLength						; d7=increment mode (+1), d6=transfer mode (copy), length
FramesChars:
	.db "Frames = "
Frames:
	.db "0000"
FramesLength=$-FramesChars

	.db $21, $09										; destination address (BIG endian)
	.db %00000000 | RNGLength							; d7=increment mode (+1), d6=transfer mode (copy), length
RNGChars:
	.db "Random =  "
RNG:
	.db "00"
RNGLength=$-RNGChars
	.db $ff												; terminator

.org NMI_1
	.dw NonMaskableInterrupt
	.dw NonMaskableInterrupt
	.dw Bypass											; default NMI vector
	.dw Reset
	.dw InterruptRequest
