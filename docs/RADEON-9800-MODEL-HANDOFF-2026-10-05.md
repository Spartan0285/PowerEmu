# Audio validation correction — 6 October 2026

User reports severe pops/distortion/slowdowns in Warcraft on the latest 9800 app. Audio is NOT fixed. Standalone firmware differs from bundled app firmware; standalone boot-command omits app secondary-CPU GPIO/startup properties. Requested `-smp 4` did not establish four online guest CPUs. Earlier FPS/tone measurements are standalone-only; do not claim matched active-SMP app validation. Read the correction at the top of `RADEON-9800-PERFORMANCE-HANDOFF-2026-10-06.md` before using older results. Next reproduce exact bundled firmware/boot-command on an overlay, verify active CPUs, and capture actual Warcraft music with aligned timing. UI open, no guest running at inspection; no user guest interrupted.

---

# Final checkpoint — 6 October 2026, partial CoreAudio playback

Supersedes earlier pending VM/build states below. See `RADEON-9800-PERFORMANCE-HANDOFF-2026-10-06.md` for a clean current continuation. All owned test QEMU guests are stopped; signed experimental app includes final row-fill, shader/cache/order changes, partial-period callback fix and opt-in diagnostics. Signature passes. Public app/original VM disks unchanged.

Latest Warcraft: 9200 **34.11 FPS**, 9800 **34.79 FPS**; both map movement/clean quit pass, original crash report unchanged. Pre-host settled tone windows: 9200 1.4–4.4% low, 9800 0–1.2%. Initial 9200 startup transient preserved separately. CoreAudio now consumes valid partial data and explicitly pads missing tail; total missing host playback time roughly unchanged. Native actual-callback stereo/order/wrap/bounds tests pass with sanitizers; old callback fails partial output. Do not claim audio fully fixed, desktop marks gone or Miles crash solved. Next: aligned virtual/wall clock and DMA/post-mix waveform tracing, then game audio lifecycle/SMP crash root cause and cursor/2D desktop marks.

---

# Latest checkpoint — 6 October 2026, audio-path diagnostics

This checkpoint supersedes earlier VM/build states below. Detailed current continuation: `RADEON-9800-PERFORMANCE-HANDOFF-2026-10-06.md`.

Signed experimental app includes the retained PM4 row-fill optimization and all prior cache/ordering changes; signature passes. Current 9200 ~33.74 FPS, 9800 ~33.49 FPS; tone low windows 2.0–5.2% vs 0–2.0%. Chess selection/movement passes with visible stray desktop marks; Miles crash remains unrooted. GPU-copy experiment was removed after zero workload copies. Public bundle/user disks unchanged.

The row-fill 9800 VM was stopped. Fresh **9200** diagnostic overlay `codex-wc9200-audiopath-oct06` uses QMP4955/HMP4953/SSH2309, same four CPUs/256 MB VRAM/CoreAudio. Launcher session 21497. New Screamer/CoreAudio opt-in counters compile successfully but are not in the signed app yet. No audio behavior change. Check actual game scene/process before capturing. Desktop no-CD app is one row below the ordinary Warcraft alias; initial launcher selected ordinary alias and displayed CD prompt, canceled before opening no-CD. Helpers copied to guest `/tmp`.

---

# Latest checkpoint — 6 October, final 9200 retry completed

Final-binary 9200 control: 31.80 FPS in the actual Chapter One map, 432,496 draws / 30.005 seconds. Warcraft PID 352 remained alive through FPS and tone measurement; crash report unchanged at 99,551 bytes / 10:13. Controlled tone interior windows: median amplitude 1363–1377, 2.2–5.4% low windows versus final 9800 0–1.8%. Some 9200 unit/control surfaces appear red or untextured; screenshot saved, baseline/regression cause not yet established. Disposable QEMU PID 40305 was stopped after capture; no test VM remains. Final experimental app is packaged and strict/deep code-signature verification passes. Read `RADEON-9800-PERFORMANCE-HANDOFF-2026-10-06.md` for the current handoff; older states below are superseded.

# Radeon 9800 continuation checkpoint — 5 October 2026

### Corrected 9200 control crashed — exclude its apparent FPS/tone result

- SameMilesPC0x0105118c crashon9200,thread7,inSS_merge→SS_stream_to_buffer→SoundManager callback. Latestcrash10:13:21 invalidaddress0x16fd54d0; original66446bytecrashloggrew99551. Saved`docs/evidence/r350-performance-2026-10-06/wc9200-miles-crash.log` anddialogPNG. This establishesoccurrenceonbothcards, **notrootcause**.
- Apparent29.83FPS/898draws was**desktopaftergamecrash**, andtonewasidle. Renamedtotmp`wc9200-finalcontrol-INVALID-desktop-rate.json` and`wc9200-finalcontrol-INVALID-idle-tone.wav`; DO NOTuseforgamecomparisons. Verifylivegame/screenshotbefore andafter allfuturebenchmarks.
- 9200postcrashdesktopalsohasstraymarks (`9200-final-current.png`) similarto9800. This suggestsasharedissue, notproofnewR350orderingcreatedit; stillneedbaselinecontrolledrepro. ReopenregularappaskedforCDbecauselauncherejectedvirtualdiscaftercrash. CancelledthenselectedNoCDwrapperbutclickeditsselectednametriggeredrenameediting; Esc/cmdOlaunch retryexec28619 currentlypending. Originaluserdiskunchanged(disposableoverlay). CurrentQEMUPID40305/session54900QMP4955/SSH2309. Needverified9200mapretry+FPS/tone, stoptestVMwhenfinished.
- Final9800appalreadybuilt/signedPASS latest34FPSbatch; Chesse2→e4/computerreplypassesbutdesktopstraylinesremain. UsernotifiedsameMilescrashseenonbothcardsandfailedcomparisonsdiscarded. Cleanhandoffupdated. No sourcechangesaftersuccessfulfinalbuild.


### Final 9800 performance build packaged — 9200 corrected control booting

- Latest compositor-order/frontendfogcachebatch33.959FPS (1019frames/30.006s),6.741µsMetalCPU/draw. `wc9800-compositororder-rate.json`; tone48.935s/helper10:01:29–10:02:17 active5smedians~1372–1380,0–1.8%lowwindows; greatlybetterthanbaseline butnotperfectallscenesclaim. Hero movement/cleanquit/Chessselectionandmove/computerreplypass; originalcrashlogunchanged. ThinstraylinesremainoutsideChess (`compositororder-chess-move.png`), retainingwindow_bypassCPUtexturewaitdidnotprovefix. Nextinvestigatecursor saveunder/linearbounds/sharedcopybaseline.
- ApprepackagedlatestsourcePASS (`r350-compositor-order-app-build.log`), strictdeepcodesignPASS, CP4PASS,diffcheckPASS. Currentartifact `/Users/adam/Developer/PowerEmu/build/PowerEmu 9800 Test.app` nowincludeslatest34FPSbatch, **do notclaimfullyrelease-ready/desktopnoregression**. No publicbuildchanges/commits/releases. Evidencecopiedtodocs/evidence/r350-performance-2026-10-06. Cleancontinuationfile `docs/RADEON-9800-PERFORMANCE-HANDOFF-2026-10-06.md` added; neweststatesupersedesolderappnotes.
- Own9800testquit. Fresh9200sameFINALbinary/MAX_READ1024controlbooting `codex-wc9200-finalcontrol-oct06`,QMP4955/SSH2309/HMP4953,session54900. Needmatched30sFPS+45stone/profile, quitgame→desktop/Chessinspectstraymarks, thenquitownQEMU sotheusercanlaunchtestappwithoutbackgroundguestcompetition. Prior9200controlMAX_READ64wasconfoundedbyknownregression—don'tuseforfinalcardcomparison. Userwasexplicitlyinformedcardhaschangedto9200.


### Capacity tone is nearly steady; conservative compositor ordering batch pending

-1024entry31.66FPS tone (`wc9800-readcapacity-tone.wav`,48.987s,helper09:52:38–09:53:26) active5–45s amplitudemedian~1377–1380, mostly0% low10mswindows, twointervals0.6%/0.8%, versus64entrynearzeroamplitude. Timeractivefirst~45mostly8–12ms; fullfilemax166msincludeslaterinactive/transition, notassertionaboutactiveinterval. This is boundedcleaner-audioevidence, notallgames/longsessionsguarantee. Read-before-overwriteguardretained andcapacityavoidedregression.
- Source**nextbatch**: frontendFPvalidationcache normalizesfogRGB/scale/offset becausecompilerusesuniformsanddoesnotemitthesevalues; perdrawbackendfinitevalidationstays. ConservativeoriginalCPUreadwaitretainedfor`window_bypass`compositor textures, whileprogrammableapplicationdirectviewsretainGPU-orderoptimization. This targets observedstraydesktoplines withoutweakeningchecks; **notyetlive-provenfix**. GPUAPIcommentupdatedread-before-overwritecontract. Build/diff/CPchecks session9625, log`r350-compositor-order-build.log`,`r350-compositor-order-pm4.log`.
- CurrentownVMPID38520/session97602 remainsOLD1024capacitybatch, gamehero movementexec13851 running; doNOTlabelitcompositor-orderbinary. Needfinishmovement, quitownVM, freshlatest9800map FPS/tone, quit/Chess/desktopvisualcheck (e2head1107,576/e4dest1107,493). Then9200matchedMAX_READ1024samebinarycontrol (prior9200MAX_READ64controlwasconfounded). Repackage/signappaftervalidation, currentlyappondiskWAR64/no-fog. Userupdatealreadyexplainedguardregressionandrestoration~32FPS; don'tclaimlatestbuildreadyyet.


### Capacity change restored most FPS; tone pending

- MAX_READ1024 latestsame-map measurement31.656FPS (950presentations/30.010s),7.132µsMetalCPU/draw, versus64entry21.33. This supportsread-tablepressure asregressionfactor; preservesread-before-overwriteguard. `wc9800-readcapacity-rate.json`. CurrentownPID38520/session97602,QMP4955/SSH2309, inmap45stoneexec57274 (helperstart09:52:38), finishthenanalyze. NativeallPASS (`r350-read-capacity-tests.log`), build/diffcheckPASS.
- **Important control caveat:**9200test17.16FPS/worstoneusedMAX_READ64 withnewWARguard, whereasfourthfast9800didnotyetincludeWARguard. It was sameconfig butnotidenticalsharedhazardbehavior. Userheard9200worse, butDONOTattributeitsolelyto9200orclaimunchangedpublic9200audioequallybad. Needretest9200withfinal1024tablematchedsamebinarybeforefinalcomparison.
- PotentialremainingearlyFPvalidationcachechurn: backendnormalizesfoguniformvaluesinkeybutfrontendr350_fp_validate stillusesexactfogRGB/scale/offset. Compiler nowsourceindependentofthosevalues, socannormalizefrontkeytoo(retainingperdrawbackendfinitevalidation/routingkeys). Notimplemented. Desktopstraylinesstillunresolved; couldconservativelyretainoldCPUtexturewaitforwindow_bypasscompositorwhilekeepingprogrammablegameviewsGPU-ordered, butmustvalidatecausallyratherthanblindlyclaimfix.
- CurrentappondiskstillWAR64/no-fogbatch; repackageonlyafterfinalboundedlivechecks. User9200followupaccepted; nexteligible2DMetalcopyoptimizationpotentialsharedbutdoNOTskipCPUbarriersorblindlyenableasync/SMPunsafeR350 path.


### Latest run REGRESSED — do not ship this batch yet

- Latestfoguniform+sharedread-before-overwritesafetybatch (MAX_READ64) measured21.33FPS/30.006s,640presentations; tone~0–30median/~43–66%lowwindows, timermaxusually24ms. This is worse thanfourth33.73FPS/mostlycleantone. `wc9800-foguniform-rate.json`, `wc9800-foguniform-tone.wav`. Do not claimnewbatch34FPS/cleanaudio. Likelyoverlyfrequentqueue splits from64entryreadtracking/overflow guard; needsmeasurement, notassumption.
- Desktop/Chess stillhasstrayonepixelhorizontal lines, differentpositionnownear913y (`foguniform-chess.png`). AddedWARguarddidNOTproveafix. Keepinvestigatinglinearbuffer/clip/aliasordering; do notpublishnoregressionclaim. Boardgray/piecesvisuallycorrect, latestmove/selectionnotyettestedafterthisbatch. Profile`wc9800-foguniform-host-sample.txt`started5sjustasquitwastriggered—mixedexitprofile, **notvalidpuremapprofile**. Avoidconcurrentprofile+quit in future.
- IncreasedMAX_READ64→1024 insharedsubmissiontracker asnextisolatedtest: retainsallCPUandGPUguards, avoidsoverflowcausingeverydrawsplitbeforeflush. Buildpending (`r350-read-capacity-build.log`). ExistingGPUtracking1024lookupcostbounded; needactualFPS/tone. CurrentownVM37822/session65677,QMP4955/SSH2309 isOLD64entrybinarynowChess. NextrestartownfreshVM latestcapacitybinary, mapFPS/tone beforeanyotherheavywork. AppondiskispreviousWAR64/no-fogbatch, **notready tohanduser**. Can fall backtofirstbatch19.8FPSvalidatedifnecessarybutdontdiscardgoodfourthfastcode.
- Usertoldlatestvalidationcaughtregressionandweareisolatingit. Accepted9200followupbaseline17.16FPS+worseaudio saved; no9200optimizationclaimed. Foguniformnative+CP4PASS; packconstants andshaderkeynormalizationcodebuilt. Needcheckpointbeforeusage limits, andkeeppersisting.


### 9200 matched control measured; switching back to latest 9800

- Currentsharedalias-safetybinary9200 matchedstaticChapterOne1680×1050 fourCPUs/256MB/coreaudio:17.161FPS (515presentations/30.010s), `wc9200-audiocontrol-rate.json`. **This is a control baseline, not a demonstrated 9200 optimization gain or regression**; old9200binarynotmatched yet. `9200-control-map.png` renders correctly. User heard worseaudio andaskedwhichGPU; answered9200, consistentwithtone.
- `wc9200-audiocontrol-tone.wav`49.371s/helper09:33:25–09:34:14: active5smedians~267–729 versusidle1379;28–41%10mswindowsbelowamplitude10. Four9800batch tonehadmostly1375–1380 and~0–1% exceptisolated775msstall. This establishesload-relatedaudiofailureexistsalso9200. Donotclaimsharedaudiocodefixed: screamerchangesdiagnostic-only.
- Profile `wc9200-audiocontrol-host-sample.txt` dominated synchronousGPU waits from **PM4 CPU2D blit accesses**, notonlytextureprep. Likely next9200 improvement: move eligible disjoint SRCCOPY bitblts fromCPUloop into sharedMetalqueue, withread/writealias/hazardtracking andCPUfallbackforoverlap/unsupportedROPs/endianformats/bounds; validatepixel-equivalence + presentationdirtyregions + Harmony. Do not merelyskip CPUbarriers. ExistingGPU2Dfastpath statusneedsinspectionbeforeimplementing. Asyncsnapshotpathseparate, do notenableblindly.
- 9200ownVMquit. Latest9800foguniform+read-before-overwritebatch booting `codex-wc9800-foguniform-oct06`, QMP4955/SSH2309/HMP4953 session65677. NeedFPS/tone, movement,quit/Chess/desktopstraylinecheck and repackage signedapp. Native/CPchecksPASS. Appondiskstillpreviousalias-safetybatchwithoutfoguniforms.


### Fog uniform batch compiled — current control still running previous binary

- Found fog scale/offset/RGB emitted as MSL literals. Warcraft lighting changes can thus create source/pipeline variants; this is a plausible source of stutters, **not yet a measured explanation of the isolated775ms stall**. Changed compiler to read host-only c[32] fogRGB and c[33].xy scale/offset, keeping32 guest constantvectors unchanged. Added `r300_fp_pack_constants`, bound34vectors in backend and native fixture helpers. Shader-source cache key normalizes only these dynamic values; fog enable/source/linkage stay in key. Backend rejects nonfinite enabled fog uniforms on every draw including cachehits. Draw staging snapshots expandeduniforms immutably.
- Native suitePASS (`r350-uniform-fog-final-tests.log`), including actual fog endpoint/half-fog/alpha tests and new twoqueueddraws changingfogred→blue withsamecachedshader, exactpixels, mutatedcallerfogbeforeflush, invalidNaN rejection. BuildPASS (`r350-uniform-fog-final-build.log`). Live latest9800pending.
- Current9200 owncontrol QMP4955/SSH2309 is previous alias-safety binary (fogbatchonly affectsR350 anyway). Menu/mapnavigationexec62624, matching1680×1050 fourCPU/coreaudio/256MB, will measure30sFPS then45stone. App packagedsignedalias-safetybatch andstrictverifyPASS (`r350-performance-final-app-build.log`), **does not yet include fog uniforms**. Need latest9800livechecks + repackage.


### Read-before-overwrite safety check / 9200 control underway

- Fourth batch Warcraft movement passes, no new crashlog (original66446bytes Oct5 21:54). Clean game quit; actual Chess grayboard/e2→e4/computerreply passes. Selection evidence and move saved `gpuordering-chess-selection.png`, `gpuordering-chess-move.png`. **Thin stray lines outside Chess observed on desktop/Finder after Warcraft. Do not claim desktop corruption solved.** Need distinguish legacy issue/new ordering regression, compare old batch/control and force redraw.
- Tone fourthbatch: capture48.063s, helperguest09:19:27–09:20:15. Active5s windows mostly amplitude~1375–1380 (idle1379), often0–1% low windows; one20–25s interval19.4% low. Timer log has isolated775147µs stall, otherwise mostly8–12ms; no clipping claim not remeasured. Sound substantially improved but occasionalstall remains. Profilewaiting reduced; no proof that isolated stall isshadercompile (needs timinginstrumentation). User subjective improvement supports this bounded result.
- Safety review found shared GPU alias tracking covered prior writes but not a texture read followed by a target overwrite when no prior writer existed. Added read epochs (CPU tracking persists across commits), checks currentbatch reads when `gpu_batch_conflict` has target key, conservative overflow taggedbyepoch. Both R200/R300 use sharedhelper. Added exact regression sample red source into secondtarget, then overwrite source green without CPU flush; oldtargetmustremainred. Native PASS, build/diffcheckPASS; latestnosplit suitepending. This may or may not explain straylines; do not claim causalfix yet.
- Own fourth9800 VMquit. Currentfreshsameconfig9200control booting `codex-wc9200-audiocontrol-oct06`, QMP4955/SSH2309/HMP4953, latestaliascheckbuild, noR350flags. Session48771. Apppackaginglatestsource underway session61689, log `r350-performance-final-app-build.log`. Need9200tone+FPS/profile; latest9800freshmap FPS/tone/quit/Chess/desktopvalidate; strictsignature; saveevidence and report remainingaudio limitations.


### GPU ordering live result

- Fourth batch now measured **33.73 FPS** in matched1680×1050 opening map (1012 presentedframes/30.001s), versusoriginal13.896 andsecond25.763. `wc9800-gpuordering-rate.json`; `gpuordering-map.png` renderscorrectly. User hearsbackgroundtestandsayssoundalreadybetter; thisisusefulsubjectiveevidence, notproofcleanaudio. Latesttonecaptureunderloadrunning. Userasks9200optimization/audioafter9800: explicitfollow-upscopeaccepted.
- No-splitnativeGPUfallbacksuitealsoPASS (`r350-gpu-texture-order-nosplit-tests.log`). CPU texture reads stillflush; onlyGPU-onlydirectviewpath avoidsCPUwait. Needmovement/Chess,9200matchedtonecontrol,latestapp packaging. CurrentownQEMUPID35386 / session89565; toneexec49497, profilenewsamplepending.


### GPU-only texture ordering batch — live validation pending

- User confirms the 9200 is smoother. Third shader-validation-cache batch measured 24.59 FPS (738 presentations / 30.008s), 6.15µs/draw: no demonstrated FPS improvement over second batch 25.76. Do not claim each optimization increased FPS. Tone capture `wc9800-passcache-tone.wav` still has gaps: in active early 5s intervals amplitude medians ~365–990 versus idle 1379; 12–25% windows below amplitude10. Guest tone start09:12:52/end09:13:40, total captured67.59s includes inactive lead/tail. Audio remains unresolved.
- Latest profile (`wc9800-passcache-host-sample.txt`) identifies synchronous CPU texture-read barrier at ppc_mac_gpu.c:8949 dominating GPU waits. It was called even for direct local textures, although no CPU reads occur and R300 backend already checks texture alias conflicts, splits batches, orders with shared events/queue, and registers pending reads/writes. Moved that barrier **after** the successful direct-view branch: retained for CPU staging, YUV conversion, captures, non-viewable resources. No BQL unlock, CPU-read barrier removal, hazard bypass or lower-quality rendering.
- Added native GPU regression: render solid color into local VRAM, sample it through another view into a second target **before any CPU flush**, then verify exact bytes. All Metal tests pass (`r350-gpu-texture-order-tests.log`, including pending alias test), build and CP4 reset checks pass (`r350-gpu-texture-order-build.log`, `r350-gpu-texture-order-pm4.log`), diffcheck passes.
- Current own disposable Tiger VM `codex-wc9800-gpuordering-oct06`, QMP4955/SSH2309/HMP4953, four CPUs/256MB VRAM/coreaudio/1680×1050, booting this fourth batch. Third VM deliberately quit. App bundle still first batch until live checks complete. Need matched ChapterOne FPS + tone, movement/quit/Chess; then 9200 same binary/config tone control; package/sign latest app. Preserve actual user VM and other sessions.

### Render-pass reuse measurement / final cache batch pending

- SecondbatchliveChapterOne/F1same1680×1050:30.004s,773presentedframes →25.763fps,432243draws,2.593536sCPU Metal submission →6.000µs/draw. `/tmp/pe9800/wc9800-passreuse-rate.json`; board/terrain/text/heroUI visuallyintact (`passreuse-map.png`). Native overlap-blending test added: two queuedred/green draws withmutatedcallerconstants, thirdpremultipliedblue framebuffer-fetchblendin samepass, then claimblitowner/flush verifiesexpectedcolorsandsentinel. AllnativeGPUtestsPASS (`r350-pass-blend-handoff-tests.log`), CP4PASS afterlatestbuild, diffcheckPASS.
- SoundManagerprecomputedtoneunderpassreuse improved butnotclean:1000Hz medians~378–721 inearlyactive5ssegments, ~26–33%10ms windowsbelowamplitude10, versusidle1379.3/~0%. Capture`wc9800-passreuse-tone.wav`; rawrecording lasts178s includinginactive tail, **do not summarizewholefile as45s tone**. Exacttoneactivewindow/end timingnotinstrumented; chooseactiveearlyintervals anddonotclaimprecisedropoutimprovementfromunmatchedmusic/recorddurations. Timermax~17–20mssteady, no50mscapdiscard/overflow. Audiofixstillunproven.
- New**thirdbatch** cacheforfront-endearlyFPvalidation:64exactsuccessfulprogrambytekeys, serializedbyexistingBQL, invalid/newstategoesthroughfullcompilerbeforetexture-bankindexing. Avoid65KB sourceallocation/regenerationeverydrawonhits. Diagnosticfinalsourcecompiledonlywhenenabled. Mac-onlyhelperguarded__APPLE__; backendexactvariantcache/resourcevalidationunchanged. BuildPASS, CP4PASS; livevalidationpending.
- CurrentownVM`app-codex-wc9800-passcache-oct06` bootingnewthirdbatchQMP4955/SSH2309. SecondbatchVMdeliberatelyquit. Need30s FPS+toneunderload (instrumentstart/end ifquantifying), thenactualmovement/quit/Chessregression and9200samebinarycontrol. **Signedappcurrentlyfirstbatchonly; repackageafterlatestlivechecks**. Alloriginaldisksunchanged, nobudget/permissionblock. Donotclaimsoundcleanyet.

### Follow-up measurements and next batch (08:49 host time)

- First optimization live staticChapterOne/F1 at1680×1050:30.007s,594presentedframes →19.795fps versus baseline13.896fps (~42% improvement).330012draws,3.187688s CPU Metal submission →9.659µs/draw versus47.805µs. `/tmp/pe9800/wc9800-optimized-rate.json`. FPS gain is less than CPU gain because latest hostprofile shows GPU waits inr350_read_barrier dominating. Scene renders correctly; game cleanlyquitto1680desktop.
- **Controlled SoundManager tone:** `/tmp/pe9800/pe-audio-tone.c` uses a completely precomputed45s stereo1000Hz buffer, CarbonSound ExtSoundHeader, no streaming callback. Compiledagainst10.4SDKonphysicalg4, copiedtoTiger/tmp. UnderWarcraft load, capture`wc9800-underload-tone.wav`has1000Hz amplitude medians~10–145 with40–65% of10ms windows belowamplitude10 (background gameaudio maycontribute). **Idle desktop identicaltone**`wc9800-idle-tone.wav`hasstable1000Hz amplitude1379.3 andnearzeroemptywindows across45.62s. This establishes load-related audio service failure with preparedsamples, not onlyMiles decode failure. Sampleclippingiszero; nominal44kframe/s/zero-underruncounters doNOTestablishcleansound. Timermaxinmap25–40ms, catchupdiscard0/ringoverflow0. UserVMmicrophone=false verified; bidirectionalDMA-budget concern therefore nottheactivecase.
- Second optimization implemented but live validation pending: keepR350direct Metalrenderpassopen acrossdraws withsamecommand/owner/color/depth/mirror attachments, closing foruploads,depthfresh/retarget,tileddepthcompute,stagedwork,flush/fence,andbackendhandoff. Addedgeneric`gpu_submit_buffer_for(end_pass)`ownershipclaim; bothR200sharedencodercreation sitesuseit, andR350usesitsown end callback. DoNOTjustunlockBQL: existingSMPsurface-corruptionguard isthereforareason. Nativequeuedconstants test also transitions toablit encoder onthe samecommand; allGPUtestsPASS, QEMUbuildPASS,diffcheckPASS.
- Latest own VM `app-codex-wc9800-passreuse-oct06`, QMP4955/SSH2309 booting4CPU/coreaudio/256MB latestsecondbatch. FirstoptimizedVM deliberatelyquit. Signedapp on disk currently includes**firstbatchonly** untilsecondbatchlivechecksandpackaging. Next: maprate,toneunderloadrepeat,same-guestWarcraft→Chess,9200handoff control. Native suiteincludesqueuedimmutableconstants/handofftest. Preserve allpriorcodeandoriginalVMdisks.

## Performance/audio follow-up — 6 October 2026 (in progress)

User confirms Chess/Warcraft graphics look correct; reports roughly7fps, heavily distorted/intermittent sound. User additionally confirms9200 is smoother. Prior test VMs were all quit at user request before this follow-up.

- Actual user disk now launchesWarcraft at **1680×1050**, not yesterday's1024×768. Current cold tests preserve that resolution,4CPU/coreaudio/256MB, fresh disposable overlays. No hidden resolution reduction or sound disable.
- Baseline host `sample` in real menu/map confirms substantial repeated FP/VP MSL translation in9800, plus Metal buffer/sampler allocation and empty upload encoders. Historical boot-only sample was not a game profile; use `/tmp/pe9800/wc9800-actual-menu-baseline-host-sample.txt` and `wc9800-map-baseline-host-sample.txt`.
- Baseline static ChapterOne/F1 scene:30.008s,417 presented frames →13.896fps;232948draws,11.136088s CPU Metal submission →47.805µs/draw. This is standalone QEMU; user's app reported~7fps, so do not equate environments. Existing perf.frames counts presentation after3D/flip, not vblank ticks (verified r200_perf_present).
- Changes: R300MetalContext exact full FP+VP byte-key cache for successfully validated MSL (bounded64), sampler cache by effective address/filter/anisotropy; direct draw vertices/constants use existing gpu_stage_alloc page lifetime tied to completed commands; skip empty blit encoders. Front-end retains early FP validation/bank-range gate, final diagnostic-only recompilation gated on traces. Backend explicitly validates texture-bank bounds before accessing instructions on cache misses. No barrier/fence/depth/bounds bypass.
- New real GPU queued-draw test mutates caller fragment constants after two queued left-red/right-green draws using same shader and checks both regions after flush. PASS; entire native suitePASS. QEMU buildPASS, CP4reset checksPASS, signed experimental app packagingPASS and strict deep signaturePASS. Latest bundle same `/Users/adam/Developer/PowerEmu/build/PowerEmu 9800 Test.app`. Optimized live comparison is pending, not yet a claimed FPS or audio fix.
- Added **diagnostic-only** Screamer timer-max-us, catchup-discarded, ring-overflow counters underexistingSCREAMER_DEBUG. Existing zero-underruns alone did not prove good sound. Audio device behaviour unchanged. Baseline HMP audio capture `/tmp/pe9800/wc9800-baseline.wav`191.38s, no clipped samples; this does not prove clean playback. `wavcapture PATH audiodev0 44100 16 2`, `stopcapture 0` (ID is audiodev0 from -audio, not#default).
- Current own optimized VM `app-codex-wc9800-perf-optimized-oct06`, QMP4955/SSH2309/PID32767 running new binary and navigatingChapterOne. BaselineVM intentionally quit. Harness **PE_HOLD=1 required** to keepexecchildalive for profiling; earlier no-hold attempt ended, no host crash report. Helpers need recopy to guest /tmp on each new overlay. Current audio log`/tmp/pe9800/wc9800-optimized-audio.log`; disablelognoneafterboundedcapture.
- Measurement helper`/tmp/pe9800/qmp-perf-rate.py PORT SECONDS OUT.json` records wall interval, presentedFPS, submissionµs/draw and rejection/IB deltas. Next: optimize/static scene30s comparison, audio timing/rawcapture, movement/quit/Chess regression, save results. Sampler/shader/buffer tests alreadypass; no further changes require repeated broad tests unless failure/new work.

## Objective and current result

Finish Tiger Chess (gray background and piece-selection lighting) and Warcraft III on the experimental 9800, using the working 9200 as the control. The user explicitly authorized launching Warcraft through the No-CD application on the guest desktop.

**The 9800 is NOT ready: the user's real-settings Warcraft map crash has now been reproduced. Warcraft four-CPU stability remains unresolved. Menu/campaign font corruption is now fixed; actual native Chess supports the strong spotlight. Earlier no-audio/128 MB runs do not establish stability with the user's 256 MB/coreaudio settings.**

- **Comparison switch implemented:** experimental app Display tab now selects Radeon 9200 or Radeon 9800 Pro per VM. Stop/shut down before changing; saved/sleeping machines disable the choice. Public builds still always use 9200. Swift release build and signed experimental packaging pass. App: `/Users/adam/Developer/PowerEmu/build/PowerEmu 9800 Test.app` (latest signed build now includes AGP glyph-alpha fix).
- **Warcraft real-settings crash reproduced:** actual user Tiger disk backing a disposable overlay, 256 MB VRAM, 4 CPUs, coreaudio, 1024×768 game resolution. Chapter One loads and enters its introductory scene; subsequent click tests crash. New report `/tmp/pe9800/user-reproduced-warcraft-crash.txt` at 22:14:02, PID223, Thread6, fault0x16d91940, PC0x0105118c. User's prior report has same PC with fault0x2. Captured process code identifies this instruction as `sthbrx r0,0,r6`, an output store in the Miles decoder/mixer. This localizes the failure, but does not establish the underlying cause. Do not call disabling sound a fix. Matched9200/coreaudio/256 MB control survived the initial gameplay commands.
- **Chess visual mismatch confirmed:** saved 9200 selection reference is much softer than current 9800's bright yellow board patch. Found missing GA_ROUND_MODE vertex-colour clamp (0x428c bits4/5). Implemented clamping only colour varyings before interpolation, retaining full-range texture coordinates and independently selecting RGB/alpha extended range. Native Metal tests pass for ordinary and separate extended clamps; QEMU builds. Guest patch still bright; native actual Chess now supports this appearance.
- **Warcraft menu/campaign text fixed:** AGP client-storage payloads were incorrectly treated as CPU-aperture-swapped local VRAM. The extra reversal put smooth glyph alpha into blue and white blue into opaque alpha, causing jagged yellow text and apparent font-face changes. AGP now uses declared texture byte order directly; local VRAM and existing Chess byte-addressed texture exception preserved. Actual main/campaign menus now match thin antialiased9200 lettering. No forced filtering/font replacement.
- Existing direct-VRAM, AA resolve barriers, CMASK/ZMASK, fog and movie fixes remain experimental. Actual MSAA coverage and native stencil export remain incomplete.

Newest successful evidence lives in `/Users/adam/Developer/PowerEmu/docs/evidence/r350-2026-10-05/`: `chess-9800-direct-selection-lighting.png`, `chess-9800-direct-e2-e4.png`, `chess-9800-direct-newgame-reset.png`, `wc3-9800-direct-cinematic.png`, `wc3-9800-direct-right-click-movement.png`.

### Reproduce the tested configuration

Use the existing Tiger boot command and latest `build-r350/qemu-system-ppc64-unsigned`, with environment `POWEREMU_R350_TILED_DEPTH=1 POWEREMU_R350_FOG=1` and device:

```text
ppc-mac-r350-probe,id=gpu0,vgamem_mb=128,x-r350-bridge-aic=on,x-r350-linear-render=on,x-r350-decode-rs=on,x-r350-direct-vram=on
```

`POWEREMU_R350_POINT=1 POWEREMU_R350_IBLOST=1` are optional diagnostics used for evidence, not rendering requirements. Preserve the original guest disk; current tests use disposable qcow2 overlays. Do not hide Movies, disable depth/stencil or force per-pass clears to disguise failures.

### Latest repeated-map validation (23:35 host time)

- Fixed-AGP build, actual user Tiger disk on disposable overlay, four CPUs/coreaudio/256 MB: two Chapter One loads and repeated F1/right-click hero movement pass. Clean mission exits report actual game elapsed 6:15 and 4:41. PID228 remains alive; no new crash report (original21:54,66446bytes). Evidence `wc3-9800-fourcpu-agp-alpha-second-map-movement.png`. This is bounded stability evidence, **not a demonstrated fix for the earlier Miles invalid-pointer crash**.
- Actual Thrall’s Vision movie plays after those two maps, Esc returns to campaign. Evidence `wc3-9800-fourcpu-agp-alpha-cinematic.png` and `wc3-9800-fourcpu-agp-alpha-cinematic-return.png`. Third movie-to-map transition also passes: loading-screen click, introductory scene, Esc, F1 hero selection and three actual right-click moves. Evidence `wc3-9800-fourcpu-agp-alpha-postmovie-map-movement.png`; PID228 remains alive and crash log unchanged. Own QMP4955/SSH2309 paused after capture, available for continuation. Coreaudio counters captured and logging disabled with `log none`.
- Latest signed experimental app includes precomputed texture byte lanes (per texture, avoiding new per-pixel helper calls). Native GPU suite rerun after that refactor PASS (`agp-alpha-final-metal-regression.log`), includes captured glyph alpha/local aperture fixtures, direct texture/depth/barrier tests. CP reset4checks PASS, QEMU/app builds PASS, strict deep code signature verification PASS, both repo diffchecks PASS.
- Static crash-code inspection additionally finds allocation base at decoder state+0x2070 is cleared in close routine0x10524fc after likely free call0x10524f0. Offset+0x2074 resets between stream blocks. This motivates lifecycle/reentrancy investigation **if the fault recurs**, but does not prove an application use-after-free or emulator SMP fault. No game patch, audio disable or CPU cap applied.

### Post-fix validation (23:18 host time)

- Newest4CPU/coreaudio/256 MB/1024×768 user-disk overlay reached ChapterOne, continued from loading screen, skipped intro, selected hero and issued repeated right-click movement commands. PID228 still alive after8:52 process CPU time, crash log still original21:54 file66446bytes. In-game quest descriptions, hero stats and menus now clear antialiased text; evidence `wc3-9800-fourcpu-agp-alpha-map.png`, `wc3-9800-fourcpu-agp-alpha-movement.png`. **Do not claim Miles crash root cause solved from one passing run.** Earlier same-PC faults remain unexplained; longer/repeated map/sound transitions needed. Current own4CPU VM QMP4955/SSH2309 still running further movement tests.
- Enabled HMP `logfile /tmp/pe9800/fourcpu-font-audio-debug.log`, `log guest_errors` to expose SCREAMER_DEBUG counters. DMA pulls44kframes/s and host writes43–45kframes/s, queued~5.5–6k, observed underruns0. This confirms backend is draining audio rather than merely selecting coreaudio. Silent-frame counters often high from this scene, not a claim about subjective sound quality. Disable `log none` after capture to bound output.
- One-CPU/noaudio corrected-texture VM successfully quitWarcraft withCmd-Q/x, returned1680×1050, launched actual installedChess (`open -a Chess` overSSH **does work in this current Tiger clone**). Full gray board, e2-pawn selection spot, e2→e4 and computer e7→e5 reply all pass. Saved `chess-9800-agp-fix-after-warcraft-selection.png` and `chess-9800-agp-fix-after-warcraft-e2-e4.png`. This VM QMP4965/SSH2319 now paused. Fonts and wood/piece colors remain correct. NativeR3xx selection reference supports current bright patch; no intensity/tint workaround added.
- Signed experimental app rebuilt, `codesign --verify --deep --strict` passes. User test artifact `/Users/adam/Developer/PowerEmu/build/PowerEmu 9800 Test.app`, DisplaytabGraphicscard selector, shut down before switching9200/9800. Public build remains9200. Latest nativeGPU suite includes new byte-order regressionPASS, CP4checkPASS, QEMUbuildPASS, repo diffchecksPASS. No commits/release yet.

### AGP font fix confirmed (23:13 host time)

- Actual raw glyph atlas `/tmp/pe9800/ui-campaign-vram.bin` at0x898000: texels `[ff ff ff coverage]`, coverage spans0..255. Mistaken big-endian interpretation gave alpha only0/255 and blue=coverage. Decoded misinterpretation saved `wc3-9800-font-coverage-misread-as-blue.png`. Main glyph samplers actually use **nearest**0x0a12; earlier0x3400 measurements were background sprites, not evidence about glyph filtering. The text defect was byte order, not filtering or a changed application font.
- `r350_linear_draw`: only **local CPU-aperture VRAM** composes missing reversal. Non-local AGP bytes now retain declared component order; YUV decoding and direct local sampling unchanged. GPU-copy-created font atlas now receives correct alpha. Signed comparison bundle rebuilt successfully with fix.
- Evidence `wc3-9800-agp-alpha-menu-fixed.png` and `wc3-9800-agp-alpha-campaign-fixed.png` confirms thin smooth lettering, normal gray/white descriptions and smooth yellow headings at1024×768. Background/menu decorations remain correctly colored. No cosmetic color/sampling workaround.
- Added production helper `r300_texture_byte_lane` in r300_data.c/h and regression fixtures: captured transparent white glyph, alpha32 white glyph, non-grayBGRA pixel, all four declared swaps and corresponding CPU-aperture local encoding. Fixtures use fixed wire bytes, not the production helper to generate expected inputs. Initial test build variable-name collision fixed; latest nativeGPU suite passes, CP4 checks pass, QEMU build and signed app packaging pass.
- New four-CPU/coreaudio/256 MB regression VM QMP4955/SSH2309 (`app-codex-user-agpfont9800-fourcpu`) is navigating to ChapterOne with fixed fonts. Old paused Chess pipeline VM was intentionally quit to free those ports; capture evidence remains saved. One-CPU/no-audio font test QMP4965/SSH2319 (`app-codex-user-agpfont9800`) runs corrected campaign menu. Older2CPU/coreaudio map QMP4935/SSH2299 is paused, old binary/font path, survived repeated movement, CPU time14:19, no fresh report.
- Physical `g4` nativeWarcraft tracing attempt did not reach a window or produce GL captures. Diagnostic wrappers only, no native game reference established. Own process quit, no image mounted in hdiutil info; native Chess evidence valid but hostOS is10.5.9, notTiger.

### Latest controls and live state (22:59 host time)

- **Actual native Chess, not only the simplified fixture:** a disposable copy `/tmp/ChessNativeTrace.app` on `ssh g4` (actually Sorbet Leopard10.5.9, verified sw_vers; compiled against10.4 SDK) captured real OpenGL back-buffer pixels before `CGLFlushDrawable`. Original application preserved. Native e2 selection produces the same conspicuous warm bright board patch as the emulated9800. Evidence `chess-native-r3xx-unselected.png` and `chess-native-r3xx-e2-selection.png`. Native frame611×556 versus guest640×583, so this is qualitative scene parity, not pixel-identical validation. Physical System Profiler identifies Mobility Radeon9700 (ATY,RV360M11); OpenGL renderer string reports ATI Radeon9600 XT OpenGL Engine. This is a physical R3xx reference, not a real9200. Do not weaken/tint9800 lighting to match an under-lit9200 control without further evidence. Trace helper `/tmp/pe9800/pe-native-chess-capture.c` wraps flush and reads RGBA, maximum16 captures. Physical display asleep; ordinary screenshots were black, so use GL readback. Native diagnostic Chess was quit after capture.
- Earlier offscreen fixture with actual Chess light/material values also produced bright selected-square pixels197→255, GL errors0. Saved `chess-spotlight-native-9600xt-offscreen.png` is simplified fixture evidence only.
- **CPU controls:**9200/coreaudio/256 MB/4 CPUs survives initial map interaction;9800/coreaudio/256 MB/1 CPU survives; newly9800/coreaudio/256 MB/**2 CPUs** survives loading, intro skip, pawn/hero selection and repeated right-click movement, process CPU time14:19, no new crash report beyond original21:54 record. This is bounded testing, not proof of long-run stability or a four-CPU fix. Four-CPU TCG thread=single did not reach usable GUI/SSH, inconclusive.
- Current map VM `app-codex-user-tiger9800-twocpu` QMP4935/SSH2299 is paused after the successful2CPU interaction. Current Chess9800 shader VM `app-codex-chess9800-pipeline` QMP4955/SSH2309 remains paused. Earlier9200 control intentionally quit.
- Current font diagnostic `app-codex-user-ui9800-ortho` QMP4965/SSH2319 is booting a1CPU/no-audio disposable overlay. Previous font diagnostic iterations intentionally quit. Guest SSH helper now accepts same verified Tiger key on2319 via `/tmp/pe9800/control-known-hosts`.
- Added bounded runtime `POWEREMU_R350_UI_TRACE`: captures up to32 orthographic/bypass shader+texture combinations, versus6 shader pairs for ordinary `POWEREMU_R350_PIPELINE_TRACE`. It includes RS/GB/VTE/PVS registers, shader source, constants, first-six vertex attributes and texture filters/formats/offsets. Reset budget by toggling flag off/on through HMP trace property. Initial short-shader/depth filters missed actual Warcraft UI: its fixed-function lighting shader is reused for UI, so filter projection W row(0,0,0,1), not shader length. Texture offset is part of UI dedup key. Last full unfiltered capture contains13 distinct shaders `/tmp/pe9800/app-codex-user-ui9800-all/qemu.log` but skipped UI using same shader with different textures/constants. RawVRAM `/tmp/pe9800/ui-font-vram.bin` from that prior run.
- GA_ROUND_MODE colour-clamp correctness fix passes native tests and remains in latest binary; it did not remove the bright patch, now supported by actual native Chess capture.
- Historical same1024×768 campaign menu showed thin9200 versus apparently bold serif9800 text. **Superseded by AGP glyph-alpha fix above**: altered channels/coverage caused this apparent font difference. Corrected font samples now match9200 qualitatively.
- Latest signed experimental bundle includes switch/clamp and AGP glyph-alpha fix; repack passed. Public build stays9200-only.

### Remaining next steps

1. Fixed-AGP in-game UI, actual movie playback/skip, three four-CPU map loads with click/movement, and Chess reopen/moves now pass. Font source corruption causally verified and fixed; do not replace fonts or force filtering. Longer mission/combat and additional cold starts remain useful; no guarantee of intermittent Miles crash resolution.
2. Diagnose four-CPU Miles PCM pointer failure: captured code `/tmp/pe9800/miles-user-code.bin`, faultPC0x105118c is`sthbrx r0,0,r6`. Caller0x104c830..c8a0 computes output pointer from decoder state+0x2070/base and+0x2074/offset. One/2CPU passes suggest timing/SMP; underlying source still unproved. Do not silently disable sound or force1CPU as a fix.
3. Repackage signed experimental app and repeat appropriate GPU/CP checks after substantive changes. Selector Displaytab9200/9800: shut down, change, cold start. App UI interaction itself has not been tested. Preserve original user disk/apps and unrelated changes.

The appended investigation records below include rejected hypotheses and earlier failures. The current result above supersedes those historical states.

## Repository and build

- QEMU: `/Users/adam/Developer/poweremu-qemu`
- Branch: `release-0.3.3-rc`
- HEAD: `5dff14f1ca7bc5e4399ff0a69e4c34fa5f7626be`
- All changes from this investigation are **uncommitted**. Preserve and inspect them.
- PowerEmu documentation: `/Users/adam/Developer/PowerEmu/docs`
- Build: `ninja -C build-r350 qemu-system-ppc64 qemu-system-ppc64-unsigned`
- Graphics tests: `tests/poweremu/run-r300-metal-test.sh`
- Latest build and graphics tests passed; build has existing warnings.

Dirty files (17):

- `hw/display/ppc_mac_gpu.c`
- `hw/display/ppc_mac_gpu_r300_{fp,vp,metal}.{c,h,m}` (only existing files)
- `hw/display/ati_r350_pvs.{c,h}` and `ati_r350_pvs_glsl.c`
- `include/hw/display/ppc_mac_gpu.h`
- `hw/display/ppc_mac_gpu_r300_data.{c,h}`
- `tests/poweremu/r300-data-test.c`
- `tests/poweremu/r300-metal-test.m`
- `tests/poweremu/run-r300-metal-test.sh`
- `tests/poweremu/r350-pm4-reset-test.py`

## Implemented and measured

### Shader instructions

The Metal vertex translator now accepts:

- Dual math `ME_RECIP_FF` (opcode 7), zero input returns zero.
- Vector `VE_MAXIMUM` (opcode 7), component-wise maximum.
- Full math `ME_POWER_FUNC_FF_CLAMP_01` (opcode 15 / combined opcode 79): base <= 0 returns 0; base > 1 returns 1; otherwise pow(base, exponent). Reads source W and replicates its scalar result.
- Full math `ME_RECIP_FF` (combined opcode 71), including writes to alternate temporary destination kind 4.
- Writable alternate temporary destinations are bounded to 0–3. Existing alternate source storage has 20 slots.
- Full reciprocal decodes only its one real source. Validating the unused second source rejected Warcraft's partially defined temporary at instruction 51.

The new power operation is also implemented in the independent CPU PVS interpreter and GLSL translator. AMD documentation identifies its opcode and semantics; see `https://www.x.org/docs/AMD/old/R5xx_Acceleration_v1.5.pdf` (v1.1/v1.2 also contain it).

### Indexed geometry

`r350_linear_draw()` now decodes PM4 0x36 inline packed 16-bit indices into the AOS vertex arrays. Low halfword is the first index, high halfword the second. Each indexed element is fetched with the array's stride and checked through the existing GPU address translation.

Accepted indexed walk flags: 0x10 and 0x810. Warcraft's repeated menu text packets use e.g. `vf_cntl=00180014`, 24 indices, 13 words. Initially allowing only 0x810 rejected most menu text; accepting the measured 0x10 restored the labels.

`POWEREMU_R350_GEOMETRY=1` logs bounded rejected walk control words for future cases.

### Driver stall during mode switching

The full-screen transition temporarily writes `MC_AGP_LOCATION` to zero and then 0x80000000. Translating these literally lost queued command buffers and their scratch fences. `ppc_mac_gpu_agp_translate()` now uses the last valid aperture for these two transition images, in addition to the existing end-before-start fallback.

Measured results:

- Before zero fallback: 137 lost IBs, draws stopped at 3211, Warcraft alive but waiting in graphics driver.
- After zero fallback: animated menu reached, but 0x80000000 still produced losses.
- After also handling 0x80000000: latest clean run reports **ib_lost=0**, with continuing command and fence progress.

This remains an empirical transition fix. Review aperture lifecycle/reset semantics before broader deployment; do not generalize every invalid mapping into a fallback.

Scratch register support was extended from 0–5 to 0–7, including storage, reads, writes, writeback, and diagnostics. Warcraft currently uses reg0 for its fences, so this is completeness, not the main stall fix.

### Texture channel order

The major blue/white menu corruption came from applying Chess's special byte interpretation to Warcraft textures.

Both apps set macro+micro tile bits (`TX_OFFSET ...0c`), but:

- Chess: `TX_FORMAT1=0008860c`, identity R,G,B,A selection; raw uploads are RGBA.
- Warcraft: `TX_FORMAT1=0000a60c`, B,G,R,A selection; raw uploads are big-endian ARGB, e.g. `ff,1b,1d,1a`.

The `r350_rgba_tiled` direct-byte exception now requires identity swizzle (0,1,2,3), so Warcraft uses the normal ARGB byte conversion. This restored the red banner, orange Warcraft logo, dark metal menu frame, and natural terrain colors.

No physical detiling was added. Earlier committed investigation found these textures are stored linearly in this emulator. The old Chess handoff recommending further detiling is superseded by HEAD's linear-texture correction.

## Latest live run

Current disposable test: `app-codex-chess-shared-vram-read`, 9800 depth attachment plus full-VRAM CPU-read trace. Unified exec session30267. Warcraft `app-codex-wc-game-shaders` was stopped cleanly after successful movement validation. HMP localhost4933, QMP4935, SSH2299. Verify active QEMU PID before acting. Previous test overlays remain available; sleeping PE_HOLD harness processes are not live VMs. Use QMP quit for the identified test, never kill unrelated PowerEmu instances.

The earlier menu run `app-codex-wc-zmask-nomovies` reached 463,847 draws, `ib_lost=0`, six texture-translation rejections, one disabled texture unit, 3181 zero-size points, plus 3324 output-kind3 and 108 full-RSQ rejections once the mission loaded. The latter two now have production translator support and real GPU tests. Zero-size points still need review; do not replace them with arbitrary positive sizes.

## Reproduction harness

`/tmp/pe9800/app-qmp.sh` boots a fresh Tiger overlay, opens a folder in the guest console, type-selects an app, launches it, captures frames and reports counters.

```sh
cd /tmp/pe9800
PE_KEEP=1 PE_HOLD=1 PE_WAIT=140 \
PE_ENV='POWEREMU_R350_IBLOST=1 POWEREMU_R350_REGCENSUS=1 POWEREMU_R350_RT=1' \
./app-qmp.sh x-r350-decode-rs=on codex-wc-next \
  /Users/adam/Desktop 'warcraft iii roc' r350
```

Use exact type-select `warcraft iii roc`. **Do not set PE_PICK_DOWN**: that selects the DMG rather than `Warcraft III ROC [NoCD]`. The running process points to `/Applications/Warcraft III Folder/Warcraft III`; that is expected for the desktop launcher.

The harness itself is disposable and kills its previously configured test VM. Avoid concurrent tests on these ports. A current run reaches the menu well before 140 seconds after launch; the older 9200 control took about 420 seconds.

For Chess:

```sh
PE_KEEP=1 PE_HOLD=1 PE_WAIT=90 \
PE_ENV='POWEREMU_R350_RESOLVE_TEX=1 R350_UNDEC=1' \
./app-qmp.sh x-r350-decode-rs=on,x-r350-shader-snapshots=on \
  codex-chess-next /Applications chess r350
```

Guest read-only inspection works via:

```sh
ssh -p 2299 -i ~/.ssh/poweremu_guest -o IdentitiesOnly=yes -o BatchMode=yes \
  -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa \
  -o KexAlgorithms=+diffie-hellman-group14-sha1,diffie-hellman-group-exchange-sha1 \
  -o Ciphers=+aes128-cbc -o MACs=+hmac-sha1 adam@127.0.0.1
```

Do not use root; the configured guest key is for adam.

## Concrete next steps

1. Diagnose `invalid programmable point size` in Warcraft. `program_point` matches prim=1, color-only route, VTE=0x405. It currently uses fixed `RE_POINTSIZE` (0x421c) and rejects zero/out-of-range dimensions. Capture the point-size registers, vertex program outputs, relevant point state, and geometry before deciding whether these are programmable-size points, degenerate no-ops, or state decoding errors. Missing clear/point draws may explain accumulated rain and repeated geometry. Do not simply make zero size equal one.
2. Implement actual R350 fog after understanding the input source. Existing code only allows linear fog and deliberately omits blending. The 9200 control has dark green atmospheric sky; 9800 remains excessively bright. Registers are FG_FOG_BLEND 0x4bc0, FOG_FACTOR 0x4bc4, colors 0x4bc8/cc/d0. Establish whether the factor comes from a constant or interpolated vertex fog output. Extend the fragment/vertex interface and test the formula against documented hardware and the 9200 control.
3. Inspect remaining aliasing/texture filtering and depth/clear behavior. Do not assume all visual distortion is fog. Compare moving frames, not just one screenshot; the menu is animated.
4. Exercise actual Warcraft gameplay after the menu matches the control. Main menu success does not prove gameplay, texture format coverage, or stability.
5. Return to Chess: trace the resolved application surface into WindowServer and test piece selection with reliable guest input. See below.
6. Re-run meaningful graphics tests and build for every substantive fix; inspect `git diff --check`. Preserve evidence in docs/evidence and update this checkpoint.

## Chess: gray background fixed; selection lighting still open

Current Chess reproduces the board, pieces, and gray background with zero rejected draws (Tiger fresh-boot test `codex-chess-cmask`, 3099 draws). Screenshot: `docs/evidence/r350-2026-10-05/chess-9800-gray-cmask.png`.

VRAM dump from `/tmp/pe9800/chess-diag-vram.bin` showed:

- Scene source: 0x017f5000, pitch 2816 (704 pixels).
- Resolve destination: 0x00c3e000, pitch 2560 (640 pixels).
- Transparent background bytes: `00 00 00 00`.
- Board sample: `bf b8 97 65`.
- Source and resolved destination match byte-for-byte.

This suggests background/composition or clear semantics, not another channel permutation in the resolve. Gray in the 9200 control is RGB153. A draw near scene setup has color mask zero, followed by undecoded opcode 0x38 packets:

```text
R350_UNDEC op=0x38 dw=3 : 00000000 00000344 00000000
```

**Correction from a fresh chronological trace:** the prior sampling missed the register transition. Immediately before opcode 0x38, `RB3D_COLOR_CLEAR_VALUE` becomes `ff999999`, the exact gray expected. Opcode 0x38 is `3D_CLEAR_CMASK`. Mesa emits the same `(start=0, count=cmask_dwords, mask=0)` packet for a fast color clear. R350 has two raster pipes, with 32x16 pixels per CMASK dword. The observed count 836 describes a 704x608 padded allocation for the 704x583 active drawable.

Implemented `r350_clear_cmask()` in `hw/display/ppc_mac_gpu.c`: flush conflicting renderer work through the existing VRAM access barrier, then write big-endian ARGB clear pixels into the uncompressed linear target. Supports observed full clears only, rejects partial/nonzero status updates with a diagnostic, checks format, count coverage, dimensions and VRAM bounds. Materializes the active scissor height, avoiding writes into unproven allocation padding. Fresh VM log: `R350_CMASK clear target=017f5000 704x583 value=ff999999 blocks=836`. Background now visibly gray. Partial CMASK and real multisample/tile storage are not implemented.

Added opt-in `POWEREMU_R350_RESOLVE_TEX=1` diagnostic: records the last 16 resolved destination GPU addresses, then logs any texture sampling that exact surface, including dimensions, format, filtering, blend registers and target. **Now exercised:** the resolved window texture is sampled as RGB with alpha forced to 1 (`f1=0000aa0c`); this confirms the missing gray was scene-clear semantics, not transparent-window composition.

A QMP click was accepted but did not reliably select a pawn; selection highlight has not been validated. Verify guest mouse coordinates and use a before/after scene capture. Avoid claiming lighting fixed merely because all draws were accepted.

Chess controls/evidence:

- `docs/evidence/r350-2026-10-04/chess-reference-9200.png`
- `docs/evidence/r350-2026-10-04/chess-9800-complete.png` (filename overstates completeness; black background remains)
- `/tmp/pe9800/app-codex-chess-diag/selected-qmp.png`

## Test and code cleanup cautions

The standalone Metal test was previously broken by a stale blend field and a diagnostic interpreter linkage dependency. It now uses `blend_in_shader` with explicit factors and provides a diagnostic-only `r300_pvs_analyse` stub. Tests pass, but new opcode acceptance cases mainly verify translation acceptance; add numerical GPU coverage for power/reciprocal boundaries and output behavior as warranted.

Review stale comments in the translator and depth/stencil path: some still describe operations as refused although implementations were subsequently added. Remove obsolete experiment comments only after final behavior is verified.

The last-valid aperture workaround and texture-byte exception deserve targeted regression coverage, especially a 9200 smoke test and fresh Chess run. The latest changes have not been tested in Leopard or packaged into the PowerEmu application.

No commits, app release, or deployment performed.


## Later update: 9800 fast depth clear implemented

A fresh Warcraft trace disproves the handback's claim that the existing 0x32 handler clears the 9800 depth correctly. It used only R200 registers (`0x1c24/28`, `0x3230`) and filled CPU VRAM. The R350 Metal backend maintains a separate private depth/stencil texture that this handler never touched.

Measured Warcraft full fast clear: `start=0 count=0x7e0 mask=0 offset=0x007bc000 pitch=0x000d0480 depthclear=ffffffff bw=5 format=0`. Pitch is 1152 pixels, format 0 is 16-bit depth. These packets repeat every menu frame. The following zero-height point clear is rejected, so it does not compensate for the missing fast clear. Color mask zero says nothing about this depth operation.

Implemented `r350_clear_zmask()` and `r300_metal_clear_depth()` in the combined working tree. Full zero-status clears validate start/count coverage, format (Z16 or Z24S8), drawable dimensions and VRAM range. Metal clears the matching private attachment using the guest clear value; Z24S8 also updates stencil. Shared direct-VRAM submission is flushed before clearing through the separate renderer queue. Partial masks, compressed 13E3 depth, physical tiling, and automatic coherent depth readback into VRAM remain unsupported (a row-readback API is now available for diagnosis).

The graphics test runner now links the production R350 backend and shared submission layer. A new real GPU regression checks far/near/far depth clears against LESS drawing, stencil EQUAL visibility after clear, and preservation of stencil on a depth-only clear. All tests pass on Apple M5.

**Historical startup tests, superseded by the successful movie-bypass mission run below:** The preceding `codex-wc-cmask` run reached the menu (baseline screenshot `/tmp/pe9800/wc-before-depth.png`). Two subsequent fresh runs remained at startup before any ZMASK packet was submitted; one uses four CPUs and one one CPU. Thus this startup failure is not caused by executing the new clear. Investigate startup/fences separately, and do not call the full game fixed. Current single-CPU disposable harness: `/tmp/pe9800/app-qmp-onecpu.sh`, output `app-codex-wc-zmask-onecpu`; HMP4933, QMP4935, SSH2299. It enables `POWEREMU_R350_IBLOST=1`; `ib_lost=2` but no missing-address log, suggesting the two are zero-size/invalid-size submissions, not unreachable buffers. Guest SSH banner can stall too.

Chess gray-background screenshot is durable in `docs/evidence/r350-2026-10-05/chess-9800-gray-cmask.png`. Selection lighting still requires a validated interactive test. QMP tablet clicks in the harness do not reliably land at requested screen coordinates. A PPC diagnostic click helper exists at `/tmp/pe9800/pe-chess-input.c`, compiled on host `g4` with the 10.4u SDK; it can foreground Chess and post CoreGraphics clicks. SSH graphics calls report success but did not produce a scene redraw, so do not treat that as proof that lighting works or fails.


### Update: movie bypass reaches a substantially corrected Warcraft menu

The user suggested the Blizzard logo/opening cinematic could be the startup failure. A disposable overlay test renames `/Applications/Warcraft III Folder/Movies` to `Movies.codex-disabled` before launching the desktop No-CD app. This changes only the overlay, not the base image or user's VM. With four CPUs it reaches the live menu: 20,594 draws, `ib_lost=0`, 104 rejects (97 zero-height points, six texture translations, one disabled unit). New clear handler runs every scene frame without unsupported-clear/failure diagnostics. The sky is dark green and rain/geometry no longer accumulate into repeated bright streaks. Fog remains disabled; the dominant prior “fog/sky” symptom was stale depth. Durable screenshot: `docs/evidence/r350-2026-10-05/wc3-9800-depth-clear-menu.png`. Gameplay remains to be tested. Movie decoding/display remains a separate open fault; bypass is diagnostic, not a shipped fix.

### Chess selection lead from Apple's actual source

Apple's `Chess-103.0.3/Sources/MBCBoardViewMouse.mm`, `MBCUnProjector::UnProject()` reads one GL_FLOAT depth pixel using `glReadPixels(... GL_DEPTH_COMPONENT ...)`, then unprojects it to locate the clicked piece. This renderer explicitly does not mirror private depth back to guest VRAM. That can make picking fail even with a correct visual board. Confirm against the guest's exact Chess version and capture the depth-read command before claiming proof. Source: https://github.com/apple-oss-distributions/Chess/blob/Chess-103.0.3/Sources/MBCBoardViewMouse.mm . Local fetched source `/tmp/pe9800/apple-chess-103`. Next: implement coherent depth readback at guest depth-read boundaries (2D copy / texture read / CPU access as actually used), with Z16 vs Z24S8 packing and stencil preservation; avoid copying whole depth surfaces after every draw if a targeted readback can suffice.


### Latest continuation: real campaign and diagnostic depth readback

Relative HMP mouse input works: `mouse_set 2`, `mouse_move dx dy`, then `mouse_button 1`, **hold at least 0.4 seconds**, `mouse_button 0`. Immediate press/release can be missed. Guest acceleration means deltas are not screen pixels. QMP tablet absolute input was unreliable. A tiny Tiger PPC `GetGlobalMouse` helper at `/tmp/pe9800/pe-mouse-position` gives true coordinates over SSH (compile on g4 with 10.4u SDK and `-mmacosx-version-min=10.4`). The guest cursor image itself currently corrupts into horizontal artifacts, so use coordinates when validating Chess input.

Warcraft campaign navigation: main-menu `s`, then `c`; click Prologue (~890,290), Chapter One (~890,490), wait loading completion, press Return. The first mission starts and renders terrain, buildings, characters. Evidence `docs/evidence/r350-2026-10-05/wc3-9800-first-mission-before-shader-fix.png`. This is not a claim of correct full gameplay. Its shader census exposed output kind 3 (`OUT_REPL_X`) and full math opcode 73 (`ME_RECIP_SQRT_FF`). Implemented both in the production Metal VP translator: kind3 writes output lanes from value.x, full RSQ reads source W, uses abs(input), zero returns zero, one real source. Fixed scalar source-lane validation to require W, independent of destination write mask. Real GPU tests compare output replication, positive/negative/zero RSQ; all pass. Newly built binary includes these, but this screenshot predates them.

Added `r300_metal_read_depth()` to the production backend. It blits only overlapping rows from private Depth32Float_Stencil8 into shared buffers, converts to guest big-endian Z16 or Z24S8 (stencil in low byte). Real GPU test verifies row bounds, byte order, and stencil preservation. `R300MetalDraw.depth_format` now tracks the actual Z16/Z24S8 format. `POWEREMU_R350_DEPTH_READBACK=1` enables the 2D VRAM read hook and logs exported rows. With a confirmed relative mouse click at (827,611) on the e2 pawn, Chess did not redraw and the hook never ran; its depth read may access CPU-mapped VRAM directly.

Added **diagnostic-only** `POWEREMU_R350_DEPTH_MIRROR=1`: mirror the latest depth allocation before scratch-fence writeback, establishing a CPU-read baseline. Never enable it by default. Cached allocations can be repurposed for color; ownership/invalidation is still missing, and copying whole rows/surfaces at fences has a performance cost. Need live result before concluding this explains Chess selection. Current disposable run is `app-codex-chess-zmirror`, HMP4933/QMP4935/SSH2299, exec session47639. Fresh overlays only; the user VM/base is unchanged. Prior Warcraft overlay `app-codex-wc-zmask-nomovies` stopped cleanly through QMP.


**Negative Chess experiment:** broad latest-depth mirroring at scratch fences did not produce selection highlighting, and starting a new game corrupted the board/border. This demonstrates the buffer-reuse/ownership hazard described above. The `POWEREMU_R350_DEPTH_MIRROR` fence hook was removed from source immediately; it is not in the current build. Keep the bounded row-readback API/tests and opt-in 2D access hook for tracing, but neither is a proven selection fix. Confirmed menu mouse clicks work, excluding a completely broken button-input path. New-game corruption occurred only in the mirror diagnostic, not the original CMASK test. Next useful step: instrument the guest's actual `glReadPixels` call to capture depth values/format/location, and trace its driver read/copy route instead of assuming which cached allocation it reads.


Tiger guest reports **Chess version2.1 (Copyright2003–2004)**. The Apple103.0.3 source is not an exact version match, so its depth-read code is a lead, not proof. Prepared a PPC OpenGL interpose library `/tmp/pe9800/pe-gl-read-trace.dylib` (source `.c` alongside it, built on g4 with10.4u SDK). It logs actual `glReadPixels` dimensions/type/format and single-pixel GL_FLOAT depth to guest `/tmp/pe-gl-read-trace.log`. `/tmp/pe9800/app-qmp-chesstrace.sh` copies the installed Chess to `/tmp/chessdiag/ChessTrace.app` in a fresh overlay, wraps its original executable with DYLD_INSERT_LIBRARIES, and opens it through the console. Invoke with folder `/tmp/chessdiag`, pick `chesstrace`. Instrumented guest test has **not run yet**. This preserves installed Chess and the base image. Test interpose operation/recursion before trusting logged values.

Production Metal tests pass again, including an added full-RSQ → alternate-temp → output roundtrip. Latest build succeeds; source diff check passes. The movie folder contained `TutorialIn.mpq`, `TutorialOp.mpq`, campaign opening/ending MPQs (not loose .mov files), so isolate those and the embedded logo sequence before blaming one specific cinematic. Two fresh four-CPU movie-bypass runs reach menus; skipping movies is still only a diagnosis/workaround.


### Confirmed Warcraft gameplay with new shader support

`app-codex-wc-game-shaders` enters ChapterOne, renders the real-time opening sequence, dialogue portrait/text, then full gameplay UI and minimap. Left click selected Thrall, displaying his green selection ring, health/mana, stats and command icons. Right click moved him from about(410,550) to(600,400). Durable evidence:
- `docs/evidence/r350-2026-10-05/wc3-9800-mission-unit-selected.png`
- `docs/evidence/r350-2026-10-05/wc3-9800-mission-movement.png`

Measured around189,543draws: ib_lost0, texturetranslation9, disabledunit1, zero-sizepoints2234, primitiveassembly8. FullRSQ/output-kind3 failures are gone. Fog remains disabled, performance and image fidelity still need a 9200 mission comparison, and movie startup remains unfixed. This confirms basic gameplay, not campaign completion or release readiness.


### Actual Tiger Chess depth read confirmed

The instrumented guest library runs correctly. Clicking the e2 pawn produces `glReadPixels(x=352,y=183,w=1,h=1,format=0x1902,type=0x1406)` (GL_DEPTH_COMPONENT/GL_FLOAT), returning **0.0**. Variant2 logs `GL_DEPTH_BITS=24` and `glGetError()=0`, so this is a successful but incorrect depth result, not a rejected GL call. Reads outside the drawable return untouched stack bytes, as expected for clipping; ignore those. At full-screen guest coordinates(811,582), the local coordinates match exactly. This finally establishes that the depth-read route is required in the guest's actual Chess2.1, not just newer Apple source.

Current diagnostic `/tmp/pe9800/pe-depth-reads.dylib` traces bounded CPU reads from physical0x894b1000..0x89642000 (VRAMbase0x88000000+Chess depthoffset0x014b1000), with PC,VA,PA and size. Source `/tmp/pe9800/pe-depth-reads.c`, compiled against QEMU's plugin header and Homebrew glib headers. Launch harness `/tmp/pe9800/app-qmp-chesscpuread.sh`. This is external diagnosis; no plugin installed/shipped in PowerEmu. It should determine whether CPU accesses the depth allocation directly, or the driver copies it elsewhere before reading. Current source still has no broad depth mirroring.


CPU-read trace result: no reads from the known Chess private-Z allocation were observed on confirmed depth reads. The driver may copy/translate depth into an AGP/system-RAM staging buffer rather than directly reading the original VRAM allocation. Do **not** implement a general VRAM CPU-read trap on this evidence. Need trace the actual read/copy route. Started a 9200 instrumented control to determine whether its selection/depth read works, or this is a shared emulation gap not previously tested.


### 9200 selection control and GPU depth attachment experiment

9200 instrumented control works: same e2 pawn click `(local352,183)` returns **0.973698914** and visible selection lighting. At local(200,183) it returns0.975233316. Saved `docs/evidence/r350-2026-10-05/chess-9200-selection-lighting-control.png`. This validates input, guest tracing, and that the missing depth return is specific to our R350 path.

The actual R200 renderer now stores depth in guest VRAM through integer second color attachments and framebuffer fetch; old R300 comments claiming R200 still uses only private depth are stale. Implemented experimental **`POWEREMU_R350_SHARED_DEPTH=1`** in R350: fragment shader outputs integer depth into a second attachment over the precise guest Z allocation, while native Metal depth/stencil keeps testing/shadows. Mirrors passing depth writes only, big-endian Z16/Z24S8, preserves the guest stencil byte rather than claiming native stencil readback. Ensures shared GPU submission is initialized, checks ownership (`gpu_submit_vram.contents` == this device's VRAM), bounds, pitch/alignment; marks writes dirty. No copying of cached/reused allocations at fences. ZMASK full clears materialize guest depth as well under the flag.

Standalone real GPU tests verify Z16/Z24 mirror byte order and stencil-byte preservation; build/test passed. First live attempt rejected mirrors because shared submission was uninitialized; fixed by initializing it explicitly. Second live attempt renders a correct board, with no mirror rejections. VRAM dump `/tmp/pe9800/chess-shared-vram.bin` confirms Z data at0x014b1000: at(352,399) BE `f9448b00` ->0.97370219, close to the 9200 selected-pawn depth. **Chess still returns0**, so its driver reads/copies from a different location or aperture; exporting the expected original Z allocation alone does not fix it. Never enable this experiment by default yet. Native stencil-to-VRAM coherence is not complete.

Expanded external CPU-read plugin `/tmp/pe9800/pe-vram-reads.dylib` traces all physical VRAM reads0x88000000..0x90000000, bounded4000records, **only while host file `/tmp/pe9800/depth-read-enable` exists**. Create marker after board appears, before moving/clicking; avoid startup floods. Source `.c` alongside it. New harness `/tmp/pe9800/app-qmp-chessvramread.sh` uses this plus v2 guest GL trace. This should identify a secondary aperture/staging mapping; the narrower original-Z trace had no reads. Current build includes experimental depth attachment and materialized ZMASK clear, but default flags remain off. Broad fence mirror was removed. Need verify new-game redraw/private-depth clears, and discover actual glReadPixels read route before shipping any depth-read fix.

### Breakthrough: exact Chess CPU depth addressing, confirmed against four reads

The broad CPU trace identifies kernel kext byte reads at PC0x4796eb28. `kextstat` places ATIRadeon9700 at0x47935000; loaded text is shifted0x1000 from object text. This resolves to `ATIR300Surface::copy_from_buffer`'s byte loop at object0x38b28, calling `get_offset_of_sample_0`. Retrieved the guest's original kext to `/tmp/pe9800/ATIRadeon9700-Tiger`; disassembly `/tmp/pe9800/ATIRadeon9700-Tiger-dis.txt` from g4's otool.

**The depth surface is 2-sample AA, with sample-aware tile addressing.** Depthpitch0x001302c0 indicates pitch704, macro+micro tiling, dword endian swap. Driver sample-zero mapping with storage pitch1408 (=704×2), samples2, bpp4 predicts all observed physical addresses exactly:
- GL(352,183) -> native(352,399): VRAM0x016d18c8 (offset0x2208c8 from Zbase0x014b1000)
- GL(359,183):0x016d19ec (+0x124)
- GL(359,176):0x016dc9e4 (+0xaff8)
- GL(353,176):0x016dc8c4

This supersedes the staging-aperture hypothesis. Original linear Z export is correct numerically but wrong physically, so the driver reads zeros. Do not hardcode the clicked pixel. Implement bounded sample/tile layout export, preserve correct endian/depth packing, test adjacent coordinates and selection against9200. Current renderer still uses single-sample native Metal depth; duplicating it into guest sample slots can restore picking but is not faithful hardware multisample coverage.

### Two-sample export restores actual Chess picking; selection discovers SGE shader

Implemented opt-in `POWEREMU_R350_TILED_DEPTH=1`: for AA config1, depthpitch flags0x13, Z24S8 depth writes, a Metal compute encoder exports the **current** native depth attachment into the guest's sample/tile layout. Both samples receive the single-sample depth; stencil byte is preserved. No stale cached-depth fence copies and no CPU pixel readback. Bounds/ownership checked; default off. Current synchronous staging backend exports after each depth-writing draw; correctness first, batching/performance still needs work.

Real GPU tests check all64pixels in two4x8 blocks, both sample slots, BE Z24 packing, stencil preservation, neighboring guards, undersized-buffer rejection. Pass `/tmp/pe9800/tiled-depth-tests.log`.

Fresh Tiger `app-codex-chess-tiled-depth` confirms actual glReadPixels now returns **0.973702192** at pawn(352,183), 9200 control0.973698914; second point(200,183)0.975230515 vs control0.975233316. Selecting now triggers an actual redraw, but that redraw rejects808draws for vector opcode9 `VE_SET_GREATER_THAN_EQUAL`, exposing a previously unreachable lighting shader. Consequently board disappears to gray after selection; do not call selection visuals fixed yet. Added componentwise SGE Metal translation (0/1 results, equality true), matching existing independent CPU/GLSL interpreters and AMD guide. Added real GPU mixed-lane/equality tests. Fresh SGE live validation is next.

SGE fixes the first rejection; the same lighting program then exposes full math69 (`ME_POWER_FUNC_FF`5). Implemented signed-power semantics, including zero exponent, in Metal/CPU/GLSL. **Full instruction exponent is source C**, per AMD's explicit routing note; source B is unused and must not be validated. Tests exercise C routing with invalid unused B, signed negative base (negated through a temporary before explicit fragment saturation), and zero exponent. `/tmp/pe9800/tiled-sge-pow-tests.log` now passes completely; initial negative-base test incorrectly compared after fragment saturation and was corrected rather than changing opcode semantics.

Fresh `app-codex-chess-tiled-sge-pow` uses shader snapshots on failures to identify any further instruction instead of guessing. Exec session86823; HMP4933/QMP4935/SSH2299. Startup still in progress as of this update. Older harnesses are only sleeping after their QEMU instances were stopped.

Movie inspection of the actual guest: `Movies/TutorialIn.mpq` is RIFF AVI800×368,24fps, MPEG1Layer3 stereo44100Hz. Blizzard Video Support and Warcraft III are PPC PEF/CFM executables. No-CD launcher on Desktop is `Warcraft III ROC [NoCD].app`, its MacOS binary `Warcraft III (ROC)`.

### Selection lighting achieved; redraw clipping traced to screen-coordinate clear

With tiled export + SGE + full FF power, actual Chess shows bright lighting on selected e2 pawn, `r350_rejected=0`, `ib_lost=0`. Evidence `docs/evidence/r350-2026-10-05/chess-9800-selection-lighting-redraw-clipping.png`. However border/top pieces clip on redraw; do not declare complete yet.

Bounded CPU execution of the real point-clear vertex program found output position **(320,291.5,1,1)**, viewport scales **(1,1)**, VTE0x405, clipping disabled (VAP_CLIP_CNTL bit16). These are screen coordinates. Existing translation treats them as GL clip positions and rasterizes no clear; first-frame fresh depth hid this bug, while subsequent depth/stencil stayed stale. Added a narrowly decoded screen-position path for programmable points with exactly these declared viewport/clip conditions. Execute the actual shader, normalize XY against render target, preserve window-depth Z, expand full-window points against target dimensions, use a full target viewport. Real GPU production test starts with near depth, submits this masked-color programmable point clear, and proves the next LESS scene renders all64pixels. Pass `/tmp/pe9800/windowpoint-tests.log`; build passes `/tmp/pe9800/windowpoint-build.log`.

Fresh validation `app-codex-chess-windowclear`, exec session26211, is booting. It uses `/tmp/pe9800/app-qmp-chess-isolated.sh`, which no longer runs the global kill script, preserving the separate9200 control. Defaults still do not enable tiled depth export.

### Actual9200 movie-present control

Separate Tiger9200 instance `/tmp/pe9800/app-codex-wc9200-movies` runs unchanged Movies, reaches live main menu, campaign selection. Evidence `/tmp/pe9800/wc9200-movies-now.png`; 512718draws, ib_lost0, fence_written55787. This supports a9800 startup-path fault, though we did not observe a full cinematic playing during automatic startup. Exact video header is AVI `divx` stream / `BLZ0` compression (Blizzard Video Support PPC PEF). Control portsHMP4953/QMP4955/SSH2309, socket sock-wc-control; harness app-qmp-control-movie.sh, exec session26197. Host RSA key verified against existing pinnedTiger key; `/tmp/pe9800/control-known-hosts` for this port. Keep separate VM input ports straight. First campaign Prologue menu currently displayed.


## Latest live verification — Chess reset and Warcraft movie control

The latest build renders Chess selection lighting without board clipping, allows e2→e4 and the computer reply, and resets to a complete fresh board through Cmd-N/Start. Evidence: `chess-9800-selection-lighting-fixed.png`, `chess-9800-e2-e4-fixed.png`, `chess-9800-newgame-reset-fixed.png` in `docs/evidence/r350-2026-10-05`. This run used `POWEREMU_R350_TILED_DEPTH=1`, not the conflicting shared-depth experiment. No rejected draws or lost IBs were observed in the move run.

9200 control, all Movies present, entered Prologue/Cinematic/Thrall's Vision, switched briefly through desktop resolution, played the actual 800×600 letterboxed video, and returned to the 1152×870 campaign menu. The brief desktop transition is normal for this control. Guest process sampling shows `TaskMovie_priv` → `MediaMoviesTask` → `DecompressSequenceFrameWhen` → `DivXImageCodecDrawBand` → `decore_frame`. Evidence `wc3-9200-cinematic-control-frame1.png` shows actual video; frame2 is the returned menu, not a second movie frame.

Chess test VM stopped cleanly through QMP. New disposable 9800 game test: `/tmp/pe9800/app-codex-wc9800-movies`, HMP4933/QMP4935/SSH2299, no Movies renamed; isolated launcher `/tmp/pe9800/app-qmp-game-isolated.sh`. 9200 control remains HMP4953/QMP4955/SSH2309. Do not run the global kill helper while comparing these guests.


## Movie reproduction: actual new failure isolated

Latest 9800 starts successfully with all Movies present and reaches main menu (zero IB lost at that point). Explicitly entering Prologue/Thrall's Vision freezes during the 1152×870→1680×1050 transition, before 800×600 video mode. 132 IBs are lost. `MC_AGP_LOCATION=3f800000`, AIC range `3f800000-3e78769f`, control `44e8175c`: suspicious floating-point words, not merely the earlier zero/80000000 transient. Do NOT extend aperture fallback blindly; find the first bad register write/packet. Game process sample blocks in `SetSystemUIMode`→`_CGSSetProcessAttributes` waiting on WindowServer, not DivX decode.

Added bounded `R350_APERTURE_PKT`/`R350_APERTURE_WRITE` under existing `POWEREMU_R350_IBLOST`. New build passes, same 11 warnings. These log the packet boundary touching memory-controller/AIC registers and whether MC_AGP write came through PM4. Need restart disposable 9800 to capture the first corruption; current run predates the new diagnostics. Raw logs `/tmp/pe9800/app-codex-wc9800-movies/qemu.log`, sample `/tmp/pe9800/wc9800-cinematic-stall-sample.txt`. Durable images `wc3-9800-movies-present-menu.png`, `wc3-9800-cinematic-transition-stall.png`. 9200 VM is paused through HMP `stop` to free CPU; resume using `cont` on QMP4955 when comparison is needed.


## First corruption captured; PIO indirect continuation fix under test

New aperture diagnostics show shader-shaped data independently parsed as PM4: IB1005c420, size256, at65 header00d10041 starts an enormous low-register write; IB10034020,size256 starts with28000000 and becomes a truncated 10241-word register write, overwriting MC_AGP with80000000. This happens at game startup and was temporarily masked by last-aperture fallback. It strongly suggests an indirect fetch supplying data for an already-open PIO packet.

Implemented narrow R350 continuation handling: if a CPU-triggered IB fetch occurs while `pm4_pkt_count>0` and `g_in_pm4==0`, feed fetched words through the existing PIO packet state rather than starting an independent parser. No fake fence, no register-value blacklist. Logs `R350_IB_CONTINUE` with destination, remaining count and first word to confirm the interpretation. Build passes; live validation pending in `/tmp/pe9800/app-codex-wc9800-continuation` QMP4935/SSH2299. Prior diagnostic run stopped cleanly. The existing PIO FIFO already has16384 words. Do not implement unrelated Type1 changes until a real Type1 packet is observed; current Type1 handling is suspicious but unproven for this guest.


Continuation hypothesis rejected: zero `R350_IB_CONTINUE` hits while bad shader-shaped packets still occur. Removed that speculative code; retained bounded diagnostics only. Added `R350_IB_RAW` with the actual execute_ib argument (earlier APERTURE_PKT used the main cp_ib_base register and could misidentify a nested source), and Type1 packet logging. Build passes. Current test `/tmp/pe9800/app-codex-wc9800-raw` uses faster QMP inputs. Neither a PIO continuation fix nor a Type1 fix is validated.


## Command-processor control register defect found

Raw-IB logs confirm the actual GPU source10034020 begins28000000, entered from another PM4 stream (`g_in_pm4=1`), with no open PIO packet. No Type1 packets observed. A separate concrete defect: `R200_CP_ME_CNTL` was defined0x0086, while actual Radeon/guest9700 driver accesses0x07d0 (driver disassembly multiple `lwbrx/stwbrx` at7d0). Corrected macro to07d0. Added bounded ME-write logs and ME/CSQ state in `R350_IB_RAW`; pending live validation in `app-codex-wc9800-me`. Execution while halted/context restoration is a hypothesis, not yet proven. Do not re-add speculative PIO continuation.


ME register readback now verified through a separate, paused qtest machine: writing0x10000000 to physical BAR2+0x07d0 reads back unchanged; old address was incorrect. `/tmp/pe9800/pm4-mmio-test.py` bootless probe passes. Guest raw-IB corruption still occurs with ME=0, so halt-state is not established as this failure's cause. Added opt-in parent command-buffer capture `POWEREMU_R350_PM4_PARENT=/tmp/pe9800/movie-parent`. Current disposable run `app-codex-wc9800-parent` first boot hit a PMU/SMP preemption-level kernel panic before Radeon bring-up (not movie evidence); reset that VM through HMP system_reset. 9200 control remains paused.


## Reset regression reproduced and fixed

A bootless qtest reproduces stale execution: initialize a ring whose old commands write MC_AGP, set CP_CSQ_CNTL=0, set writable RPTR to2 with CP_RB_CNTL bit31, write WPTR2. Before the fix, MC_AGP changes to17ff1000 although the CP is disabled. After the fix it stays0, RPTR becomes2. Positive control enables bus-master mode4 and submits/wraps the ring: newly submitted commands execute and MC_AGP changes as intended. R300 soft-reset alias170c now clears CP queue pointers/parser state.

R350 reset changes: honor CP_CSQ_CNTL primary bus-master modes, honor CP_RB_RPTR_WR at071c when bit31 is enabled, avoid executing queued ring content during disabled pointer initialization, clear ring/PIO state on CP soft reset. Canonical RPTR_WR is in the already-serialized r300_shadow array; no VM state layout change. The corrected ME address07d0 applies to both cards; other reset behavior is scoped to R350.

Permanent test: `python3 tests/poweremu/r350-pm4-reset-test.py --qemu build-r350/qemu-system-ppc64-unsigned --firmware /tmp/pe9800/fw`. All four checks pass. Raw before/after `/tmp/pe9800/pm4-reset-before.txt`, `pm4-reset-positive.txt`.

Latest disposable run `app-codex-wc9800-ringreset`, QMP4935/SSH2299, reaches Warcraft main menu with Movies present, zero IB lost, and **zero R350_IB_RAW / APERTURE_PKT corruptions** so far (prior runs produced dozens). Parent captures now filtered to main IB fetches≥128 words: `/tmp/pe9800/movie-parent-reset-*.bin` are native little-endian uint32 dumps of CPU-decoded parent streams. First meaningful parent sends base10034020 size250(hex), not the erroneous size100(hex) seen in previous replay. Cinematic test pending.


## Cinematic transition passes after CP reset fix; movie texture unsupported

The ring-reset build enters Prologue/Thrall's Vision with Movies unchanged, switches through 1680×1050 to actual 800×600 playback mode, continues submitting/completing commands, and returns to the campaign menu. `ib_lost=0`, zero bogus `R350_IB_RAW`/`R350_APERTURE_PKT` packets. This is a real improvement over the prior WindowServer transition stall, but **the video does not render yet**: the 800×600 frame shows black letterbox bars with stale desktop/menu pixels in the movie rectangle. Rejection census adds `texture format, pitch, mipmaps or microtiling` during playback. Need the exact format before implementing decode; added bounded `R350_TEXTURE_REJECT` under existing IBLOST diagnostics. New run `app-codex-wc9800-texture`, QMP4935/SSH2299, booting. Screenshot `/tmp/pe9800/wc9800-reset-cinematic1.png` is failure evidence, not successful video. Bootless four-check regression passes again on this build.


## Actual movie format identified; bounded YVYU422 decode under live test

`R350_TEXTURE_REJECT`: f0=800b7b1f, f1=00453015, f2=0000033f, off=10146000. This is YVYU422 (format21), clamped YUV→RGB mode1, AGP client storage, 800×368, pitch832 pixels. Added `r300_yvyu422_decode` to existing R300 data helpers: U/Y0/V/Y1 byte groups, declared 4-byte swap, BT.601 video range, RGBA staging. Production decode is deliberately restricted to observed format21/mode1/non-tiled/even-width AGP resources; unsupported formats/conversion modes remain rejected. YUV channel selectors are ignored per AMD register guide. Native Metal sampling/blending is still used after staging.

Tests prove black/white/red, shared chroma, padded rows, all four byte permutations, buffer guards, invalid layout rejection. Full graphics suite passes `/tmp/pe9800/yvyu-tests.log`, build passes `/tmp/pe9800/yvyu-build.log`. Live test booting `app-codex-wc9800-video`, QMP4935/SSH2299. Playback success not yet established. New dirty files include `hw/display/ppc_mac_gpu_r300_data.c/.h` and `tests/poweremu/r300-data-test.c`.


## Actual 9800 cinematic playback verified

Fresh `app-codex-wc9800-video`, all Movies unchanged, entered Thrall's Vision and rendered moving 800×368 video letterboxed at 800×600. Two distinct successful frames (sunlit hillside, camera moving through grass) preserved as `wc3-9800-cinematic-yvyu-fixed-frame1.png` and `frame2.png` in `docs/evidence/r350-2026-10-05`. First frame was the normal fade-in black; do not diagnose that alone as failure. `R350_VIDEO_TEXTURE`: raw80,11,80,11 converts01,01,01,ff, correct near-black. After791 movie draws, ib_lost0; no texture-format rejection or bogus aperture packets. Return-to-menu/gameplay check in progress. CPU staging decoder is correctness work, not a video performance optimization.

Esc returned from the playing cinematic to the live 1152×870 Prologue menu. 2,259 movie draws completed, ib_lost0. Return screenshot `/tmp/pe9800/wc9800-video-return.png`. Entering Chapter One with movies still present is the next check.


## Chapter One loads; subsequent guest audio crash needs control

After movie playback/return, Chapter One loads to the normal map/Press Any Key screen (`/tmp/pe9800/wc9800-video-mission2.png`). Continuing crashes the guest game in **Thread6: Miles Carbon Library SS_merge/SS_stream_to_buffer/SS_fill → SoundManager/CoreAudio**, EXC_BAD_ACCESS at06dcf140, unnamed PEF PC0105118c. No bogus PM4/aperture packets were logged. Full guest crash `/tmp/pe9800/wc9800-after-video-crash-full.txt`. Do not declare gameplay after movies stable. Resume 9200 control on4955 to reproduce the same transition before attributing this to9800. New build adds live fog toggling via existing trace generation and bounded `POWEREMU_R350_FOG_VERTEX` CPU-VS output diagnostics; still default-off. Build `/tmp/pe9800/fog-vertex-build.log` passes, qtest four checks pass.

GPU probe is explicitly non-migratable: attempted savevm on the disposable test rejects with `State blocked by non-migratable device pci.2:0e.0/ppc-mac-r350-probe`. Do not try to evade this gate; native render caches are not serializable. Stopped previous9800 cleanly; fresh `app-codex-wc9800-fogtrace` booting with vertex diagnostics, QMP4935/SSH2299. 9200 control reached Chapter One loading screen and is being continued on4955.


## Fog endpoint inference corrected; latest build pending live validation

Live vertex diagnostic proves unfogged menu UI emits C1A=1 (fmt7, output2), GA scale=-1 offset1. Prior blend maps resulting zero to full black fog and visibly destroys UI. The earlier claim that disabled FG fog implies factor1/no-fog was unjustified: disabling bypasses blending and proves neither endpoint. Corrected linear blend to treat GA result as **fog amount** (zero preserves RGB, one reaches fog color), preserving alpha. AMD declares fog color (0.9) versus constant factor (0.10), so color scaling is corrected /512, previously /1024. Vertex fog linkage now reads alpha when written, without requiring unused RGB components. Still opt-in/default-off until actual visual comparison succeeds; do not call this hardware-validated from shader tests alone.

New real GPU endpoint/half-fog/alpha tests pass full suite `/tmp/pe9800/fog-amount-tests.log`; build `/tmp/pe9800/fog-amount-build.log` passes. Existing live `app-codex-wc9800-fogtrace` predates this new blend (old behavior confirmed black, turned off again). It is being used to repeat Chapter One **without explicit cinematic playback** first, to isolate the guest audio crash. 9200 control progressed through first in-engine scene without crashing and is paused again. Mesa primary-source driver copy disables hardware FG fog, so it does not settle this endpoint; current inference comes from actual guest VS output +9200 visual control.

Repeat9800 in `fogtrace`, no explicit Thrall's Vision playback, reaches the in-engine first mission scene with Movies present and no audio crash at that point. Screenshot `/tmp/pe9800/wc9800-fogtrace-game.png`. This suggests the previous failure may involve movie-skip/audio lifetime or be intermittent; not proven. Stopped old build cleanly. Latest `app-codex-wc9800-fogamount` booting with corrected fog enabled plus tiled depth (for later same-guest Chess regression). QMP4935/SSH2299.


Live corrected fog (`fogamount`) preserves main menu logo/panels/buttons and adds scene haze; runtime on/off capture confirms fog is being applied rather than silently disabled. Durable `wc3-9800-fog-amount-menu-fixed.png`. First mission with fog on is loading. Additional real GPU test links an alpha-only vertex output (o1.a, RGB unwritten) and verifies the resulting partial fog/unchanged alpha. Full suite passes `/tmp/pe9800/fog-alpha-tests.log`.


Corrected fog build reaches playable Chapter One after skipping the in-engine introductory scene with Esc. 104,294 draws, ib_lost0; rejection census consists of zero-size programmable points (1175), disabled texture (1), primitive assembly (6). No new texture/program rejects. Evidence `wc3-9800-fog-amount-first-mission.png`. This run did not explicitly play/skip Thrall's Vision before entering the mission, so it does not resolve the prior audio crash. Fog is still default-off pending wider validation.


## Baseline performance/input and subsequent checks

Staged first mission remains alive through192,511 draws with ib_lost0. F1 hero selection produces intact selection ring, portrait, inventory and stats. QMP mouse commands were unreliable after resolution changes; do not claim the latest movement screenshot proves movement (it captured a delayed Confirm Exit instead). Legacy earlier movement evidence is valid, but latest fog build movement still needs exact-click retest. Guest SSH5-second banner timeout fails under heavy3D;30-second timeout succeeds after quitting. This suggests scheduling/renderer load, not established network corruption.

Warcraft Cmd-Q opens Confirm Exit; `x` confirms after allowing enough time. Latest9800 returns to1680×1050 desktop and launches actual installed Chess (no trace-app wrapper), gray/full board intact. Tiled depth and corrected fog flags were enabled in this same guest. Chess selection regression pending. 9200 control now played and explicitly Esc-skipped Thrall's Vision, then re-entered Chapter One without an audio crash at the initial scene; do not blame the prior9800 audio crash on movie skipping generally without a repeat.

Direct VRAM is still default-off and cannot be toggled on a realized QEMU device (ordinary qdev property restriction). Code inspection found its texture-view swizzle missed the already-validated Chess identity RGBA exception; fixed that to match staged conversion. Build pending `/tmp/pe9800/direct-texture-order-build.log`. Direct path live validation remains pending, so do not enable it by default.


## Latest baseline Chess regression and direct-path preparation

Actual installed Chess after Warcraft exits passed gray background, e2-pawn selection lighting, e2–e4 and automatic computer e7–e6 reply with a complete uncorrupted board. Evidence `chess-9800-after-warcraft-selection.png` and `chess-9800-after-warcraft-e2-e4.png` in the existing evidence directory. This is the corrected fog/CP-reset/YUV build with tiled-depth enabled; no interposer.

Direct texture byte-order fix builds successfully (`/tmp/pe9800/direct-texture-order-build.log`); full GPU suite passes (`/tmp/pe9800/direct-rgba-tests.log`), including actual Metal identity RGBA texture-view round-trip. `git diff --check` passes. Stopped staged9800 through its own QMP. Fresh disposable `app-codex-wc9800-direct`, QMP4935/SSH2299, boots with `x-r350-direct-vram=on`, decode-rs, POINT/IBLOST/FOG/TILED_DEPTH flags. Native direct path remains default-off. Boot desktop intact; live Warcraft/movie/gameplay and Chess direct-path correctness/performance checks pending. 9200 control remains paused on4955.


## Direct Metal path: live menu and cinematic pass

Fresh direct9800 renders animated main menu and Prologue, plays actual Thrall’s Vision (including Blizzard Entertainment Presents title), and Esc returns to campaign without surface corruption or bogus PM4. All Movies remain present. Direct menu counters166,062 draws /12.129s cumulative draw submission (~73µs/draw), zero target staging bytes, ib_lost0. This is CPU submission time, **not measured FPS**; earlier staged run averaged roughly1.3ms/draw. Guest SSH remains responsive under3D. Latest410,120 draws /30.969s; zero target staging bytes. Remaining rejects are zero-size programmable points and disabled texture. Evidence `wc3-9800-direct-menu.png`, `wc3-9800-direct-cinematic.png`, `wc3-9800-direct-cinematic-return.png`. Chapter One after explicit movie skip now loading; audio stability not yet established. Bootless reset four checks pass latest binary again.


Direct9800 **explicit movie Esc skip → Chapter One → Press Any Key → in-engine Prophet introduction → Esc → playable mission → F1 hero selection passes**. Prior guest audio crash did not recur in this repeat; that does not prove an intermittent race fixed.1115500 draws, ib_lost0, cumulative draw submission65.115s (~58µs/draw), target staging bytes0. Hero portrait/inventory/stats, terrain, rain, selection circle intact. Evidence `wc3-9800-direct-gameplay-after-movie.png`. Screenshot comparison with9200 shows remaining text/AA and clock/shading differences; do not claim exact visual parity. Gameplay/mode transition fast path now established for this sample; same-guest Chess direct path still pending.


Exact guest CG right-click620,450 moves selected Thrall from~440,540 to~620,450 and produces movement tutorial hint. Evidence `wc3-9800-direct-right-click-movement.png`. The sun/moon clock becomes fully blue in this later frame, so earlier dark clock alone is not proof of persistent rendering error (it animates). Cmd-Q then x quitting to desktop now under test; do not infer silence on host proves working audio because this harness uses `-audio none`, identically for9200. Miles/SoundManager code still runs in the guest, and the earlier crash in that code was real.


## Direct Chess uncovered host crash; fix under test

Warcraft cleanly exits to1680×1050 desktop. Launching actual Chess with direct+TILED_DEPTH crashed QEMU (host EXC_BAD_ACCESS null at gpu_note_written, export_tiled_depth caller). Host crash report `/Users/adam/Library/Logs/DiagnosticReports/qemu-system-ppc64-unsigned-2026-10-05-191148.ips`. Cause: tiled compute export passed NULL identity to gpu_note_written; API requires non-null key. Fixed caller to supply explicit depth-buffer key with padded height, pitch×8, MTLPixelFormatInvalid, keeping tiled buffer representation distinct from all actual texture views. No change to shared submit API or9200 path.

New actual direct-render depth regression checks pending-write tracking, alias conflict, outside-range exclusion, flush completion and both depth samples’ endian/stencil bytes. First test attempt uncovered test fixture ARC releasing its borrowed queue; fixture now owns static queue/buffer for full process. GPU test retry pending `/tmp/pe9800/direct-depth-track-tests.log`; build passes `/tmp/pe9800/direct-depth-track-build.log`. Fresh `app-codex-chess9800-direct` booting latest fixed binary on4935/2299, actual installed Chess, no trace wrapper. Direct remains default-off; live Chess not yet validated.


## Direct Chess race identified at AA resolve

Null-key crash fixed and full GPU suite passes, including direct tiled-depth pending-range/flush regression. Latest fixed live Chess stays running but shows partial/missing pieces, varying across redraws. Zero shader/state rejection, gray background intact. Inspection finds r350_resolve_copy performs CPU memcpy of queued direct-render source without any range barrier; staged draws completed synchronously, masking this race. Added existing r200_vram_access read barrier over source rows and write barrier over destination rows before CPU copy, exactly like the established2D blit contract. Build passes `/tmp/pe9800/direct-resolve-barrier-build.log`; git diff check passes. Stopped own guest and booting fresh `app-codex-chess9800-resolvebarrier`, direct+FOG+TILED flags,4935/2299. Latest live full-board verification pending; do not promote direct defaults yet.


## Direct Chess AA resolve barrier verified

Fresh latest binary restores complete board/all pieces. Actual e2 pawn selection lighting, e2–e4 and computer e7–e6 reply pass without missing pieces or crash. Evidence `chess-9800-direct-full-board.png`, `chess-9800-direct-selection-lighting.png`, `chess-9800-direct-e2-e4.png`. Initial2,780 draws, r350_rejected0, ib_lost0, target staging bytes0,134.68ms cumulative submission (~48µs/draw; CPU enqueue time, not end-to-end frame time). New-game reset pending. This causally distinguishes prior partial-board race (no source barrier) from correctly synchronized resolve.


Direct new-game reset passes; full pieces/board restored,32,245 draws, zero rejected/ib_lost,27 successful AA resolves, zero target staging bytes. Latest fixed binary then quits Chess and launches Warcraft successfully in the same guest, with intact animated menu and cinematic fade/title. Final explicit movie-skip→mission repeat in progress, followed by returning to Chess to test resource reuse across resolution changes. This validates the current binary, not only the earlier direct build.


Latest resolve-barrier build passes **Chess → Warcraft → movie playback/explicit Esc → Chapter One introduction → Esc → F1 selected playable hero**, without guest or host crash. Second direct movie-skip→mission repeat now passes (first was pre-resolve-barrier build). Evidence `wc3-9800-latest-gameplay-after-chess-and-movie.png`. Returning to Chess in same guest now pending. Do not upgrade this to tested host audio output: harness -audio none is unchanged.


## Final same-guest switch regression complete

Latest binary passes Chess→Warcraft→actual movie→explicit Esc→Chapter One→playable F1 hero→clean quit→1680×1050 desktop→actual installed Chess. Reopened Chess renders full gray-background board and e2-pawn selection lighting correctly. Preserved `chess-9800-latest-after-warcraft-selection.png`. End counter986381 total draws, ib_lost0, zero target staging bytes; cumulative rejections include Warcraft zero-size points/primitive cases, not a new Chess rejection. No bogus PM4/aperture packets or texture format rejects. Test9800 now paused through its own QMP;9200 still paused. Graphics suite, bootless4-check CP regression, build and diff checks pass. Files remain uncommitted.

Next priorities are actual configured audio and longer movie/mission stability, exact AA/text/stencil fidelity, then integration of opt-ins into the experimental device. Public9800 exposure remains disabled. Do not claim production/release readiness or whole-game completion from Chapter One evidence.
